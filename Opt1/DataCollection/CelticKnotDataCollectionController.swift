import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import Opt1CelticKnot

@MainActor
final class CelticKnotDataCollectionController: NSObject {
    private let captureManager: ScreenCaptureManager
    private let snipOverlay: PuzzleSnipOverlayController
    private let onActiveChanged: (Bool) -> Void

    private var isActive = false
    private var controlPanel: NSPanel?
    private var statusLabel: NSTextField?
    private var phaseLabel: NSTextField?
    private var captureNormalButton: NSButton?
    private var captureInvertedButton: NSButton?
    private var resnipButton: NSButton?
    private var doneButton: NSButton?
    private var cancelButton: NSButton?

    private var captureCount = 0
    private var currentPuzzleDir: URL?
    private var selectedLayout: CelticKnotLayoutType = .sixSpot
    private var snipResult: PuzzleSnipResult?

    private let outputRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Opt1/CelticKnotData", isDirectory: true)
    }()

    init(captureManager: ScreenCaptureManager, snipOverlay: PuzzleSnipOverlayController, onActiveChanged: @escaping (Bool) -> Void) {
        self.captureManager = captureManager
        self.snipOverlay = snipOverlay
        self.onActiveChanged = onActiveChanged
        super.init()
    }

    func start() async {
        guard !isActive else { return }
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        } catch {
            showError("Could not create output directory: \(error.localizedDescription)")
            return
        }

        guard let layout = promptForLayout() else { return }
        self.selectedLayout = layout

        guard await performSnip() else {
            showError("Celtic Knot data collection cancelled: snip selection required.")
            return
        }

        setActive(true)
        showControlPanel()
        updateLabels(status: "Snip captured. Capture Normal, or Re-snip if needed.")
    }

    // MARK: - Layout prompt

    private func promptForLayout() -> CelticKnotLayoutType? {
        let alert = NSAlert()
        alert.messageText = "Celtic Knot Data Collection"
        alert.informativeText = "Select the puzzle layout, then draw a box around the entire Celtic Knot dialog (title through buttons)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26))
        for layout in CelticKnotLayoutType.allCases {
            popup.addItem(withTitle: "\(layout.rawValue)")
        }
        alert.accessoryView = popup

        bringAppToFront()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < CelticKnotLayoutType.allCases.count else { return nil }
        return CelticKnotLayoutType.allCases[idx]
    }

    // MARK: - Snip

    private func performSnip() async -> Bool {
        guard let rsWindow = try? await WindowFinder.findRuneScapeWindow() else {
            showError("RuneScape not found.")
            return false
        }
        guard let shareable = try? await SCShareableContent.current else {
            showError("Could not read shareable content.")
            return false
        }
        let snipFrame = rsWindow.appKitGlobalFrame(content: shareable)
        guard let snip = await snipOverlay.captureSelection(around: snipFrame) else {
            return false
        }
        if snip.cropInWindowNormalized.width < 0.05 || snip.cropInWindowNormalized.height < 0.05 {
            showError("Selected snip area is too small. Please select the full rune diamond area.")
            return false
        }
        self.snipResult = snip
        return true
    }

    // MARK: - UI

    private func showControlPanel() {
        dismissControlPanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Celtic Knot Data Collection (\(selectedLayout.rawValue))"
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center()

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))

        let status = NSTextField(labelWithString: "Ready")
        status.frame = NSRect(x: 16, y: 150, width: 448, height: 44)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 3
        content.addSubview(status)

        let phase = NSTextField(labelWithString: "Captures: 0")
        phase.frame = NSRect(x: 16, y: 124, width: 448, height: 20)
        content.addSubview(phase)

        let captureNormal = NSButton(title: "Capture Normal", target: self, action: #selector(captureNormalTapped))
        captureNormal.frame = NSRect(x: 16, y: 74, width: 130, height: 32)
        content.addSubview(captureNormal)

        let captureInverted = NSButton(title: "Capture Inverted", target: self, action: #selector(captureInvertedTapped))
        captureInverted.frame = NSRect(x: 156, y: 74, width: 140, height: 32)
        content.addSubview(captureInverted)

        let resnip = NSButton(title: "Re-snip", target: self, action: #selector(resnipTapped))
        resnip.frame = NSRect(x: 310, y: 74, width: 80, height: 32)
        content.addSubview(resnip)

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.frame = NSRect(x: 280, y: 24, width: 80, height: 32)
        content.addSubview(done)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.frame = NSRect(x: 380, y: 24, width: 80, height: 32)
        content.addSubview(cancel)

        panel.contentView = content
        bringAppToFront()
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)

        self.controlPanel = panel
        self.statusLabel = status
        self.phaseLabel = phase
        self.captureNormalButton = captureNormal
        self.captureInvertedButton = captureInverted
        self.resnipButton = resnip
        self.doneButton = done
        self.cancelButton = cancel
    }

    private func dismissControlPanel() {
        controlPanel?.orderOut(nil)
        controlPanel?.close()
        controlPanel = nil
        statusLabel = nil
        phaseLabel = nil
        captureNormalButton = nil
        captureInvertedButton = nil
        resnipButton = nil
        doneButton = nil
        cancelButton = nil
    }

    private func updateLabels(status: String) {
        statusLabel?.stringValue = status
        phaseLabel?.stringValue = "Captures: \(captureCount)"
    }

    private func setControlsEnabled(_ enabled: Bool) {
        captureNormalButton?.isEnabled = enabled
        captureInvertedButton?.isEnabled = enabled
        resnipButton?.isEnabled = enabled
        doneButton?.isEnabled = enabled
        cancelButton?.isEnabled = enabled
    }

    // MARK: - Actions

    @objc private func captureNormalTapped() {
        Task { await performCapture(inverted: false) }
    }

    @objc private func captureInvertedTapped() {
        Task { await performCapture(inverted: true) }
    }

    @objc private func resnipTapped() {
        Task {
            setControlsEnabled(false)
            if await performSnip() {
                updateLabels(status: "Re-snip captured. Continue capturing.")
            } else {
                updateLabels(status: "Re-snip cancelled. Previous snip still active.")
            }
            setControlsEnabled(true)
        }
    }

    @objc private func doneTapped() {
        finish(cancelled: false)
    }

    @objc private func cancelTapped() {
        finish(cancelled: true)
    }

    // MARK: - Capture flow

    private func performCapture(inverted: Bool) async {
        guard isActive, let snipResult else { return }
        setControlsEnabled(false)
        defer { setControlsEnabled(true) }

        let phaseName = inverted ? "inverted" : "normal"

        do {
            guard let rsWindow = try await WindowFinder.findRuneScapeWindow() else {
                updateLabels(status: "RuneScape window not found.")
                return
            }
            let image = try await captureManager.captureWindow(rsWindow)

            let runeArea = SnipCoordinateMapper.normalizedSnipToImagePixels(
                snipResult.cropInWindowNormalized,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            guard runeArea.width >= 50, runeArea.height >= 50 else {
                updateLabels(status: "Snip area too small in capture. Try Re-snip.")
                return
            }

            let puzzleDir = currentPuzzleDirOrCreate()
            let phaseDir = puzzleDir.appendingPathComponent(phaseName, isDirectory: true)
            try FileManager.default.createDirectory(at: phaseDir, withIntermediateDirectories: true)

            if let runeAreaCrop = image.cropping(to: runeArea) {
                savePNG(runeAreaCrop, to: phaseDir.appendingPathComponent("rune_area.png"))
            }

            let detector = CelticKnotDetector()
            let gridAnalysis = CelticKnotGridReader().analyze(
                in: image,
                puzzleBounds: runeArea,
                runeArea: runeArea
            )
            guard let layout = CelticKnotGridReader().makeLayout(
                from: gridAnalysis,
                puzzleBounds: runeArea,
                layoutType: selectedLayout
            ) else {
                updateLabels(status: "Grid reader could not build \(selectedLayout) layout. Try Re-snip.")
                return
            }
            let crops = detector.extractRuneCrops(
                from: image, puzzleBounds: runeArea, layout: layout, runeArea: runeArea
            )

            if let overlay = detector.drawTemplateOverlay(on: image, puzzleBounds: runeArea, layout: layout) {
                savePNG(overlay, to: phaseDir.appendingPathComponent("debug_overlay.png"))
            }

            for (trackIdx, slotIdx, _, crop) in crops {
                let name = "rune_t\(trackIdx)_s\(String(format: "%02d", slotIdx)).png"
                savePNG(crop, to: phaseDir.appendingPathComponent(name))
            }

            let meta: [String: Any] = [
                "layout_type": selectedLayout.rawValue,
                "inverted": inverted,
                "captured_at": ISO8601DateFormatter().string(from: Date()),
                "rune_count": crops.count,
                "rune_area": [
                    "x": runeArea.minX,
                    "y": runeArea.minY,
                    "width": runeArea.width,
                    "height": runeArea.height,
                ],
                "snip_normalized": [
                    "x": snipResult.cropInWindowNormalized.minX,
                    "y": snipResult.cropInWindowNormalized.minY,
                    "width": snipResult.cropInWindowNormalized.width,
                    "height": snipResult.cropInWindowNormalized.height,
                ],
            ]
            let metaData = try JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
            )
            try metaData.write(to: phaseDir.appendingPathComponent("meta.json"))

            captureCount += 1

            if inverted {
                updateLabels(status: "Saved \(crops.count) inverted rune crops. " +
                             "Rotate tracks and Capture Normal, or click Done.")
                currentPuzzleDir = nil
            } else {
                updateLabels(status: "Saved \(crops.count) normal rune crops. " +
                             "Click Invert Paths in-game, then Capture Inverted.")
            }

        } catch {
            updateLabels(status: "Capture failed: \(error.localizedDescription)")
        }
    }

    private func currentPuzzleDirOrCreate() -> URL {
        if let existing = currentPuzzleDir { return existing }
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = outputRoot.appendingPathComponent("puzzle_\(ts)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        currentPuzzleDir = dir
        return dir
    }

    private func finish(cancelled: Bool) {
        guard isActive else { return }
        let summary = "Celtic Knot captures: \(captureCount)\nLayout: \(selectedLayout.rawValue)\nOutput: \(outputRoot.path)"
        dismissControlPanel()
        setActive(false)

        bringAppToFront()
        let alert = NSAlert()
        alert.messageText = cancelled ? "Collection cancelled" : "Collection complete"
        alert.informativeText = summary
        alert.addButton(withTitle: "OK")
        if captureCount > 0 {
            alert.addButton(withTitle: "Open Folder")
        }
        let resp = alert.runModal()
        if captureCount > 0, resp == .alertSecondButtonReturn {
            NSWorkspace.shared.open(outputRoot)
        }

        captureCount = 0
        currentPuzzleDir = nil
        snipResult = nil
    }

    private func setActive(_ value: Bool) {
        isActive = value
        onActiveChanged(value)
    }

    private func showError(_ message: String) {
        bringAppToFront()
        let alert = NSAlert()
        alert.messageText = "Celtic Knot Data Collection"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func bringAppToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

}
