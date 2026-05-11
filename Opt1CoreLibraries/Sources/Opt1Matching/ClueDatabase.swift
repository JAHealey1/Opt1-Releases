import Foundation

// MARK: - Data Model

public struct ClueSolution: Codable, Identifiable {
    public var id: String
    public var type: String        // "cryptic" | "coordinate" | "anagram" | "map" | "compass" | "emote"
    public var difficulty: String? // "easy" | "medium" | "hard" | "elite" | "master" — optional for back-compat
    public var clue: String        // The raw clue text as it appears in-game
    public var solution: String    // Human-readable solution
    public var location: String?   // Named location (e.g. "Varrock Palace")
    public var coordinates: String? // RS coordinates if applicable (e.g. "3213, 3424")
    public var mapId: Int?         // RS map ID for tile lookup: 28 = surface, -1 = underground/default, 695 = Arc
    public var imageRef: String?   // Base filename for bundled map clue images (MapImages/)
    public var travel: String?     // Travel suggestions, bullet-points joined with " • "
    public var confidence: Double? // Populated by FuzzyMatcher at query time

    public init(id: String, type: String, difficulty: String? = nil, clue: String, solution: String, location: String? = nil, coordinates: String? = nil, mapId: Int? = nil, imageRef: String? = nil, travel: String? = nil, confidence: Double? = nil) {
        self.id = id
        self.type = type
        self.difficulty = difficulty
        self.clue = clue
        self.solution = solution
        self.location = location
        self.coordinates = coordinates
        self.mapId = mapId
        self.imageRef = imageRef
        self.travel = travel
        self.confidence = confidence
    }
}

// MARK: - Database

/// Loads and caches the bundled clue database from clues.json.
/// Phase 3: Populated with full RS3 clue data via scrape_clues.py.
public final class ClueDatabase {

    public static let shared = ClueDatabase()
    private let resourceBundle: Bundle
    public private(set) var clues: [ClueSolution] = []

    /// Pre-computed corpus for `FuzzyMatcher.bestMatch` — excludes types that
    /// have their own dedicated detection paths (map, compass, scan) and are
    /// never reached by the general text-matching branch. Rebuilt whenever
    /// `load()` replaces `clues`, so trigram/normalised-text data stays in
    /// lockstep with the underlying list.
    public private(set) var textCorpus: ClueCorpus = ClueCorpus(clues: [])

    private static let bestMatchExcludedTypes: Set<String> = ["map", "compass", "scan"]

    public init(resourceBundle: Bundle? = nil) {
        self.resourceBundle = resourceBundle ?? .module
    }

    public func load() {
        guard let url = resourceBundle.url(forResource: "clues", withExtension: "json") else {
            print("[Opt1] clues.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            clues = try JSONDecoder().decode([ClueSolution].self, from: data)
            let textClues = clues.filter { !Self.bestMatchExcludedTypes.contains($0.type) }
            textCorpus = ClueCorpus(clues: textClues)
            print("[Opt1] Loaded \(clues.count) clues (\(textClues.count) text-matchable)")
        } catch {
            print("[Opt1] Failed to load clue database: \(error)")
        }
    }
}

