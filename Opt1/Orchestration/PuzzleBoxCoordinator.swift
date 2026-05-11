import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import Opt1Solvers

// MARK: - PuzzleBoxCoordinator

/// Owns the puzzle-box snip / detect / hint-retry / solve-and-optimize flow.
/// Lifted out of `ClueOrchestrator` so the sliding-puzzle pipeline, its
/// retry state machine, and the hint-hover classifier live in one place
/// rather than being interleaved with unrelated clue-scroll logic.
///
/// The coordinator shares `SolveFlowState` with the orchestrator and writes
/// the puzzle-specific states (`.running`, `.idle`, `.awaitingPuzzleHintCapture`).
/// The orchestrator routes the Opt+1 hotkey here when the state is
/// `.awaitingPuzzleHintCapture`, and routes Opt+2 here unconditionally.
@MainActor
final class PuzzleBoxCoordinator {

    // MARK: - Dependencies

    private let captureManager: any CaptureManaging
    private let statusBanner: any StatusBannerShowing
    private let puzzleBoxOverlay: any PuzzleBoxOverlaying
    private let puzzleSnipOverlay: any PuzzleSnipOverlaying
    private let presenter: any OverlayPresenting
    private let captureErrorPresenter: any CaptureErrorPresenting
    private let state: SolveFlowState

    // MARK: - Hint-Retry State

    /// What `resumeHintCapture` should do when the user presses Opt+1 from
    /// `.awaitingPuzzleHintCapture`. Stored as an enum because the two entry
    /// flows recover the second-capture crop differently:
    ///
    /// - `.snip` reuses the user's normalized rect from `runSnipFlow`,
    ///   re-mapping to pixel coords against the new capture's size.
    /// - `.autoDetect` reuses the pixel rect found by the first locator pass.
    ///   The slider modal can't be moved or resized by the user once open,
    ///   so we just crop the second capture at the same pixel rect rather
    ///   than re-running NCC.
    private enum PendingHintRetry {
        case snip(normalized: CGRect, originalCrop: CGImage)
        case autoDetect(
            originalCrop: CGImage,
            puzzleRectInImage: CGRect,
            sourceImageSize: CGSize
        )
    }

    private var pendingHintRetry: PendingHintRetry?

    // MARK: - Solve Session

    private var puzzleOptimizeTask: Task<Void, Never>?
    private var puzzleSolveSessionID: UUID?
    /// Flipped true when the user presses Start on the ready overlay. While
    /// true we refuse to publish later optimizer improvements (which would
    /// wipe the in-progress stepping overlay) and we cancel the background
    /// refinement task so it stops burning CPU.
    private var puzzleSteppingActive: Bool = false

    // MARK: - Debug

    private var puzzleDebugDir: URL? {
        AppSettings.debugSubfolder(named: "PuzzleBoxDebug")
    }

    // MARK: - Init

    init(
        captureManager: any CaptureManaging,
        statusBanner: any StatusBannerShowing,
        puzzleBoxOverlay: any PuzzleBoxOverlaying,
        puzzleSnipOverlay: any PuzzleSnipOverlaying,
        presenter: any OverlayPresenting,
        captureErrorPresenter: any CaptureErrorPresenting,
        state: SolveFlowState
    ) {
        self.captureManager = captureManager
        self.statusBanner = statusBanner
        self.puzzleBoxOverlay = puzzleBoxOverlay
        self.puzzleSnipOverlay = puzzleSnipOverlay
        self.presenter = presenter
        self.captureErrorPresenter = captureErrorPresenter
        self.state = state
    }

    // MARK: - Public Entry Points

