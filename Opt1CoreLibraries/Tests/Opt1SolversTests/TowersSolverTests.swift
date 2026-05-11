import Testing
import CoreGraphics
@testable import Opt1Solvers

@Suite("TowersSolver")
struct TowersSolverTests {

    private func makeState(_ hints: TowersHints) -> TowersState {
        TowersState(hints: hints, gridBoundsInImage: .zero)
    }

    // MARK: - towersVisible helper (parameterized)

    @Test("towersVisible counts correctly", arguments: [
        ([1, 2, 3, 4, 5], 5),   // strictly increasing: all visible
        ([5, 4, 3, 2, 1], 1),   // strictly decreasing: only first visible
        ([3, 1, 4, 5, 2], 3),   // 3→1, skip 1, 4→2, 5→3, skip 2
        ([1, 5, 2, 3, 4], 2),   // 1 visible, 5 visible = 2
        ([5, 1, 2, 3, 4], 1),   // only 5
        ([1, 1, 1, 1, 1], 1),   // all same height, only first
    ] as [([Int], Int)])
    func towersVisibleCount(line: [Int], expected: Int) {
        #expect(towersVisible(line) == expected)
    }

    // MARK: - Fully constrained puzzle with known solution

    @Test("Fully constrained puzzle — standard known solution")
    func fullyConstrainedKnownSolution() throws {
        // A valid 5×5 Towers puzzle with all 20 hints set.
        // Grid (rows top-to-bottom, cols left-to-right):
        //   2 1 4 3 5
        //   3 5 2 4 1
        //   4 2 5 1 3
        //   5 3 1 2 4
        //   1 4 3 5 2
        //
        // Derived visibility counts:
        //   top    (col 0→4): [2, 3, 2, 3, 2] (looking down each col from top)
        //   bottom (col 0→4): [3, 2, 3, 2, 3] (looking up each col from bottom)
        //   left   (row 0→4): [2, 2, 2, 2, 3] (looking right each row from left)
        //   right  (row 0→4): [2, 3, 2, 2, 2] (looking left each row from right)
        //
        // (Re-derived inline for correctness)
        let grid: [[Int]] = [
            [2, 1, 4, 3, 5],
            [3, 5, 2, 4, 1],
            [4, 2, 5, 1, 3],
            [5, 3, 1, 2, 4],
            [1, 4, 3, 5, 2],
        ]

        var hints = TowersHints()
        for col in 0..<5 {
            hints.top[col]    = towersVisible(grid.map { $0[col] })
            hints.bottom[col] = towersVisible(grid.map { $0[col] }.reversed())
        }
        for row in 0..<5 {
            hints.left[row]  = towersVisible(grid[row])
            hints.right[row] = towersVisible(grid[row].reversed())
        }

        let solution = TowersSolver().solve(makeState(hints))
        let result = try #require(solution)

        for row in result.grid {
            #expect(Set(row) == Set(1...5))
        }
        for col in 0..<5 {
            let colVals = (0..<5).map { result.grid[$0][col] }
            #expect(Set(colVals) == Set(1...5))
        }
        for col in 0..<5 {
            let colVals = (0..<5).map { result.grid[$0][col] }
            if let th = hints.top[col] {
                #expect(towersVisible(colVals) == th)
            }
            if let bh = hints.bottom[col] {
                #expect(towersVisible(colVals.reversed()) == bh)
            }
        }
        for row in 0..<5 {
            if let lh = hints.left[row] {
                #expect(towersVisible(result.grid[row]) == lh)
            }
            if let rh = hints.right[row] {
                #expect(towersVisible(result.grid[row].reversed()) == rh)
            }
        }
    }

    // MARK: - Partial hints (only top row given)

    @Test("Partial hints: only top hints — still produces a valid Latin square")
    func partialHintsLatinSquare() throws {
        var hints = TowersHints()
        hints.top = [2, 3, 1, 4, 2]  // valid sequence of visible counts from top

        let solution = TowersSolver().solve(makeState(hints))
        let result = try #require(solution)

        for row in result.grid {
            #expect(Set(row) == Set(1...5))
        }
        for col in 0..<5 {
            let colVals = (0..<5).map { result.grid[$0][col] }
            #expect(Set(colVals) == Set(1...5))
        }
        for col in 0..<5 {
            if let th = hints.top[col] {
                #expect(towersVisible((0..<5).map { result.grid[$0][col] }) == th)
            }
        }
    }

    // MARK: - Contradictory hints

    @Test("Contradictory hints (top=1 and bottom=1 on same column) returns nil")
    func contradictoryHintsNoSolution() throws {
        // Top-visibility of 1 on column 0 forces tower 5 at the top.
        // Bottom-visibility of 1 on column 0 also forces tower 5 at the bottom.
        // A column can hold only one 5, so this is unsatisfiable.
        var hints = TowersHints()
        hints.top[0]    = 1
        hints.bottom[0] = 1
        let solution = TowersSolver().solve(makeState(hints))
        #expect(solution == nil)
    }

    // MARK: - No hints (any valid Latin square)

    @Test("No hints: returns some valid 5×5 Latin square")
    func noHintsValidLatinSquare() throws {
        let hints = TowersHints()
        let solution = TowersSolver().solve(makeState(hints))
        let result = try #require(solution)

        for row in result.grid {
            #expect(Set(row) == Set(1...5))
        }
        for col in 0..<5 {
            let colVals = (0..<5).map { result.grid[$0][col] }
            #expect(Set(colVals) == Set(1...5))
        }
    }
}
