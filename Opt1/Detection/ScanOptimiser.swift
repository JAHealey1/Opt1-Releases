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
    /// Expected number of candidates remaining after one observation here,
    /// under a uniform prior over the surviving set.
    /// Computed as (T² + D² + S²) / n. Lower is better.
    let expectedRemaining: Double

    var isTeleport: Bool { teleport != nil }

    /// Human-readable partition hint shown in the scan overlay UI,
    /// e.g. "splits 8 / 4 / 3".
    var splitDescription: String {
        "splits \(expectedTriple) / \(expectedDouble) / \(expectedSingle)"
    }

    /// Human-readable expected-remaining hint, e.g. "exp 4.2 remaining".
    var expectedRemainingDescription: String {
        String(format: "exp %.1f remaining", expectedRemaining)
    }
}

// MARK: - Scan Optimiser

/// Stateless oracle that recommends the next observation position for an active
/// scan clue triangulation.
///
/// ## Strategy
/// Uses a **multi-factor lexicographic score** to rank candidates:
///
/// 1. **Worst-case bucket** (`max(triple, double, single)`) — greedy minimax
///    primary criterion; minimises the most candidates that can survive after
///    one unlucky observation.
/// 2. **Expected remaining** (`(T² + D² + S²) / n`) — information-theoretic
///    tie-breaker; rewards balanced splits and maximises expected eliminations.
/// 3. **Travel cost** — for non-teleport candidates this is BFS walking distance
///    (or Chebyshev fallback) from the player's last known position. For teleport
///    candidates it is the fixed `teleportOverhead` constant (~15 tiles), since
///    teleports are instant regardless of current position.
/// 4. **Teleport preference** — when two candidates share the same travel cost
///    (e.g. two teleport destinations), a teleport beats a plain grid point as a
///    last-resort tie-breaker.
///
/// ## Tolerance window
/// The travel-cost ranking is only applied within candidates whose
/// `worstBucket` is at most `worstBucketTolerance` tiles above the global
/// minimum. This prevents a near-optimal but distant position from winning
/// over a slightly-less-optimal one that is much closer.
///
/// ## Sea filtering
/// Grid-point candidates whose map pixels match the RS3 wiki sea colour are
/// discarded before scoring, preventing recommendations in open water.
///
/// ## Candidate pool
/// Two sources of candidate positions are evaluated:
///
/// 1. **Teleport destinations** within 2·range tiles of any surviving spot
///    (from `TeleportCatalogue`). These are always included and never
///    sea-filtered.
/// 2. A **regular grid** at `gridStep`-tile spacing over the same bounding
///    box, minus tiles already covered by a teleport and minus sea tiles.
enum ScanOptimiser {

    /// Tile spacing of the observation-point grid.
    private static let gridStep = 8

    /// A candidate grid point within this Chebyshev distance of a teleport
    /// destination is suppressed — the teleport entry already covers the area.
    private static let teleportExclusionRadius = 5

    /// Nominal travel-cost assigned to every teleport candidate (tiles).
    ///
    /// Teleports are instant regardless of where the player currently stands,
    /// so their real travel cost is effectively zero. However, using a teleport
    /// does carry a small interface overhead (opening the menu, animation, load
    /// screen) — roughly equivalent to walking ~15 tiles. Assigning this fixed
    /// cost means:
    ///   • Teleports win when the nearest walk-to scan position is further than
    ///     `teleportOverhead` tiles away.
    ///   • Plain grid points that are *closer* than `teleportOverhead` tiles
    ///     beat teleports — no point teleporting when you're already nearby.
    private static let teleportOverhead = 15

    // MARK: - Private Scoring Type

