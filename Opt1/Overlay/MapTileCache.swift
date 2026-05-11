import AppKit
import Foundation

// MARK: - Shared tile-cache helpers

enum MapTileCache {
    static let tilePitch      = 64
    static let tileSize       = 256
    static let defaultMapId   = 28
    static let arcMapId       = 695
    static let arcTyThreshold = 140

    /// Game-tile centre of The Arc (Eastern Lands), derived from the centroid
    /// of the bundled Arc compass dig spots. The Arc lives at high-TX within
    /// the standard mapId 28 tile set — the 695 tiles are a separate,
    /// lower-quality alternative and should not be used for the overlay.
    static let arcCenterX = 4083
    static let arcCenterY = 1907

    /// SW and NE bounding corners for the Arc (Eastern Lands) region,
    /// used as `boundsHints` in RSWorldMapView to auto-fit the initial scale.
    /// Padded slightly beyond the dig-spot extent (3743–4492, 1499–2329).
    static let arcBoundsSW = (x: 3550, y: 1180)
    static let arcBoundsNE = (x: 4544, y: 2560)

    static let dir: URL = {
        Bundle.main.resourceURL!.appendingPathComponent("MapTiles")
    }()

    /// Resolves the effective mapId stored on disk, matching the Python download logic:
    /// surface default (28) tiles with ty ≥ 140 are stored under mapId 695 (Arc).
    static func effectiveMapId(_ mapId: Int, ty: Int) -> Int {
        guard mapId == defaultMapId else { return mapId }
        return ty >= arcTyThreshold ? arcMapId : defaultMapId
    }

    static func load(tx: Int, ty: Int, mapId: Int = defaultMapId) -> NSImage? {
        let mid = effectiveMapId(mapId, ty: ty)
        if let img = NSImage(contentsOf: dir.appendingPathComponent("\(mid)_\(tx)_\(ty).png")) {
            return img
        }
        // mapId=-1 is the wiki's "Default" layer — a combined view covering the surface
        // world, underground dungeons, and the Eastern Lands at global game coordinates.
        // Use it as a runtime fallback for any specific underground mapId whose tiles
        // weren't downloaded (e.g. Zanaris=1, Taverley=17, Keldagrim=21, etc.).
        if mid != -1 && mid != defaultMapId && mid != arcMapId {
            return NSImage(contentsOf: dir.appendingPathComponent("-1_\(tx)_\(ty).png"))
        }
        return nil
    }

    /// Composites tiles covering [txMin…txMax] × [tyMin…tyMax] into one NSImage.
    /// Returns nil if no tile files exist in that range.
    static func composite(txMin: Int, txMax: Int, tyMin: Int, tyMax: Int,
                          mapId: Int = defaultMapId) -> NSImage? {
        let cols = txMax - txMin + 1
        let rows = tyMax - tyMin + 1
        let imgW = cols * tileSize
        let imgH = rows * tileSize

        var anyFound = false
        let composite = NSImage(size: NSSize(width: imgW, height: imgH))
        composite.lockFocus()
        NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.02, alpha: 1).setFill()
        NSRect(origin: .zero, size: NSSize(width: imgW, height: imgH)).fill()

        for row in 0..<rows {
            for col in 0..<cols {
                let tx = txMin + col
                let ty = tyMin + row
                if let img = load(tx: tx, ty: ty, mapId: mapId) {
                    anyFound = true
                    let drawX = CGFloat(col * tileSize)
                    // RS y increases northward; Quartz y=0 is at the bottom of the
                    // NSImage canvas (SwiftUI does NOT flip NSImage on macOS).
                    // row=0 = tyMin = southernmost → drawY=0 (bottom of canvas = bottom of screen).
                    // row=rows-1 = tyMax = northernmost → drawY=(rows-1)*tileSize (top of screen). ✓
                    let drawY = CGFloat(row * tileSize)
                    img.draw(in: NSRect(x: drawX, y: drawY,
                                       width: CGFloat(tileSize), height: CGFloat(tileSize)))
                }
            }
        }
        composite.unlockFocus()
        return anyFound ? composite : nil
    }

    /// Pixel position of a game coordinate within a composite image whose
    /// north-west corner is at mapsquare (txMin, tyMin).
    /// Quartz y=0 is at the bottom, RS y increases northward — they agree.
    static func pixelPos(gameX: Int, gameY: Int,
                         txMin: Int, tyMin: Int) -> CGPoint {
        let px = Double(gameX) / Double(tilePitch) - Double(txMin)
        let py = Double(gameY) / Double(tilePitch) - Double(tyMin)
        return CGPoint(x: px * Double(tileSize), y: py * Double(tileSize))
    }
}

