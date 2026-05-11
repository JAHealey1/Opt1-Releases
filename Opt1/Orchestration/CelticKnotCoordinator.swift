import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Opt1Detection
import Opt1CelticKnot

// MARK: - CelticKnotCoordinator

/// Owns the Celtic Knot detect/classify/solve flow. The first capture
/// classifies every slot and attempts a conservative single-capture solve
/// before parking the state machine in `.awaitingCelticKnotInvert`. The
/// second capture also classifies every slot, then runs the solver under both
/// possible invert-hypotheses and presents whichever one solves.
///
/// Capture order is no longer significant: the user can press Opt+1 with
/// the puzzle in either its normal or inverted state first, click Invert
/// Paths in-game, and capture again. The hypothesis evaluation in
/// `handleSecondPass` figures out which capture was which.
@MainActor
final class CelticKnotCoordinator {

    // MARK: - Dependencies

    private let captureManager: any CaptureManaging
    private let statusBanner: any StatusBannerShowing
    private let presenter: any OverlayPresenting
    private let captureErrorPresenter: any CaptureErrorPresenting
    private let state: SolveFlowState

    // MARK: - Init

    init(
        captureManager: any CaptureManaging,
        statusBanner: any StatusBannerShowing,
        presenter: any OverlayPresenting,
        captureErrorPresenter: any CaptureErrorPresenting,
        state: SolveFlowState
    ) {
        self.captureManager = captureManager
        self.statusBanner = statusBanner
        self.presenter = presenter
        self.captureErrorPresenter = captureErrorPresenter
        self.state = state
    }

    // MARK: - Public Entry Points

    /// First pass — called by the orchestrator when the clue pipeline detects
    /// a celtic knot. Classifies every slot, tries a single-capture partial
    /// solve, and only prompts for Invert Paths when the partial solve is not
    /// unique enough to trust.
    func handleFirstPass(
        image: CGImage,
        detector: CelticKnotDetector,
        detectionResult: CelticKnotDetectionResult,
        windowFrame: CGRect
    ) async {
        let layout = detectionResult.layout

        statusBanner.updateStatus("Loading rune classifier…")
        guard let artifact = CelticKnotRuneModelArtifact.loadFromBundle() else {
            statusBanner.cancel()
            print("[CelticKnot] No trained model found — showing detection confirmation")
            presenter.showOverlay(
                message: "Celtic Knot detected (\(detectionResult.layoutType))",
                detail: "Train rune model to enable solving. Run data collection first.",
                mode: .phase1Confirmation,
                windowFrame: windowFrame
            )
            return
        }

        logModel(artifact: artifact)
        let trackNames = Self.trackNames(for: detectionResult.layoutType, layout: layout)

        statusBanner.updateStatus("Classifying runes (1/2)…")
        // Yield once so the banner repaints with the new message before the
        // CPU-bound classifier kicks off. Without this the SwiftUI runloop
        // never gets a tick between updateStatus and the synchronous KNN
        // search, so the user only ever sees the previous status text.
        await Task.yield()
        let puzzleBounds = detectionResult.puzzleBounds
        let (labels, details) = await Task.detached(priority: .userInitiated) {
            detector.classifyAllRunes(
                in: image,
                puzzleBounds: puzzleBounds,
                layout: layout,
                artifact: artifact,
                intersectionMode: .classifyAll,
                runeArea: detectionResult.runeArea
            )
        }.value

        print("[CelticKnot] Pass 1 — classified all slots (intersections included)")
        logClassification(labels: labels, details: details, trackNames: trackNames)

        var trainingDir: URL? = nil
        if AppSettings.isDeveloperEnabled {
            statusBanner.updateStatus("Saving training crops…")
            await Task.yield()
            let puzzleDir = Self.makeFreshPuzzleTrainingDir()
            let layoutType = detectionResult.layoutType
            await Task.detached(priority: .userInitiated) {
                Self.saveCaptureCropsForTraining(
                    image: image,
                    detector: detector,
                    puzzleBounds: puzzleBounds,
                    runeArea: detectionResult.runeArea,
                    layout: layout,
                    layoutType: layoutType,
                    puzzleDir: puzzleDir,
                    captureName: "capture_1"
                )
            }.value
            trainingDir = puzzleDir
        }

        let capture = CelticKnotCapture(
            layout: layout,
            labels: labels,
            details: details,
            puzzleBoundsInImage: detectionResult.puzzleBounds,
            runeAreaInImage: detectionResult.runeArea,
            trainingDirectory: trainingDir
        )

        if let singleCaptureOutcome = trySingleCaptureSolve(
            detector: detector,
            capture: capture,
            detectionResult: detectionResult
        ) {
            print("[CelticKnot] First pass produced a unique partial solution — skipping Invert Paths.")
            presentSolveResult(
                outcome: singleCaptureOutcome,
                loserOutcome: singleCaptureOutcome,
                detectionResult: detectionResult,
                image: image,
                windowFrame: windowFrame
            )
            return
        }

        print("[CelticKnot] First pass complete — awaiting Invert Paths and second capture (capture order doesn't matter).")
        statusBanner.cancel()
        state.awaitCelticKnotInvert(firstCapture: capture, windowFrame: windowFrame)
        presenter.showOverlay(
            message: "Invert Paths needed",
            detail: "Click Invert Paths in-game, then press \(AppSettings.shared.solveHotkey.displayString) again",
            mode: .celticKnotNeedsInvert,
            windowFrame: windowFrame
        )
    }

