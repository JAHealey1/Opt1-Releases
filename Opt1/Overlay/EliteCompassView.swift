import AppKit
import SwiftUI

// MARK: - Elite Compass Triangulation View

/// Persistent overlay for Elite and Master compass clue triangulation.
///
/// Shows the full interactive world map. The user double-clicks to mark their
/// current position, which anchors the pending bearing line. After two bearings
/// from different positions, the intersection is computed and pinned on the map.
///
/// When `state.isEasternLands` is true the map auto-centres on The Arc and
/// the header label changes to "MASTER COMPASS".
struct EliteCompassView: View {
    @ObservedObject var state: CompassTriangulationState
    @State private var hasTiles: Bool? = nil
    @State private var overlayWindow: NSWindow? = nil
    /// Cursor offset from the window's bottom-left corner, captured at drag start.
    /// Stored in AppKit screen coords (Y up) so it is unaffected by window movement.
    @State private var dragAnchorOffset: CGPoint? = nil
    /// Local mirror of `AppSettings.disabledScanTeleportIds` so SwiftUI tracks
    /// the dependency and re-renders when the user disables a teleport.
    @State private var disabledTeleportIds: Set<String> = AppSettings.disabledScanTeleportIds

    /// Default map centre for surface (elite) compass clues — Lumbridge area.
    private static let defaultX = 3222
    private static let defaultY = 3218

    /// Map centre coordinates, switching to The Arc for master (Eastern Lands) compasses.
    private var mapCenterX: Int {
        state.isEasternLands ? MapTileCache.arcCenterX : Self.defaultX
    }
    private var mapCenterY: Int {
        state.isEasternLands ? MapTileCache.arcCenterY : Self.defaultY
    }

    /// Whether auto-triangulation is currently available for this compass type.
    private var autoTriActive: Bool {
        state.isEasternLands
            ? AppSettings.isArcAutoTriangulationEnabled
            : AppSettings.isAutoTriangulationEnabled
    }

    /// Finds the teleport spot nearest to the computed intersection, along with
    /// its distance in tiles. Returns `nil` when no intersection has been
    /// calculated yet. Uses the same `defaultMapId` catalogue slice as the map
    /// renderer so Arc spots are returned in translated game-tile coordinates
    /// and will naturally win the distance comparison when the intersection falls
    /// in the Eastern Lands region.
    private var nearestTeleport: (spot: TeleportSpot, tiles: Double)? {
        guard let pt = state.intersection else { return nil }
        let spots = TeleportCatalogue.shared.spots(forMapId: MapTileCache.defaultMapId)
            .filter { !disabledTeleportIds.contains($0.id) }
        let px = Double(pt.x), py = Double(pt.y)
        guard let closest = spots.min(by: {
            hypot(Double($0.x) - px, Double($0.y) - py) <
            hypot(Double($1.x) - px, Double($1.y) - py)
        }) else { return nil }
        let d = hypot(Double(closest.x) - px, Double(closest.y) - py)
        return (closest, d)
    }

