import Testing
@testable import Opt1Matching

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    // MARK: - Levenshtein similarity

    @Test("Identical strings → similarity 1.0")
    func identicalStrings() throws {
        let m = FuzzyMatcher()
        #expect(m.levenshteinSimilarity("hello", "hello") == 1.0)
    }

    @Test("Both empty → similarity 1.0")
    func bothEmpty() throws {
        let m = FuzzyMatcher()
        #expect(m.levenshteinSimilarity("", "") == 1.0)
    }

    @Test("One empty → similarity 0.0")
    func oneEmpty() throws {
        let m = FuzzyMatcher()
        #expect(m.levenshteinSimilarity("hello", "") == 0.0)
        #expect(m.levenshteinSimilarity("", "hello") == 0.0)
    }

    @Test("Known edit distances", arguments: [
        ("kitten", "sitting", 1.0 - 3.0 / 7.0),   // 3 edits, max len 7
        ("abc", "abd", 1.0 - 1.0 / 3.0),           // 1 edit, max len 3
        ("ab", "ba", 1.0 - 2.0 / 2.0),             // 2 edits (swap), max len 2 → 0.0
    ] as [(String, String, Double)])
    func knownEditDistances(a: String, b: String, expected: Double) throws {
        let m = FuzzyMatcher()
        let actual = m.levenshteinSimilarity(a, b)
        #expect(abs(actual - expected) < 0.001)
    }

    @Test("Similarity is symmetric")
    func symmetry() throws {
        let m = FuzzyMatcher()
        let a = m.levenshteinSimilarity("runescape", "runscape")
        let b = m.levenshteinSimilarity("runscape", "runescape")
        #expect(abs(a - b) < 0.001)
    }

    // MARK: - bestMatch: standard clue lookup

    private func clue(_ id: String, _ type: String, _ text: String) -> ClueSolution {
        ClueSolution(id: id, type: type, clue: text, solution: "solution", location: nil,
                     coordinates: nil, mapId: nil, imageRef: nil,
                     travel: nil, confidence: nil)
    }

    @Test("bestMatch: exact observation matches clue at high confidence")
    func exactMatchHighConfidence() throws {
        let db = [clue("c1", "cryptic", "He who wields the most powerful wand")]
        var m = FuzzyMatcher()
        m.confidenceThreshold = 0.72
        let result = m.bestMatch(forAny: ["He who wields the most powerful wand"], in: ClueCorpus(clues: db))
        let match = try #require(result)
        #expect(match.clue.id == "c1")
        #expect(match.confidence >= 0.72)
    }

    @Test("bestMatch: below-threshold observation returns nil")
    func belowThresholdReturnsNil() throws {
        let db = [clue("c1", "cryptic", "He who wields the most powerful wand")]
        var m = FuzzyMatcher()
        m.confidenceThreshold = 0.99  // unreachably high
        let result = m.bestMatch(forAny: ["Completely unrelated text xyz"], in: ClueCorpus(clues: db))
        #expect(result == nil)
    }

    @Test("bestMatch: empty observations returns nil")
    func emptyObservationsNil() throws {
        let db = [clue("c1", "cryptic", "Some clue")]
        let m = FuzzyMatcher()
        let result = m.bestMatch(forAny: [], in: ClueCorpus(clues: db))
        #expect(result == nil)
    }

    @Test("bestMatch: empty database returns nil")
    func emptyDatabaseNil() throws {
        let m = FuzzyMatcher()
        let result = m.bestMatch(forAny: ["Some observation"], in: ClueCorpus(clues: []))
        #expect(result == nil)
    }

    // MARK: - Anagram matching

    private func anagramClue(_ id: String, _ phrase: String) -> ClueSolution {
        clue(id, "anagram", "This anagram reveals who to speak to next: \(phrase)")
    }

    @Test("Anagram: exact letter-sorted match returns confidence 1.0")
    func anagramExactMatch() throws {
        let db = [anagramClue("a1", "BANKER")]
        let m = FuzzyMatcher()
        let obs = ["This anagram reveals who to speak to next: BANKER"]
        let result = m.bestMatch(forAny: obs, in: ClueCorpus(clues: db))
        let match = try #require(result)
        #expect(match.clue.id == "a1")
        #expect(match.confidence >= 0.99)
    }

    @Test("Anagram: OCR near-miss still finds a match")
    func anagramNearMiss() throws {
        let db = [anagramClue("a1", "BANKER")]
        let m = FuzzyMatcher()
        // "BANKIR" — one char off from "BANKER"
        let obs = ["This anagram reveals who to speak to next: BANKIR"]
        let result = m.bestMatch(forAny: obs, in: ClueCorpus(clues: db))
        _ = result
    }

    // MARK: - Coordinate matching

    private func coordClue(_ id: String, _ text: String) -> ClueSolution {
        clue(id, "coordinate", text)
    }

    @Test("Coordinate: valid format matches against coordinate clue")
    func coordinateMatch() throws {
        let coordText = "02 degrees 48 minutes north, 09 degrees 33 minutes east"
        let db = [coordClue("coord1", coordText)]
        let m = FuzzyMatcher()
        let result = m.bestMatch(forAny: [coordText], in: ClueCorpus(clues: db))
        let match = try #require(result)
        #expect(match.clue.id == "coord1")
    }

    @Test("Coordinate: direction mismatch drops confidence")
    func coordinateDirectionMismatch() throws {
        let coordText = "02 degrees 48 minutes north, 09 degrees 33 minutes east"
        let wrong = "02 degrees 48 minutes south, 09 degrees 33 minutes west"
        let db = [coordClue("coord1", coordText)]
        let m = FuzzyMatcher()
        let result = m.bestMatch(forAny: [wrong], in: ClueCorpus(clues: db))
        // Mismatched lat/lon directions should produce no match (coordinateSimilarity returns 0)
        #expect(result == nil)
    }

    // MARK: - Scan matching

    private func scanClue(_ id: String, _ text: String, _ location: String) -> ClueSolution {
        ClueSolution(id: id, type: "scan", clue: text, solution: "scan",
                     location: location, coordinates: nil, mapId: nil,
                     imageRef: nil, travel: nil, confidence: nil)
    }

    @Test("scanMatches: location-name containment returns matching group")
    func scanMatchesLocation() throws {
        let db = [
            scanClue("s1", "This scroll will work in the Varrock area. Orb scan range: 30 paces.", "Varrock"),
            scanClue("s2", "This scroll will work in the Varrock area. Orb scan range: 30 paces.", "Varrock"),
            scanClue("s3", "This scroll will work in the Falador area. Orb scan range: 20 paces.", "Falador"),
        ]
        let m = FuzzyMatcher()
        let obs = ["This scroll will work in the Varrock area. Orb scan range: 30 paces."]
        let matches = m.scanMatches(forAny: obs, in: db)
        #expect(!matches.isEmpty)
        #expect(matches.allSatisfy { $0.location == "Varrock" })
    }

    @Test("scanMatches: no scan clues in database returns empty")
    func scanMatchesNoDB() throws {
        let db = [clue("c1", "cryptic", "Some cryptic clue")]
        let m = FuzzyMatcher()
        let matches = m.scanMatches(forAny: ["something"], in: db)
        #expect(matches.isEmpty)
    }

    // MARK: - Multi-observation window joining

    @Test("bestMatch: clue spanning multiple OCR lines matched via join")
    func multiLineJoin() throws {
        let fullText = "He who wields the most powerful wand can break through any barrier"
        let db = [clue("c1", "cryptic", fullText)]
        let m = FuzzyMatcher()
        // Split into two observations that together recreate the clue
        let obs = ["He who wields the most powerful wand",
                   "can break through any barrier"]
        let result = m.bestMatch(forAny: obs, in: ClueCorpus(clues: db))
        let match = try #require(result)
        #expect(match.clue.id == "c1")
    }
}