    private func trySingleCaptureSolve(
        detector: CelticKnotDetector,
        capture: CelticKnotCapture,
        detectionResult: CelticKnotDetectionResult
    ) -> HypothesisOutcome? {
        let partial = buildSingleCaptureKnotState(
            capture: capture,
            detectionResult: detectionResult
        )
        let result = detector.solvePartialFirstCapture(partial.state)
        switch result {
        case .solved:
            return HypothesisOutcome(
                hypothesis: .h1,
                knotState: partial.state,
                solveResult: result,
                usedFireBloodAmbiguity: false,
                aggregateConfidence: partial.aggregateConfidence,
                captureMapping: (capture1: "single-capture", capture2: "not-used")
            )
        case .ambiguous(let count):
            print("[CelticKnot] First-pass partial solve ambiguous (\(count) candidates) — requesting Invert Paths.")
            return nil
        case .noSolution:
            print("[CelticKnot] First-pass partial solve insufficient — requesting Invert Paths.")
            return nil
        }
    }

    private func buildSingleCaptureKnotState(
        capture: CelticKnotCapture,
        detectionResult: CelticKnotDetectionResult
    ) -> (state: CelticKnotState, aggregateConfidence: Float) {
        let layout = capture.layout
        let trackCount = layout.tracks.count
        var partialLabels = [[String?]](repeating: [], count: trackCount)
        var partialDetails = [[CelticKnotDetector.SlotClassification]](repeating: [], count: trackCount)
        var aggregateConfidence: Float = 0
        let hiddenDetail = CelticKnotDetector.SlotClassification(
            label: nil,
            confidence: nil,
            margin: nil,
            reason: .noCrop
        )

        for trackIndex in 0..<trackCount {
            let trackSlots = layout.tracks[trackIndex]
            var trackLabels: [String?] = []
            var trackDetails: [CelticKnotDetector.SlotClassification] = []
            trackLabels.reserveCapacity(trackSlots.count)
            trackDetails.reserveCapacity(trackSlots.count)

            for slotIndex in 0..<trackSlots.count {
                let slot = trackSlots[slotIndex]
                let label = (trackIndex < capture.labels.count && slotIndex < capture.labels[trackIndex].count)
                    ? capture.labels[trackIndex][slotIndex]
                    : nil
                let detail = (trackIndex < capture.details.count && slotIndex < capture.details[trackIndex].count)
                    ? capture.details[trackIndex][slotIndex]
                    : hiddenDetail

                if slot.intersectionPartner != nil, !slot.isOnTop {
                    // The covered side of an intersection is deliberately unknown
                    // until the user inverts paths. Partial solving may still be
                    // constrained by known non-intersection runes rotating into
                    // those crossing positions.
                    trackLabels.append(nil)
                    trackDetails.append(hiddenDetail)
                } else {
                    trackLabels.append(label)
                    trackDetails.append(detail)
                    if label != nil, let confidence = detail.confidence {
                        aggregateConfidence += confidence
                    }
                }
            }

            partialLabels[trackIndex] = trackLabels
            partialDetails[trackIndex] = trackDetails
        }

        let state = CelticKnotState(
            layout: layout,
            runeLabels: partialLabels,
            classDetails: partialDetails,
            puzzleBoundsInImage: detectionResult.puzzleBounds,
            runeAreaInImage: detectionResult.runeArea,
            isInverted: false
        )
        return (state, aggregateConfidence)
    }

    /// Second pass — classifies every slot in the new capture, builds both
    /// invert-hypotheses against the parked first-pass capture, and runs the
    /// solver under each. Whichever hypothesis solves is presented to the
    /// user; if both solve the cheaper one wins; if neither solves the
    /// better-fit hypothesis's diagnostics are shown.
    func handleSecondPass(
        image: CGImage,
        detector: CelticKnotDetector,
        firstCapture: CelticKnotCapture,
        windowFrame: CGRect
    ) async {
        let layout = firstCapture.layout
        let layoutType = layout.type
        let puzzleBounds = firstCapture.puzzleBoundsInImage
        let runeArea = firstCapture.runeAreaInImage

        statusBanner.updateStatus("Loading rune classifier…")
        guard let artifact = CelticKnotRuneModelArtifact.loadFromBundle() else {
            statusBanner.cancel()
            print("[CelticKnot] No trained model on second pass — bailing out")
            presenter.showOverlay(
                message: "Celtic Knot — model missing",
                detail: "Rune classifier artifact not loaded.",
                mode: .error,
                windowFrame: windowFrame
            )
            return
        }

        let trackNames = Self.trackNames(for: layoutType, layout: layout)

        statusBanner.updateStatus("Classifying runes (2/2)…")
        await Task.yield()
        let (labelsB, detailsB) = await Task.detached(priority: .userInitiated) {
            detector.classifyAllRunes(
                in: image,
                puzzleBounds: puzzleBounds,
                layout: layout,
                artifact: artifact,
                intersectionMode: .classifyAll,
                runeArea: runeArea
            )
        }.value

        print("[CelticKnot] Pass 2 — classified all slots (intersections included)")
        logClassification(labels: labelsB, details: detailsB, trackNames: trackNames)

        if AppSettings.isDeveloperEnabled, let puzzleDir = firstCapture.trainingDirectory {
            statusBanner.updateStatus("Saving training crops…")
            await Task.yield()
            await Task.detached(priority: .userInitiated) {
                Self.saveCaptureCropsForTraining(
                    image: image,
                    detector: detector,
                    puzzleBounds: puzzleBounds,
                    runeArea: runeArea,
                    layout: layout,
                    layoutType: layoutType,
                    puzzleDir: puzzleDir,
                    captureName: "capture_2"
                )
            }.value
        }

        let captureB = CelticKnotCapture(
            layout: layout,
            labels: labelsB,
            details: detailsB,
            puzzleBoundsInImage: puzzleBounds,
            runeAreaInImage: runeArea,
            trainingDirectory: firstCapture.trainingDirectory
        )

        let detectionResult = CelticKnotDetectionResult(
            puzzleBounds: puzzleBounds,
            runeArea: runeArea,
            layoutType: layoutType,
            layout: layout,
            gridAnalysis: nil
        )
        statusBanner.updateStatus("Solving (trying both invert states)…")
        await Task.yield()
        evaluateHypothesesAndPresent(
            detector: detector,
            captureA: firstCapture,
            captureB: captureB,
            detectionResult: detectionResult,
            image: image,
            windowFrame: windowFrame
        )
    }

