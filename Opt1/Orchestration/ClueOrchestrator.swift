import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import Opt1Solvers

// MARK: - ClueOrchestrator

/// Owns the clue-solving state machine and delegates puzzle-type specific
/// work to dedicated coordinators (`PuzzleBoxCoordinator`, `CelticKnotCoordinator`).
/// `AppDelegate` is responsible only for app lifecycle, the status item,
/// permissions, and hotkey setup — everything else lives here.
@MainActor
final class ClueOrchestrator {

    // MARK: - Dependencies

    private let captureManager: any CaptureManaging
    private let statusBanner: any StatusBannerShowing
    private let puzzleSnipOverlay: any PuzzleSnipOverlaying
    private let presenter: any OverlayPresenting
    private let clueProvider: any ClueProviding
    private let captureErrorPresenter: any CaptureErrorPresenting
    private let clueScrollPipeline = ClueScrollPipeline()
    private let puzzleBoxCoordinator: PuzzleBoxCoordinator
    private let celticKnotCoordinator: CelticKnotCoordinator
    private let sessionState: AppSessionState

    private var state: SolveFlowState { sessionState.solveFlow }

    // MARK: - Init

    init(
        captureManager: any CaptureManaging,
        statusBanner: any StatusBannerShowing,
        puzzleBoxOverlay: any PuzzleBoxOverlaying,
        puzzleSnipOverlay: any PuzzleSnipOverlaying,
        presenter: any OverlayPresenting,
        clueProvider: any ClueProviding,
        captureErrorPresenter: any CaptureErrorPresenting,
        sessionState: AppSessionState
    ) {
        self.captureManager = captureManager
        self.statusBanner = statusBanner
        self.puzzleSnipOverlay = puzzleSnipOverlay
        self.presenter = presenter
        self.clueProvider = clueProvider
        self.captureErrorPresenter = captureErrorPresenter
        self.sessionState = sessionState
        self.puzzleBoxCoordinator = PuzzleBoxCoordinator(
            captureManager: captureManager,
            statusBanner: statusBanner,
            puzzleBoxOverlay: puzzleBoxOverlay,
            puzzleSnipOverlay: puzzleSnipOverlay,
            presenter: presenter,
            captureErrorPresenter: captureErrorPresenter,
            state: sessionState.solveFlow
        )
        self.celticKnotCoordinator = CelticKnotCoordinator(
            captureManager: captureManager,
            statusBanner: statusBanner,
            presenter: presenter,
            captureErrorPresenter: captureErrorPresenter,
            state: sessionState.solveFlow
        )
    }

    // MARK: - Public Entry Points

    func handleHotkeyAction(_ action: GlobalHotkeyAction) async {
        if sessionState.isDataCollectionActive {
            print("[Opt1] Hotkey ignored: puzzle data collection is active")
            return
        }
        switch action {
        case .solveClue:
            await handleSolveTrigger()
        case .solvePuzzleSnip:
            await handlePuzzleSnipTrigger()
        }
    }

    // MARK: - Trigger Handlers

    private func handleSolveTrigger() async {
        switch state.mode {
        case .running:
            print("[Opt1] Solve trigger ignored: pipeline already running")
        case .idle:
            // Opt+1 while a scan overlay is showing = "I'm done, move on".
            // Dismiss the overlay and then fall through to the normal pipeline
            // so the next clue (or whatever is on screen) is detected immediately.
            if presenter.isScanOverlayActive {
                print("[Opt1] Scan overlay active — dismissing and continuing pipeline")
                presenter.dismissTriangulationIfNeeded()
            }
            await solveClueAction()
        case .awaitingPuzzleHintCapture(let frame):
            await puzzleBoxCoordinator.resumeHintCapture(windowFrame: frame)
        case .awaitingCelticKnotInvert(let firstCapture, let frame):
            await celticKnotCoordinator.resumeInvert(firstCapture: firstCapture, windowFrame: frame)
        }
    }

    private func handlePuzzleSnipTrigger() async {
        if sessionState.isDataCollectionActive {
            print("[Opt1] Puzzle snip trigger ignored: data collection active")
            return
        }
        if state.isRunning {
            print("[Opt1] Puzzle snip trigger ignored: pipeline already running")
            return
        }
        if case .awaitingPuzzleHintCapture = state.mode {
            print("[Opt1] Puzzle snip trigger: cancelling pending hint retry state")
            state.reset()
            puzzleBoxCoordinator.cancelPendingHintRetry()
        }
        if let triState = presenter.triangulationState {
            let autoTriComplete = (triState.isEasternLands
                ? AppSettings.isArcAutoTriangulationEnabled
                : AppSettings.isAutoTriangulationEnabled)
                && triState.bearings.count >= 2
                && triState.intersectionRegion != nil
            if autoTriComplete {
                print("[Opt1] Puzzle snip trigger: auto-triangulation intersection complete — dismissing overlay")
                presenter.dismissTriangulationIfNeeded()
            }
        }
        AppSettings.beginDebugRun()
        await puzzleBoxCoordinator.runSnipFlow()
    }

