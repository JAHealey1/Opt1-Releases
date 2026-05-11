import Testing
import CoreGraphics
import Opt1CelticKnot
@testable import Opt1

@Suite("CelticKnotSolver")
struct CelticKnotSolverTests {

    // MARK: - CelticKnotSolution helpers

    @Test("totalClicks sums absolute rotation values", arguments: [
        ([0, 0, 0],    0),
        ([1, 2, 3],    6),
        ([-1, -2, 3],  6),
        ([0],          0),
        ([3, -3],      6),
    ] as [([Int], Int)])
    func totalClicks(rotations: [Int], expected: Int) {
        let sol = CelticKnotSolution(rotations: rotations)
        #expect(sol.totalClicks == expected)
    }

    @Test("Physical rotation direction follows per-track lane orientation")
    func physicalRotationUsesTrackDirectionMetadata() {
        let solution = CelticKnotSolution(
            rotations: [1, 1, -2],
            clockwiseRotationSigns: [1, -1, -1]
        )

        #expect(solution.physicalRotation(at: 0) == 1)
        #expect(solution.physicalRotation(at: 1) == -1)
        #expect(solution.physicalRotation(at: 2) == 2)
        #expect(solution.totalClicks == 4)
    }

    @Test("Physical rotation defaults to solver sign without direction metadata")
    func physicalRotationDefaultsToSolverSign() {
        let solution = CelticKnotSolution(rotations: [1, -1])

        #expect(solution.physicalRotation(at: 0) == 1)
        #expect(solution.physicalRotation(at: 1) == -1)
    }

    // MARK: - CelticKnotArrowPositions: normalised positions are in [0,1]

    @Test("Normalized arrow positions are within unit square", arguments: CelticKnotLayoutType.allCases)
    func normalizedPositionsInUnitSquare(layoutType: CelticKnotLayoutType) {
        let pairs = CelticKnotArrowPositions.normalized(for: layoutType)
        for pair in pairs {
            #expect(pair.cwPosition.x >= 0 && pair.cwPosition.x <= 1)
            #expect(pair.cwPosition.y >= 0 && pair.cwPosition.y <= 1)
            #expect(pair.ccwPosition.x >= 0 && pair.ccwPosition.x <= 1)
            #expect(pair.ccwPosition.y >= 0 && pair.ccwPosition.y <= 1)
        }
    }

    // MARK: - Solver: synthetic 2-track fixture

    /// Builds a minimal 2-track layout for solver testing.
    /// Track 0: 3 slots with labels ["A","B","A"]
    /// Track 1: 2 slots with labels ["A","X"]
    /// Intersection: track0.slot0 — track1.slot0
    ///
    /// Valid rotation combos where A==A at intersection:
    ///   [0,0]: t0.slot0 actual=0→"A", t1.slot0 actual=0→"A" ✓ (trivial, removed)
    ///   [1,0]: t0.slot0 actual=(0-1+3)%3=2→"A", t1.slot0 actual=0→"A" ✓ (unique non-trivial)
    ///
    /// Expected: .solved(rotations: [1, 0])
    private func makeTwoTrackFixture() -> CelticKnotState {
        let slots0: [RuneSlot] = [
            RuneSlot(x: 0.3, y: 0.5, trackIndex: 0, slotIndex: 0),
            RuneSlot(x: 0.4, y: 0.5, trackIndex: 0, slotIndex: 1),
            RuneSlot(x: 0.5, y: 0.5, trackIndex: 0, slotIndex: 2),
        ]
        let slots1: [RuneSlot] = [
            RuneSlot(x: 0.6, y: 0.5, trackIndex: 1, slotIndex: 0),
            RuneSlot(x: 0.7, y: 0.5, trackIndex: 1, slotIndex: 1),
        ]
        let layout = CelticKnotLayout(
            type: .sixSpot,
            tracks: [slots0, slots1],
            intersections: [(trackA: 0, slotA: 0, trackB: 1, slotB: 0)],
            estimatedRuneDiameter: 20
        )
        let dummyDetail = CelticKnotDetector.SlotClassification(
            label: nil, confidence: nil, margin: nil, reason: .noCrop
        )
        let classDetails: [[CelticKnotDetector.SlotClassification]] = [
            Array(repeating: dummyDetail, count: 3),
            Array(repeating: dummyDetail, count: 2),
        ]
        let state = CelticKnotState(
            layout: layout,
            runeLabels: [["A", "B", "A"], ["A", "X"]],
            classDetails: classDetails,
            puzzleBoundsInImage: CGRect(x: 0, y: 0, width: 100, height: 100),
            runeAreaInImage: CGRect(x: 0, y: 0, width: 100, height: 100),
            isInverted: false
        )
        return state
    }

