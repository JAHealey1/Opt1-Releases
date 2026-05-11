import AppKit
import CoreGraphics
import SwiftUI
import Opt1Solvers
import Opt1Matching

// MARK: - OverlayPresenter
//
// Owns the single floating overlay panel and all auxiliary panels (Celtic Knot
// arrow overlay, elite compass triangulation state). Every `showXxx` call
// goes through here so there is exactly one place that:
//   • computes the overlay frame,
//   • manages the OverlayWindowController lifecycle, and
//   • schedules auto-dismiss timers.
//
// Callers (ClueOrchestrator) never touch OverlayWindowController directly.

@MainActor
final class OverlayPresenter {

    // MARK: - State

    private var overlayWindowController: OverlayWindowController?
    private(set) var triangulationState: CompassTriangulationState?
    private(set) var scanFilterState:    ScanFilterState?
    var isScanOverlayActive: Bool { scanFilterState != nil }
    private var celticKnotArrowPanel: NSPanel?
    private var lockboxGridPanel:     NSPanel?

    /// In-flight auto-dismiss timer. Replacing an overlay (or explicit dismiss)
    /// cancels the previous work item so stale closures never fire against
    /// unrelated new overlays.
    private var dismissWorkItem: DispatchWorkItem?

    // MARK: - Dependencies

    private let clueProvider: any ClueProviding

    init(clueProvider: any ClueProviding) {
        self.clueProvider = clueProvider
    }

    // MARK: - Overlay Exclusion

    /// Window IDs the screen capturer should exclude (e.g. our overlay panel
    /// during elite compass triangulation so it doesn't appear in captured frames).
    func overlayExclusionIDs() -> [CGWindowID] {
        guard triangulationState != nil,
              let panel = overlayWindowController?.panel else { return [] }
        return [CGWindowID(panel.windowNumber)]
    }

    // MARK: - Dismiss Helpers

    /// Closes the current overlay and clears all persistent state.
    /// Called whenever a new, incompatible overlay is about to be shown.
    func dismissTriangulationIfNeeded() {
        cancelDismissTimer()
        overlayWindowController?.close()
        triangulationState = nil
        scanFilterState    = nil
        celticKnotArrowPanel?.close()
        celticKnotArrowPanel = nil
        lockboxGridPanel?.close()
        lockboxGridPanel = nil
    }