    /// Opt+1 auto-detect entry point — called when `SliderInterfaceLocator`
    /// has already found the puzzle rect from a full-window capture.
    ///
    /// - Parameters:
    ///   - cropImage:          The crop of the captured window clipped to the
    ///     5×5 puzzle grid (same crop the locator derived).
    ///   - puzzleRectInImage:  The rect of `cropImage` inside the full captured
    ///     window image (used to map tile positions back to screen coordinates,
    ///     and reused verbatim if the hint-hover retry fires).
    ///   - sourceImageSize:    Size of the full captured window image. Stashed
    ///     so the hint retry can sanity-check that the second capture has the
    ///     same dimensions (otherwise the cached rect would be stale).
    ///   - windowFrame:        Screen rect of the RS window.
    func runAutoDetectFlow(
        cropImage: CGImage,
        puzzleRectInImage: CGRect,
        sourceImageSize: CGSize,
        windowFrame: CGRect
    ) async {
        state.beginRunning()
        defer { state.finishIfRunning() }
        pendingHintRetry = .autoDetect(
            originalCrop: cropImage,
            puzzleRectInImage: puzzleRectInImage,
            sourceImageSize: sourceImageSize
        )
        await runDetectSolve(
            image: cropImage,
            windowFrame: windowFrame,
            fromHintRetry: false,
            fromSnipFlow: false,
            forceSnipMode: true,
            cropOffsetInImagePixels: puzzleRectInImage.origin,
            sourceImageSize: sourceImageSize
        )
    }

    /// Clears any pending hint-retry state. Called by the orchestrator when
    /// the user presses Opt+2 while the flow is `.awaitingPuzzleHintCapture`
    /// — we're restarting with a fresh snip, so the previous retry context
    /// is now stale.
    func cancelPendingHintRetry() {
        pendingHintRetry = nil
    }

    /// Opt+2 entry point — prompts the user to drag a rectangle around the
    /// puzzle grid, then runs the detect/solve pipeline against that crop.
    func runSnipFlow() async {
        state.beginRunning()
        defer { state.finishIfRunning() }
        do {
            guard let rsWindow = try await WindowFinder.findRuneScapeWindow() else {
                captureErrorPresenter.showWindowNotFound()
                return
            }
            let shareable = try await SCShareableContent.current
            let snipFrame = rsWindow.appKitGlobalFrame(content: shareable)
            guard let snipResult = await puzzleSnipOverlay.captureSelection(around: snipFrame) else {
                presenter.showOverlay(
                    message: "Puzzle snip cancelled",
                    detail: "Drag a rectangle around the puzzle grid, then release.",
                    mode: .phase1Confirmation,
                    windowFrame: rsWindow.frame
                )
                return
            }

            let image = try await captureManager.captureWindow(rsWindow)
            let cropRectPx = SnipCoordinateMapper.normalizedSnipToImagePixels(
                snipResult.cropInWindowNormalized,
                imageSize: CGSize(width: image.width, height: image.height)
            )
            guard cropRectPx.width >= 160, cropRectPx.height >= 160,
                  let cropImage = image.cropping(to: cropRectPx) else {
                presenter.showOverlay(
                    message: "Puzzle snip too small",
                    detail: "Please drag a rectangle covering the entire 5x5 puzzle grid.",
                    mode: .error,
                    windowFrame: rsWindow.frame
                )
                return
            }

            saveSnipDebug(
                image: image,
                cropImage: cropImage,
                snipFrame: snipFrame,
                windowFrame: rsWindow.frame,
                cropRectPx: cropRectPx,
                cropNormalized: snipResult.cropInWindowNormalized
            )
            pendingHintRetry = .snip(
                normalized: snipResult.cropInWindowNormalized,
                originalCrop: cropImage
            )

            await runDetectSolve(
                image: cropImage,
                windowFrame: rsWindow.frame,
                fromHintRetry: false,
                fromSnipFlow: true,
                forceSnipMode: true,
                cropOffsetInImagePixels: cropRectPx.origin,
                sourceImageSize: CGSize(width: image.width, height: image.height)
            )
        } catch {
            print("[Opt1] Puzzle snip flow error: \(error)")
            presenter.showOverlay(message: "Puzzle snip error", detail: error.localizedDescription, mode: .error)
        }
    }