    // MARK: - Solve Clue Action

    func solveClueAction() async {
        if sessionState.isDataCollectionActive {
            print("[Opt1] Solve action ignored: data collection active")
            return
        }
        guard state.isIdle else { return }
        AppSettings.beginDebugRun()
        state.beginRunning()
        defer { state.finishIfRunning() }
        do {
            guard let rsWindow = try await WindowFinder.findRuneScapeWindow() else {
                captureErrorPresenter.showWindowNotFound()
                return
            }
            let image = try await captureManager.captureWindow(rsWindow, excludingWindowIDs: presenter.overlayExclusionIDs())
            print("[Opt1] Captured: \(image.width)x\(image.height) from '\(rsWindow.title ?? "?")'")
            await runCluePipeline(image: image, windowFrame: rsWindow.frame, logicalWindowWidth: rsWindow.frame.width)
        } catch {
            print("[Opt1] Error: \(error)")
            captureErrorPresenter.showCaptureError(error)
        }
    }

    // MARK: - Shared Pipeline

    private func runCluePipeline(image: CGImage, windowFrame: CGRect, logicalWindowWidth: CGFloat? = nil) async {
        // If a triangulation session is already live, short-circuit straight
        // to arrow detection so the next press adds a bearing — we don't want
        // scroll/lockbox/etc. detectors firing in the middle of a triangulation.
        if let existingState = presenter.triangulationState {
            // Auto-triangulation only: once both bearings are anchored and an
            // intersection has been computed, treat the next Opt+1 as a brand-
            // new clue trigger. Dismiss the overlay and fall through to the
            // full pipeline against the fresh screenshot.
            let autoTriComplete = (existingState.isEasternLands
                ? AppSettings.isArcAutoTriangulationEnabled
                : AppSettings.isAutoTriangulationEnabled)
                && existingState.bearings.count >= 2
                && existingState.intersectionRegion != nil
            if autoTriComplete {
                print("[Opt1] Auto-triangulation: intersection complete — dismissing overlay and re-running full pipeline")
                presenter.dismissTriangulationIfNeeded()
                // intentional fall-through to the full detector chain below
            } else {
                let eliteDetector = EliteCompassDetector()
                if let reading = await eliteDetector.detect(in: image) {
                    print("[Opt1] Elite compass bearing (triangulation active): \(reading.angle.formatted())")
                    existingState.addBearing(reading.angle)
                    applyAutoTriangulationOriginIfNeeded(state: existingState)
                } else {
                    print("[Opt1] Triangulation active but no compass arrow detected in screenshot")
                }
                return
            }
        }

        do {
            statusBanner.showStatus("Checking for clues…", near: windowFrame)
            try? await Task.sleep(for: .milliseconds(50))

            statusBanner.updateStatus("Scanning for clue scroll…")
            let scrollDetector = ClueScrollDetector()
            if let clueRect = await scrollDetector.detectClueRect(in: image) {
                statusBanner.updateStatus("Reading clue text…")
                print("[Opt1] Clue scroll rect: \(clueRect)")
                let result = try await clueScrollPipeline.process(
                    clueRect: clueRect,
                    image: image,
                    clueProvider: clueProvider
                ) { [statusBanner] msg in statusBanner.updateStatus(msg) }
                statusBanner.cancel()
                handleClueScrollResult(result, windowFrame: windowFrame)
                return
            }

            // ── Phase 3: No scroll — check other puzzle/game types ──────
            statusBanner.updateStatus("Checking lockbox…")
            let lockboxDetector = LockboxDetector()
            if let lockboxState = await lockboxDetector.detect(in: image) {
                statusBanner.cancel()
                if var solution = LockboxSolver().solve(lockboxState) {
                    let scaleX = windowFrame.width  / CGFloat(image.width)
                    let scaleY = windowFrame.height / CGFloat(image.height)
                    let gridOnScreen = CGRect(
                        x: windowFrame.minX + lockboxState.gridBoundsInImage.minX * scaleX,
                        y: windowFrame.minY + lockboxState.gridBoundsInImage.minY * scaleY,
                        width:  lockboxState.gridBoundsInImage.width  * scaleX,
                        height: lockboxState.gridBoundsInImage.height * scaleY
                    )
                    solution = LockboxSolution(
                        targetStyle: solution.targetStyle,
                        clicks: solution.clicks,
                        totalClicks: solution.totalClicks,
                        gridBoundsOnScreen: gridOnScreen
                    )
                    let grid = solution.clicks.map { $0.map(String.init).joined(separator: " ") }.joined(separator: " | ")
                    print("[Opt1] Lockbox — target: \(solution.targetStyle), \(solution.totalClicks) clicks, grid: \(grid)")
                    presenter.showLockboxOverlay(solution: solution, windowFrame: windowFrame)
                } else {
                    presenter.showOverlay(
                        message: "Lockbox — no solution found",
                        detail: "Cell classification is likely wrong; try again with a cleaner frame.",
                        mode: .error,
                        windowFrame: windowFrame
                    )
                }
                return
            }

            statusBanner.updateStatus("Checking towers…")
            let towersDetector = TowersDetector()
            if let towersState = await towersDetector.detect(in: image) {
                statusBanner.cancel()
                if let solution = TowersSolver().solve(towersState) {
                    print("[Opt1] Towers solved")
                    presenter.showTowersOverlay(solution: solution, hints: towersState.hints, windowFrame: windowFrame)
                } else {
                    presenter.showOverlay(
                        message: "Towers — no solution found",
                        detail: towersState.hints.describe(),
                        mode: .error,
                        windowFrame: windowFrame
                    )
                }
                return
            }

            statusBanner.updateStatus("Checking celtic knot…")
            let celticKnotDetector = CelticKnotDetector()
            if let knotOutcome = await celticKnotDetector.detect(in: image) {
                // The X-button and "Celtic Knot" title were both confirmed —
                // the modal is definitely a Celtic Knot regardless of outcome.
                // Do NOT fall through to the puzzle-box detector; it also
                // matches the X-button and would falsely identify this as a puzzle.
                switch knotOutcome {
                case .detected(let knotResult):
                    // Hand the banner off to the coordinator — it will keep
                    // updating it through model load / classify / save and cancel
                    // it before showing the invert prompt or solve overlay.
                    await celticKnotCoordinator.handleFirstPass(
                        image: image,
                        detector: celticKnotDetector,
                        detectionResult: knotResult,
                        windowFrame: windowFrame
                    )
                case .confirmedButFailed:
                    statusBanner.cancel()
                    presenter.showOverlay(
                        message: "Celtic Knot — grid not recognised",
                        detail: "The puzzle was identified but the grid could not be analysed. Try shifting the runes or generate a new puzzle and try again.",
                        mode: .error,
                        windowFrame: windowFrame
                    )
                }
                return
            }

            if !clueProvider.clues.isEmpty {
                statusBanner.updateStatus("Checking scan clue…")
                if let scanResult = await clueScrollPipeline.matchScanWithoutScroll(
                    in: image, clues: clueProvider.clues
                ) {
                    statusBanner.cancel()
                    presenter.showScanOverlay(
                        region: scanResult.region,
                        scanRange: scanResult.scanRange,
                        spots: scanResult.spots,
                        windowFrame: windowFrame
                    )
                    return
                }
            }

            // Compass clue arrow detection runs last — it solves compass clues
            // (all difficulties) via triangulation. Kept at the tail of the
            // pipeline so stricter detectors (scroll, puzzles, scan) don't get
            // shadowed by false-positive arrow matches.
            let eliteDetector = EliteCompassDetector()
            if let reading = await eliteDetector.detect(in: image) {
                statusBanner.cancel()
                print("[Opt1] Elite compass arrow detected — bearing \(reading.angle.formatted())\(reading.isEasternLands ? " [EASTERN LANDS]" : "")")
                let triState = CompassTriangulationState()
                triState.isEasternLands = reading.isEasternLands
                triState.addBearing(reading.angle)
                presenter.showEliteCompassOverlay(state: triState, windowFrame: windowFrame)
                applyAutoTriangulationOriginIfNeeded(state: triState)
                return
            }
            
            // Run the NCC search off the main actor — it's CPU-intensive
            // (strided, but still O(W×H)) and would freeze the UI if run inline.
            // Placed before Celtic Knot so we skip Vision OCR entirely when a
            // slider is open.
            if AppSettings.isSlidePuzzleAutoDetectEnabled {
                statusBanner.updateStatus("Checking sliding puzzle…")
                let logW = logicalWindowWidth
                let sliderLoc = await Task.detached(priority: .userInitiated) {
                    SliderInterfaceLocator().locate(in: image, logicalWindowWidth: logW)
                }.value
                if let loc = sliderLoc,
                   let cropImage = image.cropping(to: loc.puzzleRectInImage) {
                    print("[Opt1] Slider anchor matched: '\(loc.anchorKey)' conf=\(String(format: "%.3f", loc.confidence))")
                    statusBanner.cancel()
                    await puzzleBoxCoordinator.runAutoDetectFlow(
                        cropImage: cropImage,
                        puzzleRectInImage: loc.puzzleRectInImage,
                        sourceImageSize: CGSize(width: image.width, height: image.height),
                        windowFrame: windowFrame
                    )
                    return
                }
            }

            // ── Nothing detected ────────────────────────────────────────
            statusBanner.cancel()
            presenter.showOverlay(
                message: "RS3 captured — no clue detected",
                detail: "\(image.width)x\(image.height) px",
                mode: .phase1Confirmation,
                windowFrame: windowFrame
            )

        } catch {
            statusBanner.cancel()
            print("[Opt1] Pipeline error: \(error)")
            presenter.showOverlay(message: "Error", detail: error.localizedDescription, mode: .error)
        }
    }

