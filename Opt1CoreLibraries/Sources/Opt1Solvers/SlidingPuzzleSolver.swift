import Opt1Core
import CoreGraphics
import Foundation
import Dispatch

// MARK: - Domain types

/// The detected state of an open puzzle box.
public struct PuzzleBoxState {
    /// 25-element tile array: `tiles[i]` is the tile number at grid position `i`
    /// (row-major, 0 = blank/empty cell). Solved state: tiles[i] == i+1 for
    /// i in 0..<24, tiles[24] == 0.
    public let tiles: [Int]
    /// Bounding rect of the puzzle grid in CoreGraphics pixel coordinates
    /// (top-left origin, matches the captured image).
    public let gridBoundsInImage: CGRect
    /// Pixel size of a single cell at the captured image resolution.
    public let cellSize: CGSize
    /// Display name of the matched reference puzzle (e.g. "Vanstrom Klause").
    public let puzzleName: String
    /// Aggregate tile-match quality from detector-side NCC matching.
    public let matchConfidence: Float
    /// True when detector considers the match low-confidence and suggests
    /// asking for a hint-hover capture retry before solving.
    public let needsHintAssistedRetry: Bool

    public init(tiles: [Int], gridBoundsInImage: CGRect, cellSize: CGSize, puzzleName: String, matchConfidence: Float, needsHintAssistedRetry: Bool) {
        self.tiles = tiles
        self.gridBoundsInImage = gridBoundsInImage
        self.cellSize = cellSize
        self.puzzleName = puzzleName
        self.matchConfidence = matchConfidence
        self.needsHintAssistedRetry = needsHintAssistedRetry
    }
}

/// One completed solve: a sequence of tile click positions and the geometric
/// info needed to draw the highlight overlay on screen.
public struct PuzzleBoxSolution {
    /// Each element `(row, col)` is the grid cell whose tile the player should
    /// click.  Clicks must be performed in order; the tile slides one step
    /// toward the blank on each click.
    public let moves: [(row: Int, col: Int)]
    /// Screen-space rect of the puzzle grid (CoreGraphics coordinates).
    public let gridBoundsOnScreen: CGRect
    /// Size of a single cell in screen points.
    public let cellSize: CGSize
    /// Display name of the matched reference puzzle.
    public let puzzleName: String

    public init(moves: [(row: Int, col: Int)], gridBoundsOnScreen: CGRect, cellSize: CGSize, puzzleName: String) {
        self.moves = moves
        self.gridBoundsOnScreen = gridBoundsOnScreen
        self.cellSize = cellSize
        self.puzzleName = puzzleName
    }
}

// MARK: - Solver (IDA* with Manhattan + linear-conflict heuristic)
//
// IDA* (iterative-deepening A*) explores the state space with a depth-first
// tree search and an ever-increasing cost bound.  With the Manhattan distance
// + linear-conflict admissible heuristic the search is extremely focused:
// most 5×5 instances (≈100 optimal moves) solve in < 2 s.  A capped timeout
// prevents infinite loops on misread board states.
//
// Tile representation
// -------------------
// Positions are numbered 0–24 in row-major order (row 0 is the top row).
// `tiles[pos]` is the tile number at that position; tile 0 is the blank.
// Solved state: tiles[i] == i + 1  ∀ i ∈ [0, 23],  tiles[24] == 0.
//
// A "move" is a player click on a tile adjacent to the blank.  Internally we
// represent a move as the (row, col) of the tile BEFORE it slides (the cell
// the player taps), which is also where the blank will be afterwards.

public struct SlidingPuzzleSolver: PuzzleSolver {

    public init() {}

    public static let N = 5
    private static let NN = N * N   // 25
    private static let defaultMaxSolveSeconds: TimeInterval = 12.0

    // MARK: Public entry point