    /// Opt+1 resume when the state is `.awaitingPuzzleHintCapture`.
    /// Re-captures the window (with the user hovering on Hint) and replays
    /// the detect/solve pipeline using the previous solve crop as the solve
    /// input and the new capture (clipped to the puzzle rect) as the
    /// hint-assist reference. Branches on `pendingHintRetry`:
    ///
    /// - `.snip`: re-derives the crop from the stored normalized rect.
    /// - `.autoDetect`: re-runs `SliderInterfaceLocator` so a moved modal
    ///   doesn't mis-align the hint reference.
    func resumeHintCapture(windowFrame: CGRect) async {
        do {
            guard let rsWindow = try await WindowFinder.findRuneScapeWindow() else {
                captureErrorPresenter.showWindowNotFound()
                return
            }
            let image = try await captureManager.captureWindow(rsWindow)
            state.beginRunning()
            defer {
                if state.isRunning {
                    state.awaitPuzzleHintCapture(windowFrame: windowFrame)
                }
            }
            let imageSize = CGSize(width: image.width, height: image.height)

            switch pendingHintRetry {
            case .snip(let normalized, let originalCrop):
                let cropRectPx = SnipCoordinateMapper.normalizedSnipToImagePixels(
                    normalized,
                    imageSize: imageSize
                )
                if cropRectPx.width >= 160, cropRectPx.height >= 160,
                   let hintCrop = image.cropping(to: cropRectPx) {
                    await runDetectSolve(
                        image: originalCrop,
                        windowFrame: rsWindow.frame,
                        fromHintRetry: true,
                        fromSnipFlow: true,
                        forceSnipMode: true,
                        hintReferenceCaptureImage: hintCrop,
                        cropOffsetInImagePixels: cropRectPx.origin,
                        sourceImageSize: imageSize
                    )
                } else {
                    await runDetectSolve(image: image, windowFrame: rsWindow.frame, fromHintRetry: true)
                }

            case .autoDetect(let originalCrop, let puzzleRectInImage, let sourceImageSize):
                // Reuse the rect from the first auto-detect pass: the slider
                // modal is fixed once open, so cropping the new capture at the
                // same pixel rect gives us the hint preview without a second
                // NCC run. Sanity check that the new capture has the same
                // dimensions — if the user resized the RS window between
                // captures the cached rect would point at the wrong pixels.
                if imageSize == sourceImageSize,
                   let hintCrop = image.cropping(to: puzzleRectInImage) {
                    print("[Opt1] Hint capture: reusing cached puzzle rect \(puzzleRectInImage.integral)")
                    await runDetectSolve(
                        image: originalCrop,
                        windowFrame: rsWindow.frame,
                        fromHintRetry: true,
                        fromSnipFlow: false,
                        forceSnipMode: true,
                        hintReferenceCaptureImage: hintCrop,
                        cropOffsetInImagePixels: puzzleRectInImage.origin,
                        sourceImageSize: imageSize
                    )
                } else {
                    // Mismatched capture size (window was resized) or rect is
                    // somehow off-image. Bail out cleanly — running against
                    // the full window would just blow up the rails localiser.
                    statusBanner.cancel()
                    state.reset()
                    cancelPendingHintRetry()
                    presenter.showOverlay(
                        message: "Puzzle Box — capture changed",
                        detail: "Press \(AppSettings.shared.solveHotkey.displayString) again to redetect, or use \(AppSettings.shared.puzzleHotkey.displayString) to crop manually.",
                        mode: .error,
                        windowFrame: rsWindow.frame
                    )
                    print("[Opt1] Hint capture aborted: capture size changed (was \(sourceImageSize), now \(imageSize))")
                }

            case .none:
                await runDetectSolve(image: image, windowFrame: rsWindow.frame, fromHintRetry: true)
            }
        } catch {
            print("[Opt1] Hint capture error: \(error)")
            presenter.showOverlay(
                message: "Puzzle Box — hint capture failed",
                detail: error.localizedDescription,
                mode: .error,
                windowFrame: windowFrame
            )
        }
    }

    // MARK: - Detect / Solve Pipeline

