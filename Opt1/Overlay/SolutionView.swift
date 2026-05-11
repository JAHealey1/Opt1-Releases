import SwiftUI

// MARK: - Solution View

struct SolutionView: View {
    let mode: OverlayMode
    let message: String
    let detail: String

    var body: some View {
        switch mode {
        case .solution(let clue):
            SolutionCardView(solution: clue)
        case .scanList(let state):
            ScanListView(state: state)
        case .lockbox(let solution):
            LockboxSolutionView(solution: solution)
        case .towers(let solution, let hints):
            TowersSolutionView(solution: solution, hints: hints)
        case .celticKnot(let solution):
            CelticKnotSolutionView(solution: solution)
        case .celticKnotNeedsInvert:
            CelticKnotInvertPromptView()
        case .eliteCompass(let state):
            EliteCompassView(state: state)
        default:
            BannerView(mode: mode, message: message, detail: detail)
        }
    }
}

// MARK: - Banner (Phase 1 confirmation, raw OCR, errors)

private struct BannerView: View {
    let mode: OverlayMode
    let message: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(mode.tintColor)
                .frame(width: 8, height: 8)
                .shadow(color: mode.tintColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(OverlayTheme.textPrimary)
                    .lineLimit(mode.messageLineLimit)
                    .fixedSize(horizontal: false, vertical: true)

                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(OverlayTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .fill(OverlayTheme.bgPrimary.opacity(OverlayTheme.bgPrimaryOp))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .strokeBorder(mode.borderColor, lineWidth: OverlayTheme.borderWidth)
        )
    }
}
