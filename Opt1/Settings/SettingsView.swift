import SwiftUI
import AppKit

/// Routes inside the Settings window's navigation stack. Kept as a separate
/// enum so callers (e.g. menu actions in `AppDelegate`) can deep-link
/// straight to a sub-screen by setting the model's `path`.
enum SettingsRoute: Hashable {
    case credits
}

/// Shared navigation state for the Settings window. AppDelegate owns one
/// instance for the lifetime of the settings window controller; menu
/// actions mutate `path` to push the corresponding destination. Mutations
/// already happen on the main thread (menu actions + SwiftUI bindings) so
/// the type intentionally avoids `@MainActor` — that would force every
/// caller into an isolated context, including the synchronous
/// `SettingsView` initialiser.
final class SettingsNavigationModel: ObservableObject {
    @Published var path: [SettingsRoute] = []
}

struct SettingsView: View {

    // Backed by the same UserDefaults key AppSettings uses so non-SwiftUI
    // readers (logging, detection pipeline, etc.) see the same value.
    @AppStorage(AppSettings.Keys.debugMode) private var debugEnabled: Bool = true
    @AppStorage(AppSettings.Keys.puzzleGuidanceSpeed) private var guidanceSpeed: Double = AppSettings.defaultPuzzleGuidanceSpeed
    @AppStorage(AppSettings.Keys.puzzleUIScale) private var puzzleUIScale: Int = AppSettings.defaultPuzzleUIScale
    // Default-on; matches `AppSettings.areTeleportsShown`.
    @AppStorage(AppSettings.Keys.showTeleports) private var showTeleports: Bool = true
    @AppStorage(AppSettings.Keys.slidePuzzleAutoDetect) private var slidePuzzleAutoDetect: Bool = true
    @AppStorage(AppSettings.Keys.scanNextSpotEnabled) private var scanNextSpotEnabled: Bool = false
    // Auto-triangulation toggle. The two saved points are read directly
    // from `AppSettings` (not via `@AppStorage`) since they are tuples.
    @AppStorage(AppSettings.Keys.autoTriEnabled) private var autoTriEnabled: Bool = false
    @AppStorage(AppSettings.Keys.autoTriPoint1Set) private var autoTriPoint1Set: Bool = false
    @AppStorage(AppSettings.Keys.autoTriPoint2Set) private var autoTriPoint2Set: Bool = false
    @AppStorage(AppSettings.Keys.autoTriPoint1X) private var autoTriPoint1X: Int = 0
    @AppStorage(AppSettings.Keys.autoTriPoint1Y) private var autoTriPoint1Y: Int = 0
    @AppStorage(AppSettings.Keys.autoTriPoint2X) private var autoTriPoint2X: Int = 0
    @AppStorage(AppSettings.Keys.autoTriPoint2Y) private var autoTriPoint2Y: Int = 0
    @AppStorage(AppSettings.Keys.arcAutoTriEnabled) private var arcAutoTriEnabled: Bool = false
    @AppStorage(AppSettings.Keys.arcAutoTriPoint1Set) private var arcAutoTriPoint1Set: Bool = false
    @AppStorage(AppSettings.Keys.arcAutoTriPoint2Set) private var arcAutoTriPoint2Set: Bool = false
    @AppStorage(AppSettings.Keys.arcAutoTriPoint1X) private var arcAutoTriPoint1X: Int = 0
    @AppStorage(AppSettings.Keys.arcAutoTriPoint1Y) private var arcAutoTriPoint1Y: Int = 0
    @AppStorage(AppSettings.Keys.arcAutoTriPoint2X) private var arcAutoTriPoint2X: Int = 0
    @AppStorage(AppSettings.Keys.arcAutoTriPoint2Y) private var arcAutoTriPoint2Y: Int = 0
    @State private var overlayResetConfirmed = false
    // Hotkey bindings — loaded from AppSettings on appear and updated on commit.
    @State private var solveBinding:  HotkeyBinding = AppSettings.shared.solveHotkey
    @State private var puzzleBinding: HotkeyBinding = AppSettings.shared.puzzleHotkey
    @State private var hotkeyResetConfirmed = false
    // Teleports the user has excluded from scan next-spot recommendations.
    // Refreshed on appear and after each removal so the list stays current.
    @State private var disabledScanTeleports: [TeleportSpot] = []
    // Custom keybind pre-steps per group, refreshed from AppSettings on appear.
    @State private var groupSteps: [String: [String]] = [:]
    // Custom keybind pre-steps per individual spot (spellbooks etc.).
    @State private var spotSteps:  [String: [String]] = [:]
    // Tracks which teleport's keybind sheet is currently open in Settings.
    @State private var keybindEditTarget: KeybindEditTarget? = nil