    private func runDetectSolve(
        image: CGImage,
        windowFrame: CGRect,
        fromHintRetry: Bool,
        fromSnipFlow: Bool = false,
        forceSnipMode: Bool = false,
        hintReferenceCaptureImage: CGImage? = nil,
        cropOffsetInImagePixels: CGPoint = .zero,
        sourceImageSize: CGSize? = nil
    ) async {
        statusBanner.showStatus(fromHintRetry ? "Capturing hint preview…" : "Checking puzzle box…", near: windowFrame)
        if fromHintRetry {
            try? await Task.sleep(for: .milliseconds(120))
        }
        statusBanner.updateStatus("Checking puzzle box…")

        let puzzleBoxDetector = PuzzleBoxDetector()
        var forcedReferenceKey: String?
        var hintReferenceImage: CGImage?
        if fromHintRetry {
            let hintCaptureSource = hintReferenceCaptureImage ?? image
            if forceSnipMode {
                hintReferenceImage = hintCaptureSource
                print("[Opt1] Hint preview (snip) captured for tile assist; keeping puzzle-class decision from scrambled board")
            } else {
                statusBanner.updateStatus("Classifying hint preview…")
                if let hintCapture = detectHintHoverReference(in: hintCaptureSource, detector: puzzleBoxDetector) {
                    forcedReferenceKey = hintCapture.match.key
                    hintReferenceImage = hintCapture.previewImage
                    print("[Opt1] Hint preview classified as \(hintCapture.match.name) (\(hintCapture.match.key)) dist=\(String(format: "%.3f", hintCapture.match.distance)) hintAssist=\(hintReferenceImage != nil)")
                } else {
                    print("[Opt1] Hint preview classification failed; proceeding without forced reference")
                }
            }
        }
        let progressCallback: PuzzleBoxDetector.ProgressCallback = { [statusBanner] msg in
            Task { @MainActor in statusBanner.updateStatus(msg) }
        }
        let outcome = await Task.detached(priority: .userInitiated) {
            return await puzzleBoxDetector.detectInSnipCrop(
                in: image,
                progress: progressCallback,
                preferredReferenceKey: forcedReferenceKey,
                hintReferenceImage: hintReferenceImage
            )
        }.value

        let puzzleState: PuzzleBoxState
        switch outcome {
        case .solved(let s):
            puzzleState = s
        case .unsupported(let puzzleName):
            statusBanner.cancel()
            state.reset()
            cancelPendingHintRetry()
            presenter.showOverlay(
                message: "\(puzzleName) isn't supported",
                detail: "Opt1 can't solve this puzzle type yet.",
                mode: .error,
                windowFrame: windowFrame
            )
            print("[Opt1] Puzzle box identified as unsupported puzzle '\(puzzleName)'. Skipping solve.")
            return
        case .gridLocalizationFailed:
            // The rails/inner-frame cascade declined, meaning the snip
            // doesn't contain a readable 5x5 grid. Hint-hover retry won't
            // help, so we ask the user to re-crop tighter around the board.
            statusBanner.cancel()
            state.reset()
            cancelPendingHintRetry()
            presenter.showOverlay(
                message: "Puzzle Box — Couldn't find the puzzle grid",
                detail: "Re-crop with \(AppSettings.shared.puzzleHotkey.displayString) so the full 5x5 board is in the snip.",
                mode: .error,
                windowFrame: windowFrame
            )
            print("[Opt1] Puzzle box inner-grid localization failed; prompting user to re-crop.")
            return
        case .failed:
            statusBanner.cancel()
            if fromHintRetry {
                presenter.showOverlay(
                    message: "Puzzle Box — hint capture didn't help",
                    detail: "Re-crop with \(AppSettings.shared.puzzleHotkey.displayString) so the full 5x5 board is in the snip.",
                    mode: .error,
                    windowFrame: windowFrame
                )
                state.reset()
                cancelPendingHintRetry()
            } else {
                // First-pass failure (snip OR auto-detect). Both paths can
                // benefit from a hint-hover retry — `pendingHintRetry` was
                // populated by whichever entry point we came from and tells
                // `resumeHintCapture` how to recover the second-capture crop.
                state.awaitPuzzleHintCapture(windowFrame: windowFrame)
                presenter.showOverlay(
                    message: "Puzzle Box - Needs hint preview",
                    detail: "Hover your mouse over Hint, then press \(AppSettings.shared.solveHotkey.displayString) again.",
                    mode: .phase1Confirmation,
                    windowFrame: windowFrame
                )
                print("[Opt1] Puzzle box first-pass tile-match failed; awaiting hint-hover capture (\(fromSnipFlow ? "snip" : "auto-detect")).")
            }
            return
        }

        if puzzleState.needsHintAssistedRetry && !fromHintRetry {
            statusBanner.cancel()
            state.awaitPuzzleHintCapture(windowFrame: windowFrame)
            presenter.showOverlay(
                message: "Puzzle Box needs hint preview",
                detail: "Hover your mouse over Hint, then press \(AppSettings.shared.solveHotkey.displayString) again.",
                mode: .phase1Confirmation,
                windowFrame: windowFrame
            )
            print("[Opt1] Puzzle box low confidence (\(String(format: "%.3f", puzzleState.matchConfidence))) (\(fromSnipFlow ? "snip" : "auto-detect")). Awaiting hint-hover capture.")
            return
        }

        let adjustedState = PuzzleBoxState(
            tiles: puzzleState.tiles,
            gridBoundsInImage: puzzleState.gridBoundsInImage.offsetBy(dx: cropOffsetInImagePixels.x, dy: cropOffsetInImagePixels.y),
            cellSize: puzzleState.cellSize,
            puzzleName: puzzleState.puzzleName,
            matchConfidence: puzzleState.matchConfidence,
            needsHintAssistedRetry: puzzleState.needsHintAssistedRetry
        )

        statusBanner.updateStatus("Solving: \(puzzleState.puzzleName)…")
        try? await Task.sleep(for: .milliseconds(50))
        puzzleOptimizeTask?.cancel()
        let solveSessionID = UUID()
        puzzleSolveSessionID = solveSessionID
        puzzleSteppingActive = false

        // Invoked from the overlay the moment the user presses Start. Cancels
        // the detached optimizer so it stops CPU-churning and (combined with
        // the `puzzleSteppingActive` guard below) prevents a late improvement
        // from overwriting the stepping overlay the user is following.
        let onSteppingStarted: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.puzzleSolveSessionID == solveSessionID else { return }
            if !self.puzzleSteppingActive {
                print("[Opt1] Stepping started — cancelling puzzle optimizer")
            }
            self.puzzleSteppingActive = true
            self.puzzleOptimizeTask?.cancel()
        }

