import Opt1Core
import CoreGraphics
import Foundation

// MARK: - Domain types

public enum CombatStyle: Int, CaseIterable, CustomStringConvertible {
    case melee  = 0   // crossed swords – silver/grey
    case ranged = 1   // bow & arrow    – orange/brown
    case magic  = 2   // wizard hat     – blue

    public var description: String {
        switch self { case .melee: "Melee"; case .ranged: "Ranged"; case .magic: "Magic" }
    }
}

public struct LockboxState {
    public let cells: [[CombatStyle]]      // [row][col], 5 × 5
    /// Grid bounding rect in the captured image (pixel coordinates, top-left origin).
    public let gridBoundsInImage: CGRect

    public init(cells: [[CombatStyle]], gridBoundsInImage: CGRect) {
        self.cells = cells
        self.gridBoundsInImage = gridBoundsInImage
    }
}

public struct LockboxSolution {
    public let targetStyle: CombatStyle
    /// [row][col] number of clicks (0, 1 or 2) needed to reach targetStyle.
    public let clicks: [[Int]]
    public let totalClicks: Int
    /// Grid bounding rect in screen coordinates (AppKit top-left origin), populated
    /// by the app layer after mapping `LockboxState.gridBoundsInImage` to screen space.
    /// Nil when the solution is produced outside of an active screen capture context.
    public let gridBoundsOnScreen: CGRect?

    public init(
        targetStyle: CombatStyle,
        clicks: [[Int]],
        totalClicks: Int,
        gridBoundsOnScreen: CGRect? = nil
    ) {
        self.targetStyle = targetStyle
        self.clicks = clicks
        self.totalClicks = totalClicks
        self.gridBoundsOnScreen = gridBoundsOnScreen
    }
}

// MARK: - Solver (Lights-Out variant over GF(3))
//
// Clicking cell (r,c) cycles it AND its 4-connected neighbours by +1 mod 3.
// Goal: all cells reach the same state.
//
// Model: A · x ≡ b  (mod 3)
//   A[k][l] = 1  iff clicking l affects k  (i.e. l == k or l is adjacent to k)
//   x[l]    = number of times to click cell l  (0, 1, or 2)
//   b[k]    = (target − current[k])  mod 3
//
// We solve with Gaussian elimination over GF(3) for each of the 3 possible
// target states and return the solution with the fewest total clicks.
//
// The 5×5 Lights-Out matrix over GF(3) has rank < 25, so some b vectors are
// inconsistent.  We try all 3 targets and return nil if none work (which
// means the cell classification fed us the wrong state).

public struct LockboxSolver: PuzzleSolver {

    public init() {}

    /// Returns a minimum-click solution, or `nil` if the grid is malformed or no
    /// GF(3) solution exists for any target style (indicating the detector
    /// mis-classified one or more cells).
    public func solve(_ state: LockboxState) -> LockboxSolution? {
        let n = 25  // 5×5 cells

        // Input shape must be exactly 5×5 — the solver assumes it below.
        guard state.cells.count == 5,
              state.cells.allSatisfy({ $0.count == 5 }) else {
            print("[LockboxSolver] ⚠ Invalid grid shape: \(state.cells.count) rows, row widths \(state.cells.map(\.count))")
            return nil
        }

        // Build the 25×25 effect matrix: A[k][l] = 1 iff clicking l affects k.
        var A = [[Int]](repeating: [Int](repeating: 0, count: n), count: n)
        for r in 0..<5 {
            for c in 0..<5 {
                let k = r * 5 + c
                A[k][k] = 1
                for (dr, dc) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let nr = r + dr, nc = c + dc
                    if nr >= 0 && nr < 5 && nc >= 0 && nc < 5 {
                        A[k][nr * 5 + nc] = 1
                    }
                }
            }
        }

        let stateFlat = state.cells.flatMap { $0.map(\.rawValue) }
        print("[LockboxSolver] State: \(stateFlat)")
        var best: LockboxSolution? = nil

