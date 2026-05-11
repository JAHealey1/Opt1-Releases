import CoreGraphics
import Foundation

enum PuzzleCollectionKind: String {
    case slidingPuzzle = "sliding_puzzle"
    case lockbox = "lockbox"
}

struct PuzzleCollectionPuzzle {
    let key: String
    let displayName: String
    let kind: PuzzleCollectionKind
}

enum PuzzleCollectionPhase: String {
    case scrambled
    case hint
}

struct PuzzleCollectionConfig {
    let puzzle: PuzzleCollectionPuzzle
    let scrambledTarget: Int
    let hintTarget: Int
    let outputRoot: URL
}

struct PuzzleCollectionProgress {
    var phase: PuzzleCollectionPhase = .scrambled
    var scrambledCaptured: Int = 0
    var hintCaptured: Int = 0

    func currentCount() -> Int {
        switch phase {
        case .scrambled: return scrambledCaptured
        case .hint: return hintCaptured
        }
    }

    func currentTarget(config: PuzzleCollectionConfig) -> Int {
        switch phase {
        case .scrambled: return config.scrambledTarget
        case .hint: return config.hintTarget
        }
    }
}