        func publishSolution(_ solution: PuzzleBoxSolution, prefix: String) {
            print("[Opt1] \(prefix): \(solution.moves.count) moves (\(puzzleState.puzzleName))")
            let screenSolution = SnipCoordinateMapper.scaleSolutionToScreen(
                solution,
                imageSize: sourceImageSize ?? CGSize(width: image.width, height: image.height),
                windowFrame: windowFrame
            )
            state.reset()
            cancelPendingHintRetry()
            statusBanner.cancel()
            puzzleBoxOverlay.showReady(solution: screenSolution, onSteppingStarted: onSteppingStarted)
        }

        statusBanner.updateStatus("Solving quickly…")
        let quickSolution = await Task.detached(priority: .userInitiated) {
            SlidingPuzzleSolver().solveFast(adjustedState, maxSeconds: 3.0, weight: 3, maxExpandedNodes: 350_000)
        }.value

        if let quickSolution {
            publishSolution(quickSolution, prefix: "Puzzle box solved (quick)")

            puzzleOptimizeTask = Task.detached(priority: .utility) { [adjustedState, solveSessionID, onSteppingStarted] in
                var best = quickSolution

                func publishImprovementIfAny(_ candidate: PuzzleBoxSolution, stage: String) async {
                    guard candidate.moves.count < best.moves.count else { return }
                    let prev = best.moves.count
                    best = candidate
                    await MainActor.run {
                        // Drop late improvements if (a) this session has been
                        // superseded by a fresh solve or (b) the user has
                        // already pressed Start — either way, republishing
                        // would wipe the in-progress stepping overlay.
                        guard self.puzzleSolveSessionID == solveSessionID,
                              !self.puzzleSteppingActive else { return }
                        print("[Opt1] Puzzle optimizer improved route (\(stage)): \(prev) -> \(candidate.moves.count) moves")
                        let improvedScreen = SnipCoordinateMapper.scaleSolutionToScreen(
                            candidate,
                            imageSize: sourceImageSize ?? CGSize(width: image.width, height: image.height),
                            windowFrame: windowFrame
                        )
                        self.puzzleBoxOverlay.showReady(solution: improvedScreen, onSteppingStarted: onSteppingStarted)
                    }
                }

                // Stage 1: less-greedy weighted A*.
                if Task.isCancelled { return }
                if let stage1 = SlidingPuzzleSolver().solveFast(
                    adjustedState, maxSeconds: 6.0, weight: 2, maxExpandedNodes: 900_000
                ) {
                    await publishImprovementIfAny(stage1, stage: "weighted-a* w=2")
                }

                // Stage 2: near-optimal A* with stricter evaluation (still bounded).
                if Task.isCancelled { return }
                if let stage2 = SlidingPuzzleSolver().solveFast(
                    adjustedState, maxSeconds: 10.0, weight: 1, maxExpandedNodes: 1_600_000
                ) {
                    await publishImprovementIfAny(stage2, stage: "a* w=1")
                }

                // Stage 3: full deep search (optimal-oriented) as final pass.
                if Task.isCancelled { return }
                if let deep = SlidingPuzzleSolver().solve(adjustedState) {
                    await publishImprovementIfAny(deep, stage: "ida*")
                }

                await MainActor.run {
                    guard self.puzzleSolveSessionID == solveSessionID else { return }
                    print("[Opt1] Puzzle optimizer finished: best=\(best.moves.count) moves")
                }
            }
            return
        }