    /// Attempts to solve `state.tiles` within the configured solver timeout.
    /// Returns nil on timeout or unrecognisable state.
    public func solve(_ state: PuzzleBoxState) -> PuzzleBoxSolution? {
        let initial  = state.tiles
        print("[SlidingPuzzleSolver] Initial state: \(initial)")
        let goal     = Array(1..<Self.NN) + [0]
        let solveStart = Date()

        guard Self.isValidTileSet(initial) else {
            print("[SlidingPuzzleSolver] ⚠ Invalid tile set (expected 0...24 exactly once) — tile detection may be wrong")
            return nil
        }

        if initial == goal {
            return PuzzleBoxSolution(
                moves: [],
                gridBoundsOnScreen: state.gridBoundsInImage,
                cellSize: state.cellSize,
                puzzleName: state.puzzleName
            )
        }

        guard Self.isSolvable(initial) else {
            print("[SlidingPuzzleSolver] ⚠ State is not solvable — tile detection may be wrong")
            return nil
        }

        guard let blankIdx = initial.firstIndex(of: 0) else { return nil }

        let h0 = Self.heuristic(initial)
        let maxSolveSeconds = Self.timeoutBudgetSeconds(for: state, initialHeuristic: h0)
        print("[SlidingPuzzleSolver] Starting solve — heuristic=\(h0) blank=\(blankIdx) timeout=\(Int(maxSolveSeconds))s")

        var tiles    = initial
        var blank    = blankIdx
        var moves:   [(row: Int, col: Int)] = []
        var bound    = h0
        let startUptime = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = UInt64(maxSolveSeconds * 1_000_000_000.0)
        var nodes    = 0

        while bound < 500 {
            let iterStart = Date()
            let nodesBefore = nodes
            let result = Self.search(
                &tiles, &blank, &moves,
                g: 0, bound: bound, lastBlank: -1,
                startUptimeNanos: startUptime,
                timeoutNanos: timeoutNanos,
                nodes: &nodes
            )
            let iterElapsedMs = Int(Date().timeIntervalSince(iterStart) * 1000)
            let iterNodes = nodes - nodesBefore
            print("[SlidingPuzzleSolver] Iteration bound=\(bound) explored=\(iterNodes) nodes elapsedMs=\(iterElapsedMs) result=\(result == 0 ? "solved" : result == Int.max ? "timeout" : "nextBound=\(result)")")
            if result == 0 {
                let totalMs = Int(Date().timeIntervalSince(solveStart) * 1000)
                print("[SlidingPuzzleSolver] Solved in \(moves.count) moves (explored \(nodes) nodes, elapsedMs=\(totalMs), initialH=\(h0))")
                return PuzzleBoxSolution(
                    moves: moves,
                    gridBoundsOnScreen: state.gridBoundsInImage,
                    cellSize: state.cellSize,
                    puzzleName: state.puzzleName
                )
            }
            if result == Int.max {
                let totalMs = Int(Date().timeIntervalSince(solveStart) * 1000)
                let reason = Task.isCancelled ? "cancelled" : "timeout"
                print("[SlidingPuzzleSolver] \(reason.capitalized) after \(nodes) nodes (bound=\(bound), elapsedMs=\(totalMs), initialH=\(h0))")
                return nil
            }
            bound = result
        }
        let totalMs = Int(Date().timeIntervalSince(solveStart) * 1000)
        print("[SlidingPuzzleSolver] Aborted: bound exceeded safety ceiling (elapsedMs=\(totalMs), nodes=\(nodes))")
        return nil
    }

    /// Fast non-optimal solver path using weighted A*.
    /// Returns quickly with a valid solution if one is found within budget.
    public func solveFast(
        _ state: PuzzleBoxState,
        maxSeconds: TimeInterval = 3.0,
        weight: Int = 3,
        maxExpandedNodes: Int = 300_000
    ) -> PuzzleBoxSolution? {
        let initial = state.tiles
        let goal = Array(1..<Self.NN) + [0]
        guard Self.isValidTileSet(initial), Self.isSolvable(initial) else { return nil }
        guard let blankIdx = initial.firstIndex(of: 0) else { return nil }
        if initial == goal {
            return PuzzleBoxSolution(
                moves: [],
                gridBoundsOnScreen: state.gridBoundsInImage,
                cellSize: state.cellSize,
                puzzleName: state.puzzleName
            )
        }

        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutNanos = UInt64(maxSeconds * 1_000_000_000.0)
        let h0 = Self.heuristic(initial)
        print("[SlidingPuzzleSolver] Fast solve start — heuristic=\(h0) blank=\(blankIdx) timeout=\(String(format: "%.1f", maxSeconds))s weight=\(weight)")

        var nodes: [FastNode] = []
        nodes.reserveCapacity(200_000)
        nodes.append(
            FastNode(
                tiles: initial,
                blank: blankIdx,
                g: 0,
                h: h0,
                parent: -1,
                move: nil
            )
        )

        var open = MinHeap()
        open.push(f: h0 * weight, id: 0)
        var bestG: [[Int]: Int] = [initial: 0]

        var expanded = 0
        while let entry = open.popMin() {
            if expanded & 0xFF == 0 {
                if Task.isCancelled {
                    print("[SlidingPuzzleSolver] Fast solve cancelled — expanded=\(expanded)")
                    return nil
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                if elapsed >= timeoutNanos {
                    print("[SlidingPuzzleSolver] Fast solve timeout — expanded=\(expanded)")
                    return nil
                }
            }
            if expanded >= maxExpandedNodes {
                print("[SlidingPuzzleSolver] Fast solve node cap reached — expanded=\(expanded)")
                return nil
            }
            let node = nodes[entry.id]
            if let known = bestG[node.tiles], node.g > known {
                continue
            }
            if node.h == 0 {
                let moves = Self.reconstructMoves(nodes: nodes, endID: entry.id)
                print("[SlidingPuzzleSolver] Fast solve found \(moves.count) moves (expanded=\(expanded))")
                return PuzzleBoxSolution(
                    moves: moves,
                    gridBoundsOnScreen: state.gridBoundsInImage,
                    cellSize: state.cellSize,
                    puzzleName: state.puzzleName
                )
            }
            expanded += 1

            let br = node.blank / Self.N
            let bc = node.blank % Self.N
            for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nr = br + dr
                let nc = bc + dc
                guard nr >= 0 && nr < Self.N && nc >= 0 && nc < Self.N else { continue }
                let nPos = nr * Self.N + nc

                var childTiles = node.tiles
                childTiles.swapAt(node.blank, nPos)
                let g2 = node.g + 1
                if let known = bestG[childTiles], known <= g2 {
                    continue
                }
                let h2 = Self.heuristic(childTiles)
                let child = FastNode(
                    tiles: childTiles,
                    blank: nPos,
                    g: g2,
                    h: h2,
                    parent: entry.id,
                    move: (row: nr, col: nc)
                )
                let id = nodes.count
                nodes.append(child)
                bestG[childTiles] = g2
                open.push(f: g2 + (weight * h2), id: id)
            }
        }

        print("[SlidingPuzzleSolver] Fast solve exhausted open set without solution")
        return nil
    }