        for targetVal in 0..<3 {
            let b = stateFlat.map { (targetVal - $0 + 3) % 3 }
            let augmented = (0..<n).map { A[$0] + [b[$0]] }

            guard let (x, total) = gf3Solve(augmented: augmented, numVars: n) else {
                print("[LockboxSolver] target=\(CombatStyle(rawValue: targetVal)!) → inconsistent (no solution)")
                continue
            }

            var verified = true
            for k in 0..<n {
                let dot = (0..<n).reduce(0) { ($0 + A[k][$1] * x[$1]) % 3 }
                if dot != b[k] { verified = false; print("[LockboxSolver] ⚠ verification failed at k=\(k)") }
            }
            print("[LockboxSolver] target=\(CombatStyle(rawValue: targetVal)!) → \(total) clicks\(verified ? " ✓" : " ✗ BAD")")

            let clicks = (0..<5).map { r in (0..<5).map { c in x[r * 5 + c] } }
            let sol = LockboxSolution(
                targetStyle: CombatStyle(rawValue: targetVal)!,
                clicks: clicks,
                totalClicks: total
            )
            if best == nil || total < best!.totalClicks { best = sol }
        }

        if best == nil {
            print("[LockboxSolver] ⚠ No solution found for any target — cell classification is likely wrong")
        }
        return best
    }
}

// MARK: - GF(3) linear solver

/// Solves the augmented system [A|b] over GF(3).
/// Returns the solution x with the minimum Σx[i], trying all free-variable
/// combinations (the 5×5 Lights-Out matrix has at most a few free variables).
private func gf3Solve(augmented: [[Int]], numVars n: Int) -> ([Int], Int)? {
    var mat = augmented
    let rows = mat.count
    let cols = mat[0].count   // n + 1 (last column is b)
    var pivotCols = [Int]()
    var nextPivotRow = 0

    // Full RREF elimination over GF(3).
    for col in 0..<n {
        guard let pr = (nextPivotRow..<rows).first(where: { mat[$0][col] != 0 }) else {
            continue  // free variable
        }
        mat.swapAt(nextPivotRow, pr)
        pivotCols.append(col)

        let inv = gf3Inv(mat[nextPivotRow][col])
        mat[nextPivotRow] = mat[nextPivotRow].map { gf3Mul($0, inv) }

        for r in 0..<rows where r != nextPivotRow {
            let f = mat[r][col]
            if f != 0 {
                for c in 0..<cols {
                    mat[r][c] = gf3Sub(mat[r][c], gf3Mul(f, mat[nextPivotRow][c]))
                }
            }
        }
        nextPivotRow += 1
    }

    // Check consistency: a zero variable-row with non-zero RHS = no solution.
    for r in nextPivotRow..<rows {
        if mat[r][cols - 1] != 0 { return nil }
    }

    let freeCols = Set(0..<n).subtracting(Set(pivotCols)).sorted()
    let combos   = Int(pow(3.0, Double(freeCols.count)))

    var bestX: [Int]? = nil
    var bestTotal = Int.max

    for combo in 0..<combos {
        var x = [Int](repeating: 0, count: n)
        var tmp = combo
        for fc in freeCols { x[fc] = tmp % 3; tmp /= 3 }

        for (i, pc) in pivotCols.enumerated() {
            var val = mat[i][cols - 1]
            for c in 0..<n where c != pc {
                val = gf3Sub(val, gf3Mul(mat[i][c], x[c]))
            }
            x[pc] = (val % 3 + 3) % 3
        }

        let total = x.reduce(0, +)
        if total < bestTotal { bestTotal = total; bestX = x }
    }

    return bestX.map { ($0, bestTotal) }
}

// MARK: - GF(3) arithmetic helpers

@inline(__always) private func gf3Mul(_ a: Int, _ b: Int) -> Int { (a * b) % 3 }
@inline(__always) private func gf3Sub(_ a: Int, _ b: Int) -> Int { (a - b + 3) % 3 }
/// Multiplicative inverse in GF(3): 1⁻¹=1, 2⁻¹=2 (since 2×2=4≡1 mod 3).
@inline(__always) private func gf3Inv(_ a: Int) -> Int { a == 2 ? 2 : 1 }
