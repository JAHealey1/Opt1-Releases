import AppKit
import SwiftUI
import Opt1Matching

// MARK: - Scan List View

/// Persistent overlay for scan clue triangulation.
///
/// The user double-taps the map to mark each scan position, then selects
/// the observed pulse. Each position+pulse pair is an observation. The
/// surviving candidate set is the intersection of all observations — each
/// new observation narrows the candidates further.
struct ScanListView: View {
    @ObservedObject var state: ScanFilterState
    @State private var hasTiles: Bool? = nil

    // MARK: - Derived data

    /// Centroid of all spots — used as the initial map focal point.
    private var centroid: (x: Int, y: Int) {
        let c = state.allCoords
        guard !c.isEmpty else { return (0, 0) }
        return (c.map(\.x).reduce(0, +) / c.count,
                c.map(\.y).reduce(0, +) / c.count)
    }

    /// True when observations have narrowed the candidate set.
    private var filterActive: Bool { !state.survivingIDs.isEmpty }

    /// Spots that survive the active filter (or all spots when no filter).
    private var activePins: [(x: Int, y: Int)] {
        let src = filterActive
            ? state.allCoords.filter { state.survivingIDs.contains($0.id) }
            : state.allCoords
        return src.map { (x: $0.x, y: $0.y) }
    }

    /// Game-tile position for the `ScanOptimiser` recommendation marker, or
    /// `nil` when no recommendation is available. Kept as a computed property
    /// so the tuple conversion doesn't confuse Swift's ViewBuilder with
    /// collection `.map` overloads.
    private var recommendedMapPin: (x: Int, y: Int)? {
        guard let step = state.recommendedStep else { return nil }
        return (x: step.x, y: step.y)
    }

    /// Spots eliminated by the filter — shown dimmed rather than removed.
    private var dimmedPins: [(x: Int, y: Int)] {
        guard filterActive else { return [] }
        return state.allCoords
            .filter { !state.survivingIDs.contains($0.id) }
            .map { (x: $0.x, y: $0.y) }
    }

    /// Confirmed observation positions + pending position (if any).
    private var playerPins: [(x: Int, y: Int)] {
        var pins = state.observations.map { (x: $0.x, y: $0.y) }
        if let p = state.pendingPos { pins.append((x: p.x, y: p.y)) }
        return pins
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Text("SCAN")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.black.opacity(0.6))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(OverlayTheme.gold.opacity(0.85)))
                if !state.scanRange.isEmpty {
                    Text("range: \(state.scanRange)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }
                Text(state.region)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(OverlayTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(state.spots.count) spots")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                Button(action: { state.onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(OverlayTheme.gold.opacity(0.8))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(OverlayTheme.gold.opacity(0.12)))
                        .overlay(Circle().strokeBorder(OverlayTheme.gold.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close scan overlay")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)

            Divider().opacity(0.25)

            // ── Map ───────────────────────────────────────────────────────
            if hasTiles != false, !state.allCoords.isEmpty {
                let c = centroid
                RSWorldMapView(
                    gameX:     c.x,
                    gameY:     c.y,
                    mapId:     state.mapId,
                    extraPins: activePins,
                    viewportHeight: .infinity,
                    hasTiles:  $hasTiles,
                    showPrimaryPin: false,
                    onMapDoubleTap: { gx, gy in
                        state.setPendingPos((gx, gy))
                    },
                    dimmedPins:    dimmedPins,
                    playerPins:    playerPins,
                    recommendedPin: recommendedMapPin
                )
            }

            Divider().opacity(0.25)

            // ── Recommendation row ────────────────────────────────────────
            if let step = state.recommendedStep {
                HStack(spacing: 6) {
                    Image(systemName: step.isTeleport
                          ? "arrow.triangle.2.circlepath"
                          : "mappin.circle")
                        .font(.system(size: 10))
                        .foregroundColor(OverlayTheme.gold.opacity(0.85))

                    Text("Next:")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))

                    if let t = step.teleport {
                        Text(t.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(OverlayTheme.gold.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("(\(step.x), \(step.y))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.75))
                    }

                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(OverlayTheme.gold.opacity(0.06))

                Divider().opacity(0.20)
            }

            // ── Control bar ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {

                // Observation badges (shown once at least one is confirmed)
                if !state.observations.isEmpty {
                    HStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                ForEach(state.observations) { obs in
                                    HStack(spacing: 3) {
                                        Circle()
                                            .fill(pulseColor(obs.pulse))
                                            .frame(width: 6, height: 6)
                                        Text(obs.pulse.label)
                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                            .foregroundColor(pulseColor(obs.pulse).opacity(0.9))
                                    }
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(pulseColor(obs.pulse).opacity(0.12)))
                                }
                            }
                        }
                        Spacer(minLength: 4)
                        if state.observations.count > 1 {
                            Button(action: { state.undoLast() }) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .help("Undo last observation")
                        }
                        Button(action: { state.clearAll() }) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .help("Clear all observations")
                    }
                }

                // Instruction + pulse selector row
                HStack(spacing: 6) {
                    if state.pendingPos != nil {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Color(red: 0.30, green: 0.92, blue: 0.38).opacity(0.9))
                        Text("Pulse:")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.55))
                    } else {
                        Image(systemName: state.observations.isEmpty ? "hand.tap" : "hand.tap.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.35))
                        Text(state.observations.isEmpty
                             ? "Double-tap map to mark position"
                             : "Double-tap to add another position")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                    }

                    ForEach(ScanPulse.allCases, id: \.self) { pulse in
                        Button(action: { state.confirmPulse(pulse) }) {
                            Text(pulse.label)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(
                                    state.pendingPos != nil
                                        ? pulseColor(pulse).opacity(0.9)
                                        : .white.opacity(0.2)
                                )
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(
                                    state.pendingPos != nil
                                        ? pulseColor(pulse).opacity(0.18)
                                        : Color.white.opacity(0.05)
                                ))
                        }
                        .buttonStyle(.plain)
                        .disabled(state.pendingPos == nil)
                    }

                    Spacer(minLength: 4)

                    if filterActive {
                        Text("\(state.survivingIDs.count) / \(state.spots.count) remaining")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(OverlayTheme.gold.opacity(0.9))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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

    // MARK: - Pulse colours

    private func pulseColor(_ pulse: ScanPulse) -> Color {
        switch pulse {
        case .single: return Color(red: 0.36, green: 0.56, blue: 1.0)   // blue
        case .double: return Color(red: 1.0,  green: 0.55, blue: 0.10)  // orange
        case .triple: return Color(red: 0.92, green: 0.24, blue: 0.20)  // red
        }
    }
}
