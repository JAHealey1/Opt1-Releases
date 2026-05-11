import CoreGraphics
import Foundation
import ScreenCaptureKit
import Opt1Solvers
import Opt1Matching
@testable import Opt1

// MARK: - MockCaptureManager

final class MockCaptureManager: CaptureManaging {
    var captureCallCount = 0
    var shouldThrow = false

    /// Minimal valid 1×1 CGImage used as the return value for all captures.
    private static let placeholder: CGImage = {
        let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }()

    struct MockCaptureError: Error {}

    func captureWindow(_ window: SCWindow, excludingWindowIDs: [CGWindowID]) async throws -> CGImage {
        captureCallCount += 1
        if shouldThrow { throw MockCaptureError() }
        return Self.placeholder
    }
}

// MARK: - MockStatusBanner

final class MockStatusBanner: StatusBannerShowing {
    var messages: [String] = []
    var cancelCount = 0

    func showStatus(_ message: String, near windowFrame: CGRect) { messages.append(message) }
    func updateStatus(_ message: String) { messages.append(message) }
    func cancel() { cancelCount += 1 }
}

// MARK: - MockPuzzleBoxOverlay

final class MockPuzzleBoxOverlay: PuzzleBoxOverlaying {
    var showReadyCallCount = 0
    var lastSolution: PuzzleBoxSolution?
    var lastOnSteppingStarted: (() -> Void)?

    func showReady(solution: PuzzleBoxSolution, onSteppingStarted: (() -> Void)?) {
        showReadyCallCount += 1
        lastSolution = solution
        lastOnSteppingStarted = onSteppingStarted
    }
}

// MARK: - MockPuzzleSnipOverlay

final class MockPuzzleSnipOverlay: PuzzleSnipOverlaying {
    var result: PuzzleSnipResult? = nil

    func captureSelection(around windowFrame: CGRect) async -> PuzzleSnipResult? {
        result
    }
}

// MARK: - MockClueProvider

final class MockClueProvider: ClueProviding {
    var clues: [ClueSolution] = []
    var textCorpus: ClueCorpus = ClueCorpus(clues: [])
}

// MARK: - MockCaptureErrorPresenter

@MainActor
final class MockCaptureErrorPresenter: CaptureErrorPresenting {
    var onOpenPermissions: (() -> Void)?
    var windowNotFoundCallCount = 0
    var captureErrors: [Error] = []

    func showWindowNotFound() {
        windowNotFoundCallCount += 1
    }

    func showCaptureError(_ error: Error) {
        captureErrors.append(error)
    }
}

// MARK: - MockPresenter

final class MockPresenter: OverlayPresenting {
    var isScanOverlayActive: Bool = false
    
    func dismissTriangulationIfNeeded() {
        
    }
    
    var triangulationState: CompassTriangulationState? = nil
    var overlayMessages: [(message: String, mode: OverlayMode)] = []
    var solutionOverlayCallCount = 0
    var lockboxOverlayCallCount = 0
    var towersOverlayCallCount = 0
    var scanOverlayCallCount = 0
    var celticKnotOverlayCallCount = 0
    var eliteCompassOverlayCallCount = 0

    func overlayExclusionIDs() -> [CGWindowID] { [] }

    func showOverlay(message: String, detail: String, mode: OverlayMode, windowFrame: CGRect?) {
        overlayMessages.append((message, mode))
    }

    func showSolutionOverlay(_ solution: ClueSolution, windowFrame: CGRect) {
        solutionOverlayCallCount += 1
    }

    func showScanOverlay(region: String, scanRange: String, spots: [ClueSolution], windowFrame: CGRect) {
        scanOverlayCallCount += 1
    }

    func showLockboxOverlay(solution: LockboxSolution, windowFrame: CGRect) {
        lockboxOverlayCallCount += 1
    }

    func showTowersOverlay(solution: TowersSolution, hints: TowersHints, windowFrame: CGRect) {
        towersOverlayCallCount += 1
    }

    func showCelticKnotOverlay(solution: CelticKnotSolution, windowFrame: CGRect) {
        celticKnotOverlayCallCount += 1
    }

    func showEliteCompassOverlay(state: CompassTriangulationState, windowFrame: CGRect) {
        eliteCompassOverlayCallCount += 1
    }
}

// MARK: - Factory

/// Builds a ClueOrchestrator wired entirely with mocks.
@MainActor
func makeOrchestratorWithMocks() -> (
    orchestrator: ClueOrchestrator,
    capture: MockCaptureManager,
    banner: MockStatusBanner,
    puzzleBox: MockPuzzleBoxOverlay,
    snip: MockPuzzleSnipOverlay,
    presenter: MockPresenter,
    clueProvider: MockClueProvider,
    captureErrorPresenter: MockCaptureErrorPresenter,
    sessionState: AppSessionState
) {
    let capture               = MockCaptureManager()
    let banner                = MockStatusBanner()
    let puzzleBox             = MockPuzzleBoxOverlay()
    let snip                  = MockPuzzleSnipOverlay()
    let presenter             = MockPresenter()
    let clueProvider          = MockClueProvider()
    let captureErrorPresenter = MockCaptureErrorPresenter()
    let sessionState          = AppSessionState()

    let orchestrator = ClueOrchestrator(
        captureManager: capture,
        statusBanner: banner,
        puzzleBoxOverlay: puzzleBox,
        puzzleSnipOverlay: snip,
        presenter: presenter,
        clueProvider: clueProvider,
        captureErrorPresenter: captureErrorPresenter,
        sessionState: sessionState
    )
    return (orchestrator, capture, banner, puzzleBox, snip, presenter, clueProvider, captureErrorPresenter, sessionState)
}
