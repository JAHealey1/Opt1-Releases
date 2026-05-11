import Opt1Solvers
import Foundation

public struct DetectionGateInput {
    public let puzzleKey: String
    public let localizationScore: Float
    public let puzzleConfidence: Float
    public let learnedIdAccepted: Bool
    public let tileConfidence: Float
    public let ambiguityCount: Int
    public let tiles: [Int]
    public let hintAssisted: Bool

    public init(puzzleKey: String, localizationScore: Float, puzzleConfidence: Float, learnedIdAccepted: Bool, tileConfidence: Float, ambiguityCount: Int, tiles: [Int], hintAssisted: Bool) {
        self.puzzleKey = puzzleKey
        self.localizationScore = localizationScore
        self.puzzleConfidence = puzzleConfidence
        self.learnedIdAccepted = learnedIdAccepted
        self.tileConfidence = tileConfidence
        self.ambiguityCount = ambiguityCount
        self.tiles = tiles
        self.hintAssisted = hintAssisted
    }
}

public struct DetectionGateResult {
    public let accepted: Bool
    public let needsHintAssistedRetry: Bool
    public let reason: String
    public let finalConfidence: Float

    public init(accepted: Bool, needsHintAssistedRetry: Bool, reason: String, finalConfidence: Float) {
        self.accepted = accepted
        self.needsHintAssistedRetry = needsHintAssistedRetry
        self.reason = reason
        self.finalConfidence = finalConfidence
    }
}

/// Per-puzzle overrides for the acceptance thresholds.
///
/// The default gate parameters work well for modern puzzles. A handful of
/// puzzles (e.g. "werewolf", "elves", and the legacy bridge/tree/troll set)
/// have higher visual complexity, lower-quality reference artwork, or larger
/// blank-tile areas that produce more ambiguous tile readings even with a
/// hint preview. Register a `PuzzleGateOverride` instead of adding more
/// `puzzleKey == "..."` branches to `evaluate()`.
///
/// NOTE on scoping: every field here is matched against an exact `puzzleKey`,
/// so a modern puzzle cannot be affected by an override targeting a legacy
/// puzzle. To drop support for legacy puzzles entirely, remove their entries
/// from `puzzleOverrides` and the surrounding behaviour reverts to the
/// default thresholds for every remaining puzzle.
public struct PuzzleGateOverride {
    /// Must match the key in the puzzle manifest (case-sensitive).
    public let puzzleKey: String
    /// Maximum number of ambiguous tile slots allowed when hint-assisted.
    public let hintAssistedAmbiguityCap: Int
    /// Minimum puzzle-identity confidence required when hint-assisted.
    public let hintAssistedMinPuzzleConfidence: Float
    /// Minimum tile-match confidence required when hint-assisted.
    public let hintAssistedMinTileConfidence: Float
    /// When true, the learned-ID model must have accepted this puzzle for
    /// the hint-assisted ambiguity cap to apply.
    let requiresLearnedIdForHintAssist: Bool
    /// Optional non-hint first-pass override. When set, the gate will accept
    /// a noisy tile match without forcing a hint retry — but only if the
    /// learned-ID model has already accepted the puzzle with high
    /// confidence. Set to `nil` for puzzles that should always force a hint
    /// retry on high ambiguity (the default for modern puzzles).
    let nonHintAmbiguityCap: Int?
    /// Minimum puzzle-identity confidence required to trigger the non-hint
    /// ambiguity override. Ignored when `nonHintAmbiguityCap` is nil.
    let nonHintMinPuzzleConfidence: Float
    /// Minimum tile-match confidence required to trigger the non-hint
    /// ambiguity override. Ignored when `nonHintAmbiguityCap` is nil.
    let nonHintMinTileConfidence: Float
    /// When true, non-hint tile matches for this puzzle are always rejected
    /// with `needsHintAssistedRetry = true`, forcing the orchestrator to
    /// request a hint capture and re-run the pipeline with a hint-assisted
    /// reference. Use for puzzles where the non-hint (v4 KNN) tile matcher is
    /// known to produce plausible-but-wrong solutions that the gate cannot
    /// reliably detect (e.g. `nomad`), so we'd rather force the v1 hint
    /// pathway than silently publish a wrong board.
    let requiresHintAssisted: Bool

    public init(
        puzzleKey: String,
        hintAssistedAmbiguityCap: Int,
        hintAssistedMinPuzzleConfidence: Float,
        hintAssistedMinTileConfidence: Float,
        requiresLearnedIdForHintAssist: Bool,
        nonHintAmbiguityCap: Int? = nil,
        nonHintMinPuzzleConfidence: Float = 0.85,
        nonHintMinTileConfidence: Float = 0.50,
        requiresHintAssisted: Bool = false
    ) {
        self.puzzleKey = puzzleKey
        self.hintAssistedAmbiguityCap = hintAssistedAmbiguityCap
        self.hintAssistedMinPuzzleConfidence = hintAssistedMinPuzzleConfidence
        self.hintAssistedMinTileConfidence = hintAssistedMinTileConfidence
        self.requiresLearnedIdForHintAssist = requiresLearnedIdForHintAssist
        self.nonHintAmbiguityCap = nonHintAmbiguityCap
        self.nonHintMinPuzzleConfidence = nonHintMinPuzzleConfidence
        self.nonHintMinTileConfidence = nonHintMinTileConfidence
        self.requiresHintAssisted = requiresHintAssisted
    }
}