    /// Called when the state machine is `.awaitingCelticKnotInvert` and the
    /// user presses Opt+1 again. Recaptures the RuneScape window and routes
    /// straight into pass 2 with the parked first-pass capture as context.
    func resumeInvert(firstCapture: CelticKnotCapture, windowFrame: CGRect) async {
        state.beginRunning()
        defer { state.finishIfRunning() }
        statusBanner.showStatus("Capturing inverted state…", near: windowFrame)
        do {
            guard let rsWindow = try await WindowFinder.findRuneScapeWindow() else {
                statusBanner.cancel()
                captureErrorPresenter.showWindowNotFound()
                return
            }
            let image = try await captureManager.captureWindow(rsWindow)
            let detector = CelticKnotDetector()
            print("[CelticKnot] Invert re-scan — reusing bounds from first pass: \(firstCapture.puzzleBoundsInImage)")
            await handleSecondPass(
                image: image,
                detector: detector,
                firstCapture: firstCapture,
                windowFrame: rsWindow.frame
            )
        } catch {
            statusBanner.cancel()
            print("[CelticKnot] Invert capture error: \(error)")
            presenter.showOverlay(
                message: "Celtic Knot — capture failed",
                detail: error.localizedDescription,
                mode: .error,
                windowFrame: windowFrame
            )
            state.awaitCelticKnotInvert(firstCapture: firstCapture, windowFrame: windowFrame)
        }
    }

    // MARK: - Hypothesis Evaluation

    /// Identifies which of the two captures was inverted by trying both
    /// hypotheses against the solver. The two hypotheses are:
    ///
    /// - **H1**: A = normal, B = inverted
    /// - **H2**: A = inverted, B = normal
    ///
    /// where A is the first capture and B is the second. For each
    /// intersection slot the visible rune comes from whichever capture sees
    /// that slot un-occluded under the hypothesis (driven by `slot.isOnTop`).
    /// Non-intersection slots are picked by classifier confidence — they're
    /// always visible so both captures should agree, but if they don't we
    /// trust the more confident one.
    private enum Hypothesis: String {
        case h1 = "H1"  // capture-1 = normal, capture-2 = inverted
        case h2 = "H2"  // capture-1 = inverted, capture-2 = normal
    }

    private struct HypothesisOutcome {
        let hypothesis: Hypothesis
        let knotState: CelticKnotState
        let solveResult: CelticKnotSolveResult
        let usedFireBloodAmbiguity: Bool
        let aggregateConfidence: Float
        let captureMapping: (capture1: String, capture2: String)
    }

    private func evaluateHypothesesAndPresent(
        detector: CelticKnotDetector,
        captureA: CelticKnotCapture,
        captureB: CelticKnotCapture,
        detectionResult: CelticKnotDetectionResult,
        image: CGImage,
        windowFrame: CGRect
    ) {
        print("[CelticKnot] Evaluating two invert-hypotheses")

        let h1 = runHypothesis(
            .h1,
            detector: detector,
            captureA: captureA,
            captureB: captureB,
            detectionResult: detectionResult
        )
        let h2 = runHypothesis(
            .h2,
            detector: detector,
            captureA: captureA,
            captureB: captureB,
            detectionResult: detectionResult
        )

        Self.logOutcomeSummary(h1)
        Self.logOutcomeSummary(h2)

        let (winner, loser, reason) = Self.pickWinner(h1, h2)
        print("[CelticKnot] Picked \(winner.hypothesis.rawValue) (\(reason))")
        print("[CelticKnot]   capture_1 → \(winner.captureMapping.capture1)")
        print("[CelticKnot]   capture_2 → \(winner.captureMapping.capture2)")

        if AppSettings.isDeveloperEnabled, let trainingDir = captureA.trainingDirectory {
            writeHypothesisMeta(
                puzzleDir: trainingDir,
                winner: winner,
                loser: loser
            )
        }

        presentSolveResult(
            outcome: winner,
            loserOutcome: loser,
            detectionResult: detectionResult,
            image: image,
            windowFrame: windowFrame
        )
    }

