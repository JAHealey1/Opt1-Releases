import SwiftUI
import Opt1Solvers

// MARK: - Lockbox Solution

/// Compact header shown in the side panel.
/// When `gridBoundsOnScreen` is set the full grid is rendered directly on-screen
/// by `LockboxGridOverlayView`, so only the summary line is shown here.
/// Falls back to the full grid when on-screen bounds are unavailable.
struct LockboxSolutionView: View {
    let solution: LockboxSolution

    private var hasOnScreenGrid: Bool { solution.gridBoundsOnScreen != nil }

    var body: some View {
        if hasOnScreenGrid {
            // Compact header: target style + total clicks.
            HStack(spacing: 10) {
                Circle()
                    .fill(OverlayTheme.gold)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LOCKBOX — click to \(solution.targetStyle.description.uppercased())")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(OverlayTheme.gold)
                    Text("\(solution.totalClicks) total click\(solution.totalClicks == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundColor(OverlayTheme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(OverlayTheme.bgPrimary.opacity(OverlayTheme.bgPrimaryOp))
            .cornerRadius(OverlayTheme.cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius)
                .strokeBorder(OverlayTheme.goldBorder.opacity(0.55), lineWidth: OverlayTheme.borderWidth))
        } else {
            // Fallback: full grid in the side panel (no on-screen bounds available).
            VStack(spacing: 6) {
                Text("LOCKBOX — click to \(solution.targetStyle.description.uppercased())")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(OverlayTheme.gold)

                Text("\(solution.totalClicks) total click\(solution.totalClicks == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundColor(OverlayTheme.textSecondary)

                VStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { row in
                        HStack(spacing: 3) {
                            ForEach(0..<5, id: \.self) { col in
                                LockboxFallbackCell(clicks: solution.clicks[row][col])
                            }
                        }
                    }
                }
            }
            .padding(10)
            .background(OverlayTheme.bgPrimary.opacity(OverlayTheme.bgPrimaryOp))
            .cornerRadius(OverlayTheme.cornerRadius)
            .overlay(RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius)
                .strokeBorder(OverlayTheme.goldBorder.opacity(0.55), lineWidth: OverlayTheme.borderWidth))
        }
    }
}

private struct LockboxFallbackCell: View {
    let clicks: Int

    var color: Color {
        switch clicks {
        case 0:  return OverlayTheme.textSecondary.opacity(0.4)
        case 1:  return OverlayTheme.gold
        default: return Color(red: 1.0, green: 0.55, blue: 0.15)
        }
    }

    var label: String { clicks == 0 ? "·" : "\(clicks)" }

    var body: some View {
        Text(label)
            .font(.system(size: 18, weight: clicks == 0 ? .light : .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 34, height: 34)
            .background(clicks == 0 ? Color.white.opacity(0.04) : color.opacity(0.15))
            .cornerRadius(5)
    }
}

// MARK: - Lockbox On-Screen Grid Overlay

/// Passthrough overlay placed directly over the 5×5 lockbox grid on screen.
/// Each cell with >0 clicks shows a coloured number badge at its centre.
struct LockboxGridOverlayView: View {
    let solution: LockboxSolution
    let panelSize: CGSize