    // MARK: - Auto-Triangulation

    /// When the user has opted in to auto-triangulation (and calibrated both
    /// reference points), anchor the just-added pending bearing at the
    /// appropriate saved coordinate based on how many bearings the state
    /// already holds. No-op when auto-triangulation is off, when the points
    /// are not calibrated, or when there is no pending bearing to anchor.
    ///
    /// For Eastern Lands (master) compasses this uses the Arc calibration
    /// points when Arc auto-tri is enabled; otherwise it falls back to the
    /// surface points for elite compasses.
    ///
    /// Counter-intuitive ordering: `addBearing` only sets `pendingBearing`
    /// — the bearing is not yet appended to `bearings`. So `bearings.count`
    /// here is the *previous* count, i.e. 0 means "this will become bearing #1",
    /// 1 means "this will become bearing #2".
    private func applyAutoTriangulationOriginIfNeeded(state: CompassTriangulationState) {
        let isArc = state.isEasternLands
        if isArc {
            guard AppSettings.isArcAutoTriangulationEnabled else { return }
        } else {
            guard AppSettings.isAutoTriangulationEnabled else { return }
        }
        guard state.pendingBearing != nil else { return }

        let priorCount = state.bearings.count
        let point: (x: Int, y: Int)?
        switch priorCount {
        case 0: point = isArc ? AppSettings.arcAutoTriPoint1 : AppSettings.autoTriPoint1
        case 1: point = isArc ? AppSettings.arcAutoTriPoint2 : AppSettings.autoTriPoint2
        default: point = nil
        }

        guard let p = point else {
            print("[Opt1] Auto-triangulation: no saved point for bearings.count=\(priorCount); skipping auto-anchor")
            return
        }

        let label = isArc ? "Arc auto-triangulation" : "Auto-triangulation"
        print("[Opt1] \(label): anchoring bearing #\(priorCount + 1) at saved point (\(p.x), \(p.y))")
        state.setOriginForPending(gameX: p.x, gameY: p.y)
    }

