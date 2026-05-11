import AppKit

/// Snip region as fractions of the RuneScape window rect **in the overlay view** (the yellow guide).
/// Matches scaling to the window `CGImage` without relying on global `CGRect` intersection with `SCWindow.frame`
/// (which breaks across displays / coordinate spaces).
struct PuzzleSnipResult: Sendable {
    /// Origin and size in 0…1 relative to the window rect (width/height of `winLocal` in the snip view).
    let cropInWindowNormalized: CGRect
}

@MainActor
final class PuzzleSnipOverlayController: NSObject {
    private var panel: NSPanel?
    private var captureView: PuzzleSnipCaptureView?
    private var continuation: CheckedContinuation<PuzzleSnipResult?, Never>?

    func captureSelection(around windowFrame: CGRect) async -> PuzzleSnipResult? {
        if continuation != nil {
            print("[Opt1] captureSelection: ignored — snip UI already active (duplicate trigger?)")
            return nil
        }
        return await withCheckedContinuation { [weak self] (cont: CheckedContinuation<PuzzleSnipResult?, Never>) in
            guard let self else {
                cont.resume(returning: nil)
                return
            }
            continuation = cont
            presentOverlay(windowFrame: windowFrame)
        }
    }

    private func presentOverlay(windowFrame: CGRect) {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? NSScreen.main
            ?? NSScreen.screens.first!
        let screenFrame = targetScreen.frame

        let panel = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.setFrame(screenFrame, display: true)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let capture = PuzzleSnipCaptureView(frame: NSRect(origin: .zero, size: screenFrame.size), targetWindowFrame: windowFrame)
        capture.autoresizingMask = [.width, .height]
        capture.onSnipComplete = { [weak self] result in
            self?.finish(with: result)
        }
        capture.onSessionEnd = { [weak self] in
            self?.finish(with: nil)
        }

        capture.frame = NSRect(origin: .zero, size: screenFrame.size)
        panel.contentView = capture

        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.captureView = capture
    }

    private func finish(with result: PuzzleSnipResult?) {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        captureView = nil
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class PuzzleSnipCaptureView: NSView {
    /// Drag produced a valid normalized crop.
    var onSnipComplete: ((PuzzleSnipResult) -> Void)?
    /// End overlay without a crop: Escape, bad/empty snip, or missing mouseDown. **Must** be wired or the panel never dismisses.
    var onSessionEnd: (() -> Void)?

    private let targetWindowFrame: CGRect
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(frame frameRect: NSRect, targetWindowFrame: CGRect) {
        self.targetWindowFrame = targetWindowFrame
        super.init(frame: frameRect)
        wantsLayer = false
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    /// `globalRect` is in AppKit desktop coordinates (same as `targetWindowFrame` passed from `appKitGlobalFrame`).
    /// Manual subtract matches `NSWindow.convertFromScreen` without flipping axes.
    private func rectFromGlobalAppKitToLocal(_ globalRect: CGRect) -> CGRect {
        guard let w = window else { return .zero }
        let p = w.frame
        return CGRect(
            x: globalRect.minX - p.minX,
            y: globalRect.minY - p.minY,
            width: globalRect.width,
            height: globalRect.height
        )
    }

    private func eventLocationInView(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func normalizedRectFromIntersection(_ inter: CGRect, win: CGRect) -> CGRect? {
        guard win.width > 2, win.height > 2 else { return nil }
        let nx = (inter.minX - win.minX) / win.width
        let ny = (inter.minY - win.minY) / win.height
        let nw = inter.width / win.width
        let nh = inter.height / win.height
        let x = min(max(nx, 0), 1)
        let y = min(max(ny, 0), 1)
        let x2 = min(max(nx + nw, 0), 1)
        let y2 = min(max(ny + nh, 0), 1)
        let w = max(0, x2 - x)
        let h = max(0, y2 - y)
        guard w > 0.003, h > 0.003 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Use one coordinate space end-to-end (screen/AppKit), then normalize.
    /// If screen conversion fails, fall back to direct local intersection only.
    private func normalizedSnip(selLocal: CGRect, winLocal: CGRect) -> CGRect? {
        guard let wnd = window else { return nil }
        let winGlobal = targetWindowFrame
        let selInWindow = convert(selLocal, to: nil)
        let selGlobal = wnd.convertToScreen(selInWindow)
        let interGlobal = selGlobal.intersection(winGlobal)
        if interGlobal.width >= 1, interGlobal.height >= 1,
           let norm = normalizedRectFromIntersection(interGlobal, win: winGlobal) {
            print("[Opt1] snip: normalized via screen ∩ (global)")
            return norm
        }

        guard winLocal.width > 2, winLocal.height > 2 else { return nil }
        let clipped = selLocal.intersection(winLocal)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        print("[Opt1] snip: normalized via view-local ∩ fallback")
        return normalizedRectFromIntersection(clipped, win: winLocal)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fill(bounds)

        let winRect = rectFromGlobalAppKitToLocal(targetWindowFrame)
        ctx.setStrokeColor(NSColor.yellow.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(winRect)

        if let sel = selectionRectLocal() {
            // Tint (not .clear) so the selection is visible on top of the dim layer.
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.22).cgColor)
            ctx.fill(sel)
            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(sel)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        dragStart = eventLocationInView(event)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        if dragStart == nil {
            dragStart = eventLocationInView(event)
        }
        dragCurrent = eventLocationInView(event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        dragCurrent = eventLocationInView(event)
        needsDisplay = true

        guard let start = dragStart, let end = dragCurrent else {
            print("[Opt1] snip mouseUp: no dragStart/dragCurrent — mouseDown missed?")
            onSessionEnd?()
            return
        }

        let selLocal = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )

        let winLocal = rectFromGlobalAppKitToLocal(targetWindowFrame)
        guard let norm = normalizedSnip(selLocal: selLocal, winLocal: winLocal) else {
            print("[Opt1] snip cancel: selLocal=\(selLocal.integral) winLocal=\(winLocal.integral)")
            onSessionEnd?()
            return
        }

        print("[Opt1] snip OK (normalized in window): \(norm) winLocal=\(winLocal)")
        onSnipComplete?(PuzzleSnipResult(cropInWindowNormalized: norm))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onSessionEnd?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func selectionRectLocal() -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(start.x - current.x),
            height: abs(start.y - current.y)
        )
    }
}
