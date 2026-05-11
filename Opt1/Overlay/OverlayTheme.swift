import SwiftUI
import Opt1Solvers
import Opt1Matching

// MARK: - Overlay Theme

/// Colour palette drawn from the app icon:
///   • Warm dark background  — dark leather/parchment (replaces flat black)
///   • Gold accent           — brass magnifying glass + the map's metal tones
///   • Parchment text        — warm off-white instead of pure white
///   • Accent red            — the "X" mark on the treasure map
///   • Icon blue             — gradient background of the app icon (Elite Compass)
enum OverlayTheme {
    // Backgrounds — warm dark leather/parchment
    static let bgPrimary    = Color(red: 0.10, green: 0.08, blue: 0.04)
    static let bgDeep       = Color(red: 0.07, green: 0.05, blue: 0.02)
    static let bgPrimaryOp: Double = 0.93

    // Gold — brass magnifying glass / coin metal
    static let gold         = Color(red: 1.00, green: 0.80, blue: 0.25)
    static let goldBorder   = Color(red: 0.90, green: 0.70, blue: 0.22)

    // Parchment text — warm off-white
    static let textPrimary  = Color(red: 0.95, green: 0.90, blue: 0.78)
    static let textSecondary = Color(red: 0.72, green: 0.67, blue: 0.53)

    // Icon blue — app icon gradient; used for Elite Compass accents
    static let iconBlue     = Color(red: 0.00, green: 0.53, blue: 1.00)

    // Standard radii / widths
    static let cornerRadius: CGFloat = 12
    static let borderWidth:  CGFloat = 1.0
}

// MARK: - Overlay Mode

enum OverlayMode {
    case phase1Confirmation
    case rawOCR(String)
    case solution(ClueSolution)
    case scanList(state: ScanFilterState)
    case lockbox(solution: LockboxSolution)
    case towers(solution: TowersSolution, hints: TowersHints)
    case celticKnot(solution: CelticKnotSolution)
    case celticKnotNeedsInvert
    case eliteCompass(state: CompassTriangulationState)
    case error

    var messageLineLimit: Int {
        switch self {
        case .rawOCR: return 6
        default:      return 3
        }
    }

    /// Width × height in points for the overlay panel.
    var preferredSize: CGSize {
        switch self {
        case .towers:              return CGSize(width: 280, height: 320)
        case .lockbox:             return CGSize(width: 240, height: 240)
        case .celticKnot:          return CGSize(width: 320, height: 200)
        case .scanList:            return CGSize(width: 480, height: 560)
        case .eliteCompass:
            // Honour any user-chosen size from a previous resize. The panel
            // itself enforces the minimum via `contentMinSize`, so we don't
            // re-clamp here.
            return AppSettings.shared.eliteCompassPanelSize
                ?? AppSettings.defaultEliteCompassSize
        case .solution(let clue):
            let isCoord   = clue.coordinates != nil
            let hasTravel = clue.travel != nil
            let height: CGFloat
            if isCoord {
                // 280 pt map + header + solution text + coords row + padding
                height = 550
            } else {
                height = hasTravel ? 230 : 150
            }
            return CGSize(width: 480, height: height)
        default:            return CGSize(width: 480, height: 150)
        }
    }

    var tintColor: Color {
        switch self {
        case .phase1Confirmation, .solution, .scanList, .lockbox, .towers,
             .celticKnot, .eliteCompass:
            return OverlayTheme.gold
        case .celticKnotNeedsInvert: return .orange
        case .rawOCR:                return OverlayTheme.iconBlue
        case .error:                 return .red
        }
    }

    var borderColor: Color { tintColor.opacity(0.50) }
}

// MARK: - Gold toggle style

/// Compact macOS-style switch tinted gold in the on-state. Used in place of
/// `.toggleStyle(.switch).tint(...)` because `.tint` is unreliable on
/// mini-sized switches and the system may override it.
struct GoldToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn
                          ? OverlayTheme.gold.opacity(0.85)
                          : Color.white.opacity(0.18))
                    .overlay(
                        Capsule().strokeBorder(
                            configuration.isOn
                                ? OverlayTheme.goldBorder.opacity(0.55)
                                : Color.white.opacity(0.20),
                            lineWidth: 0.5
                        )
                    )
                    .frame(width: 26, height: 14)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 11, height: 11)
                    .padding(1.5)
            }
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
