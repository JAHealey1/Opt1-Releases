import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class PuzzleDataCollectionController: NSObject {
    private let captureManager: ScreenCaptureManager
    private let snipOverlay: PuzzleSnipOverlayController
    private let onActiveChanged: (Bool) -> Void

    private var isActive = false
    private var config: PuzzleCollectionConfig?
    private var progress = PuzzleCollectionProgress()
    private var writer: DatasetWriter?
    private var snipResult: PuzzleSnipResult?

    private var controlPanel: NSPanel?
    private var statusLabel: NSTextField?
    private var phaseLabel: NSTextField?
    private var captureButton: NSButton?
    private var skipButton: NSButton?
    private var cancelButton: NSButton?

    private var puzzles: [PuzzleCollectionPuzzle] = []
    private var hintHotkeyMonitor: Any?
    private let hintHotkeyKeyCode: UInt16 = 20 // '3'
    private let hintHotkeyModifiers: NSEvent.ModifierFlags = [.option]

    init(
        captureManager: ScreenCaptureManager,
        snipOverlay: PuzzleSnipOverlayController,
        onActiveChanged: @escaping (Bool) -> Void
    ) {
        self.captureManager = captureManager
        self.snipOverlay = snipOverlay
        self.onActiveChanged = onActiveChanged
        super.init()
    }

    func start() async {
        guard !isActive else { return }
        guard let puzzles = loadPuzzleList(), !puzzles.isEmpty else {
            showError("Could not load puzzle manifest.")
            return
        }
        self.puzzles = puzzles

        guard let selected = promptForConfig(puzzles: puzzles) else { return }
        do {
            let writer = try DatasetWriter(config: selected)
            self.writer = writer
            self.config = selected
            self.progress = PuzzleCollectionProgress()
        } catch {
            showError("Could not initialize dataset writer: \(error.localizedDescription)")
            return
        }

        guard let rsWindow = try? await WindowFinder.findRuneScapeWindow() else {
            showError("RuneScape not found.")
            return
        }
        guard let shareable = try? await SCShareableContent.current else {
            showError("Could not read shareable content.")
            return
        }
        let snipFrame = rsWindow.appKitGlobalFrame(content: shareable)
        guard let snip = await snipOverlay.captureSelection(around: snipFrame) else {
            showError("Data collection cancelled: snip selection required.")
            return
        }
        if snip.cropInWindowNormalized.width < 0.05 || snip.cropInWindowNormalized.height < 0.05 {
            showError("Selected snip area is too small. Please select the full 5x5 puzzle region.")
            return
        }
        self.snipResult = snip

        setActive(true)
        if selected.hintTarget > 0 {
            registerHintHotkeyMonitor()
        }
        showControlPanel()
        updateLabels()
        bringAppToFront()
        updateLabels(status: "ROI captured. Shuffle puzzle, then click Capture Next.")
    }

    // MARK: - UI

    private func promptForConfig(puzzles: [PuzzleCollectionPuzzle]) -> PuzzleCollectionConfig? {
        final class AccessoryController: NSObject {
            let puzzles: [PuzzleCollectionPuzzle]
            let slidingDefaultOutput: URL
            let lockboxDefaultOutput: URL
            let puzzlePopup = NSPopUpButton(frame: NSRect(x: 0, y: 132, width: 420, height: 26))
            let scrambledField = NSTextField(string: "10")
            let hintField = NSTextField(string: "10")
            let pathField = NSTextField(string: "")
            let browseButton = NSButton(title: "Browse…", target: nil, action: nil)
            var outputURL: URL

            init(slidingDefaultOutput: URL, lockboxDefaultOutput: URL, puzzles: [PuzzleCollectionPuzzle]) {
                self.puzzles = puzzles
                self.slidingDefaultOutput = slidingDefaultOutput
                self.lockboxDefaultOutput = lockboxDefaultOutput
                self.outputURL = slidingDefaultOutput
                super.init()
                puzzlePopup.addItems(withTitles: puzzles.map(\.displayName))
                puzzlePopup.target = self
                puzzlePopup.action = #selector(puzzleSelectionChanged)
                scrambledField.frame = NSRect(x: 0, y: 82, width: 80, height: 24)
                hintField.frame = NSRect(x: 120, y: 82, width: 80, height: 24)
                pathField.frame = NSRect(x: 0, y: 32, width: 320, height: 24)
                browseButton.frame = NSRect(x: 332, y: 32, width: 88, height: 24)
                pathField.stringValue = slidingDefaultOutput.path
                browseButton.target = self
                browseButton.action = #selector(browseTapped)
                refreshForSelectedPuzzle()
            }

            @objc private func browseTapped() {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = outputURL
                if panel.runModal() == .OK, let selected = panel.url {
                    outputURL = selected
                    pathField.stringValue = selected.path
                }
            }

            @objc private func puzzleSelectionChanged() {
                refreshForSelectedPuzzle()
            }

            private func refreshForSelectedPuzzle() {
                let selected = puzzlePopup.indexOfSelectedItem
                guard selected >= 0, selected < puzzles.count else { return }
                let puzzle = puzzles[selected]
                switch puzzle.kind {
                case .slidingPuzzle:
                    outputURL = slidingDefaultOutput
                    pathField.stringValue = slidingDefaultOutput.path
                    hintField.isEnabled = true
                    if hintField.integerValue < 1 {
                        hintField.stringValue = "10"
                    }
                case .lockbox:
                    outputURL = lockboxDefaultOutput
                    pathField.stringValue = lockboxDefaultOutput.path
                    hintField.stringValue = "0"
                    hintField.isEnabled = false
                }
            }
        }

        let resourcesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Opt1")
            .appendingPathComponent("Opt1")
            .appendingPathComponent("Matching")
            .appendingPathComponent("Resources")
        let slidingDefaultOutput = resourcesRoot.appendingPathComponent("ReferencePuzzleImages")
        let lockboxDefaultOutput = resourcesRoot.appendingPathComponent("ReferenceLockboxImages")

        let accessoryController = AccessoryController(
            slidingDefaultOutput: slidingDefaultOutput,
            lockboxDefaultOutput: lockboxDefaultOutput,
            puzzles: puzzles
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 170))

        let puzzleLabel = NSTextField(labelWithString: "Puzzle")
        puzzleLabel.frame = NSRect(x: 0, y: 154, width: 200, height: 14)
        container.addSubview(puzzleLabel)
        container.addSubview(accessoryController.puzzlePopup)

        let scrambledLabel = NSTextField(labelWithString: "Scrambled captures")
        scrambledLabel.frame = NSRect(x: 0, y: 108, width: 110, height: 14)
        let hintLabel = NSTextField(labelWithString: "Hint captures")
        hintLabel.frame = NSRect(x: 120, y: 108, width: 100, height: 14)
        container.addSubview(scrambledLabel)
        container.addSubview(hintLabel)
        container.addSubview(accessoryController.scrambledField)
        container.addSubview(accessoryController.hintField)

        let outputLabel = NSTextField(labelWithString: "Dataset root")
        outputLabel.frame = NSRect(x: 0, y: 58, width: 120, height: 14)
        container.addSubview(outputLabel)
        container.addSubview(accessoryController.pathField)
        container.addSubview(accessoryController.browseButton)

        let alert = NSAlert()
        alert.messageText = "Puzzle Data Collection"
        alert.informativeText = "Choose puzzle and capture targets."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Begin")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = container

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selectedIndex = accessoryController.puzzlePopup.indexOfSelectedItem
        guard selectedIndex >= 0 && selectedIndex < puzzles.count else { return nil }
        let puzzle = puzzles[selectedIndex]

        let scrambled = max(1, accessoryController.scrambledField.integerValue)
        let hint = max(0, accessoryController.hintField.integerValue)
        let rawPath = accessoryController.pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultOutput = (puzzle.kind == .lockbox ? lockboxDefaultOutput : slidingDefaultOutput)
        let outputPath = rawPath.isEmpty ? defaultOutput.path : rawPath
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        return PuzzleCollectionConfig(
            puzzle: puzzle,
            scrambledTarget: scrambled,
            hintTarget: hint,
            outputRoot: output
        )
    }

    private func showControlPanel() {
        dismissControlPanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Puzzle Data Collection"
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let status = NSTextField(labelWithString: "Ready")
        status.frame = NSRect(x: 16, y: 118, width: 388, height: 36)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        content.addSubview(status)

        let phase = NSTextField(labelWithString: "")
        phase.frame = NSRect(x: 16, y: 88, width: 388, height: 20)
        content.addSubview(phase)

        let capture = NSButton(title: "Capture Next", target: self, action: #selector(captureNextTapped))
        capture.frame = NSRect(x: 16, y: 24, width: 120, height: 32)
        content.addSubview(capture)

        let skip = NSButton(title: "Skip", target: self, action: #selector(skipTapped))
        skip.frame = NSRect(x: 146, y: 24, width: 80, height: 32)
        content.addSubview(skip)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 310, y: 24, width: 90, height: 32)
        content.addSubview(cancel)

        panel.contentView = content
        bringAppToFront()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        self.controlPanel = panel
        self.statusLabel = status
        self.phaseLabel = phase
        self.captureButton = capture
        self.skipButton = skip
        self.cancelButton = cancel
    }

    private func dismissControlPanel() {
        controlPanel?.orderOut(nil)
        controlPanel?.close()
        controlPanel = nil
        statusLabel = nil
        phaseLabel = nil
        captureButton = nil
        skipButton = nil
        cancelButton = nil
    }

    private func updateLabels(status: String? = nil) {
        guard let config else { return }
        if let status {
            statusLabel?.stringValue = status
        } else {
            switch config.puzzle.kind {
            case .slidingPuzzle:
                statusLabel?.stringValue = "Capture \(progress.phase.rawValue) samples for \(config.puzzle.displayName)."
            case .lockbox:
                statusLabel?.stringValue = "Capture lockbox board samples for \(config.puzzle.displayName)."
            }
        }
        phaseLabel?.stringValue = "Scrambled \(progress.scrambledCaptured)/\(config.scrambledTarget)   Hint \(progress.hintCaptured)/\(config.hintTarget)"
    }

    // MARK: - Actions

    @objc private func captureNextTapped() {
        Task { await captureNext() }
    }

    @objc private func skipTapped() {
        Task { await skipCurrentStep() }
    }

    @objc private func cancelTapped() {
        finish(cancelled: true)
    }

    // MARK: - Capture flow

    private func captureNext() async {
        guard isActive, let config, let writer, let snipResult else { return }
        setControlsEnabled(false)
        defer { setControlsEnabled(true) }

        do {
            guard let rsWindow = try await WindowFinder.findRuneScapeWindow() else {
                updateLabels(status: "RuneScape not found.")
                return
            }
            let image = try await captureManager.captureWindow(rsWindow)
            let cropRectPx = SnipCoordinateMapper.normalizedSnipToImagePixels(
                snipResult.cropInWindowNormalized,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            guard cropRectPx.width >= 160, cropRectPx.height >= 160,
                  let cropImage = image.cropping(to: cropRectPx) else {
                updateLabels(status: "Snip crop too small. Re-run collection and select a larger area.")
                return
            }

            let phase = progress.phase
            let phaseIndex = progress.currentCount() + 1
            let result = try writer.writeCapture(
                cropImage,
                phase: phase,
                phaseIndex: phaseIndex,
                roiNormalized: snipResult.cropInWindowNormalized,
                sourceWindowSize: CGSize(width: image.width, height: image.height)
            )

            switch phase {
            case .scrambled:
                progress.scrambledCaptured += 1
                updateLabels(status: "Saved \(result.imageURL.lastPathComponent). Shuffle and capture next.")
                if progress.scrambledCaptured >= config.scrambledTarget {
                    if config.hintTarget > 0 {
                        progress.phase = .hint
                        showHintPhasePrompt()
                    } else {
                        finish(cancelled: false)
                        return
                    }
                }
            case .hint:
                progress.hintCaptured += 1
                updateLabels(status: "Saved \(result.imageURL.lastPathComponent). Keep hover on hint and capture next.")
            }

            if config.hintTarget > 0,
               progress.phase == .hint,
               progress.hintCaptured >= config.hintTarget {
                finish(cancelled: false)
            }
        } catch {
            updateLabels(status: "Capture failed: \(error.localizedDescription)")
        }
    }

    private func skipCurrentStep() async {
        guard isActive, let config else { return }
        switch progress.phase {
        case .scrambled:
            progress.scrambledCaptured += 1
            updateLabels(status: "Skipped one scrambled sample.")
            if progress.scrambledCaptured >= config.scrambledTarget {
                if config.hintTarget > 0 {
                    progress.phase = .hint
                    showHintPhasePrompt()
                } else {
                    finish(cancelled: false)
                    return
                }
            }
        case .hint:
            progress.hintCaptured += 1
            updateLabels(status: "Skipped one hint sample.")
            if progress.hintCaptured >= config.hintTarget {
                finish(cancelled: false)
                return
            }
        }
        updateLabels()
    }

    private func showHintPhasePrompt() {
        bringAppToFront()
        let alert = NSAlert()
        alert.messageText = "Hint phase required"
        alert.informativeText = "Hover over Hint in game, then press Option+3 for each hint sample (or click Capture Next)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        updateLabels(status: "Hint phase started. Keep hovering hint and press Option+3 to capture.")
    }

    private func finish(cancelled: Bool) {
        guard isActive else { return }
        let summary = makeSummary(cancelled: cancelled)
        dismissControlPanel()
        unregisterHintHotkeyMonitor()
        setActive(false)

        let alert = NSAlert()
        bringAppToFront()
        alert.messageText = cancelled ? "Puzzle data collection cancelled" : "Puzzle data collection complete"
        alert.informativeText = summary
        alert.addButton(withTitle: "OK")
        if !cancelled {
            alert.addButton(withTitle: "Open Folder")
        }
        let resp = alert.runModal()
        if !cancelled, resp == .alertSecondButtonReturn, let output = config?.outputRoot {
            NSWorkspace.shared.open(output)
        }

        self.config = nil
        self.writer = nil
        self.snipResult = nil
        self.progress = PuzzleCollectionProgress()
    }

    private func makeSummary(cancelled: Bool) -> String {
        guard let config, let writer else { return "No session summary available." }
        return [
            "Puzzle: \(config.puzzle.displayName)",
            "Kind: \(config.puzzle.kind.rawValue)",
            "Scrambled captured: \(progress.scrambledCaptured)/\(config.scrambledTarget)",
            "Hint captured: \(progress.hintCaptured)/\(config.hintTarget)",
            "Next index: \(writer.nextIndex)",
            "Output: \(config.outputRoot.path)",
            cancelled ? "Session cancelled before completion." : "You can now run build_puzzle_dataset_manifest.py on this root."
        ].joined(separator: "\n")
    }

    private func setActive(_ value: Bool) {
        isActive = value
        onActiveChanged(value)
    }

    private func setControlsEnabled(_ enabled: Bool) {
        captureButton?.isEnabled = enabled
        skipButton?.isEnabled = enabled
        cancelButton?.isEnabled = enabled
    }

    private func showError(_ message: String) {
        bringAppToFront()
        let alert = NSAlert()
        alert.messageText = "Puzzle Data Collection"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func bringAppToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func registerHintHotkeyMonitor() {
        unregisterHintHotkeyMonitor()
        hintHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let stripped = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard stripped == self.hintHotkeyModifiers, event.keyCode == self.hintHotkeyKeyCode else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isActive, self.progress.phase == .hint else { return }
                await self.captureNext()
            }
        }
        if !AXIsProcessTrusted() {
            updateLabels(status: "Hint hotkey Option+3 needs Accessibility permission. Use Capture Next button if needed.")
        }
    }

    private func unregisterHintHotkeyMonitor() {
        if let hintHotkeyMonitor {
            NSEvent.removeMonitor(hintHotkeyMonitor)
        }
        hintHotkeyMonitor = nil
    }

    private func loadPuzzleList() -> [PuzzleCollectionPuzzle]? {
        guard let arr = PuzzleManifest.load() else { return nil }
        var puzzles: [PuzzleCollectionPuzzle] = arr.compactMap { (row: [String: String]) -> PuzzleCollectionPuzzle? in
            guard let key = row["key"], let displayName = row["displayName"] else { return nil }
            return PuzzleCollectionPuzzle(key: key, displayName: displayName, kind: .slidingPuzzle)
        }
        puzzles.append(PuzzleCollectionPuzzle(key: "lockbox", displayName: "Lockbox", kind: .lockbox))
        return puzzles.sorted { $0.displayName < $1.displayName }
    }

    deinit {
        if let hintHotkeyMonitor {
            NSEvent.removeMonitor(hintHotkeyMonitor)
            self.hintHotkeyMonitor = nil
        }
    }
}
