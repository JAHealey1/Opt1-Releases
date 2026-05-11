import AppKit
import SwiftUI

// MARK: - Auto-triangulation calibration view
//
// Two-step capture flow for the auto-triangulation feature: the user pans
// the world map, double-clicks a reference point, then double-clicks a
// second reference point. Each click is converted to RS3 game-tile
// coordinates via the same `RSWorldMapView` used by the elite-compass
// overlay and persisted through `AppSettings.saveAutoTriPoint{1,2}` or
// `AppSettings.saveArcAutoTriPoint{1,2}` depending on `variant`.
//
// The view does not attempt to validate the user's choice (e.g. distance
// from known dig spots); good calibration is the user's responsibility,
// surfaced in the settings footer copy.

// MARK: - Calibration variant

/// Selects whether the calibration view is saving surface (elite compass)
/// or Arc (master Eastern Lands compass) triangulation points.
enum CalibrationVariant {
    case surface
    case arc

    var windowTitle: String {
        switch self {
        case .surface: return "Auto-Triangulation Calibration"
        case .arc:     return "Arc Auto-Triangulation Calibration"
        }
    }

    var defaultX: Int {
        switch self {
        case .surface: return 3222
        case .arc:     return MapTileCache.arcCenterX
        }
    }

    var defaultY: Int {
        switch self {
        case .surface: return 3218
        case .arc:     return MapTileCache.arcCenterY
        }
    }

    func savePoint1(x: Int, y: Int) {
        switch self {
        case .surface: AppSettings.saveAutoTriPoint1(x: x, y: y)
        case .arc:     AppSettings.saveArcAutoTriPoint1(x: x, y: y)
        }
    }

    func savePoint2(x: Int, y: Int) {
        switch self {
        case .surface: AppSettings.saveAutoTriPoint2(x: x, y: y)
        case .arc:     AppSettings.saveArcAutoTriPoint2(x: x, y: y)
        }
    }
}

struct CalibrationView: View {

    enum Step {
        case point1
        case point2

        var headerNumber: String {
            switch self {
            case .point1: return "Step 1 of 2"
            case .point2: return "Step 2 of 2"
            }
        }

        var instruction: String {
            switch self {
            case .point1:
                return "Pan the map and double-click your first triangulation point."
            case .point2:
                return "Now double-click your second triangulation point."
            }
        }
    }

    /// Surface or Arc calibration mode — drives default map centre and which
    /// AppSettings keys are written.
    var variant: CalibrationVariant = .surface

    @State private var step: Step = .point1
    @State private var savedPoint1: (x: Int, y: Int)? = nil
    @State private var savedPoint2: (x: Int, y: Int)? = nil
    @State private var hasTiles: Bool? = nil

    /// Called by the host (`AppDelegate`) to dismiss the window when
    /// calibration is complete or the user cancels.
    var onClose: () -> Void = {}

    /// Map re-centres on point 1 after it is saved so the second click stays
    /// in the same region; falls back to the variant's default centre.
    private var mapCenterX: Int { savedPoint1?.x ?? variant.defaultX }
    private var mapCenterY: Int { savedPoint1?.y ?? variant.defaultY }

    private func handleDoubleTap(gx: Int, gy: Int) {
        switch step {
        case .point1:
            savedPoint1 = (gx, gy)
            variant.savePoint1(x: gx, y: gy)
            step = .point2
        case .point2:
            savedPoint2 = (gx, gy)
            variant.savePoint2(x: gx, y: gy)
            onClose()
        }
    }

    private func resetCurrentStep() {
        switch step {
        case .point1:
            savedPoint1 = nil
        case .point2:
            // Bounce back to point 1 entry so the user can recapture both
            // sequentially. The persisted point 1 is left in place — only
            // overwritten when they actually click on the map again.
            savedPoint1 = nil
            step = .point1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(variant.windowTitle)
                        .font(.headline)
                    Spacer()
                    Text(step.headerNumber)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(step.instruction)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Saved-point status row (visible after step 1 is captured)
            if let p1 = savedPoint1 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Point 1 saved at (\(p1.x), \(p1.y))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Divider().opacity(0.4)

            // Map — centres on The Arc for `.arc` variant so the user doesn't
            // have to pan from Lumbridge.
            RSWorldMapView(
                gameX: mapCenterX,
                gameY: mapCenterY,
                mapId: MapTileCache.defaultMapId,
                viewportHeight: .infinity,
                hasTiles: $hasTiles,
                showPrimaryPin: false,
                onMapDoubleTap: { gx, gy in
                    handleDoubleTap(gx: gx, gy: gy)
                },
                bearingLines: [],
                intersectionPoint: nil,
                intersectionPolygon: nil,
                digSpotPins: [],
                boundsHints: variant == .arc
                    ? [MapTileCache.arcBoundsSW, MapTileCache.arcBoundsNE]
                    : []
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.4)

            // Footer buttons
            HStack {
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Re-do this point") { resetCurrentStep() }
                    .disabled(step == .point1 && savedPoint1 == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

#Preview {
    CalibrationView()
        .frame(width: 600, height: 540)
}

#Preview("Arc variant") {
    CalibrationView(variant: .arc)
        .frame(width: 600, height: 540)
}

