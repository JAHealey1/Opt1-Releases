import Foundation

// MARK: - Walkability Grid

/// A compact walkability mask for a single scan-clue region at game-tile
/// resolution. Loaded from `walkability.json` and cached for the app's lifetime.
///
/// Bits are packed 8-per-byte; index = row × width + col where row=0 is
/// the south edge (lowest game-y) and col=0 is the west edge (lowest game-x).
/// A bit value of 1 means the tile is walkable.
///
/// Tiles outside the grid's bounds are assumed walkable so the optimiser can
/// gracefully handle candidates that stray outside the stored area.
struct WalkabilityGrid {
    let regionId:  String
    let mapId:     Int
    /// Game-tile X of the grid's west edge (column 0).
    let originX:   Int
    /// Game-tile Y of the grid's south edge (row 0).
    let originY:   Int
    let width:     Int
    let height:    Int
    /// Packed bit array. Internal but non-private so `WalkabilityCache` can
    /// construct instances directly without a cross-module initialiser.
    let bits:      [UInt8]

    // MARK: - Queries

    func isWalkable(gameX: Int, gameY: Int) -> Bool {
        let col = gameX - originX
        let row = gameY - originY
        guard col >= 0, col < width, row >= 0, row < height else { return true }
        let idx = row * width + col
        return (bits[idx >> 3] >> (idx & 7)) & 1 == 1
    }

    /// Returns the packed-array index for a game coordinate, or nil when
    /// the position is outside the grid. Used by `BFSPathfinder` to look up
    /// pre-computed distances without an extra bounds check.
    func gridIndex(gameX: Int, gameY: Int) -> Int? {
        let col = gameX - originX
        let row = gameY - originY
        guard col >= 0, col < width, row >= 0, row < height else { return nil }
        return row * width + col
    }

    /// True when the grid fully covers the supplied bounding box, meaning BFS
    /// distances will be accurate everywhere the optimiser might place candidates.
    func covers(xMin: Int, yMin: Int, xMax: Int, yMax: Int) -> Bool {
        xMin >= originX && yMin >= originY
            && xMax < originX + width && yMax < originY + height
    }
}

// MARK: - JSON Backing (private)

private struct WalkabilityGridData: Codable {
    let regionId:  String
    let mapId:     Int
    let originX:   Int
    let originY:   Int
    let width:     Int
    let height:    Int
    /// Base64-encoded packed bit array (1 bit per tile, row-major, LSB first).
    let walkable:  String
    /// Tiles that are forced walkable regardless of the pixel classification,
    /// e.g. agility shortcuts embedded in otherwise impassable walls.
    let shortcuts: [ShortcutTile]?

    struct ShortcutTile: Codable {
        let x: Int
        let y: Int
        let name: String?
    }
}

// MARK: - Walkability Cache

/// Singleton that loads and caches walkability grids from the bundled
/// `walkability.json`. Returns `nil` for any region whose grid has not yet
/// been baked — the caller should fall back to Chebyshev distance.
///
/// The file is absent from the bundle until `build_walkability.py` has been
/// run for at least one scan region; silence on missing file is intentional.
///
/// `load()` is written once (guarded by `loaded`) and is always called at app
/// startup before any concurrent reads, so `nonisolated(unsafe)` is safe here.
final class WalkabilityCache: @unchecked Sendable {

    static let shared = WalkabilityCache()
    nonisolated(unsafe) private var grids:  [WalkabilityGrid] = []
    nonisolated(unsafe) private var loaded = false

    private init() {}

    /// Loads `walkability.json` from the app bundle. Safe to call repeatedly;
    /// subsequent calls are idempotent.
    func load() {
        guard !loaded else { return }
        loaded = true
        guard let url = Bundle.main.url(forResource: "walkability",
                                        withExtension: "json") else {
            // Expected until build_walkability.py has been run.
            return
        }
        do {
            let data    = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([WalkabilityGridData].self,
                                                  from: data)
            grids = decoded.compactMap { d -> WalkabilityGrid? in
                guard let raw = Data(base64Encoded: d.walkable) else {
                    print("[Opt1] WalkabilityCache: invalid base64 for \(d.regionId)")
                    return nil
                }
                // Start from the decoded bytes, then force shortcut tiles walkable.
                var bits = [UInt8](raw)
                for s in d.shortcuts ?? [] {
                    let col = s.x - d.originX
                    let row = s.y - d.originY
                    guard col >= 0, col < d.width,
                          row >= 0, row < d.height else { continue }
                    let idx = row * d.width + col
                    bits[idx >> 3] |= 1 << (idx & 7)
                }
                return WalkabilityGrid(regionId: d.regionId,
                                       mapId:    d.mapId,
                                       originX:  d.originX,
                                       originY:  d.originY,
                                       width:    d.width,
                                       height:   d.height,
                                       bits:     bits)
            }
            print("[Opt1] Loaded \(grids.count) walkability grid(s)")
        } catch {
            print("[Opt1] Failed to load walkability.json: \(error)")
        }
    }

    /// Returns the first grid for `mapId` that fully covers the given bounding
    /// box, or `nil` if none has been baked yet.
    func grid(forMapId mapId: Int,
              xMin: Int, yMin: Int,
              xMax: Int, yMax: Int) -> WalkabilityGrid? {
        grids.first {
            $0.mapId == mapId
                && $0.covers(xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
        }
    }
}