public final class DetectionQualityGate {
    public init() {}
    /// Puzzle keys that are recognised but intentionally not solved.
    ///
    /// Entries here short-circuit `evaluate()` with `accepted = false` and
    /// `needsHintAssistedRetry = false` so the pipeline stops as soon as the
    /// puzzle is identified — no tile match is published, and the UI will not
    /// keep requesting a hint screenshot. Use this when real-world tile
    /// matching is unreliable *for reasons no amount of threshold tweaking
    /// can fix* — e.g. `tree` sits at ~75% per-cell accuracy on hand-labeled
    /// scrambles (a solvable 24-tile board requires 100% cell accuracy), and
    /// `bridge`, `castle`, and `troll` fail in the same way in real-world
    /// testing despite healthy multi-session hint datasets.
    ///
    /// To restore support, remove the key and (if needed) reinstate a
    /// `PuzzleGateOverride` below. Keys here are matched case-sensitively
    /// against `DetectionGateInput.puzzleKey`.
    // `tree` was re-tested under the new inner-grid cascade localizer and
    // still produced too many tile ambiguities per capture to solve
    // reliably — confirming the root cause is visual tile similarity
    // rather than grid localization. Keeping it unsupported.
    public var unsupportedPuzzleKeys: Set<String> = ["tree", "bridge", "castle", "troll"]

    public var minimumLocalizationScore: Float = 0.20
    public var minimumPuzzleConfidence: Float = 0.42
    public var minimumTileConfidence: Float = 0.35
    public var maximumAmbiguities: Int = 7
    public var strongTileConfidenceOverride: Float = 0.93
    public var minimumPuzzleConfidenceForOverride: Float = 0.20
    public var maxAmbiguitiesForOverride: Int = 7
    public var allowLearnedIdPuzzleConfidenceOverride: Bool = true
    public var hintAssistedAmbiguityCap: Int = 7
    public var hintAssistedMinimumPuzzleConfidence: Float = 0.95
    public var hintAssistedMinimumTileConfidence: Float = 0.60

    /// Per-puzzle overrides evaluated after the general hint-assisted path.
    /// Each override is matched by `puzzleKey`; the first match wins.
    ///
    /// No puzzle currently uses `nonHintAmbiguityCap`: every legacy puzzle
    /// whose lower-quality artwork required relaxed margins (`tree`,
    /// `bridge`, `castle`, `troll`) is now declared unsupported via
    /// `unsupportedPuzzleKeys`. Modern puzzles keep the tighter global
    /// default `maximumAmbiguities = 7` — none of these entries can
    /// relax the gate for any puzzle key they do not match.
    public var puzzleOverrides: [PuzzleGateOverride] = [
        PuzzleGateOverride(
            puzzleKey: "werewolf",
            hintAssistedAmbiguityCap: 9,
            hintAssistedMinPuzzleConfidence: 0.55,
            hintAssistedMinTileConfidence: 0.58,
            requiresLearnedIdForHintAssist: false
        ),
        // `elves` forces hint-assisted mode: neither v3 nor v4 produces
        // reliable non-hint solutions (observed empirically — both embeddings
        // yield plausible-but-wrong boards). v1 grayscale + ZNCC in
        // hint-assisted mode is the only reliable path for this puzzle, so
        // we short-circuit to it rather than waste a capture on a non-hint
        // attempt that's effectively guaranteed to fail.
        PuzzleGateOverride(
            puzzleKey: "elves",
            hintAssistedAmbiguityCap: 11,
            hintAssistedMinPuzzleConfidence: 0.42,
            hintAssistedMinTileConfidence: 0.56,
            requiresLearnedIdForHintAssist: true,
            requiresHintAssisted: true
        ),
        // `tree`, `bridge`, `castle`, and `troll` intentionally omitted —
        // all four are declared unsupported via `unsupportedPuzzleKeys`
        // and rejected before reaching the override matching below.
        // `nomad` has no gate override: tile-KNN is trained universally on
        // v1 (same 52-dim grayscale embedding the hint-assisted path uses),
        // so nomad runs through the default (modern) gate. If real-world
        // non-hint captures regress we'll re-introduce a
        // `requiresHintAssisted: true` override here.
    ]

    public func evaluate(_ input: DetectionGateInput) -> DetectionGateResult {
        let validTileSet = SlidingPuzzleSolver.isValidTileSet(input.tiles)
        let solvable = SlidingPuzzleSolver.isSolvable(input.tiles)
        let baseConfidence = fusedConfidence(input)

        if unsupportedPuzzleKeys.contains(input.puzzleKey) {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: false,
                reason: "Puzzle \(input.puzzleKey) is not supported",
                finalConfidence: baseConfidence
            )
        }