    private struct FastNode {
        public let tiles: [Int]
        let blank: Int
        let g: Int
        let h: Int
        let parent: Int
        let move: (row: Int, col: Int)?
    }

    private struct HeapEntry {
        let f: Int
        let id: Int
    }

    private struct MinHeap {
        private var storage: [HeapEntry] = []

        mutating func push(f: Int, id: Int) {
            storage.append(HeapEntry(f: f, id: id))
            siftUp(from: storage.count - 1)
        }

        mutating func popMin() -> HeapEntry? {
            guard !storage.isEmpty else { return nil }
            if storage.count == 1 { return storage.removeLast() }
            let min = storage[0]
            storage[0] = storage.removeLast()
            siftDown(from: 0)
            return min
        }

        private mutating func siftUp(from index: Int) {
            var i = index
            while i > 0 {
                let p = (i - 1) / 2
                if storage[p].f <= storage[i].f { break }
                storage.swapAt(p, i)
                i = p
            }
        }

        private mutating func siftDown(from index: Int) {
            var i = index
            while true {
                let l = 2 * i + 1
                let r = 2 * i + 2
                var best = i
                if l < storage.count, storage[l].f < storage[best].f { best = l }
                if r < storage.count, storage[r].f < storage[best].f { best = r }
                if best == i { break }
                storage.swapAt(i, best)
                i = best
            }
        }
    }

    private static func reconstructMoves(nodes: [FastNode], endID: Int) -> [(row: Int, col: Int)] {
        var out: [(row: Int, col: Int)] = []
        var current = endID
        while current >= 0 {
            let node = nodes[current]
            if let move = node.move { out.append(move) }
            current = node.parent
        }
        return out.reversed()
    }

    private static func timeoutBudgetSeconds(for state: PuzzleBoxState, initialHeuristic: Int) -> TimeInterval {
        var budget = defaultMaxSolveSeconds
        // High-confidence boards are worth more search budget.
        if state.matchConfidence >= 0.80 {
            budget = max(budget, 30)
        }
        // Very hard states (high admissible heuristic) often need deeper IDA* bounds.
        if initialHeuristic >= 50 {
            budget = max(budget, 45)
        }
        return min(60, budget)
    }

    // MARK: - IDA* recursive search

