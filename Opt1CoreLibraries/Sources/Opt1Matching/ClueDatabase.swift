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
    /// Alternate OCR text patterns for the compact scan parchment (small scroll).
    /// The compact scroll uses different wording than the large scroll clue text,
    /// so entries can supply known alternates (e.g. "The crater in the Wilderness"
    /// for the Wilderness Crater scan) that the matcher checks before fuzzy fallback.
    public var scanTextAliases: [String]?
    /// Known orb scan range in paces (scan clues only). Used to validate the
    /// live OCR-detected range and fall back to this value when OCR is wrong.
    public var scanRange: Int?

    public init(id: String, type: String, difficulty: String? = nil, clue: String, solution: String, location: String? = nil, coordinates: String? = nil, mapId: Int? = nil, imageRef: String? = nil, travel: String? = nil, confidence: Double? = nil, scanTextAliases: [String]? = nil, scanRange: Int? = nil) {
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
        self.scanTextAliases = scanTextAliases
        self.scanRange = scanRange
    }

    enum CodingKeys: String, CodingKey {
        case id, type, difficulty, clue, solution, location, coordinates, mapId,
             imageRef, travel, confidence, scanTextAliases, scanRange
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        difficulty = try c.decodeIfPresent(String.self, forKey: .difficulty)
        clue = try c.decode(String.self, forKey: .clue)
        solution = try c.decode(String.self, forKey: .solution)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        coordinates = try c.decodeIfPresent(String.self, forKey: .coordinates)
        mapId = try c.decodeIfPresent(Int.self, forKey: .mapId)
        imageRef = try c.decodeIfPresent(String.self, forKey: .imageRef)
        travel = try c.decodeIfPresent(String.self, forKey: .travel)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        scanTextAliases = try c.decodeIfPresent([String].self, forKey: .scanTextAliases)
        scanRange = try Self.decodeScanRange(from: c)
    }

    /// `clues.json` uses quoted scan ranges (`"22"`) in addition to numeric JSON.
    private static func decodeScanRange(from c: KeyedDecodingContainer<CodingKeys>) throws -> Int? {
        guard c.contains(.scanRange) else { return nil }
        if try c.decodeNil(forKey: .scanRange) { return nil }
        if let i = try? c.decode(Int.self, forKey: .scanRange) { return i }
        if let s = try? c.decode(String.self, forKey: .scanRange) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(t)
        }
        return nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(difficulty, forKey: .difficulty)
        try c.encode(clue, forKey: .clue)
        try c.encode(solution, forKey: .solution)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(coordinates, forKey: .coordinates)
        try c.encodeIfPresent(mapId, forKey: .mapId)
        try c.encodeIfPresent(imageRef, forKey: .imageRef)
        try c.encodeIfPresent(travel, forKey: .travel)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(scanTextAliases, forKey: .scanTextAliases)
        try c.encodeIfPresent(scanRange, forKey: .scanRange)
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

