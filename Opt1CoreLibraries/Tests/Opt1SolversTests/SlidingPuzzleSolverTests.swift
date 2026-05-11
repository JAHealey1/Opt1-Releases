import Testing
import CoreGraphics
@testable import Opt1Solvers

@Suite("SlidingPuzzleSolver")
struct SlidingPuzzleSolverTests {

    // MARK: - Helpers

    /// Solved state: tiles 1...24 followed by 0 (blank).
    private static let solvedTiles: [Int] = Array(1..<25) + [0]

    private func makeState(_ tiles: [Int]) -> PuzzleBoxState {
        PuzzleBoxState(
            tiles: tiles,
            gridBoundsInImage: .zero,
            cellSize: CGSize(width: 50, height: 50),
            puzzleName: "TestPuzzle",
            matchConfidence: 1.0,
            needsHintAssistedRetry: false
        )
    }

    // MARK: - isValidTileSet

    @Test("isValidTileSet: solved board is valid")
    func validTileSetSolved() throws {
        #expect(SlidingPuzzleSolver.isValidTileSet(Self.solvedTiles))
    }

    @Test("isValidTileSet: duplicate tile is invalid")
    func invalidTileSetDuplicate() throws {
        var tiles = Self.solvedTiles
        tiles[0] = tiles[1]   // duplicate the first real tile
        #expect(!SlidingPuzzleSolver.isValidTileSet(tiles))
    }

    @Test("isValidTileSet: wrong count is invalid")
    func invalidTileSetWrongCount() throws {
        let short = Array(0..<24)  // 24 elements instead of 25
        #expect(!SlidingPuzzleSolver.isValidTileSet(short))
    }

    // MARK: - isSolvable

    @Test("isSolvable: solved state has zero inversions — solvable")
    func solvedStateIsSolvable() throws {
        #expect(SlidingPuzzleSolver.isSolvable(Self.solvedTiles))
    }

    @Test("isSolvable: one-swap (odd inversions) — unsolvable")
    func oneSwapUnsolvable() throws {
        var tiles = Self.solvedTiles
        tiles.swapAt(0, 1)   // swap tiles 1 and 2 → 1 inversion → odd → not solvable
        #expect(!SlidingPuzzleSolver.isSolvable(tiles))
    }

    // MARK: - Already-solved board

    @Test("solve: already-solved board returns 0 moves")
    func alreadySolvedZeroMoves() throws {
        let solution = SlidingPuzzleSolver().solve(makeState(Self.solvedTiles))
        let result = try #require(solution)
        #expect(result.moves.isEmpty)
    }

    @Test("solveFast: already-solved board returns 0 moves")
    func alreadySolvedFastZeroMoves() throws {
        let solution = SlidingPuzzleSolver().solveFast(makeState(Self.solvedTiles))
        let result = try #require(solution)
        #expect(result.moves.isEmpty)
    }

    // MARK: - One move from solved

    @Test("solve: one move from solved returns exactly one move")
    func oneMoveFromSolved() throws {
        // Move blank from position 24 (last) to position 23 (tile 24 swaps into blank).
        // Solved: [1,2,...,24,0]. Swap positions 23 and 24 → [1,2,...,23,0,24].
        var tiles = Self.solvedTiles
        tiles.swapAt(23, 24)   // tile 24 moves right; blank is now at col 3, row 4
        let solution = SlidingPuzzleSolver().solveFast(makeState(tiles))
        let result = try #require(solution)
        #expect(result.moves.count == 1)
    }

    // MARK: - Short scramble (IDA* path)

    @Test("solve: short scramble solves correctly")
    func shortScramble() throws {
        // 3-move scramble: swap blank with tile at (4,3), then (4,2), then (3,2).
        // From solved: [1..24, 0]
        // After swap 23↔24 (blank moves left): [1..23, 0, 24]
        // After swap 22↔23 (blank moves left): [1..22, 0, 23, 24]
        // After swap 17↔22 (blank moves up):   [1..17, 0, 18, 19, 20, 21, 22, 23, 24]
        // This creates a board 3 moves from solved.
        var tiles = Self.solvedTiles
        tiles.swapAt(23, 24)
        tiles.swapAt(22, 23)
        tiles.swapAt(17, 22)

        #expect(SlidingPuzzleSolver.isValidTileSet(tiles))
        #expect(SlidingPuzzleSolver.isSolvable(tiles))

        let solution = SlidingPuzzleSolver().solveFast(makeState(tiles))
        let result = try #require(solution)
        // Optimal is 3 moves; weighted A* may return a slightly longer path but should be close.
        #expect(result.moves.count >= 3)
        #expect(result.moves.count <= 15)
    }

