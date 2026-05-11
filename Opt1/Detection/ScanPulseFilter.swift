import Foundation

// MARK: - Scan Pulse

/// The three pulse states an orb emits relative to a player position.
enum ScanPulse: CaseIterable, Hashable {
    case single, double, triple

    var label: String {
        switch self {
        case .single: return "Single"
        case .double: return "Double"
        case .triple: return "Triple"
        }
    }
}

// MARK: - Scan Pulse Filter

/// Filters scan clue dig spots based on the observed orb pulse and the player's
/// current tile position.
///
/// Scan mechanics use Chebyshev distance (max of horizontal and vertical
/// tile offsets). Given scan range R:
///   - Triple pulse: player is within R tiles of the spot.
///   - Double pulse: player is between R+1 and 2R tiles away.
///   - Single pulse: player is beyond 2R tiles away.
///
/// "Different level" is excluded — it requires per-spot floor data not currently
/// stored in `clues.json`.
struct ScanPulseFilter {

    // MARK: - Distance

    /// Chebyshev distance between two game-tile positions.
    static func chebyshev(from player: (x: Int, y: Int),
                          to spot: (x: Int, y: Int)) -> Int {
        max(abs(player.x - spot.x), abs(player.y - spot.y))
    }

    // MARK: - Pulse Calculation

    /// Returns the pulse the player would observe from `player` for a spot at `spot`
    /// with the given scan `range`.
    static func pulse(from player: (x: Int, y: Int),
                      to spot: (x: Int, y: Int),
                      range: Int) -> ScanPulse {
        let d = chebyshev(from: player, to: spot)
        if d <= range         { return .triple }
        if d <= range * 2     { return .double }
        return .single
    }

    // MARK: - Filtering

    /// Returns the set of spot IDs that would produce `pulse` when scanned from
    /// `player` with the given `range`.
    ///
    /// - Parameters:
    ///   - coords: Pre-parsed spot coordinates as `(id, x, y)` triples.
    ///   - player: Player's current game-tile position.
    ///   - range:  Effective scan range (including any familiar bonuses).
    ///   - pulse:  The observed pulse to filter for.
    static func survivingIDs(from coords: [(id: String, x: Int, y: Int)],
                              player: (x: Int, y: Int),
                              range: Int,
                              pulse: ScanPulse) -> Set<String> {
        Set(coords
            .filter { Self.pulse(from: player, to: ($0.x, $0.y), range: range) == pulse }
            .map(\.id)
        )
    }
}