    private func detail(
        label: String?,
        confidence: Float? = 0.95,
        margin: Float? = 0.8,
        reason: CelticKnotDetector.SlotNilReason? = nil
    ) -> CelticKnotDetector.SlotClassification {
        CelticKnotDetector.SlotClassification(
            label: label,
            confidence: confidence,
            margin: margin,
            reason: reason
        )
    }

    private func makeTwoTrackState(
        labels: [[String?]],
        details: [[CelticKnotDetector.SlotClassification]]
    ) -> CelticKnotState {
        let tracks = labels.enumerated().map { trackIdx, trackLabels in
            trackLabels.indices.map { slotIdx in
                RuneSlot(
                    x: CGFloat(0.2 + Double(slotIdx) * 0.1),
                    y: CGFloat(0.4 + Double(trackIdx) * 0.1),
                    trackIndex: trackIdx,
                    slotIndex: slotIdx
                )
            }
        }
        let layout = CelticKnotLayout(
            type: .sixSpot,
            tracks: tracks,
            intersections: [(trackA: 0, slotA: 0, trackB: 1, slotB: 0)],
            estimatedRuneDiameter: 20
        )
        return CelticKnotState(
            layout: layout,
            runeLabels: labels,
            classDetails: details,
            puzzleBoundsInImage: .zero,
            runeAreaInImage: .zero,
            isInverted: false
        )
    }

    @Test("Solver: unique non-trivial solution is found for 2-track fixture")
    func twoTrackUniqueSolution() {
        let detector = CelticKnotDetector()
        let state = makeTwoTrackFixture()
        let result = detector.solve(state)
        guard case .solved(let solution) = result else {
            #expect(Bool(false), "Expected .solved, got \(result)")
            return
        }
        #expect(solution.rotations.count == 2)
        #expect(solution.rotations[0] == 1)
        #expect(solution.rotations[1] == 0)
        #expect(solution.totalClicks == 1)
    }

    @Test("Solver: no intersections returns .noSolution")
    func noIntersectionsNoSolution() {
        let slots0: [RuneSlot] = [
            RuneSlot(x: 0.3, y: 0.5, trackIndex: 0, slotIndex: 0),
        ]
        let slots1: [RuneSlot] = [
            RuneSlot(x: 0.6, y: 0.5, trackIndex: 1, slotIndex: 0),
        ]
        let layout = CelticKnotLayout(
            type: .sixSpot,
            tracks: [slots0, slots1],
            intersections: [],  // no intersections — solver returns .noSolution immediately
            estimatedRuneDiameter: 20
        )
        let dummyDetail = CelticKnotDetector.SlotClassification(
            label: nil, confidence: nil, margin: nil, reason: .noCrop
        )
        let state = CelticKnotState(
            layout: layout,
            runeLabels: [["A"], ["B"]],
            classDetails: [[dummyDetail], [dummyDetail]],
            puzzleBoundsInImage: .zero,
            runeAreaInImage: .zero,
            isInverted: false
        )
        let result = CelticKnotDetector().solve(state)
        guard case .noSolution = result else {
            #expect(Bool(false), "Expected .noSolution, got \(result)")
            return
        }
    }

    @Test("Solver: unclassified rune at any intersection yields .noSolution")
    func unclassifiedRuneAtIntersectionYieldsNoSolution() {
        // Start from the known-solvable fixture, then blank the rune that sits at
        // the intersection for the one winning rotation ([1,0]): track 0 slot 2.
        // With strict OCR-failure handling, no rotation can verify the constraint,
        // so the solver must report .noSolution rather than silently accepting
        // an unverified match.
        let state = makeTwoTrackFixture()
        let withMissingOCR = CelticKnotState(
            layout: state.layout,
            runeLabels: [["A", "B", nil], ["A", "X"]],
            classDetails: state.classDetails,
            puzzleBoundsInImage: state.puzzleBoundsInImage,
            runeAreaInImage: state.runeAreaInImage,
            isInverted: false
        )
        let result = CelticKnotDetector().solve(withMissingOCR)
        guard case .noSolution = result else {
            #expect(Bool(false), "Expected .noSolution when intersection rune is nil, got \(result)")
            return
        }
    }

