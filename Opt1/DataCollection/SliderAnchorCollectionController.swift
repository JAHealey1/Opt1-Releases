import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Offset model

struct SliderAnchorOffset: Codable {
    /// Signed pixel offset from the top-left corner of the matched close-X
    /// needle to the top-left tile of the 5×5 puzzle grid.
    let tlOffsetFromX: [Int]   // [dx, dy]
    /// Width and height of the 5×5 puzzle grid in pixels.
    let puzzleSize: [Int]      // [width, height]
    /// Width and height of the matched close-X needle in pixels (informational).
    let needleSize: [Int]      // [width, height]
    /// NXT interface scale as an integer percentage
    /// (70, 80, 90, 100, 110, 120, 135, 150, 175, 200, 225, 250, 275, 300).
    let uiScale: Int
}

// MARK: - Known 100% constants (from ClueTrainer)

private extension SliderAnchorOffset {
    /// Published ClueTrainer constants for 100% NXT UI scale.
    /// `TL_TILE_FROM_X_OFFSET = {x: -297, y: 15}`, `PUZZLE_SIZE = {x: 273, y: 273}`.
    /// All values scale linearly with UI scale.
    static func scaled(to uiScale: Int, needleSize: (Int, Int)) -> SliderAnchorOffset {
        let factor = Double(uiScale) / 100.0
        let dx = Int(round(-297.0 * factor))
        let dy = Int(round(  15.0 * factor))
        let pw = Int(round( 273.0 * factor))
        let ph = Int(round( 273.0 * factor))
        return SliderAnchorOffset(
            tlOffsetFromX: [dx, dy],
            puzzleSize: [pw, ph],
            needleSize: [needleSize.0, needleSize.1],
            uiScale: uiScale
        )
    }
}

// MARK: - Controller

/// Developer-only data-collection tool for capturing slider-anchor needles
/// (the modal close-X glyph). One run = one X needle PNG + one JSON entry.
///
/// The puzzle-grid offset is computed automatically from ClueTrainer's published
/// 100% constants (`tlOffsetFromX: [-297, 15]`, `puzzleSize: [273, 273]`) scaled
/// by `uiScale / 100`. No second snip is required.
///
/// The same needle works for both Modern and Classic interfaces.
///
/// Usage:
///   1. Open a 5×5 slide-puzzle in RuneScape.
///   2. Set the NXT UI scale you want to capture (Interface Settings → Scaling).
///   3. Launch via the Developer menu → Slider Anchor Collection….
///   4. Pick the current scale, then snip the close-X button on the modal.
///   5. Rebuild Opt1 (⌘B) to bundle the new data.
///   6. Repeat for each of the 14 scales:
///      70, 80, 90, 100, 110, 120, 135, 150, 175, 200, 225, 250, 275, 300.
@MainActor
final class SliderAnchorCollectionController: NSObject {
    private let captureManager: ScreenCaptureManager
    private let snipOverlay: PuzzleSnipOverlayController
    private let onActiveChanged: (Bool) -> Void

    private var isActive = false

