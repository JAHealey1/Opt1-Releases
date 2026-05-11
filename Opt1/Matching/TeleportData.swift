import Foundation
import AppKit

// MARK: - Data model

/// Single teleport spot, ported from ClueTrainer's `teleport_data.ts`
/// One row per (group, spot) tuple — a single physical destination on the RS3
/// world map. The `groupId`/`groupName` pair lets us cluster spots by their
/// access method (Lodestone Network, Amulet of Glory, Slayer Cape, …) for
/// future filtering UI without bloating the per-spot rows.
struct TeleportSpot: Codable, Identifiable, Hashable {
    let groupId:   String
    let groupName: String
    /// Spot id within its group (e.g. "alkharid"). Decoded from the JSON's
    /// `id` field; renamed to `spotId` here because the raw value collides
    /// across groups (every Lodestone-like network has an "alkharid" spot)
    /// so it can't satisfy `Identifiable` on its own.
    let spotId:    String
    let name:      String
    /// Sprite filename. Resolved at port time by walking ClueTrainer's
    /// fallback chain (per-spot `img` → group `img` → group `access[*].img`)
    /// so Swift never has to know the access-block schema. Bare filename;
    /// the loader resolves it against the bundled `TeleportIcons/` folder.
    let icon:      String?
    /// Game-tile X coordinate of the teleport's destination (or
    /// `icon_position_override` when ClueTrainer specified one).
    let x:         Int
    /// Game-tile Y coordinate of the teleport's destination.
    let y:         Int
    /// Plane / floor (0 = surface).
    let level:     Int
    /// Keyboard shortcut shown in the in-game teleport UI (e.g. "A" for the
    /// Al Kharid lodestone, "Opt+M" for Menaphos). Optional.
    let code:      String?

    /// `Identifiable` conformance — synthesised from (group, spot) so
    /// SwiftUI lists/ForEach can key on a globally-unique value even though
    /// duplicate spot ids exist across groups.
    var id: String { "\(groupId).\(spotId)" }

    /// Convenience alias kept for symmetry with rendering code that talks
    /// about "the icon to draw for this spot". Identical to `icon` now that
    /// resolution is done at port time, but keeps `TeleportLayer` agnostic
    /// to the schema's evolution.
    var resolvedIcon: String? { icon }
}

extension TeleportSpot {
    enum CodingKeys: String, CodingKey {
        case groupId, groupName
        case spotId = "id"
        case name, icon, x, y, level, code
    }
}

// MARK: - Catalogue

/// Singleton catalogue that loads `teleports.json` once and caches the parsed
/// spots in memory for the lifetime of the app. Parallels `ClueDatabase`.
///
/// Loading is lazy and silent on failure — teleport overlay rendering is
/// strictly opt-in (gated by `AppSettings.showTeleports`), so a missing or
/// malformed file should never crash the app or block clue solving.
final class TeleportCatalogue {

    static let shared = TeleportCatalogue()
    private(set) var spots: [TeleportSpot] = []

    private init() {}

    /// Loads and decodes the bundled `teleports.json`. Safe to call from
    /// any thread; subsequent calls are idempotent.
    func load() {
        guard spots.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "teleports", withExtension: "json") else {
            print("[Opt1] teleports.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            spots = try JSONDecoder().decode([TeleportSpot].self, from: data)
            print("[Opt1] Loaded \(spots.count) teleport spot(s) "
                  + "(\(Set(spots.map(\.groupId)).count) group(s))")
        } catch {
            print("[Opt1] Failed to load teleport catalogue: \(error)")
        }
    }

    // MARK: - Coordinate offsets for local-coordinate underground maps

