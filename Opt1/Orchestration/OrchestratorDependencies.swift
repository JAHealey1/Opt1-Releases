import CoreGraphics
import Foundation
import ScreenCaptureKit
import Opt1Solvers
import Opt1Matching

// MARK: - CaptureManaging

protocol CaptureManaging: AnyObject {
    func captureWindow(_ window: SCWindow, excludingWindowIDs: [CGWindowID]) async throws -> CGImage
}

extension CaptureManaging {
    func captureWindow(_ window: SCWindow) async throws -> CGImage {
        try await captureWindow(window, excludingWindowIDs: [])
    }
}

extension ScreenCaptureManager: CaptureManaging {}

// MARK: - StatusBannerShowing

protocol StatusBannerShowing: AnyObject {
    func showStatus(_ message: String, near windowFrame: CGRect)
    func updateStatus(_ message: String)
    func cancel()
}

extension PipelineStatusBanner: StatusBannerShowing {}

// MARK: - PuzzleBoxOverlaying

protocol PuzzleBoxOverlaying: AnyObject {
    /// Shows the ready overlay. `onSteppingStarted` fires when the user presses
    /// Start (before any tile click is guided) so callers can drop background
    /// work that would otherwise race with the in-progress solve.
    func showReady(solution: PuzzleBoxSolution, onSteppingStarted: (() -> Void)?)
}

extension PuzzleBoxOverlaying {
    func showReady(solution: PuzzleBoxSolution) {
        showReady(solution: solution, onSteppingStarted: nil)
    }
}

extension PuzzleBoxOverlayController: PuzzleBoxOverlaying {}

// MARK: - PuzzleSnipOverlaying

protocol PuzzleSnipOverlaying: AnyObject {
    func captureSelection(around windowFrame: CGRect) async -> PuzzleSnipResult?
}

extension PuzzleSnipOverlayController: PuzzleSnipOverlaying {}

// MARK: - OverlayPresenting

protocol OverlayPresenting: AnyObject {
    var triangulationState: CompassTriangulationState? { get }
    /// True when a scan triangulation overlay is currently showing. Used by
    /// the orchestrator to treat subsequent Opt+1 presses as "done" and close
    /// the overlay without re-running the full capture pipeline.
    var isScanOverlayActive: Bool { get }
    func overlayExclusionIDs() -> [CGWindowID]
    func showOverlay(message: String, detail: String, mode: OverlayMode, windowFrame: CGRect?)
    func showSolutionOverlay(_ solution: ClueSolution, windowFrame: CGRect)
    func showScanOverlay(region: String, scanRange: String, spots: [ClueSolution], windowFrame: CGRect)
    func showLockboxOverlay(solution: LockboxSolution, windowFrame: CGRect)
    func showTowersOverlay(solution: TowersSolution, hints: TowersHints, windowFrame: CGRect)
    func showCelticKnotOverlay(solution: CelticKnotSolution, windowFrame: CGRect)
    func showEliteCompassOverlay(state: CompassTriangulationState, windowFrame: CGRect)
    /// Dismisses the active elite compass overlay (and clears the
    /// triangulation state) if one is currently showing. Used by the
    /// orchestrator to end an auto-triangulation session and resume the
    /// normal clue pipeline on the next Opt+1 press.
    func dismissTriangulationIfNeeded()
}

extension OverlayPresenting {
    func showOverlay(message: String, detail: String, mode: OverlayMode) {
        showOverlay(message: message, detail: detail, mode: mode, windowFrame: nil)
    }
}

extension OverlayPresenter: OverlayPresenting {}

// MARK: - ClueProviding

/// Read-only view over the bundled clue corpus. Orchestrator and presenter
/// depend on this instead of `ClueDatabase.shared` directly, so tests can
/// inject a fixed corpus without touching the bundled JSON.
protocol ClueProviding: AnyObject {
    /// Full clue list — includes map/compass/scan entries that have their own
    /// dedicated detection paths alongside the text-matched entries.
    var clues: [ClueSolution] { get }

    /// Pre-computed corpus routed through `FuzzyMatcher.bestMatch`. Excludes
    /// types that are never reached via text matching (map, compass, scan)
    /// and carries the trigram/normalised-text cache alongside the filtered
    /// clue list.
    var textCorpus: ClueCorpus { get }
}

extension ClueDatabase: ClueProviding {}
