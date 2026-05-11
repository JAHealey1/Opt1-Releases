import CoreGraphics
import Foundation
import Opt1Solvers

/// Outcome of a puzzle-box detection attempt.
///
/// - `.solved`: pipeline produced an accepted, gate-approved board state.
/// - `.unsupported`: pipeline identified the puzzle confidently but the
///   puzzle key is on the gate's unsupported list. Callers should show a
///   named message to the user rather than prompting for a hint capture.
/// - `.gridLocalizationFailed`: the rails -> inner_frame cascade in
///   `GridLocalizer` declined. A hint capture will not help — the user's
///   snip doesn't contain a readable 5x5 grid. Callers should prompt for
///   a re-crop, not a hint-retry.
/// - `.failed`: anything else (tile match rejected, gate demanded
///   hint-assisted retry, etc.). Existing callers should fall back to
///   their prior "ask for hint / try again" UI.
enum PuzzleBoxDetectionOutcome {
    case solved(PuzzleBoxState)
    case unsupported(puzzleName: String)
    case gridLocalizationFailed
    case failed
}

/// Thin wrapper over PuzzleDetectionPipeline.
/// All puzzle box detection uses the snip-crop pipeline (Opt+2).
final class PuzzleBoxDetector {
    typealias ProgressCallback = @Sendable (String) -> Void

    struct ReferenceMatch {
        let key: String
        let name: String
        let distance: Float
    }

    private var debugDir: URL? {
        AppSettings.debugSubfolder(named: "PuzzleBoxDebug")
    }

    private lazy var pipeline = PuzzleDetectionPipeline(debugDir: debugDir)

    func detectInSnipCrop(
        in image: CGImage,
        progress: ProgressCallback? = nil,
        preferredReferenceKey: String? = nil,
        hintReferenceImage: CGImage? = nil
    ) async -> PuzzleBoxDetectionOutcome {
        let result = pipeline.detect(
            in: image,
            mode: .snipCrop,
            preferredReferenceKey: preferredReferenceKey,
            hintReferenceImage: hintReferenceImage,
            progress: progress
        )
        if let state = result.state {
            return .solved(state)
        }
        if let name = result.unsupportedPuzzleName {
            return .unsupported(puzzleName: name)
        }
        if result.reason == "inner-grid-localization-failed" {
            return .gridLocalizationFailed
        }
        return .failed
    }

    func classifyReference(in image: CGImage) -> ReferenceMatch? {
        pipeline.classifyReference(in: image).map {
            ReferenceMatch(key: $0.key, name: $0.name, distance: max(0, 1.0 - $0.confidence))
        }
    }
}