    /// Global tile offset to add to a local map coordinate to get the
    /// equivalent global RS3 tile coordinate.
    ///
    /// Certain underground maps store scan clue coordinates in a local tile
    /// space that starts near (0, 0), while the teleport catalogue uses the
    /// global tile grid. Adding this offset converts local → global; subtracting
    /// converts global → local.
    ///
    /// Offsets are multiples of 64 (map-square boundaries). Each was derived
    /// by matching a known teleport landing tile to its local coordinate:
    /// — Keldagrim (mapId 21): local (40, 149) ≡ global (2856, 10197),
    ///   confirmed via the Luck of the Dwarves landing tile.
    static let localMapGlobalOffset: [Int: (x: Int, y: Int)] = [
        21: (x: 2816, y: 10048),   // Keldagrim underground
    ]

    // MARK: - Spot queries

    /// Spots filtered for the given map, with coordinates expressed in that
    /// map's own tile space.
    ///
    /// • For surface / sub-realm maps (mapId 28, Zanaris, etc.) the teleport
    ///   coordinates are returned as-is — they already live in the global tile
    ///   space that the map uses. **All elevation planes are included** because
    ///   the 2D map overlay collapses floors onto the same grid (e.g. Prifddinas
    ///   clan districts sit at plane 1 but appear on the standard surface map).
    /// • For known underground local-coordinate maps (e.g. Keldagrim, mapId 21)
    ///   the global teleport coordinates are **translated to local coords** by
    ///   subtracting the map's known offset, so callers (map renderer, optimiser)
    ///   can work in a single consistent coordinate space without special-casing.
    ///   The `plane` parameter is applied here because underground floors are
    ///   genuinely distinct areas.
    /// • Only spots whose translated position falls within a generous bounding
    ///   box around the map's local origin are returned, which naturally excludes
    ///   unrelated surface teleports from appearing on underground maps.
    func spots(forMapId mapId: Int, plane: Int = 0) -> [TeleportSpot] {
        let arcMapId           = 695
        let arcYThreshold      = 140 * 64   // ~8960 — separates Arc from surface

        if let offset = Self.localMapGlobalOffset[mapId] {
            // Underground local-coordinate map: translate global → local and
            // keep only spots that land within a plausible local range.
            // The plane filter is retained here because different floors in
            // an underground region genuinely occupy different spaces.
            return spots.compactMap { spot in
                guard spot.level == plane else { return nil }
                let localX = spot.x - offset.x
                let localY = spot.y - offset.y
                // Accept spots within ±512 tiles of the local origin so that
                // nearby entrances / teleport pads show up but remote surface
                // teleports (which would translate to large negative values) do not.
                guard localX > -512, localY > -512,
                      localX < 2048, localY < 2048 else { return nil }
                return TeleportSpot(
                    groupId:   spot.groupId,
                    groupName: spot.groupName,
                    spotId:    spot.spotId,
                    name:      spot.name,
                    icon:      spot.icon,
                    x:         localX,
                    y:         localY,
                    level:     spot.level,
                    code:      spot.code
                )
            }
        }

        // Surface / sub-realm map: no plane filter.
        //
        // The 2D map overlay collapses all elevation levels (plane 0 = ground,
        // plane 1 = first floor, etc.) onto the same tile grid, so filtering
        // by plane would incorrectly hide teleports like the Prifddinas clan
        // districts (plane 1) when viewing the standard overworld map.
        //
        // The wiki map displays the Eastern Lands in a separate tile band at
        // ty = 177–187 (game-coord equivalent y ≈ 11 000–12 000). However,
        // all Arc *clue* data in clues.json stores RS3 in-game coordinates
        // (y ≈ 1 500–2 300, the actual minimap values the player sees). These
        // are entirely different coordinate spaces; teleport spots and dig-spot
        // pins must live in the same space so they appear together on the map.
        //
        // Since dig spots (from the clue database) are already in game coords,
        // Arc teleport spots must be translated from wiki display coords to game
        // coords by adding the empirical offset derived from matching Arc island
        // centroids across both datasets:
        //
        //   game_x ≈ wiki_x + 1984   (= wiki_x + 31 × 64)
        //   game_y ≈ wiki_y − 9664   (= wiki_y − 151 × 64)
        //
        // The offset is tile-aligned (multiples of 64) and accurate to within
        // ≈ 40–80 game tiles — enough for icon placement on compass overlays.
        //
        // Only genuine Arc destinations (y ≥ 10 500 in wiki coords) are
        // translated; underground spots with y ≈ 8 960–10 200 are excluded
        // because their translated x values would fall outside the Arc game-
        // coord bounding box and the `localX < arcGameXMax` guard below
        // rejects them.
        let arcGameDX = 1984   // wiki_x → game_x
        let arcGameDY = -9664  // wiki_y → game_y  (subtract the large northern offset)
        let arcWikiYLower = 10_500  // y below this → underground dungeon, not the Arc
        // Generous bounding box for the Arc in game-tile space.
        let arcGameXMin =  3_500
        let arcGameXMax =  5_000
        let arcGameYMin =  1_200
        let arcGameYMax =  2_600

        if mapId == MapTileCache.defaultMapId {
            return spots.compactMap { spot in
                let isArc = spot.y >= arcYThreshold  // wiki y ≥ 8 960
                let isTrueArc = spot.y >= arcWikiYLower  // wiki y ≥ 10 500

                if isTrueArc {
                    // Translate to game coords so the icon appears alongside
                    // Arc compass clue dig spots (which use game coords).
                    let gx = spot.x + arcGameDX
                    let gy = spot.y + arcGameDY
                    guard gx >= arcGameXMin, gx <= arcGameXMax,
                          gy >= arcGameYMin, gy <= arcGameYMax else { return nil }
                    return TeleportSpot(
                        groupId:   spot.groupId,
                        groupName: spot.groupName,
                        spotId:    spot.spotId,
                        name:      spot.name,
                        icon:      spot.icon,
                        x:         gx,
                        y:         gy,
                        level:     spot.level,
                        code:      spot.code
                    )
                }
                // Underground spots and surface spots: return as-is if not Arc.
                if isArc { return nil }
                return spot
            }
        }

        // Arc-only map view (mapId 695): not currently used by the compass
        // overlay but kept for completeness. Returns only true Arc spots in
        // wiki coordinates so the caller can apply its own transform if needed.
        if mapId == arcMapId {
            return spots.filter { $0.y >= arcYThreshold }
        }

        // Underground dungeons (Brimhaven, Taverley, Fremennik Slayer Dungeon,
        // Lumbridge Swamp Caves, etc.) and sub-realm maps (Zanaris, etc.) all
        // use global RS3 game coordinates. Underground teleports land at game-y
        // values up to ~10 200, so we only exclude true Arc wiki display coords
        // (y ≥ 10 500). The caller's bounding-box filter removes any spots that
        // are not near the current scan / overlay area.
        return spots.filter { $0.y < arcWikiYLower }
    }
}

// MARK: - Sprite cache

final class TeleportSpriteCache {

    static let shared = TeleportSpriteCache()
    private var cache: [String: CGImage] = [:]
    /// Filenames we've already failed to load; avoids spamming the log when
    /// the same Canvas redraws repeatedly with a missing sprite.
    private var missing: Set<String> = []

    private init() {}

    /// Root directory for bundled teleport sprites. Resolved once via the
    /// app bundle's resource URL so we work with `TeleportIcons` shipped as
    /// a folder reference (blue folder in Xcode) — `Bundle.url(forResource:)`
    /// would otherwise fail to find the sprites because folder references
    /// keep their nested directory structure in the bundle. Mirrors the same
    /// pattern used by `MapTileCache.dir`.
    private static let dir: URL = {
        Bundle.main.resourceURL!.appendingPathComponent("TeleportIcons")
    }()

    func image(named filename: String) -> CGImage? {
        if let cached = cache[filename] { return cached }
        if missing.contains(filename) { return nil }

        let url = Self.dir.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: url.path) else {
            missing.insert(filename)
            return nil
        }

        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            print("[Opt1] TeleportSpriteCache: failed to decode \(filename)")
            missing.insert(filename)
            return nil
        }

        cache[filename] = cg
        return cg
    }
}