        // Per-puzzle forced hint-assisted gate — reject any non-hint attempt
        // for opted-in puzzles so the orchestrator prompts for a hint capture
        // and re-runs the pipeline with a hint-assisted reference.
        if !input.hintAssisted,
           let override = puzzleOverrides.first(where: { $0.puzzleKey == input.puzzleKey }),
           override.requiresHintAssisted {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Puzzle \(input.puzzleKey) requires hint-assisted mode",
                finalConfidence: baseConfidence
            )
        }

        guard input.localizationScore >= minimumLocalizationScore else {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Grid localization confidence too low",
                finalConfidence: baseConfidence
            )
        }
        guard input.tileConfidence >= minimumTileConfidence else {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Tile assignment confidence too low",
                finalConfidence: baseConfidence
            )
        }
        guard validTileSet else {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Tile set is invalid (duplicate/missing IDs)",
                finalConfidence: baseConfidence
            )
        }
        guard solvable else {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Detected board is not solvable",
                finalConfidence: baseConfidence
            )
        }

        let learnedIdPuzzleConfidenceOverride =
            allowLearnedIdPuzzleConfidenceOverride &&
            input.learnedIdAccepted
        let puzzlePass = input.puzzleConfidence >= minimumPuzzleConfidence || learnedIdPuzzleConfidenceOverride
        let ambiguityPass = input.ambiguityCount <= maximumAmbiguities
        let strongTileOverride =
            input.tileConfidence >= strongTileConfidenceOverride &&
            input.puzzleConfidence >= minimumPuzzleConfidenceForOverride &&
            input.ambiguityCount <= maxAmbiguitiesForOverride

        // Per-puzzle non-hint override — only applies to puzzle keys that
        // have explicitly opted in via `nonHintAmbiguityCap`. Cannot affect
        // modern puzzles since their keys are not in `puzzleOverrides`.
        let perPuzzleNonHintOverride: Bool = {
            guard let override = puzzleOverrides.first(where: { $0.puzzleKey == input.puzzleKey }),
                  let cap = override.nonHintAmbiguityCap
            else { return false }
            if override.requiresLearnedIdForHintAssist && !input.learnedIdAccepted { return false }
            return input.puzzleConfidence >= override.nonHintMinPuzzleConfidence
                && input.tileConfidence >= override.nonHintMinTileConfidence
                && input.ambiguityCount <= cap
        }()

        // General hint-assisted override (applies to all puzzles without a specific override).
        let hintAssistedAmbiguityOverride =
            input.hintAssisted &&
            input.localizationScore >= 0.95 &&
            input.puzzleConfidence >= hintAssistedMinimumPuzzleConfidence &&
            input.tileConfidence >= hintAssistedMinimumTileConfidence &&
            input.ambiguityCount <= hintAssistedAmbiguityCap

        // Per-puzzle override — first matching entry wins.
        let puzzleSpecificOverride: Bool = {
            guard input.hintAssisted,
                  input.localizationScore >= 0.95,
                  let override = puzzleOverrides.first(where: { $0.puzzleKey == input.puzzleKey })
            else { return false }
            if override.requiresLearnedIdForHintAssist && !input.learnedIdAccepted { return false }
            return input.puzzleConfidence >= override.hintAssistedMinPuzzleConfidence
                && input.tileConfidence >= override.hintAssistedMinTileConfidence
                && input.ambiguityCount <= override.hintAssistedAmbiguityCap
        }()

        if !puzzlePass && !strongTileOverride {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Puzzle ID confidence too low",
                finalConfidence: baseConfidence
            )
        }

        if !ambiguityPass &&
            !strongTileOverride &&
            !perPuzzleNonHintOverride &&
            !hintAssistedAmbiguityOverride &&
            !puzzleSpecificOverride {
            return DetectionGateResult(
                accepted: false,
                needsHintAssistedRetry: true,
                reason: "Too many ambiguous tile assignments",
                finalConfidence: baseConfidence
            )
        }

        let reason: String
        if puzzleSpecificOverride && !ambiguityPass {
            reason = "ok (\(input.puzzleKey) hint-assisted ambiguity override)"
        } else if hintAssistedAmbiguityOverride && !ambiguityPass {
            reason = "ok (hint-assisted ambiguity override)"
        } else if strongTileOverride && (!puzzlePass || !ambiguityPass) {
            reason = "ok (strong tile override)"
        } else if perPuzzleNonHintOverride && !ambiguityPass {
            reason = "ok (\(input.puzzleKey) non-hint ambiguity override)"
        } else if learnedIdPuzzleConfidenceOverride && input.puzzleConfidence < minimumPuzzleConfidence {
            reason = "ok (learned ID confidence override)"
        } else {
            reason = "ok"
        }
        return DetectionGateResult(
            accepted: true,
            needsHintAssistedRetry: false,
            reason: reason,
            finalConfidence: baseConfidence
        )
    }

    private func fusedConfidence(_ input: DetectionGateInput) -> Float {
        max(0, min(1, input.localizationScore * 0.22 + input.puzzleConfidence * 0.33 + input.tileConfidence * 0.45))
    }
}