    private func runHypothesis(
        _ hypothesis: Hypothesis,
        detector: CelticKnotDetector,
        captureA: CelticKnotCapture,
        captureB: CelticKnotCapture,
        detectionResult: CelticKnotDetectionResult
    ) -> HypothesisOutcome {
        let layout = captureA.layout
        let trackCount = layout.tracks.count

        // For H1: A is normal, B is inverted.
        // For H2: A is inverted, B is normal.
        // For an `isOnTop` slot the rune is visible whenever the puzzle is in
        // its normal (un-inverted) state, so we pick from whichever capture
        // is the "normal" one under this hypothesis. For an `isOnTop=false`
        // slot it's the other way around.
        let aIsNormal = hypothesis == .h1

        func slotKey(track: Int, slot: Int) -> String {
            "\(track):\(slot)"
        }

        func actualSlot(track: Int, slot: Int, rotation: Int) -> Int {
            let size = layout.tracks[track].count
            return ((slot - rotation) % size + size) % size
        }

        func buildKnotState(flippedIntersectionSlots: Set<String> = []) -> (state: CelticKnotState, aggregateConfidence: Float) {
            var mergedLabels = [[String?]](
                repeating: [], count: trackCount
            )
            var mergedDetails = [[CelticKnotDetector.SlotClassification]](
                repeating: [], count: trackCount
            )
            var aggregateConfidence: Float = 0

            for t in 0..<trackCount {
                let trackSlots = layout.tracks[t]
                var trackLabels: [String?] = []
                var trackDetails: [CelticKnotDetector.SlotClassification] = []
                trackLabels.reserveCapacity(trackSlots.count)
                trackDetails.reserveCapacity(trackSlots.count)

                for s in 0..<trackSlots.count {
                    let slot = trackSlots[s]
                    let aLabel = (t < captureA.labels.count && s < captureA.labels[t].count)
                        ? captureA.labels[t][s] : nil
                    let bLabel = (t < captureB.labels.count && s < captureB.labels[t].count)
                        ? captureB.labels[t][s] : nil
                    let aDetail = (t < captureA.details.count && s < captureA.details[t].count)
                        ? captureA.details[t][s]
                        : CelticKnotDetector.SlotClassification(label: nil, confidence: nil, margin: nil, reason: .noCrop)
                    let bDetail = (t < captureB.details.count && s < captureB.details[t].count)
                        ? captureB.details[t][s]
                        : CelticKnotDetector.SlotClassification(label: nil, confidence: nil, margin: nil, reason: .noCrop)

                    let pickedLabel: String?
                    let pickedDetail: CelticKnotDetector.SlotClassification

                    if slot.intersectionPartner != nil {
                        // `isOnTop` comes from a single over/under colour sample and can occasionally
                        // be wrong. Near-solution repair below can flip selected slots to the other
                        // capture without changing the graph-derived intersection topology.
                        var pickFromA = slot.isOnTop ? aIsNormal : !aIsNormal
                        if flippedIntersectionSlots.contains(slotKey(track: t, slot: s)) {
                            pickFromA.toggle()
                        }

                        if pickFromA {
                            pickedLabel = aLabel
                            pickedDetail = aDetail
                        } else {
                            pickedLabel = bLabel
                            pickedDetail = bDetail
                        }
                    } else {
                        // Non-intersection: prefer the higher-confidence call, fall back to whatever's non-nil.
                        let aConf = aDetail.confidence ?? -1
                        let bConf = bDetail.confidence ?? -1
                        if aLabel != nil && bLabel != nil {
                            if aConf >= bConf {
                                pickedLabel = aLabel
                                pickedDetail = aDetail
                            } else {
                                pickedLabel = bLabel
                                pickedDetail = bDetail
                            }
                        } else if aLabel != nil {
                            pickedLabel = aLabel
                            pickedDetail = aDetail
                        } else {
                            pickedLabel = bLabel
                            pickedDetail = bDetail
                        }
                    }

                    trackLabels.append(pickedLabel)
                    trackDetails.append(pickedDetail)
                    if pickedLabel != nil, let conf = pickedDetail.confidence {
                        aggregateConfidence += conf
                    }
                }
                mergedLabels[t] = trackLabels
                mergedDetails[t] = trackDetails
            }

            return (
                CelticKnotState(
                    layout: layout,
                    runeLabels: mergedLabels,
                    classDetails: mergedDetails,
                    puzzleBoundsInImage: detectionResult.puzzleBounds,
                    runeAreaInImage: detectionResult.runeArea,
                    isInverted: false  // labels already merged into "normal-state" view
                ),
                aggregateConfidence
            )
        }

        func solve(_ knotState: CelticKnotState, repairNote: String? = nil) -> (result: CelticKnotSolveResult, usedFireBloodAmbiguity: Bool) {
            var result = detector.solve(knotState)
            var usedFireBloodAmbiguity = false
            if case .noSolution = result {
                let fallback = detector.solveAllowingFireBloodAmbiguity(knotState)
                if case .solved = fallback {
                    let suffix = repairNote.map { " after \($0)" } ?? ""
                    print("[CelticKnot] \(hypothesis.rawValue): solved with fire/blood ambiguity fallback\(suffix)")
                    result = fallback
                    usedFireBloodAmbiguity = true
                }
            }
            return (result, usedFireBloodAmbiguity)
        }

        func sourceRepairSets(from diagnostics: CelticKnotSolveDiagnostics) -> [Set<String>] {
            let maxMissingIntersections = 3
            guard diagnostics.satisfiedIntersections >= diagnostics.totalIntersections - maxMissingIntersections else {
                return []
            }

            var candidates: [String] = []
            var seen = Set<String>()
            for failing in diagnostics.failingIntersections {
                let slotA = actualSlot(
                    track: failing.trackA,
                    slot: failing.slotA,
                    rotation: diagnostics.bestRotations[failing.trackA]
                )
                let keyA = slotKey(track: failing.trackA, slot: slotA)
                if seen.insert(keyA).inserted {
                    candidates.append(keyA)
                }

                let slotB = actualSlot(
                    track: failing.trackB,
                    slot: failing.slotB,
                    rotation: diagnostics.bestRotations[failing.trackB]
                )
                let keyB = slotKey(track: failing.trackB, slot: slotB)
                if seen.insert(keyB).inserted {
                    candidates.append(keyB)
                }
            }

            let maxCandidates = 8
            let limited = Array(candidates.prefix(maxCandidates))
            guard !limited.isEmpty else { return [] }

            var repairs: [Set<String>] = limited.map { [$0] }
            if diagnostics.failingIntersections.count >= 2 {
                for i in limited.indices {
                    for j in limited.indices where j > i {
                        repairs.append([limited[i], limited[j]])
                    }
                }
            }
            if diagnostics.failingIntersections.count >= 3 {
                for i in limited.indices {
                    for j in limited.indices where j > i {
                        for k in limited.indices where k > j {
                            repairs.append([limited[i], limited[j], limited[k]])
                        }
                    }
                }
            }

            return repairs
        }

        let initialMerge = buildKnotState()
        var knotState = initialMerge.state
        var aggregateConfidence = initialMerge.aggregateConfidence
        var solved = solve(knotState)
        var result = solved.result
        var usedFireBloodAmbiguity = solved.usedFireBloodAmbiguity

        if case .noSolution = result {
            if case .noSolution(let diagnostics?) = result {
                for repairSet in sourceRepairSets(from: diagnostics) {
                    let repairDescription = repairSet.sorted().joined(separator: ",")
                    let repairedMerge = buildKnotState(flippedIntersectionSlots: repairSet)
                    let repairedSolve = solve(repairedMerge.state, repairNote: "flipping \(repairDescription)")
                    if case .solved = repairedSolve.result {
                        print("[CelticKnot] \(hypothesis.rawValue): solved by flipping intersection capture source for slot(s) \(repairDescription)")
                        knotState = repairedMerge.state
                        aggregateConfidence = repairedMerge.aggregateConfidence
                        result = repairedSolve.result
                        usedFireBloodAmbiguity = repairedSolve.usedFireBloodAmbiguity
                        break
                    }
                }
            }
        }

        return HypothesisOutcome(
            hypothesis: hypothesis,
            knotState: knotState,
            solveResult: result,
            usedFireBloodAmbiguity: usedFireBloodAmbiguity,
            aggregateConfidence: aggregateConfidence,
            captureMapping: hypothesis == .h1
                ? (capture1: "normal", capture2: "inverted")
                : (capture1: "inverted", capture2: "normal")
        )
    }