    /// Multi-factor score for a candidate observation position.
    /// Lexicographic `<` means lower == better across all four criteria.
    private struct CandidateScore: Comparable {
        /// Minimax worst-case bucket size. Primary criterion.
        let worstBucket: Int
        /// Information-theoretic expected candidates remaining = (T²+D²+S²)/n.
        /// Penalises unbalanced splits; rewards maximum expected eliminations.
        let expectedRemaining: Double
        /// 0 for a teleport destination (preferred), 1 for a plain grid point.
        let notTeleport: Int
        /// Walking distance from the player's last known position.
        /// 0 when no player position is supplied.
        let travelCost: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.worstBucket, lhs.expectedRemaining,
             lhs.travelCost,  lhs.notTeleport)
            < (rhs.worstBucket, rhs.expectedRemaining,
               rhs.travelCost,  rhs.notTeleport)
        }
    }

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
    ///                      confirmed observation). When non-nil, travel cost is
    ///                      factored into scoring within the tolerance window.
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
        guard let xLow = xs.min(), let xHigh = xs.max(),
              let yLow = ys.min(), let yHigh = ys.max() else { return nil }
        let xMin = xLow  - margin
        let xMax = xHigh + margin
        let yMin = yLow  - margin
        let yMax = yHigh + margin

        let nearTeleports = TeleportCatalogue.shared
            .spots(forMapId: mapId, plane: plane)
            .filter { $0.x >= xLow - range && $0.x <= xHigh + range
                   && $0.y >= yLow - range && $0.y <= yHigh + range }

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

        let n = survivingCoords.count

        // Pre-compute BFS distance map from playerPos when a walkability grid
        // is available for this region. Falls back to Chebyshev otherwise.
        let walkGrid = WalkabilityCache.shared.grid(
            forMapId: mapId, xMin: xMin, yMin: yMin, xMax: xMax, yMax: yMax)
        let bfsDist: [Int]? = playerPos.flatMap { pos in
            guard let g = walkGrid else { return nil }
            return BFSPathfinder.distanceMap(from: pos, over: g)
        }

        // MARK: Scoring helper

        func score(_ c: (x: Int, y: Int, teleport: TeleportSpot?))
            -> (step: RecommendedScanStep, cs: CandidateScore)?
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

            let expRem = Double(triple*triple + dbl*dbl + single*single) / Double(n)
            let worst  = max(triple, max(dbl, single))

            // Travel cost: teleports are instant so pay only a fixed overhead;
            // non-teleports use BFS walking distance when a grid is available,
            // otherwise Chebyshev distance. Zero when no player position known.
            let travelCost: Int
            if let pos = playerPos {
                if c.teleport != nil {
                    travelCost = teleportOverhead
                } else if let bfs = bfsDist,
                   let g   = walkGrid,
                   let idx = g.gridIndex(gameX: c.x, gameY: c.y),
                   bfs[idx] != Int.max {
                    travelCost = bfs[idx]
                } else {
                    travelCost = max(abs(c.x - pos.x), abs(c.y - pos.y))
                }
            } else {
                travelCost = 0
            }

            let step = RecommendedScanStep(
                x:                 c.x,
                y:                 c.y,
                teleport:          c.teleport,
                expectedTriple:    triple,
                expectedDouble:    dbl,
                expectedSingle:    single,
                expectedRemaining: expRem
            )
            let cs = CandidateScore(
                worstBucket:       worst,
                expectedRemaining: expRem,
                notTeleport:       c.teleport == nil ? 1 : 0,
                travelCost:        travelCost
            )
            return (step, cs)
        }

        // MARK: First-step path (preferTeleports)

        if preferTeleports {
            // The player arrives at the region via teleport and gets that tile's
            // reading for free. Even a suboptimal teleport split is better than
            // walking past a free observation to reach a marginally better spot.
            var best: (step: RecommendedScanStep, cs: CandidateScore)?
            for c in candidates where c.teleport != nil {
                guard let scored = score(c) else { continue }
                if best == nil || scored.cs < best!.cs {
                    best = scored
                }
            }
            if let best { return best.step }
            // No informative teleport — fall through to the normal pass below.
        }

        // MARK: Normal pass

        // Tolerance scales with range so it stays proportionate across scan areas:
        //   range 5→1, 10→2, 20→4, 30→6
        let worstBucketTolerance = max(1, range / 5)

        // Pass 1: score all candidates, record the global minimum worstBucket
        // independently of travel cost so the tolerance threshold is fair.
        var allScored: [(step: RecommendedScanStep, cs: CandidateScore)] = []
        var bestWorse = Int.max

        for c in candidates {
            guard let scored = score(c) else { continue }
            if scored.cs.worstBucket < bestWorse { bestWorse = scored.cs.worstBucket }
            allScored.append(scored)
        }

        guard !allScored.isEmpty else { return nil }

        // Pass 2: shortlist every candidate within the tolerance window, then
        // let the full CandidateScore (expectedRemaining → teleport → travelCost)
        // pick the winner. This replaces the original three-pass nearest/snap
        // logic with a single min() over the structured score.
        let shortlist = allScored.filter {
            $0.cs.worstBucket <= bestWorse + worstBucketTolerance
        }
        return shortlist.min(by: { $0.cs < $1.cs })?.step
    }
}
