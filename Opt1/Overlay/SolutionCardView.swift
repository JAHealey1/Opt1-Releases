import SwiftUI
import Opt1Matching

// MARK: - Solution Card (Phase 3+)

struct SolutionCardView: View {
    let solution: ClueSolution

    @State private var copied     = false
    /// nil = loading, true = tiles present, false = no tiles for this region.
    /// When false the map view suppresses itself and the card collapses around
    /// the text content.
    @State private var mapState: Bool? = nil

    /// Parses "x,y" game-tile coordinate strings.
    private func parseGameCoords(_ str: String?) -> (Int, Int)? {
        guard let str else { return nil }
        let parts = str.split(separator: ";").flatMap { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        guard parts.count >= 2, let x = Int(parts[0]), let y = Int(parts[1]) else { return nil }
        return (x, y)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header bar
            HStack(spacing: 8) {
                Text(solution.type.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(OverlayTheme.gold.opacity(0.85)))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.25)

            // Map — rendered first so text always sits below it.
            // RSWorldMapView uses a fixed 280 pt viewport and suppresses itself
            // when no tiles are cached for the region.
            if let coords = parseGameCoords(solution.coordinates), mapState != false {
                RSWorldMapView(gameX: coords.0, gameY: coords.1,
                               mapId: solution.mapId ?? MapTileCache.defaultMapId,
                               hasTiles: $mapState)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            // Primary answer — NPC name for anagrams, dig/search instruction for others
            Text(solution.solution)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(OverlayTheme.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // Secondary location detail — only when it adds information beyond the primary
            if let loc = solution.location,
               !loc.isEmpty,
               loc.lowercased() != solution.solution.lowercased() {
                Text(loc)
                    .font(.system(size: 11))
                    .foregroundColor(OverlayTheme.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }

            // Travel suggestions
            if let travel = solution.travel, !travel.isEmpty {
                Divider().opacity(0.15).padding(.horizontal, 12).padding(.top, 6)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.triangle.turn.up.right.circle")
                        .font(.system(size: 10))
                        .foregroundColor(OverlayTheme.gold.opacity(0.7))
                        .padding(.top, 1)
                    Text(travel)
                        .font(.system(size: 10))
                        .foregroundColor(OverlayTheme.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            Spacer(minLength: 8)
        }
        // maxWidth fills the window; height is driven by content.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .fill(OverlayTheme.bgPrimary.opacity(OverlayTheme.bgPrimaryOp))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.goldBorder.opacity(0.50), lineWidth: OverlayTheme.borderWidth)
        )
    }
}

