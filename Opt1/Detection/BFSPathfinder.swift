import Foundation

// MARK: - BFS Pathfinder

/// Single-source BFS over a `WalkabilityGrid` using 8-directional movement,
/// matching RS3's tile-pathing model on open terrain.
///
/// One call to `distanceMap(from:over:)` computes walking distances from a
/// single origin to every reachable tile in O(width × height) time. For a
/// typical 150×150 scan region this is < 1 ms — fast enough to call inside
/// `ScanOptimiser.recommend` without threading.
enum BFSPathfinder {

    // MARK: - Full Distance Map

    /// Returns a flat distance array indexed by `gridIndex` (row × width + col).
    /// Unreachable tiles hold `Int.max`. The returned array has
    /// `grid.width × grid.height` elements.
    ///
    /// Use `grid.gridIndex(gameX:gameY:)` to look up a specific game coordinate.
    static func distanceMap(from origin: (x: Int, y: Int),
                            over grid: WalkabilityGrid) -> [Int] {
        let total    = grid.width * grid.height
        var dist     = [Int](repeating: Int.max, count: total)

        let startCol = origin.x - grid.originX
        let startRow = origin.y - grid.originY
        guard startCol >= 0, startCol < grid.width,
              startRow >= 0, startRow < grid.height else { return dist }

        let startIdx = startRow * grid.width + startCol
        guard grid.isWalkable(gameX: origin.x, gameY: origin.y) else { return dist }
        dist[startIdx] = 0
        var queue         = [Int]()
        queue.reserveCapacity(total / 4)
        queue.append(startIdx)
        var head = 0

        let W = grid.width
        let H = grid.height

        while head < queue.count {
            let idx  = queue[head]; head += 1
            let d    = dist[idx]
            let col  = idx % W
            let row  = idx / W

            for dy in -1 ... 1 {
                for dx in -1 ... 1 {
                    guard dx != 0 || dy != 0 else { continue }
                    let nc = col + dx
                    let nr = row + dy
                    guard nc >= 0, nc < W, nr >= 0, nr < H else { continue }
                    let nIdx = nr * W + nc
                    guard dist[nIdx] == Int.max else { continue }
                    guard grid.isWalkable(gameX: grid.originX + nc,
                                         gameY: grid.originY + nr) else { continue }
                    dist[nIdx] = d + 1
                    queue.append(nIdx)
                }
            }
        }
        return dist
    }

    // MARK: - Point-to-Point Convenience

    /// Returns the walking distance from `origin` to `destination` through the
    /// grid, or `nil` when either point is outside the grid or unreachable.
    ///
    /// - Note: Computes a full `O(width × height)` distance map internally.
    ///   Call `distanceMap(from:over:)` directly and reuse the result if you
    ///   need distances to multiple destinations from the same origin.
    static func distance(from origin:      (x: Int, y: Int),
                         to destination:   (x: Int, y: Int),
                         over grid:        WalkabilityGrid) -> Int? {
        guard let destIdx = grid.gridIndex(gameX: destination.x,
                                           gameY: destination.y) else { return nil }
        let map = distanceMap(from: origin, over: grid)
        let d   = map[destIdx]
        return d == Int.max ? nil : d
    }
}
