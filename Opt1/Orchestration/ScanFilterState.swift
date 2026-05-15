import Foundation
import Opt1Matching

// MARK: - Scan Filter State

/// Persistent state for an active scan clue overlay.
///
/// Accumulates position + pulse observations as the player moves between
/// scan positions. `survivingIDs` is the intersection of all observations —
/// each new observation narrows the candidate set further.
///
/// Owned by `OverlayPresenter` for the lifetime of the scan overlay session,
/// so re-detections of the same region (e.g. repeated Opt+1 presses) do not
/// reset the accumulated observations.
@MainActor
final class ScanFilterState: ObservableObject {

    // MARK: - Observation

    struct Observation: Identifiable {
        let id = UUID()
        let x: Int
        let y: Int
        let pulse: ScanPulse
    }

    // MARK: - Published state

    @Published var observations:    [Observation] = []
    @Published var pendingPos:       (x: Int, y: Int)? = nil
    @Published var survivingIDs:     Set<String> = []
    /// The next recommended observation position, re-computed after every
    /// observation. `nil` when ≤1 candidate remains or no good split exists.
    @Published var recommendedStep:  RecommendedScanStep? = nil

    // MARK: - Fixed data

    let region:    String
    let scanRange: String
    let spots:     [ClueSolution]
    let mapId:     Int

    /// Pre-parsed spot coordinates for Chebyshev distance math.
    let allCoords: [(id: String, x: Int, y: Int)]

    var onClose: (() -> Void)? = nil

    private var rangeInt: Int { Int(scanRange) ?? 0 }

    // MARK: - Init

    init(region: String, scanRange: String, spots: [ClueSolution]) {
        self.region    = region
        self.scanRange = scanRange
        self.spots     = spots
        self.mapId     = spots.compactMap(\.mapId).first ?? MapTileCache.defaultMapId
        self.allCoords = spots.compactMap { spot in
            guard let c = spot.coordinates else { return nil }
            let parts = c.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let x = Int(parts[0]),
                  let y = Int(parts[1]) else { return nil }
            return (spot.id, x, y)
        }
        // Compute the initial recommendation from all spots (no observations yet).
        // preferTeleports: true — the player hasn't moved yet, so any teleport
        // into the region is a free first reading.
        if AppSettings.isScanNextSpotEnabled {
            let allIDs = Set(self.allCoords.map(\.id))
            self.recommendedStep = ScanOptimiser.recommend(
                surviving:       allIDs,
                allCoords:       self.allCoords,
                range:           Int(scanRange) ?? 0,
                mapId:           self.mapId,
                preferTeleports: true
            )
        }
    }

    // MARK: - Mutation

    /// Records the double-tapped map position as the pending scan origin.
    func setPendingPos(_ pos: (x: Int, y: Int)) {
        pendingPos = pos
    }

    /// Locks in the pending position with the observed pulse, appending a new
    /// observation and recomputing the surviving candidate set.
    ///
    /// If the user hasn't double-tapped a position, falls back to the current
    /// recommended step's position so they can confirm a pulse without needing
    /// to explicitly select the suggested tile first.
    func confirmPulse(_ pulse: ScanPulse) {
        let pos: (x: Int, y: Int)
        if let p = pendingPos {
            pos = p
        } else if let s = recommendedStep {
            pos = (s.x, s.y)
        } else {
            return
        }
        observations.append(Observation(x: pos.x, y: pos.y, pulse: pulse))
        pendingPos = nil
        recompute()
    }

    /// Removes the most recent confirmed observation and recomputes.
    func undoLast() {
        guard !observations.isEmpty else { return }
        observations.removeLast()
        recompute()
    }

    /// Clears all observations and resets to the unfiltered state.
    func clearAll() {
        observations = []
        pendingPos   = nil
        survivingIDs = []
        updateRecommendation()
    }

    /// Re-runs the recommendation from the current surviving set without
    /// recording a new observation. Call this when user preferences change
    /// mid-session — e.g. after the user disables a teleport.
    func refreshRecommendation() {
        updateRecommendation()
    }

    // MARK: - Filter computation

    private func recompute() {
        guard !observations.isEmpty else {
            survivingIDs = []
            updateRecommendation()
            return
        }
        var surviving: Set<String>? = nil
        for obs in observations {
            let ids = ScanPulseFilter.survivingIDs(
                from: allCoords,
                player: (obs.x, obs.y),
                range: rangeInt,
                pulse: obs.pulse
            )
            surviving = surviving == nil ? ids : surviving!.intersection(ids)
        }
        survivingIDs = surviving ?? []
        updateRecommendation()
    }

    // MARK: - Recommendation

    private func updateRecommendation() {
        guard AppSettings.isScanNextSpotEnabled else {
            recommendedStep = nil
            return
        }
        // When no observations are recorded yet, recommend from the full set.
        let ids: Set<String>
        if observations.isEmpty {
            ids = Set(allCoords.map(\.id))
        } else {
            ids = survivingIDs
        }
        // Use the most recent confirmed observation as a proxy for where the
        // player currently is, so the optimiser can prefer nearby candidates.
        let playerPos = observations.last.map { ($0.x, $0.y) }
        recommendedStep = ScanOptimiser.recommend(
            surviving:       ids,
            allCoords:       allCoords,
            range:           rangeInt,
            mapId:           mapId,
            preferTeleports: observations.isEmpty,
            playerPos:       playerPos
        )
    }
}
