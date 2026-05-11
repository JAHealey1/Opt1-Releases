import Foundation

/// Common shape for every puzzle solver in the app.
///
/// Each concrete solver binds `State` and `Solution` to its domain types, so
/// the protocol is usable as a generic constraint (e.g. in tests that want to
/// swap a real solver for a mock) while preserving each solver's full result
/// fidelity — Lockbox/Towers/SlidingPuzzle return `T?`, Celtic Knot returns a
/// richer `CelticKnotSolveResult`.
///
/// This protocol intentionally exposes only the canonical one-shot entry
/// point. Multi-stage ladders (e.g. SlidingPuzzle's `solveFast` escalation
/// chain) stay on the concrete type because the escalation policy belongs
/// alongside the solver, not in a shared abstraction.
///
/// Conformances live next to each solver's implementation:
///   - `LockboxSolver`          (LockboxSolver.swift)
///   - `TowersSolver`           (TowersSolver.swift)
///   - `SlidingPuzzleSolver`    (SlidingPuzzleSolver.swift)
///   - `CelticKnotDetector`     (CelticKnotSolver.swift, via extension)
public protocol PuzzleSolver {
    associatedtype State
    associatedtype Solution

    func solve(_ state: State) -> Solution
}
