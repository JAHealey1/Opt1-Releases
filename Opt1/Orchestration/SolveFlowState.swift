import CoreGraphics
import Foundation
import Opt1CelticKnot

// MARK: - SolveFlowState

/// Shared solve-flow state owned by `ClueOrchestrator` and read by the
/// puzzle-box and celtic-knot coordinators.
///
/// The state machine has four modes:
/// - `.idle`: no pipeline is running; Opt+1 starts a fresh solve.
/// - `.running`: a pipeline is executing (capture/detect/solve).
/// - `.awaitingPuzzleHintCapture`: a puzzle-box solve finished its first
///   pass and is waiting for the user to hover the hint indicator and
///   press Opt+1 again.
/// - `.awaitingCelticKnotInvert`: a celtic-knot first pass finished and is
///   waiting for the user to click Invert Paths and press Opt+1 again.
///
/// Transitions are exposed as explicit methods so call sites read as state
/// machine steps rather than raw enum assignments. The backing `mode`
/// remains publicly readable for pattern matching.
@MainActor
final class SolveFlowState {
    enum Mode {
        case idle
        case running
        case awaitingPuzzleHintCapture(windowFrame: CGRect)
        case awaitingCelticKnotInvert(firstCapture: CelticKnotCapture, windowFrame: CGRect)
    }

    private(set) var mode: Mode = .idle

    var isIdle: Bool {
        if case .idle = mode { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = mode { return true }
        return false
    }

    // MARK: - Transitions

    /// Transition into `.running`. Expected when entering a pipeline from
    /// `.idle` or when resuming from a wait state.
    func beginRunning() {
        mode = .running
    }

    /// If currently `.running`, drop back to `.idle`; otherwise leave the
    /// state untouched. Used in `defer` blocks so pipelines that parked
    /// the state in a wait mode don't get reset on the way out.
    func finishIfRunning() {
        if isRunning { mode = .idle }
    }

    /// Unconditional reset to `.idle`. Used when abandoning a wait state.
    func reset() {
        mode = .idle
    }

    /// Park the state machine waiting for the user to hover the hint
    /// indicator and press Opt+1 again.
    func awaitPuzzleHintCapture(windowFrame: CGRect) {
        mode = .awaitingPuzzleHintCapture(windowFrame: windowFrame)
    }

    /// Park the state machine waiting for the user to click Invert Paths
    /// and press Opt+1 again. The first-pass capture is preserved so the
    /// coordinator can run both invert-hypotheses against the second pass.
    func awaitCelticKnotInvert(firstCapture: CelticKnotCapture, windowFrame: CGRect) {
        mode = .awaitingCelticKnotInvert(firstCapture: firstCapture, windowFrame: windowFrame)
    }
}