    // Returns: 0 = found,  Int.max = timeout,  else = minimum exceeded cost
    private static func search(
        _ tiles:   inout [Int],
        _ blank:   inout Int,
        _ moves:   inout [(row: Int, col: Int)],
        g:         Int,
        bound:     Int,
        lastBlank: Int,
        startUptimeNanos: UInt64,
        timeoutNanos: UInt64,
        nodes:     inout Int
    ) -> Int {

        nodes += 1
        if nodes & 0xFF == 0 {
            // Treat Task cancellation the same as a timeout: propagate the
            // sentinel up so the outer `while bound < 500` loop exits, and
            // the caller logs the reason.
            if Task.isCancelled { return Int.max }
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds &- startUptimeNanos
            if elapsedNanos >= timeoutNanos { return Int.max }
        }

        let h = heuristic(tiles)
        let f = g + h
        if f > bound { return f }
        if h == 0    { return 0 }   // solved

        let br = blank / N,  bc = blank % N
        var minimum = Int.max
        // Order next moves by lower child heuristic first to reduce search explosion.
        var orderedChildren: [(nPos: Int, nr: Int, nc: Int, hChild: Int)] = []
        orderedChildren.reserveCapacity(4)
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nr = br + dr,  nc = bc + dc
            guard nr >= 0 && nr < N && nc >= 0 && nc < N else { continue }
            let nPos = nr * N + nc
            if nPos == lastBlank { continue }   // don't immediately undo
            tiles.swapAt(blank, nPos)
            let hChild = heuristic(tiles)
            tiles.swapAt(blank, nPos)
            orderedChildren.append((nPos: nPos, nr: nr, nc: nc, hChild: hChild))
        }
        orderedChildren.sort { $0.hChild < $1.hChild }

        for child in orderedChildren {
            let savedBlank = blank
            tiles.swapAt(blank, child.nPos)
            blank = child.nPos
            // Record the position the tile was clicked from — the pre-move
            // position of the tile that just slid into the blank.
            moves.append((row: child.nr, col: child.nc))

            let result = search(
                &tiles, &blank, &moves,
                g: g + 1,
                bound: bound,
                lastBlank: savedBlank,
                startUptimeNanos: startUptimeNanos,
                timeoutNanos: timeoutNanos,
                nodes: &nodes
            )
            if result == 0   { return 0 }
            if result == Int.max { return Int.max } // timeout: propagate immediately
            if result < minimum { minimum = result }

            // Undo move
            tiles.swapAt(blank, savedBlank)
            blank = savedBlank
            moves.removeLast()
        }

        return minimum
    }

    // MARK: - Solvability check
    //
    // For an odd-sized grid (N = 5), a configuration is solvable if the
    // number of inversions in the tile sequence (blank excluded) is even.

    public static func isSolvable(_ tiles: [Int]) -> Bool {
        let flat = tiles.filter { $0 != 0 }
        var inversions = 0
        for i in 0..<flat.count {
            for j in (i + 1)..<flat.count {
                if flat[i] > flat[j] { inversions += 1 }
            }
        }
        return inversions % 2 == 0
    }

    /// Guardrail against OCR/matching mistakes: valid state must contain exactly
    /// one instance of each value in 0...24.
    public static func isValidTileSet(_ tiles: [Int]) -> Bool {
        guard tiles.count == NN else { return false }
        let allowed = Set(0..<NN)
        let values = Set(tiles)
        return values == allowed && values.count == NN
    }

    // MARK: - Admissible heuristic: Manhattan + linear conflict

    private static func heuristic(_ tiles: [Int]) -> Int {
        var h = 0
        for pos in 0..<NN {
            let tile = tiles[pos]
            guard tile != 0 else { continue }
            let target = tile - 1   // tile k belongs at position k-1
            h += abs(pos / N - target / N) + abs(pos % N - target % N)
        }
        h += linearConflict(tiles)
        return h
    }

    // Each pair of tiles in the same row (or column) whose goal positions
    // are also both in that row (or column) but reversed adds +2 to the
    // lower bound (they need at least 2 extra moves to get past each other).
    private static func linearConflict(_ tiles: [Int]) -> Int {
        var lc = 0

        for row in 0..<N {
            for c1 in 0..<N {
                let t1 = tiles[row * N + c1]
                guard t1 != 0, (t1 - 1) / N == row else { continue }
                for c2 in (c1 + 1)..<N {
                    let t2 = tiles[row * N + c2]
                    guard t2 != 0, (t2 - 1) / N == row else { continue }
                    if (t1 - 1) % N > (t2 - 1) % N { lc += 2 }
                }
            }
        }

        for col in 0..<N {
            for r1 in 0..<N {
                let t1 = tiles[r1 * N + col]
                guard t1 != 0, (t1 - 1) % N == col else { continue }
                for r2 in (r1 + 1)..<N {
                    let t2 = tiles[r2 * N + col]
                    guard t2 != 0, (t2 - 1) % N == col else { continue }
                    if (t1 - 1) / N > (t2 - 1) / N { lc += 2 }
                }
            }
        }

        return lc
    }
}