    private static func pickWinner(
        _ h1: HypothesisOutcome,
        _ h2: HypothesisOutcome
    ) -> (winner: HypothesisOutcome, loser: HypothesisOutcome, reason: String) {
        let h1Solved = Self.totalClicks(h1.solveResult)
        let h2Solved = Self.totalClicks(h2.solveResult)

        switch (h1Solved, h2Solved) {
        case (.some(let c1), .some(let c2)):
            if h1.usedFireBloodAmbiguity != h2.usedFireBloodAmbiguity {
                return h1.usedFireBloodAmbiguity
                    ? (h2, h1, "both solved; H2 was strict and H1 used fire/blood fallback")
                    : (h1, h2, "both solved; H1 was strict and H2 used fire/blood fallback")
            }
            if c1 != c2 {
                return c1 < c2
                    ? (h1, h2, "both solved; H1 has fewer clicks (\(c1) vs \(c2))")
                    : (h2, h1, "both solved; H2 has fewer clicks (\(c2) vs \(c1))")
            }
            // Same click count: tie-break on aggregate classifier confidence.
            return h1.aggregateConfidence >= h2.aggregateConfidence
                ? (h1, h2, "both solved with \(c1) clicks; H1 has higher classifier confidence")
                : (h2, h1, "both solved with \(c2) clicks; H2 has higher classifier confidence")
        case (.some, .none):
            return (h1, h2, "only H1 solved")
        case (.none, .some):
            return (h2, h1, "only H2 solved")
        case (.none, .none):
            // Neither solved — pick whichever satisfied more intersections.
            let h1Sat = Self.satisfiedIntersections(h1.solveResult) ?? -1
            let h2Sat = Self.satisfiedIntersections(h2.solveResult) ?? -1
            if h1Sat == h2Sat {
                // Final tiebreak: aggregate confidence.
                return h1.aggregateConfidence >= h2.aggregateConfidence
                    ? (h1, h2, "neither solved; equal intersection fit, H1 has higher confidence")
                    : (h2, h1, "neither solved; equal intersection fit, H2 has higher confidence")
            }
            return h1Sat >= h2Sat
                ? (h1, h2, "neither solved; H1 fits more intersections (\(h1Sat) vs \(h2Sat))")
                : (h2, h1, "neither solved; H2 fits more intersections (\(h2Sat) vs \(h1Sat))")
        }
    }

