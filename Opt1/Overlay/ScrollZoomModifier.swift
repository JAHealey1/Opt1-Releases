import AppKit
import SwiftUI

// MARK: - Scroll-wheel zoom passthrough

/// Transparent NSView that captures scroll-wheel events via a local event
/// monitor while remaining invisible to hit-testing. This prevents it from
/// blocking SwiftUI gestures (DragGesture, SpatialTapGesture) on views below.
final class ScrollWheelZoomView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var scrollMonitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self,
                      let window = self.window,
                      event.window === window else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(loc) else { return event }
                if event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
                    || event.phase != [] {
                    self.onScroll?(event.scrollingDeltaY)
                    return nil
                }
                return event
            }
        } else if window == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }
}

struct ScrollZoomModifier: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelZoomView {
        let v = ScrollWheelZoomView()
        v.onScroll = onScroll
        return v
    }
    func updateNSView(_ nsView: ScrollWheelZoomView, context: Context) {
        nsView.onScroll = onScroll
    }
}
