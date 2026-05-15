import Testing
@testable import Opt1Matching

/// End-to-end tests that run `FuzzyMatcher.scanMatches` against the real
/// bundled `clues.json` database.  Each test validates that a given OCR
/// observation — either the verbatim large-scroll clue text, a compact
/// small-scroll alias, or a realistic partial read — resolves to the
/// expected scan region and to no other region.
@Suite("Scan Region Matching")
struct ScanMatchingTests {

    // Load once; `static let` initialisation is thread-safe in Swift.
    private static let allClues: [ClueSolution] = {
        ClueDatabase.shared.load()
        return ClueDatabase.shared.clues
    }()

    // MARK: - Helpers

    private func matches(for observations: [String]) -> [ClueSolution] {
        FuzzyMatcher().scanMatches(forAny: observations, in: Self.allClues)
    }

    // MARK: - Large-scroll clue text → correct location
    //
    // Each entry is the verbatim in-game large-scroll clue text paired with
    // the expected `location` value from clues.json.  These cover every
    // distinct scan region in the database.

    static let largeScrollCases: [(String, String)] = [
        (
            "This scroll will work within the walls of East or West Ardougne. Orb scan range: 22 paces.",
            "Ardougne"
        ),
        (
            "This scroll will work in Brimhaven Dungeon. Orb scan range: 14 paces.",
            "Brimhaven Dungeon"
        ),
        (
            "This scroll will work in Darkmeyer. Orb scan range: 16 paces.",
            "Darkmeyer"
        ),
        (
            "This scroll will work in the deepest levels of the Wilderness. Orb scan range: 25 paces.",
            "Deep Wilderness"
        ),
        (
            "This scroll will work in the cave goblin city of Dorgesh-Kaan. Orb scan range: 16 paces.",
            "Dorgesh-Kaan"
        ),
        (
            "This scroll will work in the desert, east of the Elid and north of Nardah. Orb scan range: 27 paces.",
            "East Kharidian Desert"
        ),
        (
            "This scroll will work within the walls of Falador. Orb scan range: 22 paces.",
            "Falador"
        ),
        (
            "This scroll will work on the Fremennik Isles of Jatizso and Neitiznot. Orb scan range: 16 paces.",
            "Fremennik Isles"
        ),
        (
            "This scroll will work in the Fremennik Slayer Dungeons. Orb scan range: 16 paces.",
            "Fremennik Slayer Dungeon"
        ),
        (
            "This scroll will work within the Haunted Woods. Orb scan range: 11 paces.",
            "Haunted Woods"
        ),
        (
            "This scroll will work around the Heart of Gielinor. Orb scan range: 49 paces.",
            "Heart of Gielinor"
        ),
        (
            "This scroll will work in Isafdar and Lletya. Orb scan range: 22 paces.",
            "Isafdar and Lletya"
        ),
        (
            "This scroll will work within the dwarven city of Keldagrim. Orb scan range: 11 paces.",
            "Keldagrim"
        ),
        (
            "This scroll will work in the Kharazi Jungle. Orb scan range: 14 paces.",
            "Kharazi Jungle"
        ),
        (
            "This scroll will work in the dark and damp caves below Lumbridge Swamp. Orb scan range: 11 paces.",
            "Lumbridge Swamp Caves"
        ),
        (
            "This scroll will work within Menaphos. Orb scan range: 30 paces.",
            "Menaphos"
        ),
        (
            "This scroll will work on the faraway island of Mos Le'Harmless. Orb scan range: 27 paces.",
            "Mos Le'Harmless"
        ),
        (
            "This scroll will work in Piscatoris Hunter Area. Orb scan range: 14 paces.",
            "Piscatoris Hunter Area"
        ),
        (
            "This scroll will work in Prifddinas. Orb scan range: 30 paces.",
            "Prifddinas"
        ),
        (
            "This scroll will work in Taverley Dungeon. Orb scan range: 22 paces.",
            "Taverley Dungeon"
        ),
        (
            "This scroll will work on The Islands That Once Were Turtles. Orb scan range: 27 paces.",
            "The Islands That Once Were Turtles"
        ),
        (
            "This scroll will work in the Lost Grove. Orb scan range: 14 paces.",
            "The Lost Grove"
        ),
        (
            "This scroll will work within the walls of Varrock. Orb scan range: 16 paces.",
            "Varrock"
        ),
        (
            "This scroll will work in the crater of the Wilderness volcano. Orb scan range: 11 paces.",
            "Wilderness Crater"
        ),
        (
            "This scroll will work in the city of Zanaris. Orb scan range: 16 paces.",
            "Zanaris"
        ),
    ]

