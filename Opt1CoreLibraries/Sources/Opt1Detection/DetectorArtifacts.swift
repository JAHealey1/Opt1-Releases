import Foundation

public struct PuzzleClassifierArtifact: Codable {
    public struct PrototypeSet: Codable {
        public let key: String
        public let vectors: [[Float]]
    }

    public struct Centroid: Codable {
        public let key: String
        public let vector: [Float]
    }

    public let embeddingVersion: Int
    public let centroids: [Centroid]?
    public let prototypes: [PrototypeSet]?
}

public struct PuzzleReferenceEmbeddingsArtifact: Codable {
    public struct Reference: Codable {
        public let key: String
        public let puzzleEmbedding: [Float]
        public let tileEmbeddings: [[Float]?]
    }

    public let embeddingVersion: Int
    public let references: [Reference]
}

public struct PuzzleLearnedIdArtifact: Codable {
    public struct ClassMetrics: Codable {
        public let support: Int
        public let top1Accuracy: Float
        public let avgTrueClassProbability: Float
    }

    public let type: String?
    public let version: Int
    public let embeddingVersion: Int
    public let k: Int?
    public let classToIndex: [String: Int]
    public let indexToClass: [String]
    public let centroids: [[Float]]
    public let referenceEmbeddings: [[Float]]?
    public let referenceLabels: [String]?
    public let excludedKeys: [String]
    public let preprocessing: [String: String]
    public let calibratedTemperature: Float?
    public let recommendedMinConfidence: Float?
    public let recommendedMinMargin: Float?
    public let trainSampleCount: Int
    public let validationSampleCount: Int
    public let top1Accuracy: Float
    public let generatedAt: String
    public let perClassMetrics: [String: ClassMetrics]

    public var isKNN: Bool { (type ?? "").lowercased() == "knn" }
}

public struct PuzzleTileKnnArtifact: Codable {
    public struct SlotReferences: Codable {
        /// Slot index within the 5x5 grid (0..<25).
        public let slot: Int
        public let embeddings: [[Float]]
    }

    public struct PuzzleEntry: Codable {
        /// Puzzle identifier (matches `PuzzleLearnedIdArtifact.indexToClass`).
        public let puzzleId: String
        public let sampleCount: Int
        public let slots: [SlotReferences]
        /// Per-puzzle ambiguity margin (p95 of top-1 - top-2 cosine gaps) used
        /// by TileMatcher to decide which pairs are too close to accept.
        public let ambiguityMargin: Float?
        /// Optional p50 alongside p95 for diagnostics.
        public let ambiguityMarginP50: Float?
        /// Optional per-puzzle embedding-version override. When present, the
        /// runtime encodes observed cells for this puzzle with this version
        /// instead of the artifact-level `embeddingVersion`. Used when a
        /// specific puzzle's tile art is better discriminated by an older
        /// embedding (e.g. `nomad` uses v3 because v4's LBP + quadrant HSV
        /// bins collapse its homogeneous organic tiles).
        public let embeddingVersion: Int?
    }

    public let version: Int
    public let type: String
    public let embeddingVersion: Int
    public let k: Int
    public let preprocessing: [String: String]
    public let defaultAmbiguityMargin: Float
    public let puzzles: [PuzzleEntry]
    public let trainHintSampleCount: Int
    public let trainScrambledSampleCount: Int
    public let generatedAt: String
}

public struct LockboxCellModelArtifact: Codable {
    public struct ClassMetrics: Codable {
        public let support: Int
        public let top1Accuracy: Float
        public let avgTrueClassProbability: Float
    }

    public let version: Int
    public let embeddingVersion: Int
    public let classToIndex: [String: Int]
    public let indexToClass: [String]
    public let centroids: [[Float]]
    public let preprocessing: [String: String]
    public let calibratedTemperature: Float?
    public let recommendedMinConfidence: Float?
    public let recommendedMinMargin: Float?
    public let trainSampleCount: Int
    public let validationSampleCount: Int
    public let top1Accuracy: Float
    public let generatedAt: String
    public let perClassMetrics: [String: ClassMetrics]
}

public struct TowersDigitTemplateArtifact: Codable {
    public struct GoldFilter: Codable {
        public let minR: Int
        public let minG: Int
        public let maxB: Int
        public let minRminusB: Int
    }

    public let version: Int
    public let templateWidth: Int
    public let templateHeight: Int
    public let goldFilter: GoldFilter
    /// Key = digit string ("1"…"5"), value = flattened binary pixel vector (templateWidth × templateHeight).
    public let templates: [String: [Float]]
}

public struct CelticKnotRuneModelArtifact: Codable {
    public struct ClassMetrics: Codable {
        public let support: Int
        public let top1Accuracy: Float
        public let avgTrueClassProbability: Float?
        public let avgConfidence: Float?
    }

    public let type: String?
    public let version: Int
    public let embeddingVersion: Int
    public let k: Int?
    public let classToIndex: [String: Int]?
    public let indexToClass: [String]
    public let centroids: [[Float]]?
    public let referenceEmbeddings: [[Float]]?
    public let referenceLabels: [String]?
    public let preprocessing: [String: String]
    public let calibratedTemperature: Float?
    public let recommendedMinConfidence: Float?
    public let recommendedMinMargin: Float?
    public let trainSampleCount: Int
    public let validationSampleCount: Int
    public let top1Accuracy: Float
    public let generatedAt: String
    public let perClassMetrics: [String: ClassMetrics]

    public var isKNN: Bool { type == "knn" }
}

// MARK: - BundleArtifact

/// JSON artifact shipped inside the app bundle. Each conforming type declares
/// its own resource name (and optionally a subdirectory), so callers load via
/// `Artifact.loadFromBundle()` instead of going through a central dispatcher
/// — the resource name lives next to the type that owns it.
public protocol BundleArtifact: Decodable {
    static var bundleResourceName: String { get }
    static var bundleSubdirectory: String? { get }
}

public extension BundleArtifact {
    static var bundleSubdirectory: String? { "PuzzleImages" }

    static func loadFromBundle(bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(
            forResource: bundleResourceName,
            withExtension: "json",
            subdirectory: bundleSubdirectory
        ),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

extension PuzzleClassifierArtifact: BundleArtifact {
    public static var bundleResourceName: String { "puzzle_classifier" }
}

extension PuzzleReferenceEmbeddingsArtifact: BundleArtifact {
    public static var bundleResourceName: String { "reference_embeddings" }
}

extension PuzzleLearnedIdArtifact: BundleArtifact {
    public static var bundleResourceName: String { "puzzle_id_model" }
}

extension PuzzleTileKnnArtifact: BundleArtifact {
    public static var bundleResourceName: String { "puzzle_tile_knn_model" }
}

extension LockboxCellModelArtifact: BundleArtifact {
    public static var bundleResourceName: String { "lockbox_cell_model" }
}

extension TowersDigitTemplateArtifact: BundleArtifact {
    public static var bundleResourceName: String { "towers_digit_templates" }
}

extension CelticKnotRuneModelArtifact: BundleArtifact {
    public static var bundleResourceName: String { "celtic_knot_rune_model" }
}