    var body: some View {
        ZStack {
            Color.clear
            GeometryReader { geo in
                let cellW = geo.size.width  / 5
                let cellH = geo.size.height / 5
                ForEach(0..<5, id: \.self) { row in
                    ForEach(0..<5, id: \.self) { col in
                        let clicks = solution.clicks[row][col]
                        if clicks > 0 {
                            LockboxCellBadge(clicks: clicks)
                                .position(
                                    x: CGFloat(col) * cellW + cellW / 2,
                                    y: CGFloat(row) * cellH + cellH / 2
                                )
                        }
                    }
                }
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }
}

private struct LockboxCellBadge: View {
    let clicks: Int

    private var color: Color {
        clicks == 1 ? OverlayTheme.gold : Color(red: 1.0, green: 0.55, blue: 0.15)
    }

    var body: some View {
        Text("\(clicks)")
            .font(.system(size: 20, weight: .black, design: .rounded))
            .foregroundColor(color)
            .shadow(color: .black, radius: 1, x: 0, y: 0)
            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
    }
}

// MARK: - Towers Solution

/// Shows the solved 5×5 grid with the edge-hint numbers as context.
struct TowersSolutionView: View {
    let solution: TowersSolution
    let hints: TowersHints

    /// Distinct colours for tower heights 1-5.
    private static let heightColors: [Color] = [
        .purple, .blue, .green, .yellow, .red
    ]

    private func color(for value: Int) -> Color {
        guard (1...5).contains(value) else { return .gray }
        return Self.heightColors[value - 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("TOWERS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.6))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(OverlayTheme.gold.opacity(0.85)))
                Spacer()
                Text("MASTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Divider().opacity(0.25)

            // Legend
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { v in
                    HStack(spacing: 3) {
                        Circle().fill(color(for: v)).frame(width: 6, height: 6)
                        Text("\(v)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)

            Spacer(minLength: 4)

            // 7×7 layout: hint ring + 5×5 solution grid
            VStack(spacing: 2) {
                // Top hint row
                HStack(spacing: 2) {
                    TowersHintCell(value: nil)   // corner
                    ForEach(0..<5, id: \.self) { c in TowersHintCell(value: hints.top[c]) }
                    TowersHintCell(value: nil)   // corner
                }
                // Grid rows with left/right hints
                ForEach(0..<5, id: \.self) { r in
                    HStack(spacing: 2) {
                        TowersHintCell(value: hints.left[r])
                        ForEach(0..<5, id: \.self) { c in
                            TowersSolvedCell(value: solution.grid[r][c], color: color(for: solution.grid[r][c]))
                        }
                        TowersHintCell(value: hints.right[r])
                    }
                }
                // Bottom hint row
                HStack(spacing: 2) {
                    TowersHintCell(value: nil)
                    ForEach(0..<5, id: \.self) { c in TowersHintCell(value: hints.bottom[c]) }
                    TowersHintCell(value: nil)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

private struct TowersSolvedCell: View {
    let value: Int
    let color: Color

    var body: some View {
        Text("\(value)")
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }
}

private struct TowersHintCell: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(OverlayTheme.textSecondary)
            .frame(width: 30, height: 30)
    }
}

// MARK: - Celtic Knot Solution

private struct CelticKnotTrackInfo {
    let name: String
    let color: Color
    let cwHint: String
    let ccwHint: String

    static let tracks: [CelticKnotTrackInfo] = [
        CelticKnotTrackInfo(name: "Gold", color: .yellow, cwHint: "left ▲", ccwHint: "left ▼"),
        CelticKnotTrackInfo(name: "Dark", color: Color(white: 0.55), cwHint: "right ▲", ccwHint: "right ▼"),
        CelticKnotTrackInfo(name: "Blue", color: .blue, cwHint: "left ◀", ccwHint: "right ▶"),
        CelticKnotTrackInfo(name: "Grey", color: .gray, cwHint: "upper arrow", ccwHint: "lower arrow"),
    ]

    static func info(for index: Int) -> CelticKnotTrackInfo {
        if index < tracks.count { return tracks[index] }
        return CelticKnotTrackInfo(name: "Track\(index+1)", color: .white, cwHint: "▲", ccwHint: "▼")
    }
}

struct CelticKnotSolutionView: View {
    let solution: CelticKnotSolution

    var body: some View {
        VStack(spacing: 0) {
            celticKnotHeader
            Divider().opacity(0.25)
            celticKnotRows
            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .fill(OverlayTheme.bgPrimary.opacity(OverlayTheme.bgPrimaryOp))
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.goldBorder.opacity(0.50), lineWidth: OverlayTheme.borderWidth)
        )
    }

    private var celticKnotHeader: some View {
        HStack(spacing: 8) {
            Text("CELTIC KNOT")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.black.opacity(0.6))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(OverlayTheme.gold.opacity(0.85)))
            Spacer()
            Text("\(solution.totalClicks) total clicks")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(OverlayTheme.textSecondary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private var celticKnotRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(solution.rotations.enumerated()), id: \.offset) { idx, rotation in
                CelticKnotTrackRow(index: idx, rotation: rotation, physicalRotation: solution.physicalRotation(at: idx))
            }
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }
}

private struct CelticKnotTrackRow: View {
    let index: Int
    let rotation: Int
    let physicalRotation: Int

    var body: some View {
        let info = CelticKnotTrackInfo.info(for: index)
        HStack(spacing: 8) {
            Text(info.name)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(info.color)
                .frame(width: 48, alignment: .leading)

            if rotation == 0 {
                Text("no move")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(OverlayTheme.textSecondary.opacity(0.6))
            } else {
                let dir = physicalRotation > 0 ? "CW" : "CCW"
                let count = abs(rotation)
                let clicks = count == 1 ? "click" : "clicks"
                Text("\(count) \(dir)")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(info.color)
                Text("(\(count) \(clicks))")
                    .font(.system(size: 10))
                    .foregroundColor(OverlayTheme.textSecondary)
            }

            Spacer()
        }
    }
}


// MARK: - Celtic Knot Invert Prompt

struct CelticKnotInvertPromptView: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text("Invert Paths needed")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(OverlayTheme.textPrimary)
                Text("Click Invert Paths in-game, then press \(AppSettings.shared.solveHotkey.displayString) again")
                    .font(.system(size: 13))
                    .foregroundColor(OverlayTheme.textSecondary)
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
                .strokeBorder(Color.orange.opacity(0.55), lineWidth: OverlayTheme.borderWidth)
        )
    }
}

// MARK: - Celtic Knot On-Screen Arrow Overlay

struct CelticKnotArrowOverlayView: View {
    let solution: CelticKnotSolution
    let panelSize: CGSize

    private static let trackColors: [Color] = [.yellow, Color(white: 0.55), .blue, .gray]

    var body: some View {
        ZStack {
            Color.clear

            if let arrows = solution.arrowScreenPositions,
               let puzzleRect = solution.puzzleBoundsOnScreen {
                ForEach(Array(solution.rotations.enumerated()), id: \.offset) { idx, rotation in
                    if idx < arrows.count && rotation != 0 {
                        let pair = arrows[idx]
                        let pos = solution.physicalRotation(at: idx) > 0 ? pair.cwPosition : pair.ccwPosition
                        let relativeX = pos.x - puzzleRect.minX
                        let relativeY = pos.y - puzzleRect.minY

                        ArrowClickBadge(
                            clicks: abs(rotation),
                            trackColor: idx < Self.trackColors.count ? Self.trackColors[idx] : .white
                        )
                        .position(x: relativeX, y: relativeY)
                    }
                }
            }
        }
        .frame(width: panelSize.width, height: panelSize.height)
    }
}

private struct ArrowClickBadge: View {
    let clicks: Int
    let trackColor: Color

    var body: some View {
        Text("\(clicks)")
            .font(.system(size: 18, weight: .black, design: .rounded))
            .foregroundColor(.white)
            .frame(minWidth: 30, minHeight: 30)
            .background(
                Circle()
                    .fill(trackColor.opacity(0.85))
                    .shadow(color: .black.opacity(0.7), radius: 3, x: 0, y: 1)
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
            )
    }
}