    private static func totalClicks(_ result: CelticKnotSolveResult) -> Int? {
        if case .solved(let solution) = result {
            return solution.totalClicks
        }
        return nil
    }

    private static func satisfiedIntersections(_ result: CelticKnotSolveResult) -> Int? {
        if case .noSolution(let diag) = result, let diag {
            return diag.satisfiedIntersections
        }
        return nil
    }

    private static func logOutcomeSummary(_ outcome: HypothesisOutcome) {
        let h = outcome.hypothesis.rawValue
        let map = outcome.captureMapping
        let mapStr = "(capture_1=\(map.capture1), capture_2=\(map.capture2))"
        let mode = outcome.usedFireBloodAmbiguity ? " fire/blood-fallback" : ""
        switch outcome.solveResult {
        case .solved(let solution):
            print("[CelticKnot] \(h) \(mapStr): solved\(mode) — rotations=\(solution.rotations) clicks=\(solution.totalClicks) conf=\(String(format: "%.2f", outcome.aggregateConfidence))")
        case .ambiguous(let count):
            print("[CelticKnot] \(h) \(mapStr): ambiguous\(mode) — \(count) candidates conf=\(String(format: "%.2f", outcome.aggregateConfidence))")
        case .noSolution(let diag):
            if let diag {
                print("[CelticKnot] \(h) \(mapStr): no-solution\(mode) — \(diag.satisfiedIntersections)/\(diag.totalIntersections) intersections satisfied conf=\(String(format: "%.2f", outcome.aggregateConfidence))")
            } else {
                print("[CelticKnot] \(h) \(mapStr): no-solution\(mode) — no diagnostics conf=\(String(format: "%.2f", outcome.aggregateConfidence))")
            }
        }
    }

    // MARK: - Solve Result Presentation

    private func presentSolveResult(
        outcome: HypothesisOutcome,
        loserOutcome: HypothesisOutcome,
        detectionResult: CelticKnotDetectionResult,
        image: CGImage,
        windowFrame: CGRect
    ) {
        statusBanner.cancel()
        switch outcome.solveResult {
        case .solved(var solution):
            let arrowPositions = CelticKnotArrowPositions.screenPositions(
                for: detectionResult.layoutType,
                puzzleBoundsInImage: detectionResult.puzzleBounds,
                imageSize: CGSize(width: image.width, height: image.height),
                windowFrame: windowFrame
            )
            let scaleX = windowFrame.width / CGFloat(image.width)
            let scaleY = windowFrame.height / CGFloat(image.height)
            let puzzleOnScreen = CGRect(
                x: windowFrame.minX + detectionResult.puzzleBounds.minX * scaleX,
                y: windowFrame.minY + detectionResult.puzzleBounds.minY * scaleY,
                width: detectionResult.puzzleBounds.width * scaleX,
                height: detectionResult.puzzleBounds.height * scaleY
            )
            solution = CelticKnotSolution(
                rotations: solution.rotations,
                clockwiseRotationSigns: outcome.knotState.layout.clockwiseRotationSigns,
                arrowScreenPositions: arrowPositions,
                puzzleBoundsOnScreen: puzzleOnScreen
            )
            print("[CelticKnot] Solved: \(solution.rotations) (\(solution.totalClicks) clicks)")
            presenter.showCelticKnotOverlay(solution: solution, windowFrame: windowFrame)
        case .ambiguous(let count):
            print("[CelticKnot] Still ambiguous after invert — \(count) candidates")
            presenter.showOverlay(
                message: "Celtic Knot — \(count) solutions found",
                detail: "Could not narrow to unique solution. Rune classification may be incorrect.",
                mode: .error,
                windowFrame: windowFrame
            )
        case .noSolution(let diagnostics):
            // Pick the better-fit hypothesis's diagnostics for the user-facing
            // message — `outcome` is already that one by construction in
            // `pickWinner`, so prefer it. Fall back to the loser's diagnostics
            // if for some reason the winner has none.
            let trackNames = Self.trackNames(for: detectionResult.layoutType, layout: outcome.knotState.layout)
            let chosenDiag = diagnostics ?? Self.diagnostics(of: loserOutcome.solveResult)
            let chosenState = diagnostics != nil ? outcome.knotState : loserOutcome.knotState
            let detail = Self.noSolutionDetail(
                diagnostics: chosenDiag,
                classDetails: chosenState.classDetails,
                trackNames: trackNames
            )
            presenter.showOverlay(
                message: "Celtic Knot — no solution found",
                detail: detail,
                mode: .error,
                windowFrame: windowFrame
            )
        }
    }

    private static func diagnostics(of result: CelticKnotSolveResult) -> CelticKnotSolveDiagnostics? {
        if case .noSolution(let diag) = result { return diag }
        return nil
    }

