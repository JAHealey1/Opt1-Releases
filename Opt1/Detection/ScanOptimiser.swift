import Foundation

// MARK: - Recommended Scan Step

/// A single recommended observation position produced by `ScanOptimiser`.
struct RecommendedScanStep {
    /// Game-tile X coordinate of the recommended standing position.
    let x: Int
    /// Game-tile Y coordinate of the recommended standing position.
    let y: Int
    /// Non-nil when the recommended position coincides with a known teleport
    /// destination. Nil means "walk to this tile".
    let teleport: TeleportSpot?
    /// How many surviving candidates would yield a triple pulse from here.
    let expectedTriple: Int
    /// How many surviving candidates would yield a double pulse from here.
    let expectedDouble: Int
    /// How many surviving candidates would yield a single pulse from here.
    let expectedSingle: Int

    var isTeleport: Bool { teleport != nil }

    /// Human-readable partition hint shown in the scan overlay UI,
    /// e.g. "splits 8 / 4 / 3".
    var splitDescription: String {
        "splits \(expectedTriple) / \(expectedDouble) / \(expectedSingle)"
    }
}

// MARK: - Scan Optimiser

/// Stateless oracle that recommends the next observation position for an active
/// scan clue triangulation.
///
/// ## Strategy
/// Uses a **greedy minimax** approach: for every candidate standing position,
/// compute how many surviving candidates would produce a triple, double, or
/// single pulse. The position whose *worst-case bucket* is smallest is chosen.
/// This minimises how many candidates can still survive after one unlucky
/// observation, which is the safest strategy when you don't know the answer.
///
/// ## Travel awareness
/// When the player's last known position is supplied via `playerPos`, the
/// algorithm uses a *tolerance window* (scaled to the scan range) to shortlist
/// candidates that are informatively close to the minimax optimum, then picks
/// the geographically nearest one. A nearby teleport that is also within
/// tolerance is promoted to the primary recommendation so the player can
/// arrive for free.
///
/// ## Sea filtering
/// Grid-point candidates whose map pixels match the RS3 wiki sea colour are
/// discarded before scoring, preventing recommendations in open water.
///
/// ## Candidate pool
/// Two sources of candidate positions are evaluated:
///
/// 1. **Teleport destinations** within 2·range tiles of any surviving spot
///    (from `TeleportCatalogue`). These are always included and never sea-filtered.
/// 2. A **regular grid** at `gridStep`-tile spacing over the same bounding
///    box, minus tiles already covered by a teleport and minus sea tiles.
///
/// ## Performance
/// Typical scan regions have ≤30 spots and ≤300 candidates. Each call
/// performs O(candidates × spots) Chebyshev distance computations —
/// well under a millisecond for these sizes. Sea-filtering adds one bitmap
/// pixel lookup per grid point; tiles are cached within the call.
enum ScanOptimiser {

    /// Tile spacing of the observation-point grid. Finer → better coverage;
    /// coarser → faster. 8 tiles gives ~300 grid points for a 50-tile-wide
    /// region, which is more than sufficient for good coverage.
    private static let gridStep = 8

    /// A candidate grid point within this Chebyshev distance of a teleport
    /// destination is suppressed — the teleport entry already covers the area.
    private static let teleportExclusionRadius = 5

    // MARK: - Public API