    // MARK: - Clue Scroll Result Dispatch

    private func handleClueScrollResult(_ result: ClueScrollPipeline.Result, windowFrame: CGRect) {
        switch result {
        case .cropFailed:
            presenter.showOverlay(
                message: "Detection error",
                detail: "Could not crop detected region",
                mode: .error,
                windowFrame: windowFrame
            )
        case .mapClue(let solution):
            presenter.showSolutionOverlay(solution, windowFrame: windowFrame)
        case .scan(let region, let scanRange, let spots):
            presenter.showScanOverlay(region: region, scanRange: scanRange, spots: spots, windowFrame: windowFrame)
        case .scanRegionUnknown(let rawOCR):
            presenter.showOverlay(
                message: "Scan clue — region not in database",
                detail: "Re-run scrape_clues.py, then restart",
                mode: .rawOCR(rawOCR),
                windowFrame: windowFrame
            )
        case .solution(let solution, _):
            presenter.showSolutionOverlay(solution, windowFrame: windowFrame)
        case .ocrEmpty:
            presenter.showOverlay(
                message: "Clue detected, OCR returned empty",
                detail: "Scroll may be partially off-screen",
                mode: .rawOCR(""),
                windowFrame: windowFrame
            )
        case .corpusEmpty(let rawOCR):
            presenter.showOverlay(
                message: rawOCR,
                detail: "Run scrape_clues.py to populate database",
                mode: .rawOCR(rawOCR),
                windowFrame: windowFrame
            )
        case .noMatch(let rawOCR):
            presenter.showOverlay(
                message: rawOCR,
                detail: "No match — try pressing again with the scroll fully open",
                mode: .rawOCR(rawOCR),
                windowFrame: windowFrame
            )
        }
    }
}