    private var instructionText: String {
        let solveKey = AppSettings.shared.solveHotkey.displayString
        if state.intersection != nil {
            return autoTriActive
                ? "Dig at the intersection! Press \(solveKey) to start a new clue."
                : "Dig at the intersection! Press \(solveKey) for more bearings."
        }
        if state.pendingBearing != nil {
            return autoTriActive
                ? "Auto-anchoring bearing at calibrated point…"
                : "Double-click your position on the map"
        }
        if state.bearings.count == 1 {
            return autoTriActive
                ? "Travel in-game to your second calibrated point, then press \(solveKey)"
                : "Move in-game and press \(solveKey) again"
        }
        return "Press \(solveKey) with the compass visible"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 8) {
                Text(state.isEasternLands ? "MASTER COMPASS" : "ELITE COMPASS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.6))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(OverlayTheme.gold.opacity(0.85)))

                if let pending = state.pendingBearing {
                    Text(pending.formatted())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(OverlayTheme.gold)
                } else if let last = state.bearings.last {
                    Text(last.bearing.formatted())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(OverlayTheme.gold.opacity(0.6))
                }

                Spacer()

                Text("All spots")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(OverlayTheme.textSecondary)
                Toggle("Show all spots", isOn: $state.showAllDigSpots)
                    .toggleStyle(GoldToggleStyle())
                    .help("Show every known compass dig spot as a faint pin (surface + Arc)")

                Text("\(state.bearings.count) bearing\(state.bearings.count == 1 ? "" : "s")")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(OverlayTheme.textSecondary.opacity(0.7))

                Button(action: { state.onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(OverlayTheme.gold.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(OverlayTheme.gold.opacity(0.12)))
                        .overlay(Circle().strokeBorder(OverlayTheme.gold.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close compass overlay")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        guard let win = overlayWindow else { return }
                        // NSEvent.mouseLocation is in AppKit screen coords (Y up),
                        // completely independent of the window's position.
                        let mouse = NSEvent.mouseLocation
                        if dragAnchorOffset == nil {
                            dragAnchorOffset = CGPoint(
                                x: mouse.x - win.frame.origin.x,
                                y: mouse.y - win.frame.origin.y
                            )
                        }
                        let anchor = dragAnchorOffset!
                        win.setFrameOrigin(NSPoint(
                            x: mouse.x - anchor.x,
                            y: mouse.y - anchor.y
                        ))
                    }
                    .onEnded { _ in dragAnchorOffset = nil }
            )
            .background(DragCursorArea())

            Divider().opacity(0.25)

            // Instruction bar
            HStack(spacing: 6) {
                Image(systemName: state.pendingBearing != nil ? "hand.tap" : "location.circle")
                    .font(.system(size: 10))
                    .foregroundColor(OverlayTheme.gold.opacity(0.8))
                Text(instructionText)
                    .font(.system(size: 10))
                    .foregroundColor(OverlayTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Map — flexes to fill remaining vertical space so the user can
            // resize the panel and see more of the map.
            // mapCenterX/Y switches between Lumbridge and The Arc depending on
            // whether this is a surface elite or Eastern Lands master compass.
            // RSWorldMapView's .task(id:) resets the focal point when these change.
            RSWorldMapView(
                gameX:  mapCenterX,
                gameY:  mapCenterY,
                mapId:  MapTileCache.defaultMapId,
                viewportHeight: .infinity,
                hasTiles: $hasTiles,
                showPrimaryPin: false,
                onMapDoubleTap: { gx, gy in
                    state.setOriginForPending(gameX: gx, gameY: gy)
                },
                // When auto-triangulation is enabled the bearing origins
                // come from the user's two saved calibration points, so
                // map double-clicks are suppressed to avoid accidentally
                // overriding them.
                disableDoubleTap: autoTriActive,
                bearingLines: state.bearings,
                intersectionPoint: state.intersection,
                intersectionPolygon: state.intersectionRegion?.polygon,
                digSpotPins: state.showAllDigSpots ? CompassDigSpots.all : [],
                // For Eastern Lands compasses pass the SW/NE corners of the
                // Arc tile area as invisible bounding hints so the map
                // auto-fits to show the full Arc on first open.
                boundsHints: state.isEasternLands
                    ? [MapTileCache.arcBoundsSW, MapTileCache.arcBoundsNE]
                    : []
            )
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            // Nearest teleport banner — visible only once an intersection resolves
            if let nearest = nearestTeleport {
                Divider().opacity(0.2).padding(.horizontal, 8)

                HStack(spacing: 8) {
                    if let iconName = nearest.spot.resolvedIcon,
                       let cg = TeleportSpriteCache.shared.image(named: iconName) {
                        Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 20, height: 20)))
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 12))
                            .foregroundColor(OverlayTheme.gold.opacity(0.7))
                            .frame(width: 20, height: 20)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Closest teleport")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(OverlayTheme.textSecondary.opacity(0.6))
                        Text(nearest.spot.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(OverlayTheme.gold)
                        Text(nearest.spot.groupName)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(OverlayTheme.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(Int(nearest.tiles.rounded())) tiles")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(OverlayTheme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(OverlayTheme.gold.opacity(0.12)))

                        Button {
                            AppSettings.disableScanTeleport(id: nearest.spot.id)
                            disabledTeleportIds = AppSettings.disabledScanTeleportIds
                        } label: {
                            Text("I don't have this")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(0.08)))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Exclude this teleport from suggestions. Re-enable it in Settings → Scan Teleports.")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Close button
            Button(action: { state.onClose?() }) {
                Text("Close")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(OverlayTheme.bgDeep)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(OverlayTheme.gold.opacity(0.75)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(OverlayTheme.goldBorder.opacity(0.4), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowAccessor(window: $overlayWindow))
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .fill(OverlayTheme.bgPrimary.opacity(OverlayTheme.bgPrimaryOp))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.goldBorder.opacity(0.50), lineWidth: OverlayTheme.borderWidth)
        )
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            disabledTeleportIds = AppSettings.disabledScanTeleportIds
        }
    }
}

// MARK: - Helpers

/// Captures the hosting NSWindow from within a SwiftUI view tree.
/// Needed because the overlay is a non-activating NSPanel, so NSApp.keyWindow
/// is unreliable for obtaining the panel reference from SwiftUI.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { window = v.window }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shows the open-hand cursor when the pointer is over the drag handle area.
/// Uses `.activeAlways` so it works on the non-activating NSPanel overlay.
/// SwiftUI's built-in `.onHover` uses `.activeInKeyWindow`, which never fires
/// on a non-activating panel, making this custom NSView necessary.
private struct DragCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragCursorView { DragCursorView() }
    func updateNSView(_ nsView: DragCursorView, context: Context) {}
}

private final class DragCursorView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent)  { NSCursor.arrow.set() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

