import AppKit
import SwiftUI

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - RS World Map View (interactive tiled map)

/// Kartographer-style interactive tiled map viewer for RS3 world coordinates.
///
/// Renders a fixed-size viewport over the full local tile cache with:
///   • Pan  — drag to move the map freely
///   • Zoom — scroll-wheel, pinch gesture, or +/− buttons
///   • Pin  — teardrop marker(s) drawn in screen-space at world coordinates
///
/// Tiles are loaded lazily from ~/Library/Application Support/Opt1/MapTiles/
/// and cached for the lifetime of the view. Missing tiles are left transparent.
/// If no tiles exist at all, `hasTiles` is set to false so the caller can
/// suppress the map entirely.
struct RSWorldMapView: View {
    let gameX:  Int
    let gameY:  Int
    let mapId:  Int
    /// Additional pins beyond the primary (gameX, gameY) pin.
    var extraPins: [(x: Int, y: Int)] = []
    /// Fixed pixel height for the map viewport. Pass `.infinity` to let the
    /// map fill whatever height its parent gives it (used by the resizable
    /// elite-compass overlay).
    var viewportHeight: CGFloat = 280
    @Binding var hasTiles: Bool?
    /// When true, the primary (gameX, gameY) pin is drawn. Set to false for
    /// map-only modes like elite compass triangulation.
    var showPrimaryPin: Bool = true
    /// Double-click callback returning game-tile coordinates. When non-nil,
    /// a double-click gesture is layered on the map canvas.
    var onMapDoubleTap: ((Int, Int) -> Void)? = nil
    /// When true, the double-click callback is suppressed even if
    /// `onMapDoubleTap` is set. Used by the elite-compass overlay when
    /// auto-triangulation is active so map clicks cannot accidentally
    /// override the auto-anchored bearing origin.
    var disableDoubleTap: Bool = false
    /// Bearing lines to render on the Canvas (elite compass triangulation).
    var bearingLines: [BearingLine] = []
    /// Intersection point of the bearing lines (game-tile coords).
    var intersectionPoint: CGPoint? = nil
    /// Optional polygonal intersection region (game-tile coords) — when
    /// supplied, rendered as a filled+stroked polygon. The pin (if any) is
    /// drawn at the polygon's centroid (`intersectionPoint`).
    var intersectionPolygon: [CGPoint]? = nil
    /// Known dig spots to render as faint cyan pins. Used by the elite
    /// compass overlay's "Show all dig spots" toggle. Drawn under the
    /// triangulation pins so they don't visually compete with the result.
    var digSpotPins: [DigSpot] = []
    /// Pins to draw at reduced opacity (0.22). Used by the scan overlay to
    /// show spots eliminated by the current pulse filter without removing them
    /// from view entirely.
    var dimmedPins: [(x: Int, y: Int)] = []
    /// Player-position markers drawn as green pins above all other pins.
    /// The scan overlay appends a pin for each confirmed observation and
    /// for the current pending position.
    var playerPins: [(x: Int, y: Int)] = []
    /// Recommended next observation position emitted by `ScanOptimiser`.
    /// Drawn as a gold target ring on top of all other layers so it is
    /// immediately visible, but visually distinct from confirmed pins.
    var recommendedPin: (x: Int, y: Int)? = nil
    /// Game-tile coordinates used solely to compute the initial auto-fit scale
    /// and focal point. Unlike `extraPins` these are never rendered as visible
    /// pins on the map — they act as invisible bounding-box anchors.
    var boundsHints: [(x: Int, y: Int)] = []

    /// User toggle — surfaced via `SettingsView`'s "Show teleport icons on
    /// map" switch and the `AppSettings.Keys.showTeleports` key. Default-on.
    @AppStorage(AppSettings.Keys.showTeleports) private var showTeleports: Bool = true

