import AppKit
import SwiftUI
import Opt1Matching

// NSHostingView can call layoutSubtreeIfNeeded while a layout pass is already
// in progress, producing an "It's not legal to call -layoutSubtreeIfNeeded…"
// warning. Guarding the layout() entry-point prevents the recursion.
private final class SafeHostingView<Content: View>: NSHostingView<Content> {
    private var layoutInProgress = false

    override func layout() {
        guard !layoutInProgress else { return }
        layoutInProgress = true
        defer { layoutInProgress = false }
        super.layout()
    }
}

/// Manages a single floating, transparent, borderless NSPanel used for all Opt1 overlays.
/// Phase 3: Tracks the RS window position and repositions the overlay accordingly.
/// The overlay is draggable; the user's custom offset from the default position is
/// persisted in UserDefaults and re-applied whenever the RS window moves.
@MainActor
class OverlayWindowController: NSObject, NSWindowDelegate {

    private(set) var panel: NSPanel?
    private var trackingTimer: Timer?

    // Most recent RS window frame — used by the tracking timer.
    private var lastWindowFrame: CGRect?
    private var overlaySize: CGSize = .zero

    // Set to true while we call setFrame programmatically so windowDidMove
    // doesn't misinterpret our own repositioning as a user drag.
    private var isUpdatingPosition = false

    // Debounces the UserDefaults write so we only persist the final resting
    // position after the user finishes dragging, not every intermediate pixel.
    private var saveOffsetTask: Task<Void, Never>?

    // Optional callback invoked (debounced) when the user resizes the panel —
    // wired up by callers that want to persist the chosen size, e.g. the
    // elite compass overlay. Receives the new content size.
    private var onResize: ((CGSize) -> Void)?
    private var saveResizeTask: Task<Void, Never>?

    // MARK: - Persisted user offset

    /// Offset the user has dragged the overlay away from its computed default position.
    /// Stored in screen-space AppKit coordinates (Y=0 at bottom).
    private var userOffset: CGPoint {
        get {
            CGPoint(
                x: UserDefaults.standard.double(forKey: AppSettings.Keys.overlayOffsetX),
                y: UserDefaults.standard.double(forKey: AppSettings.Keys.overlayOffsetY)
            )
        }
        set {
            UserDefaults.standard.set(newValue.x, forKey: AppSettings.Keys.overlayOffsetX)
            UserDefaults.standard.set(newValue.y, forKey: AppSettings.Keys.overlayOffsetY)
        }
    }

    // MARK: - Generic Show

    func show(view: AnyView,
              frame: NSRect,
              movableByBackground: Bool = true,
              resizable: Bool = false,
              minSize: CGSize? = nil) {
        close()

        var styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        // Adding .resizable to a borderless panel doesn't draw chrome but
        // does enable AppKit's invisible edge/corner resize handles.
        if resizable { styleMask.insert(.resizable) }

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .floating
        newPanel.ignoresMouseEvents = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        newPanel.hasShadow = false
        newPanel.isMovableByWindowBackground = movableByBackground
        newPanel.delegate = self
        if let minSize {
            newPanel.contentMinSize = minSize
        }

        newPanel.contentView = SafeHostingView(rootView: view)

        // Raise the flag before orderFront so any synchronous windowDidMove call sees it.
        // Reset it asynchronously so the windowDidMove Task (also async) still sees it true.
        isUpdatingPosition = true
        newPanel.orderFront(nil)
        self.panel = newPanel
        self.overlaySize = frame.size
        Task { @MainActor [weak self] in self?.isUpdatingPosition = false }
    }

    // MARK: - Solution Display (offset-aware, window-tracking)

    /// Shows any solution overlay: applies the persisted user drag-offset and
    /// starts the RS-window tracking timer so the panel follows if the game moves.
    /// - Parameter resizable: when true, AppKit gives the borderless panel
    ///   invisible edge handles so the user can drag to resize. The supplied
    ///   `minSize` enforces the smallest allowed size; pass an `onResize`
    ///   closure to persist the chosen size when the user finishes resizing.
    func showSolutionView(_ view: AnyView,
                          size: CGSize,
                          windowFrame: CGRect,
                          movableByBackground: Bool = true,
                          resizable: Bool = false,
                          minSize: CGSize? = nil,
                          onResize: ((CGSize) -> Void)? = nil) {
        // Set lastWindowFrame and overlaySize BEFORE show() so that any synchronous
        // windowDidMove fired by orderFront can compute the correct default frame.
        lastWindowFrame = windowFrame
        overlaySize = size
        self.onResize = onResize
        let frame = panelFrame(size: size, near: windowFrame)
        show(view: view,
             frame: frame,
             movableByBackground: movableByBackground,
             resizable: resizable,
             minSize: minSize)
        startTracking()
    }

    func showSolution(_ solution: ClueSolution, windowFrame: CGRect) {
        let size = OverlayMode.solution(solution).preferredSize
        let view = SolutionView(
            mode: .solution(solution),
            message: solution.solution,
            detail: solution.location ?? ""
        )
        showSolutionView(AnyView(view), size: size, windowFrame: windowFrame)
    }