        statusBanner.updateStatus("Solving (deep search)…")
        let deepSolution = await Task.detached(priority: .userInitiated) {
            SlidingPuzzleSolver().solve(adjustedState)
        }.value
        if let deepSolution {
            publishSolution(deepSolution, prefix: "Puzzle box solved")
            return
        }

        statusBanner.cancel()
        if fromHintRetry {
            state.awaitPuzzleHintCapture(windowFrame: windowFrame)
            presenter.showOverlay(
                message: "Puzzle Box — still couldn't solve",
            detail: "Keep hover on Hint and press \(AppSettings.shared.solveHotkey.displayString) again.",
            mode: .error,
            windowFrame: windowFrame
            )
        } else {
            presenter.showOverlay(
                message: "Puzzle Box — could not solve",
                detail: "Try re-triggering \(AppSettings.shared.solveHotkey.displayString) once the puzzle is fully visible",
                mode: .error,
                windowFrame: windowFrame
            )
        }
    }

    // MARK: - Hint Preview Detection

    private struct HintHoverReferenceCapture {
        let match: PuzzleBoxDetector.ReferenceMatch
        let previewImage: CGImage?
    }

    private func detectHintHoverReference(in image: CGImage, detector: PuzzleBoxDetector) -> HintHoverReferenceCapture? {
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try handler.perform([request]) } catch { return nil }

        guard let observations = request.results, !observations.isEmpty else { return nil }
        var ocrHits: [(text: String, bounds: CGRect, confidence: Float)] = []
        var hintBounds: CGRect?
        var bestConf: Float = -1
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let bb = obs.boundingBox
            let pixelBounds = CGRect(
                x: bb.origin.x * imgW,
                y: (1.0 - bb.origin.y - bb.height) * imgH,
                width: bb.width * imgW,
                height: bb.height * imgH
            )
            ocrHits.append((cand.string, pixelBounds, cand.confidence))
            let lower = cand.string.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard lower.contains("hint") else { continue }
            if cand.confidence > bestConf {
                hintBounds = pixelBounds
                bestConf = cand.confidence
            }
        }

        guard let hb = hintBounds else {
            saveHintDetectionDebug(
                image: image, ocrHits: ocrHits, hintBounds: nil,
                candidateRects: [], chosenRect: nil, chosenMatch: nil,
                note: "No OCR hint text detected"
            )
            return nil
        }

        let imageRect = CGRect(x: 0, y: 0, width: imgW, height: imgH)
        let candidates: [CGRect] = [
            CGRect(
                x: hb.minX - hb.width * 8.0,
                y: hb.minY - hb.height * 18.0,
                width: hb.width * 24.0,
                height: hb.height * 18.0
            ).intersection(imageRect),
            CGRect(
                x: hb.minX - hb.width * 2.0,
                y: hb.minY - hb.height * 20.0,
                width: hb.width * 30.0,
                height: hb.height * 22.0
            ).intersection(imageRect)
        ].filter { $0.width > 120 && $0.height > 120 }

        var best: PuzzleBoxDetector.ReferenceMatch?
        var chosenRect: CGRect?
        var chosenCrop: CGImage?
        for rect in candidates {
            guard let crop = image.cropping(to: rect) else { continue }
            if let match = detector.classifyReference(in: crop) {
                if best == nil || match.distance < best!.distance {
                    best = match
                    chosenRect = rect
                    chosenCrop = crop
                }
            }
        }

        if let final = best, final.distance < 0.80 {
            saveHintDetectionDebug(
                image: image, ocrHits: ocrHits, hintBounds: hb,
                candidateRects: candidates, chosenRect: chosenRect, chosenMatch: final,
                note: "Hint preview classified successfully"
            )
            return HintHoverReferenceCapture(match: final, previewImage: chosenCrop)
        }

        saveHintDetectionDebug(
            image: image, ocrHits: ocrHits, hintBounds: hb,
            candidateRects: candidates, chosenRect: chosenRect, chosenMatch: best,
            note: "Classification failed threshold (best distance too high or no match)"
        )
        if let best {
            print("[Opt1] Hint preview best match \(best.name) dist=\(String(format: "%.3f", best.distance)) (threshold < 0.800)")
        }
        return nil
    }

    // MARK: - Debug Output

    private func saveSnipDebug(
        image: CGImage,
        cropImage: CGImage,
        snipFrame: CGRect,
        windowFrame: CGRect,
        cropRectPx: CGRect,
        cropNormalized: CGRect
    ) {
        guard let debugDir = puzzleDebugDir else { return }
        try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true)
        savePNG(image, to: debugDir.appendingPathComponent("opt2_snip_full.png"))
        savePNG(cropImage, to: debugDir.appendingPathComponent("opt2_snip_crop.png"))
        let note = [
            "opt2 snip debug",
            "windowFrame (SCK): \(windowFrame.integral)",
            "windowFrame (snip overlay): \(snipFrame.integral)",
            "cropInWindowNormalized: \(cropNormalized)",
            "cropRectPx: \(cropRectPx.integral)",
            "imageSize: \(image.width)x\(image.height)"
        ].joined(separator: "\n")
        try? note.write(
            to: debugDir.appendingPathComponent("opt2_snip_debug.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func saveHintDetectionDebug(
        image: CGImage,
        ocrHits: [(text: String, bounds: CGRect, confidence: Float)],
        hintBounds: CGRect?,
        candidateRects: [CGRect],
        chosenRect: CGRect?,
        chosenMatch: PuzzleBoxDetector.ReferenceMatch?,
        note: String
    ) {
        guard let d = puzzleDebugDir else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        savePNG(image, to: d.appendingPathComponent("hint_capture_full.png"))

        let W = image.width, H = image.height
        guard let ctx = CGContext(
            data: nil, width: W, height: H,
            bitsPerComponent: 8, bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))

        for hit in ocrHits {
            let flipped = CGRect(
                x: hit.bounds.minX, y: CGFloat(H) - hit.bounds.maxY,
                width: hit.bounds.width, height: hit.bounds.height
            )
            ctx.setStrokeColor(NSColor(white: 0.7, alpha: 0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(flipped)
        }
        if let hb = hintBounds {
            let flipped = CGRect(x: hb.minX, y: CGFloat(H) - hb.maxY, width: hb.width, height: hb.height)
            ctx.setStrokeColor(NSColor.yellow.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(flipped)
        }
        for rect in candidateRects {
            let flipped = CGRect(x: rect.minX, y: CGFloat(H) - rect.maxY, width: rect.width, height: rect.height)
            ctx.setStrokeColor(NSColor.cyan.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(flipped)
        }
        if let rect = chosenRect {
            let flipped = CGRect(x: rect.minX, y: CGFloat(H) - rect.maxY, width: rect.width, height: rect.height)
            ctx.setStrokeColor(NSColor.green.cgColor)
            ctx.setLineWidth(4)
            ctx.stroke(flipped)
            if let crop = image.cropping(to: rect) {
                savePNG(crop, to: d.appendingPathComponent("hint_capture_chosen_crop.png"))
            }
        }
        if let annotated = ctx.makeImage() {
            savePNG(annotated, to: d.appendingPathComponent("hint_capture_annotated.png"))
        }

        let lines = ocrHits.map {
            "\($0.text) | conf=\(String(format: "%.2f", $0.confidence)) | bounds=\($0.bounds.integral)"
        }
        let summary = [
            "Hint capture debug",
            "note: \(note)",
            "hintBounds: \(hintBounds?.integral.debugDescription ?? "nil")",
            "candidateRects: \(candidateRects.map { $0.integral.debugDescription }.joined(separator: " | "))",
            "chosenRect: \(chosenRect?.integral.debugDescription ?? "nil")",
            "chosenMatch: \(chosenMatch.map { "\($0.name) (\($0.key)) dist=\(String(format: "%.3f", $0.distance))" } ?? "nil")",
            "--- OCR hits ---",
            lines.joined(separator: "\n")
        ].joined(separator: "\n")
        try? summary.write(to: d.appendingPathComponent("hint_capture_debug.txt"), atomically: true, encoding: .utf8)
    }

    private func savePNG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