    @ObservedObject var navigation: SettingsNavigationModel
    /// Invoked when the user clicks "Calibrate triangulation points". Owned
    /// by `AppDelegate` so it can host the calibration window in the same
    /// way it hosts the settings window.
    var onOpenCalibration: (() -> Void)?
    /// Invoked when the user clicks "Calibrate Arc triangulation points".
    var onOpenArcCalibration: (() -> Void)?
    /// Invoked whenever the user saves a new hotkey binding, so AppDelegate
    /// can re-register the global monitor and refresh menu titles.
    var onHotkeyChanged: (() -> Void)?

    init(navigation: SettingsNavigationModel = SettingsNavigationModel(),
         onOpenCalibration: (() -> Void)? = nil,
         onOpenArcCalibration: (() -> Void)? = nil,
         onHotkeyChanged: (() -> Void)? = nil) {
        self.navigation = navigation
        self.onOpenCalibration = onOpenCalibration
        self.onOpenArcCalibration = onOpenArcCalibration
        self.onHotkeyChanged = onHotkeyChanged
    }

    private var hotkeysConflict: Bool {
        solveBinding == puzzleBinding
    }

    // MARK: - Hotkey rows

    private var hotkeySolveRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Solve clue")
                    .font(.body)
                Text("Triggers clue detection and solution lookup.")
                    .font(.caption)
                    .foregroundStyle(OverlayTheme.textSecondary)
            }
            Spacer()
            KeyRecorderView(binding: $solveBinding) { newBinding in
                AppSettings.shared.solveHotkey = newBinding
                onHotkeyChanged?()
            }
            .frame(width: 100, height: 28)
        }
    }

    private var hotkeyPuzzleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Puzzle snip")
                    .font(.body)
                Text("Drag-to-crop a sliding puzzle for detection.")
                    .font(.caption)
                    .foregroundStyle(OverlayTheme.textSecondary)
            }
            Spacer()
            KeyRecorderView(binding: $puzzleBinding) { newBinding in
                AppSettings.shared.puzzleHotkey = newBinding
                onHotkeyChanged?()
            }
            .frame(width: 100, height: 28)
        }
    }

    private var bothCalibrationPointsSet: Bool {
        autoTriPoint1Set && autoTriPoint2Set
    }

    private var bothArcCalibrationPointsSet: Bool {
        arcAutoTriPoint1Set && arcAutoTriPoint2Set
    }

    private func formatPoint(set: Bool, x: Int, y: Int) -> String {
        set ? "(\(x), \(y))" : "Not set"
    }

    private func refreshDisabledScanTeleports() {
        let ids = AppSettings.disabledScanTeleportIds
        disabledScanTeleports = TeleportCatalogue.shared.spots
            .filter { ids.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    private func refreshGroupSteps() {
        groupSteps = AppSettings.teleportGroupSteps
        spotSteps  = AppSettings.teleportSpotSteps
    }

    /// Resolves a groupId to the first matching TeleportSpot so we can read
    /// `groupName` and `code` without needing a separate lookup structure.
    private func spotForGroupId(_ groupId: String) -> TeleportSpot? {
        TeleportCatalogue.shared.spots.first { $0.groupId == groupId }
    }

    /// Resolves a full TeleportSpot.id to the matching spot.
    private func spotForSpotId(_ spotId: String) -> TeleportSpot? {
        TeleportCatalogue.shared.spots.first { $0.id == spotId }
    }

    private var guidanceIntervalMilliseconds: Int {
        let clampedSpeed = min(max(guidanceSpeed, AppSettings.minPuzzleGuidanceSpeed),
                               AppSettings.maxPuzzleGuidanceSpeed)
        let interval = AppSettings.basePuzzleGuidanceInterval / clampedSpeed
        return Int((interval * 1000).rounded())
    }


    var body: some View {
        NavigationStack(path: $navigation.path) {
            settingsForm
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .credits:
                        CreditsView()
                    }
                }
        }
        .frame(width: 420, height: 640)
        .background(OverlayTheme.bgPrimary)
    }

    private var settingsForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Overlay
                ThemedSection(header: "Overlay") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Overlay position")
                                .font(.body)
                            Text("Resets the draggable overlay to the default top-right corner of the RS window.")
                                .font(.caption)
                                .foregroundStyle(OverlayTheme.textSecondary)
                        }
                        Spacer()
                        Button(overlayResetConfirmed ? "Reset ✓" : "Reset Position") {
                            AppSettings.shared.resetOverlayOffset()
                            overlayResetConfirmed = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                overlayResetConfirmed = false
                            }
                        }
                        .disabled(overlayResetConfirmed)
                        .tint(OverlayTheme.gold)
                        .accessibilityLabel(overlayResetConfirmed ? "Overlay position reset" : "Reset overlay position")
                        .accessibilityHint("Returns the solution overlay to its default position near the RuneScape window.")
                    }
                }

                // MARK: Hotkeys
                ThemedSection(header: "Hotkeys") {
                    hotkeySolveRow
                    ThemedDivider()
                    hotkeyPuzzleRow
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if hotkeysConflict {
                            Text("⚠ Both hotkeys are set to the same combo. Change one before saving.")
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Text("Requires at least one of ⌘ ⌥ ⌃. Press Escape to cancel recording.")
                            Spacer()
                            Button(hotkeyResetConfirmed ? "Reset ✓" : "Reset to defaults") {
                                AppSettings.shared.resetHotkeys()
                                solveBinding  = .defaultSolve
                                puzzleBinding = .defaultPuzzle
                                hotkeyResetConfirmed = true
                                onHotkeyChanged?()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    hotkeyResetConfirmed = false
                                }
                            }
                            .disabled(hotkeyResetConfirmed)
                            .controlSize(.small)
                            .tint(OverlayTheme.gold)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(OverlayTheme.textSecondary)
                    .padding(.horizontal, 4)
                }

                // MARK: Guidance
                ThemedSection(header: "Guidance") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Puzzle guidance speed")
                                    .font(.body)
                                Text("Controls how fast the sliding-puzzle overlay walks through each move.")
                                    .font(.caption)
                                    .foregroundStyle(OverlayTheme.textSecondary)
                            }
                            Spacer()
                            Text(String(format: "%.2f× (%d ms)", guidanceSpeed, guidanceIntervalMilliseconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OverlayTheme.textSecondary)
                        }

                        HStack(spacing: 8) {
                            Text("Slower")
                                .font(.caption2)
                                .foregroundStyle(OverlayTheme.textSecondary)
                            Slider(
                                value: $guidanceSpeed,
                                in: AppSettings.minPuzzleGuidanceSpeed...AppSettings.maxPuzzleGuidanceSpeed,
                                step: 0.05
                            )
                            .tint(OverlayTheme.gold)
                            .accessibilityLabel("Puzzle guidance speed")
                            .accessibilityValue(String(format: "%.2f times, %d milliseconds per step",
                                                       guidanceSpeed, guidanceIntervalMilliseconds))
                            Text("Faster")
                                .font(.caption2)
                                .foregroundStyle(OverlayTheme.textSecondary)
                            Button("Reset") {
                                AppSettings.shared.resetPuzzleGuidanceSpeed()
                                guidanceSpeed = AppSettings.defaultPuzzleGuidanceSpeed
                            }
                            .controlSize(.small)
                            .tint(OverlayTheme.gold)
                            .accessibilityHint("Restores the default guidance speed.")
                        }
                    }
                }

                // MARK: Experimental
                ThemedSection(header: "Experimental") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Auto-detect sliding puzzle")
                                    .font(.body)
                                Text("Automatically detects and opens the sliding-puzzle solver when Opt+1 is pressed.")
                                    .font(.caption)
                                    .foregroundStyle(OverlayTheme.textSecondary)
                            }
                            Spacer()
                            Toggle("Auto-detect sliding puzzle", isOn: $slidePuzzleAutoDetect)
                                .toggleStyle(GoldToggleStyle())
                                .accessibilityHint("When enabled, Opt+1 scans for an open sliding puzzle and launches the solver without the manual snip hotkey.")
                        }

                        ThemedDivider()

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Scan next best spot")
                                    .font(.body)
                                Text("Shows the recommended next scan position on the map and in the scan overlay.")
                                    .font(.caption)
                                    .foregroundStyle(OverlayTheme.textSecondary)
                            }
                            Spacer()
                            Toggle("Scan next best spot", isOn: $scanNextSpotEnabled)
                                .toggleStyle(GoldToggleStyle())
                                .accessibilityHint("When enabled, the scan overlay displays a suggested next tile to minimise remaining candidates.")
                        }

                        ThemedDivider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("RuneScape UI scale")
                                    .font(.body)
                                Text("Tells Opt1 which slider-puzzle anchor to template-match against. Set this to whatever your in-game NXT Interface Scale is.")
                                    .font(.caption)
                                    .foregroundStyle(OverlayTheme.textSecondary)
                            }
                            Spacer()
                            Picker("RuneScape UI scale", selection: $puzzleUIScale) {
                                ForEach(AppSettings.supportedPuzzleUIScales, id: \.self) { scale in
                                    Text("\(scale)%").tag(scale)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 90)
                            .tint(OverlayTheme.gold)
                            .accessibilityLabel("RuneScape interface scale")
                            .accessibilityHint("Pick the same percentage as Settings → Interface Scale in RuneScape so puzzle auto-detection knows which template to use.")
                        }
                    }
                } footer: {
                    Text("These features are under active development and may change or be removed in a future release. If auto-detect keeps failing, double check the UI scale matches the value shown under Settings → Graphics → Interface Scaling in RuneScape.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                // MARK: Auto-Triangulation
                ThemedSection(header: "Auto-Triangulation") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Auto-anchor compass triangulation")
                                .font(.body)
                                .foregroundStyle(bothCalibrationPointsSet
                                                 ? OverlayTheme.textPrimary
                                                 : OverlayTheme.textSecondary)
                            Spacer()
                            Toggle("Auto-anchor compass triangulation", isOn: $autoTriEnabled)
                                .toggleStyle(GoldToggleStyle())
                                .disabled(!bothCalibrationPointsSet)
                                .accessibilityHint("Skip the two map double-clicks during elite compass triangulation by using your two calibrated points as bearing origins.")
                        }

                        ThemedDivider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Point 1: \(formatPoint(set: autoTriPoint1Set, x: autoTriPoint1X, y: autoTriPoint1Y))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(autoTriPoint1Set
                                                     ? OverlayTheme.textSecondary
                                                     : OverlayTheme.textSecondary.opacity(0.5))
                                Text("Point 2: \(formatPoint(set: autoTriPoint2Set, x: autoTriPoint2X, y: autoTriPoint2Y))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(autoTriPoint2Set
                                                     ? OverlayTheme.textSecondary
                                                     : OverlayTheme.textSecondary.opacity(0.5))
                            }
                            Spacer()
                            Button(bothCalibrationPointsSet ? "Recalibrate" : "Calibrate") {
                                onOpenCalibration?()
                            }
                            .tint(OverlayTheme.gold)
                            .accessibilityLabel(bothCalibrationPointsSet
                                                ? "Recalibrate triangulation points"
                                                : "Calibrate triangulation points")
                        }
                    }
                } footer: {
                    Text(bothCalibrationPointsSet
                         ? "When enabled, the first \(AppSettings.shared.solveHotkey.displayString) anchors a bearing at Point 1 automatically; the second \(AppSettings.shared.solveHotkey.displayString) anchors at Point 2. For the best results, pick two well-known spots far from any dig spot and on the same side of the map."
                         : "Calibrate two reference points on the RS world map before enabling.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                // MARK: Arc Auto-Triangulation
                ThemedSection(header: "Arc Auto-Triangulation") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Auto-anchor Arc triangulation")
                                .font(.body)
                                .foregroundStyle(bothArcCalibrationPointsSet
                                                 ? OverlayTheme.textPrimary
                                                 : OverlayTheme.textSecondary)
                            Spacer()
                            Toggle("Auto-anchor Arc triangulation", isOn: $arcAutoTriEnabled)
                                .toggleStyle(GoldToggleStyle())
                                .disabled(!bothArcCalibrationPointsSet)
                                .accessibilityHint("Skip the two map double-clicks during master compass (Eastern Lands) triangulation by using your two Arc calibrated points as bearing origins.")
                        }

                        ThemedDivider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Point 1: \(formatPoint(set: arcAutoTriPoint1Set, x: arcAutoTriPoint1X, y: arcAutoTriPoint1Y))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(arcAutoTriPoint1Set
                                                     ? OverlayTheme.textSecondary
                                                     : OverlayTheme.textSecondary.opacity(0.5))
                                Text("Point 2: \(formatPoint(set: arcAutoTriPoint2Set, x: arcAutoTriPoint2X, y: arcAutoTriPoint2Y))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(arcAutoTriPoint2Set
                                                     ? OverlayTheme.textSecondary
                                                     : OverlayTheme.textSecondary.opacity(0.5))
                            }
                            Spacer()
                            Button(bothArcCalibrationPointsSet ? "Recalibrate" : "Calibrate") {
                                onOpenArcCalibration?()
                            }
                            .tint(OverlayTheme.gold)
                            .accessibilityLabel(bothArcCalibrationPointsSet
                                                ? "Recalibrate Arc triangulation points"
                                                : "Calibrate Arc triangulation points")
                        }
                    }
                } footer: {
                    Text(bothArcCalibrationPointsSet
                         ? "Used during an Eastern Lands compass clue. Pick two fixed spots on The Arc islands. These points are independent of the surface auto-triangulation points above."
                         : "Calibrate two reference points on The Arc before enabling.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                // MARK: World Map
                ThemedSection(header: "World Map") {
                    HStack {
                        Text("Show teleport icons on map")
                            .font(.body)
                        Spacer()
                        Toggle("Show teleport icons on map", isOn: $showTeleports)
                            .toggleStyle(GoldToggleStyle())
                            .accessibilityHint("Paints lodestone, jewellery, and other teleport destinations on top of the RS world map shown in solution cards.")
                    }
                } footer: {
                    Text("Teleport locations are rendered on top of the RS world map. Disable for a less cluttered view.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                // MARK: Excluded Teleports
                ThemedSection(header: "Excluded Teleports") {
                    if disabledScanTeleports.isEmpty {
                        Text("No teleports excluded.")
                            .font(.body)
                            .foregroundStyle(OverlayTheme.textSecondary)
                    } else {
                        ForEach(disabledScanTeleports, id: \.id) { spot in
                            VStack(spacing: 0) {
                                if spot.id != disabledScanTeleports.first?.id {
                                    ThemedDivider()
                                }
                                HStack(spacing: 10) {
                                    if let iconName = spot.resolvedIcon,
                                       let cg = TeleportSpriteCache.shared.image(named: iconName) {
                                        Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 18, height: 18)))
                                            .frame(width: 18, height: 18)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                            .font(.system(size: 12))
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                            .frame(width: 18, height: 18)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(spot.name)
                                            .font(.body)
                                        Text(spot.groupName)
                                            .font(.caption)
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                    }

                                    Spacer()

                                    Button {
                                        AppSettings.enableScanTeleport(id: spot.id)
                                        refreshDisabledScanTeleports()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Re-enable \(spot.name)")
                                    .accessibilityHint("Removes this teleport from the exclusion list so it can appear as a suggested scan position again.")
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } footer: {
                    Text("Teleports excluded here won't appear as suggested scan positions. Use \"I don't have this teleport\" in the scan overlay to add entries, or remove them here to re-enable.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                // MARK: Teleport Keybinds
                ThemedSection(header: "Teleport Keybinds") {
                    let hasAny = !groupSteps.isEmpty || !spotSteps.isEmpty
                    if !hasAny {
                        Text("No custom keybinds set.")
                            .font(.body)
                            .foregroundStyle(OverlayTheme.textSecondary)
                    } else {
                        // Build a unified list of entries sorted by display name.
                        // Group-level entries: keyed by groupId, primary label = groupName.
                        // Spot-level entries: keyed by spot.id, primary label = spot.name.
                        let groupEntries: [(key: String, primary: String, secondary: String)] =
                            groupSteps.keys.compactMap { gid in
                                guard let spot = spotForGroupId(gid) else { return nil }
                                return (key: gid, primary: spot.groupName, secondary: "All teleports")
                            }
                        let spotEntries: [(key: String, primary: String, secondary: String)] =
                            spotSteps.keys.compactMap { sid in
                                guard let spot = spotForSpotId(sid) else { return nil }
                                return (key: sid, primary: spot.name, secondary: spot.groupName)
                            }
                        let allEntries = (groupEntries + spotEntries)
                            .sorted { $0.primary.localizedCaseInsensitiveCompare($1.primary) == .orderedAscending }

                        ForEach(Array(allEntries.enumerated()), id: \.element.key) { idx, entry in
                            let isSpot = spotSteps[entry.key] != nil
                            let steps  = isSpot ? (spotSteps[entry.key] ?? []) : (groupSteps[entry.key] ?? [])
                            let spot   = isSpot ? spotForSpotId(entry.key) : spotForGroupId(entry.key)

                            VStack(spacing: 0) {
                                if idx != 0 { ThemedDivider() }
                                HStack(spacing: 10) {
                                    if let iconName = spot?.resolvedIcon,
                                       let cg = TeleportSpriteCache.shared.image(named: iconName) {
                                        Image(nsImage: NSImage(cgImage: cg, size: NSSize(width: 18, height: 18)))
                                            .frame(width: 18, height: 18)
                                    } else {
                                        Image(systemName: "keyboard")
                                            .font(.system(size: 12))
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                            .frame(width: 18, height: 18)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.primary)
                                            .font(.body)
                                        Text(entry.secondary)
                                            .font(.caption)
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                        if !steps.isEmpty {
                                            Text(steps.joined(separator: " > "))
                                                .font(.caption)
                                                .foregroundStyle(OverlayTheme.gold.opacity(0.8))
                                                .fontDesign(.monospaced)
                                        }
                                    }

                                    Spacer()

                                    Button {
                                        keybindEditTarget = KeybindEditTarget(
                                            scopeId:     entry.key,
                                            scopeName:   entry.primary,
                                            contextLine: isSpot
                                                ? "\(entry.primary) · \(entry.secondary)"
                                                : "Applies to all \(entry.primary) teleports",
                                            knownCode:   spot?.code,
                                            isSpotLevel: isSpot
                                        )
                                    } label: {
                                        Image(systemName: "pencil")
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Edit keybind for \(entry.primary)")

                                    Button {
                                        if isSpot {
                                            AppSettings.removeSpotSteps(forSpotId: entry.key)
                                        } else {
                                            AppSettings.removeGroupSteps(forGroupId: entry.key)
                                        }
                                        refreshGroupSteps()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(OverlayTheme.textSecondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove keybind for \(entry.primary)")
                                    .accessibilityHint("Removes the custom keybind pre-steps for this teleport.")
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                } footer: {
                    Text("Custom keybind steps are shown before the in-game shortcut when a teleport is suggested. Add them using the \"Add keybind\" button in the scan or compass overlays.")
                        .font(.caption)
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 4)
                }

                // MARK: Diagnostics
                ThemedSection(header: "Diagnostics") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Enable debug mode")
                                .font(.body)
                            Spacer()
                            Toggle("Enable debug mode", isOn: $debugEnabled)
                                .toggleStyle(GoldToggleStyle())
                                .accessibilityHint("Writes detection images and a log file to the debug folder while enabled.")
                                .onChange(of: debugEnabled) { _, newValue in
                                    if newValue {
                                        try? FileManager.default.createDirectory(
                                            at: AppSettings.debugFolder,
                                            withIntermediateDirectories: true)
                                    }
                                }
                        }

                        if debugEnabled {
                            ThemedDivider()
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Debug output folder")
                                        .font(.body)
                                    Text("Detection images and the opt1.log file are written here.")
                                        .font(.caption)
                                        .foregroundStyle(OverlayTheme.textSecondary)
                                    Text(AppSettings.debugFolder.path)
                                        .font(.caption2)
                                        .foregroundStyle(OverlayTheme.textSecondary.opacity(0.6))
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button("Show in Finder") {
                                    let folder = AppSettings.debugFolder
                                    try? FileManager.default.createDirectory(
                                        at: folder, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(folder)
                                }
                                .tint(OverlayTheme.gold)
                                .accessibilityLabel("Show debug folder in Finder")
                                .accessibilityHint("Opens the folder where detection images and logs are saved.")
                            }
                        }
                    }
                } footer: {
                    if debugEnabled {
                        Text("Debug mode captures detection images and a full log to disk. Turn off when not needed.")
                            .font(.caption)
                            .foregroundStyle(OverlayTheme.textSecondary)
                            .padding(.horizontal, 4)
                    }
                }

                // MARK: About
                ThemedSection(header: "About") {
                    NavigationLink(value: SettingsRoute.credits) {
                        HStack {
                            Text("Credits & Licenses")
                                .font(.body)
                                .foregroundStyle(OverlayTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(OverlayTheme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the third-party credits and licence notices.")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(OverlayTheme.bgPrimary)
        .foregroundStyle(OverlayTheme.textPrimary)
        .navigationTitle("Opt1 Settings")
        .onAppear {
            refreshDisabledScanTeleports()
            refreshGroupSteps()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshDisabledScanTeleports()
            refreshGroupSteps()
        }
        .sheet(item: $keybindEditTarget, onDismiss: refreshGroupSteps) { target in
            TeleportInstructionSheet(
                scopeId:     target.scopeId,
                scopeName:   target.scopeName,
                contextLine: target.contextLine,
                knownCode:   target.knownCode,
                isSpotLevel: target.isSpotLevel
            )
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}

// MARK: - ThemedSection

private struct ThemedSection<RowContent: View, Footer: View>: View {
    let header: String
    let content: () -> RowContent
    let footer: () -> Footer

    init(header: String,
         @ViewBuilder content: @escaping () -> RowContent,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.header = header
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(OverlayTheme.gold)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                    .fill(OverlayTheme.bgDeep)
                    .overlay(
                        RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                            .strokeBorder(OverlayTheme.goldBorder.opacity(0.25), lineWidth: 1)
                    )
            )

            footer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ThemedSection where Footer == EmptyView {
    init(header: String, @ViewBuilder content: @escaping () -> RowContent) {
        self.init(header: header, content: content, footer: { EmptyView() })
    }
}

// MARK: - ThemedDivider

private struct ThemedDivider: View {
    var body: some View {
        Rectangle()
            .fill(OverlayTheme.goldBorder.opacity(0.20))
            .frame(maxWidth: .infinity, minHeight: 0.5, maxHeight: 0.5)
            .padding(.vertical, 8)
    }
}

// MARK: - KeybindEditTarget

/// Identifiable wrapper used to drive the keybind edit sheet from SettingsView.
private struct KeybindEditTarget: Identifiable {
    let scopeId:     String
    let scopeName:   String
    let contextLine: String
    let knownCode:   String?
    let isSpotLevel: Bool
    var id: String { scopeId }
}