    // Committed pan/zoom state
    @State private var focalPt: CGPoint = .zero
    @State private var scale:   CGFloat = Self.defaultScale
    // Live gesture deltas (merged into committed state on gesture end)
    @State private var dragDelta: CGSize  = .zero
    @State private var gesScale:  CGFloat = 1.0
    // Tile image cache  key = "\(tx)_\(ty)".
    // CGImage (force-decoded off-main) so the Canvas composite stays cheap —
    // NSImage would defer PNG decode until first draw on the main actor.
    @State private var tileCache: [String: CGImage] = [:]
    @State private var initialCheckDone = false
    // Measured once via background GeometryReader; used for tile-visibility math
    @State private var vpSize: CGSize = CGSize(width: 456, height: 280)
    // Single in-flight tile-load task used to coalesce rapid gestures.
    @State private var loadTask: Task<Void, Never>? = nil

    private static let tilePixels:    CGFloat = 256
    private static let pxPerGameTile: CGFloat = 4        // tilePixels / tilePitch (256/64)
    private static let scaleRange: ClosedRange<CGFloat> = 0.10...5.0
    private static let defaultScale:  CGFloat = 0.28     // ≈ 6-7 tiles wide in a 456 pt viewport
    /// Zoom used when elite-compass triangulation yields an intersection — tighter than
    /// the multi-pin auto-fit (~2–3 map tiles wide at a typical overlay width).
    private static let intersectionRevealScale: CGFloat = 0.72
    private static let pinRadius:     CGFloat = 9        // fixed screen-space pin size (pts)
    /// Debounce window for coalescing rapid gesture-end loads (scroll-wheel
    /// zoom, pinch, drag). A fresh call cancels any pending load so we only
    /// hit disk once per gesture burst.
    private static let loadDebounceNs: UInt64 = 60_000_000

    // MARK: - Coordinate helpers

    private static func toMapPx(_ coord: Int) -> CGFloat { CGFloat(coord) * pxPerGameTile }

    private func effectiveScale() -> CGFloat { scale * gesScale }

    /// Effective focal point accounting for the live drag offset.
    /// Drag right (positive width) moves the focal point westward (smaller mapX).
    private func effectiveFocal() -> CGPoint {
        let s = effectiveScale()
        return CGPoint(x: focalPt.x - dragDelta.width  / s,
                       y: focalPt.y + dragDelta.height / s)   // y-flip: drag up → focal moves north
    }

    /// RS map-pixel coordinate → SwiftUI Canvas screen point.
    /// RS y increases northward; Canvas y increases downward → y-axis flip applied.
    private func toScreen(_ mx: CGFloat, _ my: CGFloat,
                          size: CGSize, s: CGFloat, focal: CGPoint) -> CGPoint {
        CGPoint(x:  (mx - focal.x) * s + size.width  / 2,
                y: -(my - focal.y) * s + size.height / 2)
    }

    /// Inverse of toScreen(): screen point → game-tile coordinates.
    private func fromScreen(_ screenPt: CGPoint, size: CGSize,
                            s: CGFloat, focal: CGPoint) -> (Int, Int) {
        let mx = (screenPt.x - size.width  / 2)  / s + focal.x
        let my = -(screenPt.y - size.height / 2) / s + focal.y
        return (Int(mx / Self.pxPerGameTile), Int(my / Self.pxPerGameTile))
    }

    /// Screen-space CGRect for tile (tx, ty).
    /// The tile's NW corner in RS map-pixels = (tx·256, (ty+1)·256) → screen top-left.
    private func tileRect(tx: Int, ty: Int,
                          size: CGSize, s: CGFloat, focal: CGPoint) -> CGRect {
        let side    = Self.tilePixels * s
        let topLeft = toScreen(CGFloat(tx)     * Self.tilePixels,
                               CGFloat(ty + 1) * Self.tilePixels,
                               size: size, s: s, focal: focal)
        return CGRect(x: topLeft.x, y: topLeft.y, width: side, height: side)
    }