    /// Returns the next recommended observation position for the given
    /// surviving candidate set.
    ///
    /// - Parameters:
    ///   - surviving:       IDs of spots not yet eliminated by previous
    ///                      observations. Pass **all** spot IDs when no
    ///                      observations have been recorded yet.
    ///   - allCoords:       Full (id, x, y) coordinate list for the scan region.
    ///   - range:           Scan range in game tiles (Chebyshev, as read from OCR).
    ///   - mapId:           World map ID used to filter `TeleportCatalogue`.
    ///   - plane:           Plane/floor (0 = surface).
    ///   - preferTeleports: When `true`, any informative teleport destination
    ///                      unconditionally beats any walk-to grid point, even
    ///                      if the grid point would split the candidates more
    ///                      evenly. Pass `true` only for the very first
    ///                      recommendation (no observations recorded yet), when
    ///                      the player will arrive at the region via teleport
    ///                      and gets that reading for free.
    ///   - playerPos:       Player's last known position (from the most recent
    ///                      confirmed observation). When non-nil, candidates
    ///                      within the tolerance window are ranked by proximity
    ///                      to this point rather than by exact minimax score.
    /// - Returns: The best recommendation, or `nil` when ≤1 candidate
    ///            survives (no further discrimination is useful).
    static func recommend(
        surviving: Set<String>,
        allCoords: [(id: String, x: Int, y: Int)],
        range: Int,
        mapId: Int,
        plane: Int = 0,
        preferTeleports: Bool = false,
        playerPos: (x: Int, y: Int)? = nil
    ) -> RecommendedScanStep? {

        let survivingCoords = allCoords.filter { surviving.contains($0.id) }
        guard survivingCoords.count >= 2, range > 0 else { return nil }

        TeleportCatalogue.shared.load()

        // Bounding box of surviving spots, expanded by 2·range so we include
        // any position from which a meaningful (non-all-single) reading is
        // possible.
        let xs = survivingCoords.map(\.x)
        let ys = survivingCoords.map(\.y)
        let margin = range * 2
        let xMin = xs.min()! - margin
        let xMax = xs.max()! + margin
        let yMin = ys.min()! - margin
        let yMax = ys.max()! + margin

        let nearTeleports = TeleportCatalogue.shared
            .spots(forMapId: mapId, plane: plane)
            .filter { $0.x >= xMin && $0.x <= xMax
                   && $0.y >= yMin && $0.y <= yMax }

        // Build the candidate pool.
        var candidates: [(x: Int, y: Int, teleport: TeleportSpot?)] = []

        // Teleports first — named landmarks are never in the sea.
        for t in nearTeleports {
            candidates.append((t.x, t.y, t))
        }

        // Grid, skipping tiles already well-covered by a teleport and sea tiles.
        var seaChecker = MapTileCache.SeaChecker()
        var gx = xMin
        while gx <= xMax {
            var gy = yMin
            while gy <= yMax {
                let suppressedByTeleport = nearTeleports.contains {
                    max(abs($0.x - gx), abs($0.y - gy)) <= teleportExclusionRadius
                }
                if !suppressedByTeleport,
                   !seaChecker.isSea(gameX: gx, gameY: gy, mapId: mapId) {
                    candidates.append((gx, gy, nil))
                }
                gy += gridStep
            }
            gx += gridStep
        }

        guard !candidates.isEmpty else { return nil }

        // MARK: Scoring helpers

        func score(_ c: (x: Int, y: Int, teleport: TeleportSpot?))
            -> RecommendedScanStep?
        {
            var triple = 0, dbl = 0, single = 0
            for coord in survivingCoords {
                let d = ScanPulseFilter.chebyshev(
                    from: (c.x, c.y),
                    to:   (coord.x, coord.y)
                )
                if d <= range          { triple += 1 }
                else if d <= range * 2 { dbl    += 1 }
                else                   { single += 1 }
            }
            let nonEmptyBuckets = (triple > 0 ? 1 : 0)
                                + (dbl    > 0 ? 1 : 0)
                                + (single > 0 ? 1 : 0)
            guard nonEmptyBuckets >= 2 else { return nil }
            return RecommendedScanStep(
                x:              c.x,
                y:              c.y,
                teleport:       c.teleport,
                expectedTriple: triple,
                expectedDouble: dbl,
                expectedSingle: single
            )
        }

        func worstBucket(_ step: RecommendedScanStep) -> Int {
            max(step.expectedTriple, max(step.expectedDouble, step.expectedSingle))
        }

        // MARK: First-step path (preferTeleports)

        if preferTeleports {
            // The player arrives at the region via teleport and gets that tile's
            // reading for free. Even a suboptimal teleport split is better than
            // walking past a free observation to reach a marginally better spot.
            var bestTeleScore = Int.max
            var bestTeleStep:  RecommendedScanStep?

            for c in candidates where c.teleport != nil {
                guard let step = score(c) else { continue }
                let s = worstBucket(step)
                if s < bestTeleScore { bestTeleScore = s; bestTeleStep = step }
            }

            if let tele = bestTeleStep { return tele }
            // No informative teleport — fall through to the normal pass below.
        }

        // MARK: Normal minimax pass

        // Tolerance window and snap radius both scale with range so they remain
        // proportionate across small and large scan areas.
        //   worstBucketTolerance: range 5→1, 10→2, 20→4, 30→6
        //   nearbyTeleportRadius: range 5→5, 10→5, 20→10, 30→15
        let worstBucketTolerance = max(1, range / 5)
        let nearbyTeleportRadius = max(5, range / 2)

        // Pass 1: score all candidates and record the global minimax optimum.
        var allScored: [(step: RecommendedScanStep, isTele: Bool)] = []
        var bestWorse = Int.max

        for c in candidates {
            guard let step = score(c) else { continue }
            let w = worstBucket(step)
            if w < bestWorse { bestWorse = w }
            allScored.append((step, c.teleport != nil))
        }

        guard !allScored.isEmpty else { return nil }

        if let playerPos {
            // Pass 2: shortlist every candidate within the tolerance window,
            // then pick the one closest to the player's last known position.
            let shortlist = allScored.filter {
                worstBucket($0.step) <= bestWorse + worstBucketTolerance
            }
            guard let walkTo = shortlist.min(by: { a, b in
                let dA = max(abs(a.step.x - playerPos.x), abs(a.step.y - playerPos.y))
                let dB = max(abs(b.step.x - playerPos.x), abs(b.step.y - playerPos.y))
                return dA < dB
            })?.step else { return nil }

            // If the best candidate is already a teleport, return it directly.
            if walkTo.teleport != nil { return walkTo }

            // Pass 3: try to snap to a nearby teleport that is also informative
            // within the same tolerance window. If one exists, use it as the
            // recommended scan spot — the player teleports there for free.
            let snapped = nearTeleports.compactMap { tele -> RecommendedScanStep? in
                let distToWalkTo = max(abs(tele.x - walkTo.x), abs(tele.y - walkTo.y))
                guard distToWalkTo <= nearbyTeleportRadius else { return nil }
                guard let teleStep = score((tele.x, tele.y, tele)) else { return nil }
                guard worstBucket(teleStep) <= bestWorse + worstBucketTolerance else { return nil }
                return teleStep
            }.min(by: { a, b in
                // Among qualifying teleports, prefer the one nearest the walk-to spot.
                let dA = max(abs(a.x - walkTo.x), abs(a.y - walkTo.y))
                let dB = max(abs(b.x - walkTo.x), abs(b.y - walkTo.y))
                return dA < dB
            })

            return snapped ?? walkTo

        } else {
            // No playerPos: pure minimax with teleport tie-break.
            let bestEntries = allScored.filter { worstBucket($0.step) == bestWorse }
            return bestEntries.first(where: { $0.isTele })?.step
                ?? bestEntries.first?.step
        }
    }
}