    /// Build the user-facing "try rotating X" hint from the solver's
    /// near-miss diagnostics. Strategy:
    /// 1. From the best near-miss rotation combo, take every track that
    ///    appears in any failing intersection — those are our suspects.
    /// 2. If we have per-slot classification confidence/margin, prefer the
    ///    suspect tracks whose involved slots had the weakest classifications
    ///    (lowest min margin); this disambiguates between two suspect tracks
    ///    when only one of them has a dubious slot.
    /// 3. Fall back to the generic message if diagnostics are missing or no
    ///    failing intersections were recorded (e.g. layout had no
    ///    intersections at all).
    private static func noSolutionDetail(
        diagnostics: CelticKnotSolveDiagnostics?,
        classDetails: [[CelticKnotDetector.SlotClassification]],
        trackNames: [String]
    ) -> String {
        guard let diag = diagnostics, !diag.failingIntersections.isEmpty else {
            return "Rune classification may be incorrect. Try again."
        }

        // Per-track minimum classification margin across the slots that
        // participate in failing intersections — lower means more dubious.
        // Slots with no margin recorded (hidden, or model returned nil)
        // contribute nothing here, so a track only "wins" the dubiousness
        // ranking if it has a measurably weak classification.
        var minMarginByTrack: [Int: Float] = [:]
        for f in diag.failingIntersections {
            for (track, slot) in [(f.trackA, f.slotA), (f.trackB, f.slotB)] {
                guard track < classDetails.count, slot < classDetails[track].count else { continue }
                guard let m = classDetails[track][slot].margin else { continue }
                let prev = minMarginByTrack[track] ?? .greatestFiniteMagnitude
                if m < prev { minMarginByTrack[track] = m }
            }
        }

        let suspects = diag.suspectTrackIndices.sorted()
        let names = suspects.map { idx -> String in
            let raw = idx < trackNames.count ? trackNames[idx] : "Track \(idx)"
            return raw.components(separatedBy: " (").first ?? raw
        }

        let trackPhrase: String
        switch names.count {
        case 0:
            return "Rune classification may be incorrect. Try again."
        case 1:
            trackPhrase = "the \(names[0]) track"
        case 2:
            trackPhrase = "the \(names[0]) or \(names[1]) track"
        default:
            if let weakest = minMarginByTrack.min(by: { $0.value < $1.value })?.key,
               weakest < trackNames.count {
                let weakestName = (trackNames[weakest].components(separatedBy: " (").first ?? trackNames[weakest])
                trackPhrase = "the \(weakestName) track (most likely) or any of the others"
            } else {
                let head = names.dropLast().joined(separator: ", ")
                trackPhrase = "any of the \(head) or \(names.last!) tracks"
            }
        }

        return "Try rotating \(trackPhrase) in-game and capture again. (\(diag.satisfiedIntersections)/\(diag.totalIntersections) intersections matched)"
    }

    // MARK: - Classification Logging

    private static func trackNames(for layoutType: CelticKnotLayoutType, layout: CelticKnotLayout) -> [String] {
        switch layoutType {
        case .sixSpot, .eightSpot:
            return ["Gold (left arrows)", "Dark (right arrows)", "Blue (bottom arrows)"]
        case .eightSpotLinked:
            return ["Gold (left arrows)", "Dark (top arrows)", "Blue (bottom arrows)", "Grey (right arrows)"]
        case .eightSpotWrap:
            return ["Gold", "Dark", "Blue"]
        case .eightSpotL, .tenSpot, .tenSpotLinked, .twelveSpot, .fourteenSpot:
            return ["Gold", "Dark", "Blue"]
        }
    }

    private func logModel(artifact: CelticKnotRuneModelArtifact) {
        let modelType = artifact.isKNN
            ? "knn (k=\(artifact.k ?? 0), refs=\(artifact.referenceEmbeddings?.count ?? 0))"
            : "centroid (classes=\(artifact.centroids?.count ?? 0))"
        print("[CelticKnot] Loaded model: type=\(modelType) acc=\(String(format: "%.2f%%", artifact.top1Accuracy * 100)) recConf=\(artifact.recommendedMinConfidence.map { String(format: "%.3f", $0) } ?? "nil") recMargin=\(artifact.recommendedMinMargin.map { String(format: "%.3f", $0) } ?? "nil")")
    }

    private func logClassification(
        labels: [[String?]],
        details: [[CelticKnotDetector.SlotClassification]],
        trackNames: [String]
    ) {
        for (t, track) in labels.enumerated() {
            let name = t < trackNames.count ? trackNames[t] : "Track \(t)"
            let filled = track.compactMap { $0 }.count
            let nils = track.filter { $0 == nil }.count
            let slotStrings: [String] = track.enumerated().map { s, label in
                let detail = details[t][s]
                if let lbl = label {
                    let conf = detail.confidence.map { String(format: "%.2f", $0) } ?? "?"
                    return "[\(s)]=\(lbl)(\(conf))"
                } else if let reason = detail.reason {
                    let bestGuess = detail.label.map { " best=\($0)" } ?? ""
                    let conf = detail.confidence.map { String(format: " c=%.2f", $0) } ?? ""
                    let margin = detail.margin.map { String(format: " m=%.3f", $0) } ?? ""
                    return "[\(s)]=nil(\(reason.rawValue)\(bestGuess)\(conf)\(margin))"
                } else {
                    return "[\(s)]=nil"
                }
            }
            print("[CelticKnot] \(name): \(filled) classified, \(nils) nil")
            print("[CelticKnot]   \(slotStrings.joined(separator: " "))")
        }
    }

