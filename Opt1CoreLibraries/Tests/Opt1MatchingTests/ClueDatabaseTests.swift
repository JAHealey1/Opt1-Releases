import Testing
@testable import Opt1Matching

/// Tests that clues.json loads correctly and satisfies basic structural invariants.
/// These tests run against the real bundled database so they also act as
/// a sanity check that the JSON has not been corrupted.
@Suite("ClueDatabase")
struct ClueDatabaseTests {

    private static let knownTypes: Set<String> = [
        "cryptic", "coordinate", "anagram", "map",
        "compass", "scan", "emote", "skill",
        "simple", "challenge",
    ]

    // MARK: - Loading

    @Test("Shared database is non-empty after load")
    func sharedDatabaseNonEmpty() {
        ClueDatabase.shared.load()
        #expect(!ClueDatabase.shared.clues.isEmpty,
                "clues.json should contain at least one clue")
    }

    @Test("Repeated load does not crash")
    func repeatedLoadNoCrash() {
        ClueDatabase.shared.load()
        ClueDatabase.shared.load()
        #expect(!ClueDatabase.shared.clues.isEmpty)
    }

    // MARK: - Required fields

    @Test("Every clue has a non-empty id")
    func allCluesHaveId() {
        ClueDatabase.shared.load()
        for clue in ClueDatabase.shared.clues {
            #expect(!clue.id.isEmpty, "Clue with empty id: \(clue.clue.prefix(40))")
        }
    }

    @Test("Every clue has a non-empty type")
    func allCluesHaveType() {
        ClueDatabase.shared.load()
        for clue in ClueDatabase.shared.clues {
            #expect(!clue.type.isEmpty, "Clue \(clue.id) has empty type")
        }
    }

    @Test("Every clue has a non-empty clue text")
    func allCluesHaveText() {
        ClueDatabase.shared.load()
        for clue in ClueDatabase.shared.clues {
            #expect(!clue.clue.isEmpty, "Clue \(clue.id) has empty clue text")
        }
    }

    // MARK: - Type values are within known set

    @Test("All type values are recognised")
    func allTypesRecognised() {
        ClueDatabase.shared.load()
        let unexpectedTypes = ClueDatabase.shared.clues
            .map(\.type)
            .filter { !Self.knownTypes.contains($0) }
        #expect(unexpectedTypes.isEmpty,
                "Unexpected clue types: \(Set(unexpectedTypes))")
    }

    // MARK: - Type coverage

    @Test("Database contains at least one clue of each core type",
          arguments: ["cryptic", "coordinate", "anagram", "compass"])
    func coreTypesPresent(type: String) {
        ClueDatabase.shared.load()
        let count = ClueDatabase.shared.clues.filter { $0.type == type }.count
        #expect(count > 0, "Expected at least one '\(type)' clue in database")
    }

    // MARK: - ID uniqueness

    @Test("All clue IDs are unique")
    func allIdsUnique() {
        ClueDatabase.shared.load()
        let ids = ClueDatabase.shared.clues.map(\.id)
        let unique = Set(ids)
        #expect(unique.count == ids.count,
                "\(ids.count - unique.count) duplicate IDs in database")
    }
}
