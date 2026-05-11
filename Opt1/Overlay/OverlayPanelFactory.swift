import AppKit

/// Builds the borderless, non-activating floating panels used by overlays throughout
/// the app (solution overlays, status banner, puzzle-box grid, Celtic-knot arrows).
///
/// Centralising these properties guarantees every overlay panel has consistent
/// behaviour around spaces, mouse passthrough, transparency, and z-order.
enum OverlayPanelFactory {

    /// Creates a transparent floating panel sized to `frame`.
    /// - Parameter passthrough: when `true`, the panel does not intercept mouse events
    ///   (used for pure decoration like arrows/banners); when `false`, the panel is
    ///   interactive (used for solution cards the user can drag).
    static func makeFloatingPanel(frame: NSRect, passthrough: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = passthrough
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hasShadow = false
        return panel
    }
}
