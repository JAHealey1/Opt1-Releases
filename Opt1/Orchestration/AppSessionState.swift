import Foundation

// MARK: - AppSessionState

/// Single owner for app-wide session state that multiple components need to
/// read/write coherently:
/// - `solveFlow`: the solve pipeline state machine (idle/running/awaiting…).
/// - `isDataCollectionActive`: true while a puzzle data-collection run is in
///   progress (blocks solves and hotkeys).
/// - `isCelticKnotCollectionActive`: true while a celtic-knot data-collection
///   run is in progress.
///
/// Owned by `AppDelegate` and passed into `ClueOrchestrator`, which forwards
/// `solveFlow` into its coordinators. Data-collection controllers flip the
/// collection flags directly via callback; the orchestrator reads them to
/// gate hotkey behaviour.
@MainActor
final class AppSessionState {
    let solveFlow: SolveFlowState = SolveFlowState()

    var isDataCollectionActive: Bool = false
    var isCelticKnotCollectionActive: Bool = false

    /// True while the clue-solving pipeline is running.
    var isSolveRunning: Bool { solveFlow.isRunning }

    /// True if either data-collection flow is active.
    var isAnyCollectionActive: Bool {
        isDataCollectionActive || isCelticKnotCollectionActive
    }
}