    @Test(
        "Large scroll clue text identifies correct scan region",
        arguments: largeScrollCases
    )
    func largeScrollTextMatchesLocation(clueText: String, expectedLocation: String) {
        // Given
        let observations = [clueText]

        // When
        let result = matches(for: observations)

        // Then
        #expect(!result.isEmpty,
                "No match found for '\(clueText.prefix(50))...'")
        let locations = Set(result.compactMap(\.location))
        #expect(
            locations == [expectedLocation],
            "Expected [\(expectedLocation)] but got \(locations)"
        )
    }

    // MARK: - Small-scroll (compact parchment) aliases → correct location
    //
    // The compact scan note uses shorter, differently-worded text than the
    // full scroll.  Entries in clues.json carry `scanTextAliases` for these
    // alternates so the matcher can resolve them via Strategy 0.

    static let aliasMatchCases: [(String, String)] = [
        ("The crater in the Wilderness", "Wilderness Crater"),
    ]

    @Test(
        "Small scroll alias text identifies correct scan region",
        arguments: aliasMatchCases
    )
    func aliasTextMatchesLocation(aliasText: String, expectedLocation: String) {
        // Given — the compact scroll typically also shows the scan range line
        let observations = [aliasText, "Orb scan range: 11 paces."]

        // When
        let result = matches(for: observations)

        // Then
        #expect(!result.isEmpty,
                "No match found for alias '\(aliasText)'")
        let locations = Set(result.compactMap(\.location))
        #expect(
            locations == [expectedLocation],
            "Expected [\(expectedLocation)] but got \(locations)"
        )
    }

    // MARK: - Regression: Wilderness Crater alias must not match Deep Wilderness

    @Test("Alias 'The crater in the Wilderness' does not match Deep Wilderness")
    func craterAliasDoesNotMatchDeepWilderness() {
        // Given
        let observations = ["The crater in the Wilderness", "Orb scan range: 11 paces."]

        // When
        let result = matches(for: observations)

        // Then
        #expect(
            result.allSatisfy { $0.location != "Deep Wilderness" },
            "Alias incorrectly matched Deep Wilderness"
        )
    }

    // MARK: - Regression: single-word 'Wilderness' must not produce an ambiguous match
    //
    // Before the reverse-containment fix, a single-word OCR read of "Wilderness"
    // would fire the reverse-containment check against BOTH "Wilderness Crater"
    // (which contains "wilderness") and "Deep Wilderness" (same), returning
    // whichever group happened to be iterated first.  After the fix, single-word
    // queries are excluded from reverse containment, so the result is either
    // empty or a single unambiguous region — never two.

    @Test("Single-word 'Wilderness' observation does not match two different regions")
    func singleWordWildernessIsNotAmbiguous() {
        // Given — OCR reads only the word "Wilderness" from the scroll
        let observations = ["Wilderness"]

        // When
        let result = matches(for: observations)

        // Then — must not blend spots from two different regions
        let locations = Set(result.compactMap(\.location))
        #expect(
            locations.count <= 1,
            "Single-word 'Wilderness' ambiguously matched multiple regions: \(locations)"
        )
    }

    // MARK: - All scan regions have at least one spot in the database

    @Test("Every known scan region has at least one spot loaded from clues.json")
    func allKnownRegionsPresent() {
        let knownLocations = Set(Self.largeScrollCases.map(\.1))
        let loadedLocations = Set(
            Self.allClues
                .filter { $0.type == "scan" }
                .compactMap(\.location)
        )
        let missing = knownLocations.subtracting(loadedLocations)
        #expect(missing.isEmpty, "Missing scan regions in database: \(missing)")
    }
}