    // MARK: - Window Tracking (5 Hz)

    private func startTracking() {
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.updatePosition()
            }
        }
    }

    private func updatePosition() async {
        guard let panel else { return }
        // Don't reposition while the user is actively dragging the overlay —
        // fighting a live drag would cause jitter and corrupt the saved offset.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard let newFrame = try? await findRSWindowFrame() else { return }
        guard newFrame != lastWindowFrame else { return }
        lastWindowFrame = newFrame
        let newPanelFrame = panelFrame(size: overlaySize, near: newFrame)
        isUpdatingPosition = true
        panel.setFrame(newPanelFrame, display: true, animate: false)
        // Reset asynchronously so the windowDidMove Task spawned by setFrame still sees the flag.
        Task { @MainActor [weak self] in self?.isUpdatingPosition = false }
    }

    private func findRSWindowFrame() async throws -> CGRect? {
        let window = try await WindowFinder.findRuneScapeWindow()
        return window?.frame
    }

    // MARK: - NSWindowDelegate — save drag offset

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard !isUpdatingPosition,
                  let panel = notification.object as? NSPanel,
                  let windowFrame = lastWindowFrame else { return }

            // windowDidMove fires on every pixel during a drag. Cancel any
            // pending save and reschedule so we only write to UserDefaults once
            // the window has been still for 150 ms — i.e. after mouse-up.
            saveOffsetTask?.cancel()
            saveOffsetTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                let defaultFrame = self.panelFrame(size: self.overlaySize, near: windowFrame, applyOffset: false)
                self.userOffset = CGPoint(
                    x: panel.frame.origin.x - defaultFrame.origin.x,
                    y: panel.frame.origin.y - defaultFrame.origin.y
                )
            }
        }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        Task { @MainActor in
            guard !isUpdatingPosition,
                  let panel = notification.object as? NSPanel,
                  let onResize = self.onResize else { return }

            // Track the live size so panel-frame recomputations (e.g. when
            // the RS window moves) keep using the user's chosen dimensions.
            let newSize = panel.frame.size
            self.overlaySize = newSize

            // Debounce the persist callback the same way we debounce the
            // drag-offset save — only write once the user lets go.
            saveResizeTask?.cancel()
            saveResizeTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                onResize(newSize)
            }
        }
    }

    // MARK: - Dismiss

    func close() {
        // Idempotent: if no panel is live, leave bookkeeping state alone.
        // `show()` calls close() defensively at the top, and the public
        // `showSolutionView` entry point sets `onResize`, `lastWindowFrame`
        // and `overlaySize` *before* calling `show()` so a synchronous
        // delegate callback during `orderFront` sees them. Wiping those
        // fields here would silently break the resize-persist callback for
        // every fresh controller.
        guard panel != nil else { return }

        trackingTimer?.invalidate()
        trackingTimer = nil
        // Flush any pending drag-offset save synchronously so the position is
        // persisted even if the user triggers a new clue within the debounce window.
        flushPendingOffsetSave()
        flushPendingResizeSave()
        saveOffsetTask?.cancel()
        saveOffsetTask = nil
        saveResizeTask?.cancel()
        saveResizeTask = nil
        onResize = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        lastWindowFrame = nil
        isUpdatingPosition = false
    }

    /// Writes the current panel position to UserDefaults immediately, without
    /// waiting for the debounce timer, so position is never lost on quick close.
    private func flushPendingOffsetSave() {
        guard saveOffsetTask != nil,
              let panel,
              let windowFrame = lastWindowFrame else { return }
        let defaultFrame = panelFrame(size: overlaySize, near: windowFrame, applyOffset: false)
        userOffset = CGPoint(
            x: panel.frame.origin.x - defaultFrame.origin.x,
            y: panel.frame.origin.y - defaultFrame.origin.y
        )
    }

    /// Persists the current panel size synchronously if a resize-save is
    /// pending — mirrors `flushPendingOffsetSave` for the resize callback.
    private func flushPendingResizeSave() {
        guard saveResizeTask != nil,
              let panel,
              let onResize else { return }
        onResize(panel.frame.size)
    }

    // MARK: - Frame Calculation

    /// Returns the panel frame for the given overlay size, positioned near the RS window
    /// and offset by any user-saved drag delta, then clamped to the screen that contains
    /// the RS window so the overlay can never drift to a different display.
    private func panelFrame(size: CGSize, near windowFrame: CGRect, applyOffset: Bool = true) -> NSRect {
        let ak = PuzzleSnipDesktop.cgRectToAppKit(windowFrame)
        let offset = applyOffset ? userOffset : .zero
        var frame = NSRect(
            x: ak.maxX - size.width - 16 + offset.x,
            y: ak.maxY - size.height - 16 + offset.y,
            width: size.width,
            height: size.height
        )

        // Clamp to the screen that contains the centre of the RS window so the
        // overlay never inadvertently appears on a different display.
        let rsCenter = CGPoint(x: ak.midX, y: ak.midY)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(rsCenter) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, bounds.minX), bounds.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, bounds.minY), bounds.maxY - size.height)
        }

        return frame
    }
}