    // MARK: - Invalid boards return nil

    @Test("solve: invalid tile set returns nil")
    func invalidTileSetReturnsNil() throws {
        var tiles = Self.solvedTiles
        tiles[0] = tiles[1]
        let solution = SlidingPuzzleSolver().solveFast(makeState(tiles))
        #expect(solution == nil)
    }

    @Test("solve: unsolvable board returns nil from solveFast")
    func unsolvableBoardReturnsNil() throws {
        var tiles = Self.solvedTiles
        tiles.swapAt(0, 1)    // 1-inversion swap → unsolvable
        let solution = SlidingPuzzleSolver().solveFast(makeState(tiles))
        #expect(solution == nil)
    }

    // MARK: - Solution self-verification (apply moves → solved)

    /// Applies a sequence of `(row, col)` clicks to `tiles` in-place.
    /// Each click must refer to a cell adjacent to the blank; the tile
    /// and blank are swapped. Throws if any click is invalid.
    private func applyMoves(_ moves: [(row: Int, col: Int)], to tiles: inout [Int]) throws {
        let n = SlidingPuzzleSolver.N
        for (row, col) in moves {
            let idx = row * n + col
            guard idx >= 0, idx < tiles.count else {
                throw ApplyError.outOfBounds
            }
            guard let blankIdx = tiles.firstIndex(of: 0) else {
                throw ApplyError.noBlank
            }
            let blankRow = blankIdx / n, blankCol = blankIdx % n
            let isAdjacent = (abs(blankRow - row) + abs(blankCol - col)) == 1
            guard isAdjacent else {
                throw ApplyError.notAdjacent(row: row, col: col, blankRow: blankRow, blankCol: blankCol)
            }
            tiles.swapAt(idx, blankIdx)
        }
    }

    private enum ApplyError: Error, CustomStringConvertible {
        case outOfBounds
        case noBlank
        case notAdjacent(row: Int, col: Int, blankRow: Int, blankCol: Int)
        var description: String {
            switch self {
            case .outOfBounds: return "Move out of bounds"
            case .noBlank: return "No blank tile on the board"
            case let .notAdjacent(r, c, br, bc):
                return "Move (\(r),\(c)) is not adjacent to blank at (\(br),\(bc))"
            }
        }
    }

    @Test("solveFast: applying returned moves produces the solved board",
          arguments: [
              [(23, 24)],                               // 1-move scramble
              [(23, 24), (22, 23)],                     // 2-move scramble
              [(23, 24), (22, 23), (17, 22)],           // 3-move scramble
              [(23, 24), (22, 23), (17, 22), (16, 17)], // 4-move scramble
          ] as [[(Int, Int)]])
    func appliedMovesReachSolvedState(swaps: [(Int, Int)]) throws {
        var tiles = Self.solvedTiles
        for (a, b) in swaps { tiles.swapAt(a, b) }

        #expect(SlidingPuzzleSolver.isValidTileSet(tiles))
        #expect(SlidingPuzzleSolver.isSolvable(tiles))

        let solution = try #require(SlidingPuzzleSolver().solveFast(makeState(tiles)))

        try applyMoves(solution.moves, to: &tiles)
        #expect(tiles == Self.solvedTiles,
                "After applying \(solution.moves.count) moves the board should match the solved state.")
    }

    // MARK: - Solution metadata pass-through

    @Test("solveFast: solution carries puzzleName from state")
    func puzzleNamePassThrough() throws {
        let state = PuzzleBoxState(
            tiles: Self.solvedTiles,
            gridBoundsInImage: .zero,
            cellSize: CGSize(width: 40, height: 40),
            puzzleName: "Vanstrom",
            matchConfidence: 0.9,
            needsHintAssistedRetry: false
        )
        let solution = try #require(SlidingPuzzleSolver().solveFast(state))
        #expect(solution.puzzleName == "Vanstrom")
    }
}
