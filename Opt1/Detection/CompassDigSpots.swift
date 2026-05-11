import Foundation
import Opt1Matching

// MARK: - Known compass dig spot

/// One fixed RS3 compass dig spot, projected from the bundled `clues.json`.
struct DigSpot: Equatable {
    /// Game-tile X coordinate.
    let x: Int
    /// Game-tile Y coordinate.
    let y: Int
    /// Region name shown by the compass (e.g. "Asgarnia").
    let clue: String
    /// Human-readable dig description.
    let solution: String
}

// MARK: - Catalogue

/// Projection of the bundled compass clue list into a lightweight `DigSpot`
/// array. Used by the Elite compass overlay's "show all dig spots" toggle.
///
/// The bundled `clues.json` ships every compass entry from the wiki covering
/// both elite surface compass clues and master Arc (Eastern Lands) compass
/// clues. The compass overlay uses mapId 28 (main world), whose tile router
/// already handles Eastern Lands tiles when the user pans there — so both
/// sets of dig spots are valid to display on the same map.
enum CompassDigSpots {

    /// Every compass dig spot (elite surface + master Arc) from the bundled
    /// database. Evaluated lazily on first access, initialised exactly once.
    static let all: [DigSpot] = loadFromDatabase()

    private static func loadFromDatabase() -> [DigSpot] {
        let clues = ClueDatabase.shared.clues
        var spots: [DigSpot] = []
        spots.reserveCapacity(clues.count / 3)

        for clue in clues where clue.type == "compass" {
            guard let raw = clue.coordinates,
                  let spot = parse(coordinates: raw, clue: clue)
            else { continue }
            spots.append(spot)
        }

        print("[Opt1] CompassDigSpots: loaded \(spots.count) dig spot(s) (surface + Arc)")
        return spots
    }

    /// Parses a single-point compass coordinate string (e.g. `"2878,3529"`).
    /// Returns nil for box-list strings (`"x1,y1;x2,y2"`) or malformed input.
    private static func parse(coordinates: String, clue: ClueSolution) -> DigSpot? {
        guard !coordinates.contains(";") else { return nil }
        let parts = coordinates
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let x = Int(parts[0]),
              let y = Int(parts[1])
        else { return nil }
        return DigSpot(x: x, y: y, clue: clue.clue, solution: clue.solution)
    }
}