    private let outputRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Opt1/Opt1/Matching/Resources/SliderAnchors")
    }()

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

    // MARK: - Public entry point

    func start() async {
        guard !isActive else { return }

        guard let scale = promptForScale() else { return }
        let key = "scale_\(scale)"

        bringAppToFront()
        let infoAlert = NSAlert()
        infoAlert.messageText = "Slider Anchor Collection — \(key)"
        infoAlert.informativeText = """
        One snip is needed:

        Drag a tight rectangle around the close-X button (top-right corner of the slider modal).

        Make sure the slider puzzle is open in RuneScape at \(scale)% UI scale now.

        The puzzle grid position is calculated automatically from ClueTrainer's published constants.
        """
        infoAlert.addButton(withTitle: "Start")
        infoAlert.addButton(withTitle: "Cancel")
        guard infoAlert.runModal() == .alertFirstButtonReturn else { return }

        guard let rsWindow = try? await WindowFinder.findRuneScapeWindow() else {
            showError("RuneScape window not found.")
            return
        }
        guard let shareable = try? await SCShareableContent.current else {
            showError("Could not read shareable content.")
            return
        }
        let snipFrame = rsWindow.appKitGlobalFrame(content: shareable)

        setActive(true)
        defer { setActive(false) }

        guard let xSnip = await snipOverlay.captureSelection(around: snipFrame) else {
            showError("Close-X snip cancelled.")
            return
        }

        guard let windowImage = try? await captureManager.captureWindow(rsWindow) else {
            showError("Window capture failed.")
            return
        }

        let xCropPx = SnipCoordinateMapper.normalizedSnipToImagePixels(
            xSnip.cropInWindowNormalized,
            imageSize: CGSize(width: windowImage.width, height: windowImage.height)
        )
        guard xCropPx.width >= 4, xCropPx.height >= 4,
              let xImage = windowImage.cropping(to: xCropPx) else {
            showError("Close-X snip is too small or out of bounds.")
            return
        }

        let nWidth  = Int(round(xCropPx.width))
        let nHeight = Int(round(xCropPx.height))

        let offset = SliderAnchorOffset.scaled(to: scale, needleSize: (nWidth, nHeight))
        do {
            let anchorsDir = outputRoot.appendingPathComponent("anchors")
            try FileManager.default.createDirectory(at: anchorsDir, withIntermediateDirectories: true)
            let pngURL = anchorsDir.appendingPathComponent("\(key).png")
            guard savePNG(xImage, to: pngURL) else {
                showError("Failed to save needle PNG to \(pngURL.path).")
                return
            }

            let jsonURL = outputRoot.appendingPathComponent("anchor_offsets.json")
            var offsets = loadOffsets(from: jsonURL)
            offsets[key] = offset
            try saveOffsets(offsets, to: jsonURL)

            bringAppToFront()
            let done = NSAlert()
            done.messageText = "Anchor captured: \(key)"
            done.informativeText = """
            Needle:          \(nWidth)×\(nHeight) px  → \(pngURL.lastPathComponent)
            Puzzle offset:   (\(offset.tlOffsetFromX[0]), \(offset.tlOffsetFromX[1])) px
            Puzzle size:     \(offset.puzzleSize[0])×\(offset.puzzleSize[1]) px
            (offsets scaled from ClueTrainer 100% constants × \(scale)/100)

            Saved to:
            \(pngURL.path)

            Rebuild Opt1 to bundle the new data.
            """
            done.addButton(withTitle: "OK")
            done.addButton(withTitle: "Open Folder")
            let resp = done.runModal()
            if resp == .alertSecondButtonReturn {
                NSWorkspace.shared.open(outputRoot)
            }
        } catch {
            showError("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Scale picker

    static let supportedScales = [70, 80, 90, 100, 110, 120, 135, 150, 175, 200, 225, 250, 275, 300]

    private func promptForScale() -> Int? {
        let scales = Self.supportedScales

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))

        let scalePopup = NSPopUpButton(frame: NSRect(x: 0, y: 22, width: 180, height: 26))
        scalePopup.addItems(withTitles: scales.map { "\($0)%" })
        // Default selection to 100%
        if let idx = scales.firstIndex(of: 100) {
            scalePopup.selectItem(at: idx)
        }

        let scaleLabel = NSTextField(labelWithString: "NXT UI Scale")
        scaleLabel.frame = NSRect(x: 0, y: 2, width: 180, height: 18)

        container.addSubview(scalePopup)
        container.addSubview(scaleLabel)

        let alert = NSAlert()
        alert.messageText = "Slider Anchor Collection"
        alert.informativeText = "Choose the NXT UI scale currently set in RuneScape.\n(Interface Settings → Interface Scaling)\n\nThe same needle works for both Modern and Classic interfaces."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Next")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = container

        bringAppToFront()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        return scales[scalePopup.indexOfSelectedItem]
    }

    // MARK: - JSON helpers

    private func loadOffsets(from url: URL) -> [String: SliderAnchorOffset] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: SliderAnchorOffset].self, from: data) else {
            return [:]
        }
        return raw
    }

    private func saveOffsets(_ offsets: [String: SliderAnchorOffset], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(offsets)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - PNG save

    private func savePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - Helpers

    private func setActive(_ value: Bool) {
        isActive = value
        onActiveChanged(value)
    }

    private func bringAppToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ message: String) {
        bringAppToFront()
        let alert = NSAlert()
        alert.messageText = "Slider Anchor Collection"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