    @Test("Solver: mismatched label counts returns .noSolution")
    func mismatchedLabelCount() {
        let state = makeTwoTrackFixture()
        // Build a state with label count that doesn't match layout track count
        let badState = CelticKnotState(
            layout: state.layout,
            runeLabels: [["A", "B", "A"]],   // only 1 track, layout has 2
            classDetails: state.classDetails,
            puzzleBoundsInImage: state.puzzleBoundsInImage,
            runeAreaInImage: state.runeAreaInImage,
            isInverted: false
        )
        let result = CelticKnotDetector().solve(badState)
        guard case .noSolution = result else {
            #expect(Bool(false), "Expected .noSolution for mismatched labels, got \(result)")
            return
        }
    }

    @Test("Solver: strict solve rejects fire/blood mismatch")
    func strictSolveRejectsFireBloodMismatch() {
        let labels: [[String?]] = [["X", "B", "fire"], ["blood", "Y"]]
        let details = [
            [detail(label: "X"), detail(label: "B"), detail(label: "fire")],
            [detail(label: "blood"), detail(label: "Y")],
        ]
        let state = makeTwoTrackState(labels: labels, details: details)

        let result = CelticKnotDetector().solve(state)
        guard case .noSolution = result else {
            #expect(Bool(false), "Expected strict .noSolution for fire/blood mismatch, got \(result)")
            return
        }
    }

    @Test("Solver: fire/blood ambiguity solves weak rejected slot")
    func fireBloodAmbiguitySolvesWeakRejectedSlot() {
        let labels: [[String?]] = [["X", "B", nil], ["blood", "Y"]]
        let details = [
            [
                detail(label: "X"),
                detail(label: "B"),
                detail(label: "fire", confidence: 0.82, margin: 0.04, reason: .belowMargin),
            ],
            [detail(label: "blood"), detail(label: "Y")],
        ]
        let state = makeTwoTrackState(labels: labels, details: details)

        let strict = CelticKnotDetector().solve(state)
        guard case .noSolution = strict else {
            #expect(Bool(false), "Expected strict .noSolution before ambiguity retry, got \(strict)")
            return
        }

        let result = CelticKnotDetector().solveAllowingFireBloodAmbiguity(state)
        guard case .solved(let solution) = result else {
            #expect(Bool(false), "Expected ambiguity solve to recover, got \(result)")
            return
        }
        #expect(solution.rotations == [1, 0])
    }

    @Test("Solver: high-confidence fire/blood labels are not expanded")
    func highConfidenceFireBloodLabelsAreNotExpanded() {
        let labels: [[String?]] = [["X", "B", "fire"], ["blood", "Y"]]
        let details = [
            [detail(label: "X"), detail(label: "B"), detail(label: "fire", margin: 0.8)],
            [detail(label: "blood", margin: 0.8), detail(label: "Y")],
        ]
        let state = makeTwoTrackState(labels: labels, details: details)

        let result = CelticKnotDetector().solveAllowingFireBloodAmbiguity(state)
        guard case .noSolution = result else {
            #expect(Bool(false), "Expected high-confidence fire/blood mismatch to remain rejected, got \(result)")
            return
        }
    }

    @Test("Solver: strict candidate beats ambiguous candidate at same click cost")
    func strictCandidateBeatsAmbiguousCandidateAtSameCost() {
        let labels: [[String?]] = [
            [nil, "B", "C", "A"],
            ["A", "Y", "Z", "blood"],
        ]
        let details = [
            [
                detail(label: "fire", confidence: 0.82, margin: 0.04, reason: .belowMargin),
                detail(label: "B"),
                detail(label: "C"),
                detail(label: "A"),
            ],
            [
                detail(label: "A"),
                detail(label: "Y"),
                detail(label: "Z"),
                detail(label: "blood"),
            ],
        ]
        let state = makeTwoTrackState(labels: labels, details: details)

        let result = CelticKnotDetector().solveAllowingFireBloodAmbiguity(state)
        guard case .solved(let solution) = result else {
            #expect(Bool(false), "Expected ambiguity-aware solver to find a solution, got \(result)")
            return
        }
        #expect(solution.rotations == [1, 0])
    }
}
