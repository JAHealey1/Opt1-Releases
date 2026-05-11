import Opt1Core
import CoreGraphics
import Foundation

// MARK: - Domain types

/// Hint values for all four edges of the 5×5 grid.
/// Index 0 is always the "near" end (left→right for top/bottom, top→bottom for left/right).
public struct TowersHints {
    public init() {}
    /// Viewed from the top, looking down.   top[0] = leftmost column.
    public var top:    [Int?] = Array(repeating: nil, count: 5)
    /// Viewed from the bottom, looking up.  bottom[0] = leftmost column.
    public var bottom: [Int?] = Array(repeating: nil, count: 5)
    /// Viewed from the left, looking right. left[0] = topmost row.
    public var left:   [Int?] = Array(repeating: nil, count: 5)
    /// Viewed from the right, looking left. right[0] = topmost row.
    public var right:  [Int?] = Array(repeating: nil, count: 5)

    public var presentCount: Int {
        (top + bottom + left + right).compactMap { $0 }.count
    }

    public func describe() -> String {
        let f: ([Int?]) -> String = { $0.map { $0.map(String.init) ?? "?" }.joined(separator: " ") }
        return "T[\(f(top))]  B[\(f(bottom))]  L[\(f(left))]  R[\(f(right))]"
    }
}

public struct TowersState {
    public let hints: TowersHints
    /// The 5×5 playing-cell area in captured-image pixel coords (top-left origin).
    /// Does NOT include the outer hint-number ring.
    public let gridBoundsInImage: CGRect

    public init(hints: TowersHints, gridBoundsInImage: CGRect) {
        self.hints = hints
        self.gridBoundsInImage = gridBoundsInImage
    }
}

public struct TowersSolution {
    public let grid: [[Int]]   // [row][col], each value 1–5
}

// MARK: - Solver

public struct TowersSolver: PuzzleSolver {

    public init() {}

    /// Solves the Towers puzzle using backtracking with incremental visibility pruning.
    public func solve(_ state: TowersState) -> TowersSolution? {
        var grid = Array(repeating: Array(repeating: 0, count: 5), count: 5)
        guard towersBacktrack(&grid, pos: 0, hints: state.hints) else {
            print("[TowersSolver] No solution found")
            return nil
        }
        let rows = grid.map { $0.map(String.init).joined(separator: " ") }.joined(separator: " | ")
        print("[TowersSolver] Solution: \(rows)")
        return TowersSolution(grid: grid)
    }
}

/// Counts towers visible along `line` from index 0 toward the end.
/// Taller towers block shorter ones behind them.
public func towersVisible(_ line: [Int]) -> Int {
    var count = 0, maxH = 0
    for h in line where h > 0 {
        if h > maxH { count += 1; maxH = h }
    }
    return count
}

private func towersCanPlace(_ grid: [[Int]], row: Int, col: Int, val: Int) -> Bool {
    for c in 0..<5 where grid[row][c] == val { return false }
    for r in 0..<5 where grid[r][col] == val { return false }
    return true
}

/// Returns false if a partially-filled row/column already violates a hint.
private func towersConstraintsOK(_ grid: [[Int]], row: Int, col: Int, hints: TowersHints) -> Bool {
    let rowVals  = (0..<5).map { grid[row][$0] }
    let rowDone  = rowVals.allSatisfy { $0 > 0 }
    let colVals  = (0..<5).map { grid[$0][col] }
    let colDone  = colVals.allSatisfy { $0 > 0 }

    if let lh = hints.left[row] {
        let partial = Array(rowVals.prefix(col + 1))
        if towersVisible(partial) > lh { return false }
        if rowDone && towersVisible(rowVals) != lh { return false }
    }
    if let rh = hints.right[row], rowDone {
        if towersVisible(rowVals.reversed()) != rh { return false }
    }
    if let th = hints.top[col] {
        let partial = Array(colVals.prefix(row + 1))
        if towersVisible(partial) > th { return false }
        if colDone && towersVisible(colVals) != th { return false }
    }
    if let bh = hints.bottom[col], colDone {
        if towersVisible(colVals.reversed()) != bh { return false }
    }
    return true
}

private func towersBacktrack(_ grid: inout [[Int]], pos: Int, hints: TowersHints) -> Bool {
    guard pos < 25 else { return true }
    let row = pos / 5, col = pos % 5
    for val in 1...5 {
        guard towersCanPlace(grid, row: row, col: col, val: val) else { continue }
        grid[row][col] = val
        if towersConstraintsOK(grid, row: row, col: col, hints: hints) {
            if towersBacktrack(&grid, pos: pos + 1, hints: hints) { return true }
        }
        grid[row][col] = 0
    }
    return false
}