// MARK: - Sea Detection

extension MapTileCache {

    /// Reusable, per-optimiser-call helper for detecting open-sea candidates.
    ///
    /// Caches decoded `NSBitmapImageRep` objects keyed by tile so every tile
    /// image is only loaded and decoded once, even when many nearby grid points
    /// sample pixels from the same tile.
    struct SeaChecker {

        // RS3 wiki map sea colour ≈ RGB (107, 132, 155); ±22 tolerance per channel.
        private static let seaR = 107, seaG = 132, seaB = 155, seaTol = 22

        private var reps: [String: NSBitmapImageRep?] = [:]

        /// Returns `true` when (gameX, gameY) appears to be open sea.
        ///
        /// Five sample points are tested (centre + four cardinal offsets at
        /// `sampleRadius` game tiles). All five must match the sea colour for the
        /// position to be rejected.
        ///
        /// A radius of 1 is deliberately tight: a sea candidate near a coastline
        /// can have one of its wide cardinal samples land on a land or coast tile,
        /// causing `allSatisfy` to fail and the sea spot to slip through. Keeping
        /// the samples at 1-tile spacing ensures they all stay within the water
        /// body for any genuinely ocean position.
        mutating func isSea(gameX: Int, gameY: Int, mapId: Int,
                            sampleRadius: Int = 1) -> Bool {
            let offsets: [(Int, Int)] = [
                (0, 0),
                ( sampleRadius,  0),
                (-sampleRadius,  0),
                (0,  sampleRadius),
                (0, -sampleRadius),
            ]
            return offsets.allSatisfy { dx, dy in
                pixelIsSea(gx: gameX + dx, gy: gameY + dy, mapId: mapId)
            }
        }

        private mutating func pixelIsSea(gx: Int, gy: Int, mapId: Int) -> Bool {
            let tx  = gx / MapTileCache.tilePitch
            let ty  = gy / MapTileCache.tilePitch
            let key = "\(mapId)_\(tx)_\(ty)"

            let rep: NSBitmapImageRep?
            if let cached = reps[key] {
                rep = cached
            } else {
                let decoded: NSBitmapImageRep? = MapTileCache
                    .load(tx: tx, ty: ty, mapId: mapId)
                    .flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
                    .map  { NSBitmapImageRep(cgImage: $0) }
                reps[key] = decoded
                rep = decoded
            }

            guard let rep else { return false }  // missing tile → assume land (safe)

            let scale = MapTileCache.tileSize / MapTileCache.tilePitch  // = 4 px/tile
            let px    = (gx % MapTileCache.tilePitch) * scale
            let py    = (gy % MapTileCache.tilePitch) * scale
            // colorAt(x:y:) uses y=0 at top. The sea is a flat uniform colour so
            // any y-axis orientation ambiguity between game coords and image coords
            // has no practical effect on the classification.
            guard let color = rep.colorAt(x: px, y: py) else { return false }

            let safe = color.usingColorSpace(.deviceRGB) ?? color
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            safe.getRed(&r, green: &g, blue: &b, alpha: &a)
            let ri = Int((r * 255).rounded())
            let gi = Int((g * 255).rounded())
            let bi = Int((b * 255).rounded())
            return abs(ri - Self.seaR) <= Self.seaTol
                && abs(gi - Self.seaG) <= Self.seaTol
                && abs(bi - Self.seaB) <= Self.seaTol
        }
    }
}
