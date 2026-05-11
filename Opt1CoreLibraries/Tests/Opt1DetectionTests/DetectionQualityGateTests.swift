import Testing
@testable import Opt1Detection

@Suite("DetectionQualityGate")
struct DetectionQualityGateTests {

    // MARK: - Helpers

    private static let validSolvedTiles: [Int] = Array(1..<25) + [0]

    /// Returns a valid, high-confidence input that passes all gate checks.
    private func passingInput(puzzleKey: String = "test", hintAssisted: Bool = false) -> DetectionGateInput {
        DetectionGateInput(
            puzzleKey: puzzleKey,
            localizationScore: 0.85,
            puzzleConfidence: 0.75,
            learnedIdAccepted: false,
            tileConfidence: 0.70,
            ambiguityCount: 2,
            tiles: Self.validSolvedTiles,
            hintAssisted: hintAssisted
        )
    }

    // MARK: - Acceptance paths

    @Test("Passing input is accepted")
    func passingInputAccepted() {
        let gate = DetectionQualityGate()
        let result = gate.evaluate(passingInput())
        #expect(result.accepted)
        #expect(!result.needsHintAssistedRetry)
        #expect(result.finalConfidence > 0)
    }

    @Test("Accepted result reason begins with 'ok'")
    func acceptedReasonPrefixOk() {
        let gate = DetectionQualityGate()
        let result = gate.evaluate(passingInput())
        #expect(result.reason.hasPrefix("ok"))
    }

    // MARK: - Localization rejection

    @Test("Low localization score → rejected, needsHintAssistedRetry")
    func lowLocalizationRejected() {
        let gate = DetectionQualityGate()
        var input = passingInput()
        input = DetectionGateInput(
            puzzleKey: input.puzzleKey,
            localizationScore: 0.10,   // below default 0.20
            puzzleConfidence: input.puzzleConfidence,
            learnedIdAccepted: input.learnedIdAccepted,
            tileConfidence: input.tileConfidence,
            ambiguityCount: input.ambiguityCount,
            tiles: input.tiles,
            hintAssisted: input.hintAssisted
        )
        let result = gate.evaluate(input)
        #expect(!result.accepted)
        #expect(result.needsHintAssistedRetry)
        #expect(result.reason.lowercased().contains("localization"))
    }

    // MARK: - Tile confidence rejection

    @Test("Low tile confidence → rejected")
    func lowTileConfidenceRejected() {
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.75,
            learnedIdAccepted: false,
            tileConfidence: 0.10,   // below default 0.35
            ambiguityCount: 2,
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(!result.accepted)
        #expect(result.reason.lowercased().contains("tile"))
    }

    // MARK: - Invalid tile set

    @Test("Invalid tile set (duplicates) → rejected")
    func invalidTileSetRejected() {
        var tiles = Self.validSolvedTiles
        tiles[0] = tiles[1]  // duplicate
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.75,
            learnedIdAccepted: false,
            tileConfidence: 0.70,
            ambiguityCount: 2,
            tiles: tiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(!result.accepted)
        #expect(result.reason.lowercased().contains("invalid") || result.reason.lowercased().contains("tile"))
    }

    // MARK: - Unsolvable board

    @Test("Unsolvable board → rejected")
    func unsolvableBoardRejected() {
        var tiles = Self.validSolvedTiles
        tiles.swapAt(0, 1)  // 1 inversion → unsolvable
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.75,
            learnedIdAccepted: false,
            tileConfidence: 0.70,
            ambiguityCount: 2,
            tiles: tiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(!result.accepted)
        #expect(result.reason.lowercased().contains("solvable") || result.reason.lowercased().contains("not solvable"))
    }

    // MARK: - Puzzle confidence rejection + strong tile override