    // MARK: - Training Data

    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    /// Build a fresh `puzzle_<ts>` directory to hold both captures' crops.
    /// Called from `handleFirstPass` so the second pass can deposit into the
    /// same directory via `firstCapture.trainingDirectory`.
    private static func makeFreshPuzzleTrainingDir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Opt1/CelticKnotData", isDirectory: true)
        let ts = iso8601.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return base.appendingPathComponent("puzzle_\(ts)", isDirectory: true)
    }

    /// Save the rune crops for one capture under `<puzzleDir>/<captureName>/`.
    /// The directory layout records which capture was first vs second; the
    /// actual normal/inverted assignment is recorded later in `meta.json`
    /// after hypothesis selection.
    /// Static so it can run in a detached `Task` (off the main actor) without
    /// capturing `self`. The classify/save passes are CPU- and I/O-heavy and
    /// would otherwise stall the SwiftUI runloop, freezing the status banner
    /// on whichever message it last received.
    nonisolated static func saveCaptureCropsForTraining(
        image: CGImage,
        detector: CelticKnotDetector,
        puzzleBounds: CGRect,
        runeArea: CGRect,
        layout: CelticKnotLayout,
        layoutType: CelticKnotLayoutType,
        puzzleDir: URL,
        captureName: String
    ) {
        let fm = FileManager.default
        let captureDir = puzzleDir.appendingPathComponent(captureName, isDirectory: true)
        do {
            try fm.createDirectory(at: captureDir, withIntermediateDirectories: true)
        } catch {
            print("[CelticKnot] Failed to create training data dir: \(error)")
            return
        }

        let crops = detector.extractRuneCrops(
            from: image,
            puzzleBounds: puzzleBounds,
            layout: layout,
            runeArea: runeArea
        )
        for (trackIdx, slotIdx, _, crop) in crops {
            let name = "rune_t\(trackIdx)_s\(String(format: "%02d", slotIdx)).png"
            savePNG(crop, to: captureDir.appendingPathComponent(name))
        }

        if let overlay = detector.drawTemplateOverlay(on: image, puzzleBounds: puzzleBounds, layout: layout) {
            savePNG(overlay, to: captureDir.appendingPathComponent("debug_overlay.png"))
        }
        if let puzzleCrop = image.cropping(to: puzzleBounds) {
            savePNG(puzzleCrop, to: captureDir.appendingPathComponent("puzzle_crop.png"))
        }

        let meta: [String: Any] = [
            "layout_type": layoutType.rawValue,
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "source": "detection",
            "rune_count": crops.count,
            "puzzle_bounds": [
                "x": puzzleBounds.minX, "y": puzzleBounds.minY,
                "width": puzzleBounds.width, "height": puzzleBounds.height,
            ],
        ]
        if let metaData = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? metaData.write(to: captureDir.appendingPathComponent("meta.json"))
        }

        print("[CelticKnot] Saved \(crops.count) training crops to \(captureDir.path)")
    }

    /// After hypothesis selection write a puzzle-level `meta.json` that
    /// records which capture was the normal-state one, the winning
    /// hypothesis's solver outcome, and per-hypothesis summaries. Lets the
    /// retraining pipeline reconstruct the normal/inverted labelling
    /// post-hoc without needing to keep the directories named.
    private func writeHypothesisMeta(
        puzzleDir: URL,
        winner: HypothesisOutcome,
        loser: HypothesisOutcome
    ) {
        let summary: (HypothesisOutcome) -> [String: Any] = { outcome in
            var entry: [String: Any] = [
                "hypothesis": outcome.hypothesis.rawValue,
                "capture_1": outcome.captureMapping.capture1,
                "capture_2": outcome.captureMapping.capture2,
                "used_fire_blood_ambiguity": outcome.usedFireBloodAmbiguity,
                "aggregate_confidence": Double(outcome.aggregateConfidence),
            ]
            switch outcome.solveResult {
            case .solved(let solution):
                entry["solve_status"] = "solved"
                entry["rotations"] = solution.rotations
                entry["total_clicks"] = solution.totalClicks
            case .ambiguous(let count):
                entry["solve_status"] = "ambiguous"
                entry["candidate_count"] = count
            case .noSolution(let diag):
                entry["solve_status"] = "no_solution"
                if let diag {
                    entry["satisfied_intersections"] = diag.satisfiedIntersections
                    entry["total_intersections"] = diag.totalIntersections
                }
            }
            return entry
        }

        let meta: [String: Any] = [
            "winning_hypothesis": winner.hypothesis.rawValue,
            "capture_1": winner.captureMapping.capture1,
            "capture_2": winner.captureMapping.capture2,
            "evaluated_at": Self.iso8601.string(from: Date()),
            "winner": summary(winner),
            "loser": summary(loser),
        ]

        let url = puzzleDir.appendingPathComponent("meta.json")
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try FileManager.default.createDirectory(at: puzzleDir, withIntermediateDirectories: true)
                try data.write(to: url)
                print("[CelticKnot] Wrote hypothesis meta to \(url.path)")
            } catch {
                print("[CelticKnot] Failed to write hypothesis meta: \(error)")
            }
        }
    }

    nonisolated private static func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