    private func cancelDismissTimer() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }

    /// Schedules a single auto-dismiss for the currently-active overlay. Any
    /// previously-scheduled dismiss is cancelled so stale timers never outlive
    /// their overlay.
    private func scheduleDismiss(controller: OverlayWindowController, after delay: TimeInterval) {
        cancelDismissTimer()
        let item = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller, self.overlayWindowController === controller else { return }
            controller.close()
            self.overlayWindowController = nil
            self.celticKnotArrowPanel?.close()
            self.celticKnotArrowPanel = nil
            self.lockboxGridPanel?.close()
            self.lockboxGridPanel = nil
            self.dismissWorkItem = nil
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Schedules auto-dismiss for the lockbox on-grid panel (no controller companion).
    private func scheduleDismiss(panel: NSPanel, after delay: TimeInterval) {
        cancelDismissTimer()
        let item = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.lockboxGridPanel === panel else { return }
            panel.close()
            self.lockboxGridPanel = nil
            self.dismissWorkItem = nil
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Generic

    func showOverlay(
        message: String,
        detail: String,
        mode: OverlayMode,
        windowFrame: CGRect? = nil
    ) {
        dismissTriangulationIfNeeded()

        let view = SolutionView(mode: mode, message: message, detail: detail)
        let panelFrame = overlayFrame(size: mode.preferredSize, near: windowFrame)

        let controller = OverlayWindowController()
        controller.show(view: AnyView(view), frame: panelFrame)
        overlayWindowController = controller

        let delay: Double
        if case .error = mode { delay = 4.0 } else { delay = 3.0 }
        scheduleDismiss(controller: controller, after: delay)
    }

    // MARK: - Puzzle-specific overlays

    func showSolutionOverlay(_ solution: ClueSolution, windowFrame: CGRect) {
        // Scan clues must show ALL possible dig spots for the region, not just
        // the single entry that happened to fuzzy-match.
        if solution.type == "scan" {
            let allSpots = clueProvider.clues.filter {
                $0.type == "scan" && $0.clue == solution.clue
            }
            let region = solution.location ?? "Unknown region"
            var scanRange = ""
            let lower = solution.clue.lowercased()
            if let rangeStart = lower.range(of: "orb scan range:") {
                let after = String(lower[rangeStart.upperBound...]).trimmingCharacters(in: .whitespaces)
                scanRange = String(after.prefix(while: { $0.isNumber }))
            }
            print("[Opt1] Scan clue via scroll detector — region: '\(region)', \(allSpots.count) spots")
            showScanOverlay(region: region, scanRange: scanRange, spots: allSpots, windowFrame: windowFrame)
            return
        }

        dismissTriangulationIfNeeded()
        let controller = OverlayWindowController()
        controller.showSolution(solution, windowFrame: windowFrame)
        overlayWindowController = controller

        let hasRichContent = solution.travel != nil
        let dismissDelay: Double = hasRichContent ? 45 : 30
        scheduleDismiss(controller: controller, after: dismissDelay)
    }

    func showScanOverlay(region: String, scanRange: String, spots: [ClueSolution], windowFrame: CGRect) {
        // Same region already active — keep the window and its accumulated
        // observations rather than resetting mid-session.
        if let existing = scanFilterState, existing.region == region { return }

        // New region — tear down everything and build fresh.
        cancelDismissTimer()
        overlayWindowController?.close()
        overlayWindowController = nil
        celticKnotArrowPanel?.close()
        celticKnotArrowPanel = nil
        lockboxGridPanel?.close()
        lockboxGridPanel = nil
        triangulationState   = nil
        scanFilterState      = nil

        let state = ScanFilterState(region: region, scanRange: scanRange, spots: spots)
        state.onClose = { [weak self] in self?.dismissTriangulationIfNeeded() }
        scanFilterState = state

        let mode = OverlayMode.scanList(state: state)
        let view = SolutionView(mode: mode, message: "", detail: "")
        let size = AppSettings.shared.scanPanelSize ?? mode.preferredSize
        let controller = OverlayWindowController()
        controller.showSolutionView(
            AnyView(view),
            size: size,
            windowFrame: windowFrame,
            resizable: true,
            minSize: AppSettings.minScanPanelSize,
            onResize: { newSize in
                AppSettings.shared.scanPanelSize = newSize
            }
        )
        overlayWindowController = controller
        // No auto-dismiss — overlay persists until the user closes it
        // or a different clue type is detected.
    }

    func showTowersOverlay(solution: TowersSolution, hints: TowersHints, windowFrame: CGRect) {
        dismissTriangulationIfNeeded()
        let mode = OverlayMode.towers(solution: solution, hints: hints)
        let view = SolutionView(mode: mode, message: "", detail: "")
        // 7 columns × 32 pt + gaps + header ~= 280 × 320
        let size = CGSize(width: 280, height: 320)
        let controller = OverlayWindowController()
        controller.showSolutionView(AnyView(view), size: size, windowFrame: windowFrame)
        overlayWindowController = controller
        scheduleDismiss(controller: controller, after: 60)
    }

    func showLockboxOverlay(solution: LockboxSolution, windowFrame: CGRect) {
        dismissTriangulationIfNeeded()

        if let gridOnScreen = solution.gridBoundsOnScreen {
            // On-grid passthrough panel — places click badges directly on each tile.
            // No companion side panel needed.
            let panelFrame = PuzzleSnipDesktop.cgRectToAppKit(gridOnScreen)
            let panel = OverlayPanelFactory.makeFloatingPanel(frame: panelFrame, passthrough: true)
            let gridView = LockboxGridOverlayView(solution: solution, panelSize: gridOnScreen.size)
            let hosting = NSHostingView(rootView: gridView)
            hosting.frame = panel.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(hosting)
            panel.orderFront(nil)
            lockboxGridPanel = panel
            scheduleDismiss(panel: panel, after: 10)
        } else {
            // Fallback: no screen bounds — show the mimic-grid side panel.
            let mode = OverlayMode.lockbox(solution: solution)
            let view = SolutionView(mode: mode, message: "", detail: "")
            let size = CGSize(width: 240, height: 240)
            let controller = OverlayWindowController()
            controller.showSolutionView(AnyView(view), size: size, windowFrame: windowFrame)
            overlayWindowController = controller
            scheduleDismiss(controller: controller, after: 30)
        }
    }

    func showEliteCompassOverlay(state: CompassTriangulationState, windowFrame: CGRect) {
        cancelDismissTimer()
        overlayWindowController?.close()
        overlayWindowController = nil
        celticKnotArrowPanel?.close()
        celticKnotArrowPanel = nil
        lockboxGridPanel?.close()
        lockboxGridPanel = nil

        state.onClose = { [weak self] in
            self?.dismissTriangulationIfNeeded()
        }

        let mode = OverlayMode.eliteCompass(state: state)
        let view = SolutionView(mode: mode, message: "", detail: "")
        let size = mode.preferredSize
        let controller = OverlayWindowController()
        controller.showSolutionView(
            AnyView(view),
            size: size,
            windowFrame: windowFrame,
            movableByBackground: false,
            resizable: true,
            minSize: AppSettings.minEliteCompassSize,
            onResize: { newSize in
                AppSettings.shared.eliteCompassPanelSize = newSize
            }
        )
        overlayWindowController = controller
        triangulationState = state
    }

    func showCelticKnotOverlay(solution: CelticKnotSolution, windowFrame: CGRect) {
        dismissTriangulationIfNeeded()

        if let puzzleRect = solution.puzzleBoundsOnScreen,
           let arrows = solution.arrowScreenPositions, !arrows.isEmpty {
            let panelFrame = PuzzleSnipDesktop.cgRectToAppKit(puzzleRect)
            let panel = OverlayPanelFactory.makeFloatingPanel(frame: panelFrame, passthrough: true)

            let overlayView = CelticKnotArrowOverlayView(
                solution: solution,
                panelSize: puzzleRect.size
            )
            let hosting = NSHostingView(rootView: overlayView)
            hosting.frame = panel.contentView?.bounds ?? .zero
            hosting.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(hosting)
            panel.orderFront(nil)
            celticKnotArrowPanel = panel
        }

        let mode = OverlayMode.celticKnot(solution: solution)
        let view = SolutionView(mode: mode, message: "", detail: "")
        let size = mode.preferredSize
        let controller = OverlayWindowController()
        controller.showSolutionView(AnyView(view), size: size, windowFrame: windowFrame)
        overlayWindowController = controller
        scheduleDismiss(controller: controller, after: 30)
    }

    // MARK: - Frame Calculation

    /// Canonical overlay frame: top-right corner of the RS window, 16 pt inset.
    /// Falls back to top-right of the main screen if no window frame is provided.
    func overlayFrame(size: CGSize, near windowFrame: CGRect?) -> NSRect {
        if let wf = windowFrame {
            let ak = PuzzleSnipDesktop.cgRectToAppKit(wf)
            return NSRect(
                x: ak.maxX - size.width - 16,
                y: ak.maxY - size.height - 16,
                width: size.width,
                height: size.height
            )
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screen.maxX - size.width - 16,
            y: screen.maxY - size.height - 16,
            width: size.width,
            height: size.height
        )
    }
}