    @Test("Low puzzle confidence → rejected when no override conditions met")
    func lowPuzzleConfidenceRejected() {
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.20,   // below default 0.42
            learnedIdAccepted: false,
            tileConfidence: 0.50,     // below strongTileConfidenceOverride (0.93)
            ambiguityCount: 2,
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(!result.accepted)
        #expect(result.reason.lowercased().contains("puzzle") ||
                result.reason.lowercased().contains("confidence"))
    }

    @Test("Strong tile confidence overrides low puzzle confidence")
    func strongTileOverrideAccepts() {
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.20,   // below 0.42
            learnedIdAccepted: false,
            tileConfidence: 0.95,     // above strongTileConfidenceOverride (0.93)
            ambiguityCount: 2,
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(result.accepted)
        #expect(result.reason.contains("strong tile override"))
    }

    // MARK: - Ambiguity rejection

    @Test("Too many ambiguities → rejected")
    func tooManyAmbiguitiesRejected() {
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.75,
            learnedIdAccepted: false,
            tileConfidence: 0.70,
            ambiguityCount: 10,   // above default maximumAmbiguities (7)
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(!result.accepted)
        #expect(result.reason.lowercased().contains("ambigu"))
    }

    // MARK: - LearnedID override

    @Test("learnedId override accepts despite low puzzle confidence")
    func learnedIdOverrideAccepts() {
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.85,
            puzzleConfidence: 0.20,   // below threshold
            learnedIdAccepted: true,  // override
            tileConfidence: 0.70,
            ambiguityCount: 2,
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let result = gate.evaluate(input)
        #expect(result.accepted)
        #expect(result.reason.contains("learned ID"))
    }

    // MARK: - Hint-assisted path

    @Test("Hint-assisted with high scores accepts despite ambiguity overflow")
    func hintAssistedAmbiguityOverride() {
        let gate = DetectionQualityGate()
        let input = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.97,   // >= 0.95 for hint-assist
            puzzleConfidence: 0.96,    // >= hintAssistedMinimumPuzzleConfidence (0.95)
            learnedIdAccepted: false,
            tileConfidence: 0.65,      // >= hintAssistedMinimumTileConfidence (0.60)
            ambiguityCount: 5,         // above maximumAmbiguities (default 7) — within cap
            tiles: Self.validSolvedTiles,
            hintAssisted: true
        )
        let result = gate.evaluate(input)
        #expect(result.accepted)
    }

    // MARK: - Per-puzzle override: "werewolf"

    @Test("'werewolf' puzzle-specific override applies relaxed ambiguity cap")
    func werewolfPuzzleOverride() {
        let gate = DetectionQualityGate()
        // werewolf override: hintAssistedAmbiguityCap = 9, minPuzzleConf = 0.55, minTileConf = 0.58
        let input = DetectionGateInput(
            puzzleKey: "werewolf",
            localizationScore: 0.97,
            puzzleConfidence: 0.60,   // >= 0.55
            learnedIdAccepted: false,
            tileConfidence: 0.60,     // >= 0.58
            ambiguityCount: 8,        // > default hintAssistedAmbiguityCap (7), within werewolf cap (9)
            tiles: Self.validSolvedTiles,
            hintAssisted: true
        )
        let result = gate.evaluate(input)
        #expect(result.accepted)
        #expect(result.reason.contains("werewolf"))
    }

    // MARK: - Per-puzzle override: "elves" (requiresLearnedId = true)

    @Test("'elves' override without learnedId falls through to general path")
    func elvesRequiresLearnedId() {
        let gate = DetectionQualityGate()
        // elves: requiresLearnedIdForHintAssist = true → needs learnedIdAccepted
        let input = DetectionGateInput(
            puzzleKey: "elves",
            localizationScore: 0.97,
            puzzleConfidence: 0.50,
            learnedIdAccepted: false,   // required but missing
            tileConfidence: 0.60,
            ambiguityCount: 9,
            tiles: Self.validSolvedTiles,
            hintAssisted: true
        )
        let result = gate.evaluate(input)
        // Without learnedId, the elves override doesn't apply and ambiguity is too high
        #expect(!result.accepted)
    }

    // MARK: - finalConfidence calculation

    @Test("finalConfidence is clamped to [0, 1]")
    func finalConfidenceClamped() {
        let gate = DetectionQualityGate()
        let result = gate.evaluate(passingInput())
        #expect(result.finalConfidence >= 0)
        #expect(result.finalConfidence <= 1)
    }

    @Test("finalConfidence changes with input scores")
    func finalConfidenceVaries() {
        let gate = DetectionQualityGate()
        let low = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.21,
            puzzleConfidence: 0.43,
            learnedIdAccepted: false,
            tileConfidence: 0.36,
            ambiguityCount: 1,
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let high = DetectionGateInput(
            puzzleKey: "test",
            localizationScore: 0.99,
            puzzleConfidence: 0.99,
            learnedIdAccepted: false,
            tileConfidence: 0.99,
            ambiguityCount: 1,
            tiles: Self.validSolvedTiles,
            hintAssisted: false
        )
        let lowConf  = gate.evaluate(low).finalConfidence
        let highConf = gate.evaluate(high).finalConfidence
        #expect(highConf > lowConf)
    }
}