    /// Tile grid indices that overlap the viewport, with a 1-tile buffer on each edge.
    private func visibleTileKeys(size: CGSize, s: CGFloat, focal: CGPoint) -> [(Int, Int)] {
        let halfW = size.width  / 2 / s + Self.tilePixels
        let halfH = size.height / 2 / s + Self.tilePixels
        let txMin = Int(floor((focal.x - halfW) / Self.tilePixels))
        let txMax = Int(ceil( (focal.x + halfW) / Self.tilePixels))
        let tyMin = Int(floor((focal.y - halfH) / Self.tilePixels))
        let tyMax = Int(ceil( (focal.y + halfH) / Self.tilePixels))
        var result: [(Int, Int)] = []
        for ty in tyMin...tyMax {
            for tx in txMin...txMax { result.append((tx, ty)) }
        }
        return result
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottomTrailing) {

            // ── Tiled map canvas ─────────────────────────────────────────
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.06, green: 0.05, blue: 0.02)))

                let s  = self.effectiveScale()
                let fc = self.effectiveFocal()

                for (tx, ty) in visibleTileKeys(size: size, s: s, focal: fc) {
                    let rect = tileRect(tx: tx, ty: ty, size: size, s: s, focal: fc)
                    guard rect.maxX > 0, rect.minX < size.width,
                          rect.maxY > 0, rect.minY < size.height else { continue }
                    if let img = tileCache["\(tx)_\(ty)"] {
                        ctx.draw(Image(decorative: img, scale: 1.0), in: rect)
                    }
                }

                // Teleport sprite layer (sits between tiles and pins so
                // beams/pins remain visually dominant when both layers
                // overlap a single spot).
                if showTeleports {
                    TeleportLayer.draw(
                        &ctx,
                        spots: TeleportCatalogue.shared.spots(forMapId: mapId),
                        spriteLookup: { TeleportSpriteCache.shared.image(named: $0) },
                        size: size, s: s, focal: fc,
                        toScreenFn: toScreen,
                        toMapPxFn: Self.toMapPx
                    )
                }

                // Known dig-spot pins ("Show all dig spots" toggle). Drawn
                // above teleports but under bearing beams / intersection
                // overlays so the triangulation result stays dominant.
                if !digSpotPins.isEmpty {
                    Self.drawDigSpotPins(&ctx, spots: digSpotPins,
                                         size: size, s: s, focal: fc,
                                         toScreenFn: toScreen)
                }

                // Bearing beams + centerlines (elite compass triangulation)
                for line in bearingLines {
                    Self.drawBearingBeam(&ctx, line: line, size: size, s: s, focal: fc,
                                         toScreenFn: toScreen)
                }

                // Intersection polygon (translucent fill + stroke)
                if let poly = intersectionPolygon, poly.count >= 2 {
                    Self.drawIntersectionRegion(
                        &ctx, polygon: poly, size: size, s: s, focal: fc,
                        toScreenFn: toScreen
                    )
                }

                // Intersection pin (gold, distinct from standard red pins)
                if let ix = intersectionPoint {
                    let sp = toScreen(Self.toMapPx(Int(ix.x)), Self.toMapPx(Int(ix.y)),
                                      size: size, s: s, focal: fc)
                    Self.drawPin(&ctx, at: sp, radius: Self.pinRadius,
                                 fill: Color(red: 1.0, green: 0.84, blue: 0.0),
                                 stroke: Color(red: 0.55, green: 0.45, blue: 0.0))
                }

                // Dimmed pins (scan pulse filter — excluded spots at reduced opacity)
                for pin in dimmedPins {
                    let pp = toScreen(Self.toMapPx(pin.x), Self.toMapPx(pin.y),
                                      size: size, s: s, focal: fc)
                    Self.drawPin(&ctx, at: pp, radius: Self.pinRadius,
                                 fill:   Color(red: 0.96, green: 0.27, blue: 0.18).opacity(0.22),
                                 stroke: Color(red: 0.20, green: 0.04, blue: 0.04).opacity(0.22))
                }

                // Primary pin
                if showPrimaryPin {
                    let primary = toScreen(Self.toMapPx(gameX), Self.toMapPx(gameY),
                                           size: size, s: s, focal: fc)
                    Self.drawPin(&ctx, at: primary, radius: Self.pinRadius)
                }

                // Optional extra pins
                for pin in extraPins {
                    let pp = toScreen(Self.toMapPx(pin.x), Self.toMapPx(pin.y),
                                      size: size, s: s, focal: fc)
                    Self.drawPin(&ctx, at: pp, radius: Self.pinRadius)
                }

                // Player position pins (scan overlay — green)
                for pp in playerPins {
                    let sp = toScreen(Self.toMapPx(pp.x), Self.toMapPx(pp.y),
                                      size: size, s: s, focal: fc)
                    Self.drawPin(&ctx, at: sp, radius: Self.pinRadius,
                                 fill:   Color(red: 0.30, green: 0.92, blue: 0.38),
                                 stroke: Color(red: 0.08, green: 0.32, blue: 0.10))
                }

                // Recommended scan position (top-most — gold target ring)
                if let rp = recommendedPin {
                    let sp = toScreen(Self.toMapPx(rp.x), Self.toMapPx(rp.y),
                                      size: size, s: s, focal: fc)
                    Self.drawRecommendedPin(&ctx, at: sp, radius: Self.pinRadius)
                }
            }
            .overlay(
                // Spinner shown until the initial tile-existence check completes
                Group {
                    if !initialCheckDone {
                        ProgressView()
                            .scaleEffect(0.65)
                            .tint(.white.opacity(0.45))
                    }
                }
            )
            // ── Pan gesture ──────────────────────────────────────────────
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in dragDelta = v.translation }
                    .onEnded   { _ in
                        focalPt   = effectiveFocal()
                        dragDelta = .zero
                        scheduleTileLoad()
                    }
            )
            // ── Pinch-to-zoom ────────────────────────────────────────────
            .gesture(
                MagnificationGesture()
                    .onChanged { v in gesScale = v }
                    .onEnded   { v in
                        scale    = (scale * v).clamped(to: Self.scaleRange)
                        gesScale = 1.0
                        scheduleTileLoad()
                    }
            )
            // ── Scroll-wheel zoom ────────────────────────────────────────
            .overlay(
                ScrollZoomModifier { delta in
                    let factor = 1.0 + delta * 0.015
                    scale = (scale * factor).clamped(to: Self.scaleRange)
                    scheduleTileLoad()
                }
            )
            // ── Double-click to mark position ────────────────────────────
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        guard !disableDoubleTap, let callback = onMapDoubleTap else { return }
                        let s  = effectiveScale()
                        let fc = effectiveFocal()
                        let size = vpSize.width > 0
                            ? vpSize
                            : CGSize(width: 456, height: viewportHeight.isFinite ? viewportHeight : 380)
                        let (gx, gy) = fromScreen(value.location, size: size, s: s, focal: fc)
                        print("[Opt1] Map double-click: screen=\(value.location), game=(\(gx), \(gy)), scale=\(s)")
                        callback(gx, gy)
                    }
            )
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )

            // ── Zoom / reset controls ────────────────────────────────────
            HStack(spacing: 4) {
                Button("+") {
                    withAnimation(.easeOut(duration: 0.12)) {
                        scale = (scale * 1.35).clamped(to: Self.scaleRange)
                    }
                    scheduleTileLoad()
                }
                .accessibilityLabel("Zoom in")
                Button("−") {
                    withAnimation(.easeOut(duration: 0.12)) {
                        scale = (scale / 1.35).clamped(to: Self.scaleRange)
                    }
                    scheduleTileLoad()
                }
                .accessibilityLabel("Zoom out")
                Button("↺") {
                    withAnimation(.spring(duration: 0.2)) {
                        focalPt   = CGPoint(x: Self.toMapPx(gameX), y: Self.toMapPx(gameY))
                        scale     = Self.defaultScale
                        dragDelta = .zero
                        gesScale  = 1.0
                    }
                    scheduleTileLoad()
                }
                .accessibilityLabel("Reset map view")
                .accessibilityHint("Re-centres the map on the primary pin at the default zoom level.")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(OverlayTheme.gold)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(OverlayTheme.bgDeep.opacity(0.88)))
            .padding(6)
        }
        .frame(maxWidth: .infinity,
               minHeight: viewportHeight.isFinite ? viewportHeight : 200,
               maxHeight: viewportHeight.isFinite ? viewportHeight : .infinity)
        .clipped()
        // Measure the actual viewport size so loadVisibleTiles() knows what's
        // on screen — using onChange so resizable parents (elite compass)
        // refresh tile loading when the user drags the panel edge.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { vpSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in
                        guard newSize != vpSize else { return }
                        vpSize = newSize
                        scheduleTileLoad()
                    }
            }
        )
        .onChange(of: intersectionPoint) { _, newPoint in
            guard let ix = newPoint else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                focalPt   = CGPoint(x: Self.toMapPx(Int(ix.x)), y: Self.toMapPx(Int(ix.y)))
                scale     = Self.intersectionRevealScale.clamped(to: Self.scaleRange)
                dragDelta = .zero
                gesScale  = 1.0
            }
            scheduleTileLoad()
        }
        .task(id: "\(gameX),\(gameY),\(mapId)") {
            initialCheckDone = false
            tileCache        = [:]
            dragDelta        = .zero
            gesScale         = 1.0
            // Choose initial focal point and scale to fit all pins.
            // `boundsHints` extend the bounding box without rendering a pin.
            let renderPins = [(gameX, gameY)] + extraPins.map { ($0.x, $0.y) }
            let allPins    = renderPins + boundsHints.map { ($0.x, $0.y) }
            let centX = renderPins.map(\.0).reduce(0, +) / renderPins.count
            let centY = renderPins.map(\.1).reduce(0, +) / renderPins.count
            focalPt = CGPoint(x: Self.toMapPx(centX), y: Self.toMapPx(centY))

            if allPins.count > 1 {
                // Auto-fit: pick a scale that shows all pins with a 1-tile margin each side
                let size = vpSize.width > 0
                    ? vpSize
                    : CGSize(width: 456, height: viewportHeight.isFinite ? viewportHeight : 380)
                let pxX  = allPins.map { Self.toMapPx($0.0) }
                let pxY  = allPins.map { Self.toMapPx($0.1) }
                let spanX = (pxX.max()! - pxX.min()!) + Self.tilePixels * 2
                let spanY = (pxY.max()! - pxY.min()!) + Self.tilePixels * 2
                let fitS  = min(size.width / max(spanX, 1), size.height / max(spanY, 1))
                scale = fitS.clamped(to: Self.scaleRange)
            } else {
                scale = Self.defaultScale
            }
            await loadVisibleTiles()
        }
    }

    // MARK: - Tile loading

    /// Coalesces rapid gesture-end loads: cancels any in-flight debounce and
    /// schedules a single `loadVisibleTiles()` after `loadDebounceNs`.
    private func scheduleTileLoad() {
        loadTask?.cancel()
        loadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.loadDebounceNs)
            if Task.isCancelled { return }
            await loadVisibleTiles()
        }
    }

    @MainActor
    private func loadVisibleTiles() async {
        let s     = effectiveScale()
        let focal = effectiveFocal()
        let size  = vpSize.width > 0
            ? vpSize
            : CGSize(width: 456, height: viewportHeight.isFinite ? viewportHeight : 380)
        let keys  = visibleTileKeys(size: size, s: s, focal: focal)

        let existingKeys = Set(tileCache.keys)
        var anyFound     = !existingKeys.isEmpty

        let needed = keys.filter { !existingKeys.contains("\($0.0)_\($0.1)") }

        if !needed.isEmpty {
            let resolvedMapId = mapId
            // Force-decode NSImage → CGImage inside the child tasks so all
            // PNG decoding happens off the main actor. Canvas draws only see
            // already-decoded bitmaps.
            let loaded: [(String, CGImage)] = await withTaskGroup(of: (String, CGImage)?.self) { group in
                for (tx, ty) in needed {
                    group.addTask {
                        guard let ns = MapTileCache.load(tx: tx, ty: ty, mapId: resolvedMapId),
                              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
                        else { return nil }
                        return ("\(tx)_\(ty)", cg)
                    }
                }
                var results: [(String, CGImage)] = []
                for await entry in group { if let e = entry { results.append(e) } }
                return results
            }
            for (k, img) in loaded { tileCache[k] = img }
            if !loaded.isEmpty { anyFound = true }
        }

        if !initialCheckDone {
            initialCheckDone = true
            hasTiles = anyFound
        }
    }

    // MARK: - Pin drawing

    /// Draws a teardrop map-pin into a SwiftUI Canvas GraphicsContext.
    ///
    /// `pos` is the screen-space tip of the pin (points to the exact world coordinate).
    /// The teardrop head is drawn above the tip (lower screen-y in Canvas y-down space).
    static func drawPin(_ ctx: inout GraphicsContext, at pos: CGPoint, radius r: CGFloat,
                         fill: Color = Color(red: 0.96, green: 0.27, blue: 0.18),
                         stroke: Color = Color(red: 0.20, green: 0.04, blue: 0.04)) {
        let cx     = pos.x
        let tipY   = pos.y
        let headCY = tipY - r * 2.3

        var path = Path()
        path.move(to: CGPoint(x: cx, y: tipY))

        path.addCurve(to:      CGPoint(x: cx - r,         y: headCY),
                      control1: CGPoint(x: cx - r * 0.55, y: tipY  - r * 0.6),
                      control2: CGPoint(x: cx - r,        y: headCY + r * 0.7))

        path.addArc(center: CGPoint(x: cx, y: headCY), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)

        path.addCurve(to:      CGPoint(x: cx,             y: tipY),
                      control1: CGPoint(x: cx + r,        y: headCY + r * 0.7),
                      control2: CGPoint(x: cx + r * 0.55, y: tipY  - r * 0.6))
        path.closeSubpath()

        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - r * 0.5, y: tipY - r * 0.15, width: r, height: r * 0.3)),
            with: .color(.black.opacity(0.35))
        )

        ctx.fill(path, with: .color(fill))
        ctx.stroke(path, with: .color(stroke), lineWidth: r * 0.14)

        let dr = r * 0.38
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - dr, y: headCY - dr, width: dr * 2, height: dr * 2)),
            with: .color(.white.opacity(0.92))
        )
    }

    // MARK: - Recommended scan position drawing

    /// Draws a gold target-ring marker for the `ScanOptimiser`-recommended
    /// observation position.
    ///
    /// The ring style is intentionally different from the teardrop pins used
    /// for dig spots and player positions: a bold stroked circle with a filled
    /// centre dot and a ground-shadow ellipse. The hollow ring signals
    /// "suggested, not confirmed".
    static func drawRecommendedPin(_ ctx: inout GraphicsContext,
                                   at pos: CGPoint,
                                   radius r: CGFloat) {
        let gold     = Color(red: 1.0,  green: 0.84, blue: 0.0)
        let darkGold = Color(red: 0.55, green: 0.45, blue: 0.0)

        // Ground shadow
        ctx.fill(
            Path(ellipseIn: CGRect(x: pos.x - r * 0.55, y: pos.y - r * 0.18,
                                   width: r * 1.1, height: r * 0.36)),
            with: .color(.black.opacity(0.28))
        )

        // Outer ring (stroked, hollow)
        let outerRect = CGRect(x: pos.x - r, y: pos.y - r,
                               width: r * 2, height: r * 2)
        ctx.stroke(Path(ellipseIn: outerRect),
                   with: .color(gold.opacity(0.95)),
                   lineWidth: r * 0.28)

        // Inner ring (tighter, darker — gives a double-ring "target" look)
        let innerR    = r * 0.58
        let innerRect = CGRect(x: pos.x - innerR, y: pos.y - innerR,
                               width: innerR * 2, height: innerR * 2)
        ctx.stroke(Path(ellipseIn: innerRect),
                   with: .color(darkGold.opacity(0.70)),
                   lineWidth: r * 0.15)

        // Centre dot
        let dotR    = r * 0.22
        let dotRect = CGRect(x: pos.x - dotR, y: pos.y - dotR,
                             width: dotR * 2, height: dotR * 2)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(gold))
    }

    // MARK: - Bearing beam drawing

    /// Draws a bearing beam (wedge at `median ± epsilon`) plus the centerline,
    /// originating from a game-tile coordinate. Also draws a small dot at the
    /// origin. When epsilon is tiny, falls back to a thin centerline only.
    static func drawBearingBeam(_ ctx: inout GraphicsContext,
                                line: BearingLine,
                                size: CGSize, s: CGFloat, focal: CGPoint,
                                toScreenFn: (CGFloat, CGFloat, CGSize, CGFloat, CGPoint) -> CGPoint) {
        let originScreen = toScreenFn(toMapPx(Int(line.origin.x)),
                                       toMapPx(Int(line.origin.y)),
                                       size, s, focal)

        // Bearing CW from North. RS +y = screen -y (y-flip), RS +x = screen +x.
        // dx_screen =  sin(rad), dy_screen = -cos(rad).
        let mid = line.bearing.bearingRadians
        let eps = line.bearing.epsilonRadians

        let extent: CGFloat = 50_000  // large enough to cross the viewport at any zoom level

        // Centerline (always)
        let dxC =  sin(mid)
        let dyC = -cos(mid)
        let toC = CGPoint(x: originScreen.x + dxC * extent,
                          y: originScreen.y + dyC * extent)
        var linePath = Path()
        linePath.move(to: originScreen)
        linePath.addLine(to: toC)
        ctx.stroke(linePath, with: .color(.cyan.opacity(0.85)), lineWidth: 1.25)

        // Beam wedge (only if epsilon is meaningful)
        if eps > 1e-4 {
            let loR = mid - eps
            let hiR = mid + eps
            let dxLo =  sin(loR), dyLo = -cos(loR)
            let dxHi =  sin(hiR), dyHi = -cos(hiR)
            let toLo = CGPoint(x: originScreen.x + dxLo * extent,
                               y: originScreen.y + dyLo * extent)
            let toHi = CGPoint(x: originScreen.x + dxHi * extent,
                               y: originScreen.y + dyHi * extent)

            var wedge = Path()
            wedge.move(to: originScreen)
            wedge.addLine(to: toLo)
            wedge.addLine(to: toHi)
            wedge.closeSubpath()

            ctx.fill(wedge, with: .color(.cyan.opacity(0.10)))
            ctx.stroke(wedge, with: .color(.cyan.opacity(0.45)), lineWidth: 0.75)
        }

        // Origin dot
        let dotR: CGFloat = 5
        ctx.fill(
            Path(ellipseIn: CGRect(x: originScreen.x - dotR, y: originScreen.y - dotR,
                                   width: dotR * 2, height: dotR * 2)),
            with: .color(.cyan.opacity(0.9))
        )
        ctx.stroke(
            Path(ellipseIn: CGRect(x: originScreen.x - dotR, y: originScreen.y - dotR,
                                   width: dotR * 2, height: dotR * 2)),
            with: .color(.white.opacity(0.6)), lineWidth: 1
        )
    }

    /// Draws the bundled compass dig-spot catalogue as small cyan pins.
    /// Off-screen pins are skipped for performance — there are ~480 of them
    /// when the toggle is on and the user might be zoomed deep into a region.
    static func drawDigSpotPins(_ ctx: inout GraphicsContext,
                                spots: [DigSpot],
                                size: CGSize, s: CGFloat, focal: CGPoint,
                                toScreenFn: (CGFloat, CGFloat, CGSize, CGFloat, CGPoint) -> CGPoint) {
        let r: CGFloat = 6.5
        let pad: CGFloat = r * 3   // teardrop head sits ~2.3·r above the tip
        let fill = Color(red: 0.20, green: 0.78, blue: 0.92).opacity(0.85)
        let stroke = Color(red: 0.04, green: 0.20, blue: 0.32)
        for spot in spots {
            let p = toScreenFn(toMapPx(spot.x), toMapPx(spot.y), size, s, focal)
            guard p.x > -pad, p.x < size.width + pad,
                  p.y > -pad, p.y < size.height + pad else { continue }
            drawPin(&ctx, at: p, radius: r, fill: fill, stroke: stroke)
        }
    }

    /// Draws the intersection polygon (translucent gold fill + stroke).
    static func drawIntersectionRegion(_ ctx: inout GraphicsContext,
                                        polygon: [CGPoint],
                                        size: CGSize, s: CGFloat, focal: CGPoint,
                                        toScreenFn: (CGFloat, CGFloat, CGSize, CGFloat, CGPoint) -> CGPoint) {
        guard polygon.count >= 2 else { return }
        var path = Path()
        for (i, p) in polygon.enumerated() {
            let sp = toScreenFn(toMapPx(Int(p.x)), toMapPx(Int(p.y)),
                                size, s, focal)
            if i == 0 { path.move(to: sp) } else { path.addLine(to: sp) }
        }
        if polygon.count >= 3 { path.closeSubpath() }

        let gold = Color(red: 1.0, green: 0.84, blue: 0.0)
        if polygon.count >= 3 {
            ctx.fill(path, with: .color(gold.opacity(0.18)))
        }
        ctx.stroke(path, with: .color(gold.opacity(0.85)), lineWidth: 1.25)
    }
}
