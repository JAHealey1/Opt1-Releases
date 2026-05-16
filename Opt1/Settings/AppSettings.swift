import Foundation
import AppKit

// MARK: - HotkeyBinding

/// A key-code + modifier-flags pair that identifies a global hotkey combo.
/// Persisted as two separate UserDefaults entries (raw UInt16 key code and raw UInt modifiers).
struct HotkeyBinding: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    // MARK: Defaults

    static let defaultSolve  = HotkeyBinding(keyCode: 18, modifiers: [.option])   // ⌥1
    static let defaultPuzzle = HotkeyBinding(keyCode: 19, modifiers: [.option])   // ⌥2

    // MARK: Display

    /// Human-readable representation in standard macOS order, e.g. "⌥1", "⌘⌥F2", "⌃⇧A".
    var displayString: String {
        var result = ""
        // Standard macOS modifier order: ⌃ ⌥ ⇧ ⌘
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option)  { result += "⌥" }
        if modifiers.contains(.shift)   { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    // MARK: Key-code → display name

    static func keyName(for code: UInt16) -> String {
        switch code {
        // Number row
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        // Letters (US QWERTY positions)
        case 0:  return "A"
        case 11: return "B"
        case 8:  return "C"
        case 2:  return "D"
        case 14: return "E"
        case 3:  return "F"
        case 5:  return "G"
        case 4:  return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1:  return "S"
        case 17: return "T"
        case 32: return "U"
        case 9:  return "V"
        case 13: return "W"
        case 7:  return "X"
        case 16: return "Y"
        case 6:  return "Z"
        // Function keys
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        // Navigation / special
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36:  return "↩"
        case 48:  return "⇥"
        case 51:  return "⌫"
        case 53:  return "⎋"
        case 49:  return "Space"
        case 116: return "PgUp"
        case 121: return "PgDn"
        case 115: return "Home"
        case 119: return "End"
        default:  return "(\(code))"
        }
    }
}

// MARK: - AppSettings

/// Central store for all user-configurable settings, backed by UserDefaults.
/// All reads are thread-safe (UserDefaults reads are documented as thread-safe by Apple).
final class AppSettings {

    static let shared = AppSettings()
    private init() {}

    // MARK: - Keys

    enum Keys {
        static let debugMode     = "debugModeEnabled"
        static let developerMode = "developerModeEnabled"
        static let overlayOffsetX = "overlayOffsetX"
        static let overlayOffsetY = "overlayOffsetY"
        static let puzzleGuidanceSpeed = "puzzleGuidanceSpeed"
        static let puzzleUIScale = "puzzleUIScalePercent"
        static let showTeleports = "showTeleportsOnMap"
        // Elite compass overlay is user-resizable; we persist the chosen
        // size so it sticks across solves and app launches.
        static let eliteCompassWidth  = "eliteCompassPanelWidth"
        static let eliteCompassHeight = "eliteCompassPanelHeight"
        // Scan overlay is also user-resizable; same persistence pattern.
        static let scanPanelWidth  = "scanPanelWidth"
        static let scanPanelHeight = "scanPanelHeight"
        static let eliteCompassShowAllDigSpots = "eliteCompassShowAllDigSpots"
        // Auto-triangulation: opt-in toggle plus two saved RS3 game-tile
        // coordinates that act as bearing-line origins during compass
        // triangulation, removing the need to double-click the map.
        static let autoTriEnabled  = "autoTriangulationEnabled"
        static let autoTriPoint1X  = "autoTriPoint1X"
        static let autoTriPoint1Y  = "autoTriPoint1Y"
        static let autoTriPoint1Set = "autoTriPoint1Set"
        static let autoTriPoint2X  = "autoTriPoint2X"
        static let autoTriPoint2Y  = "autoTriPoint2Y"
        static let autoTriPoint2Set = "autoTriPoint2Set"
        // Arc (Eastern Lands) auto-triangulation: separate calibration points
        // used when a master compass clue is detected (isEasternLands == true).
        static let arcAutoTriEnabled   = "arcAutoTriangulationEnabled"
        static let arcAutoTriPoint1X   = "arcAutoTriPoint1X"
        static let arcAutoTriPoint1Y   = "arcAutoTriPoint1Y"
        static let arcAutoTriPoint1Set = "arcAutoTriPoint1Set"
        static let arcAutoTriPoint2X   = "arcAutoTriPoint2X"
        static let arcAutoTriPoint2Y   = "arcAutoTriPoint2Y"
        static let arcAutoTriPoint2Set = "arcAutoTriPoint2Set"
        // User-configurable hotkey bindings. Key code stored as Int (UInt16 fits),
        // modifiers stored as Int (raw UInt of NSEvent.ModifierFlags).
        // Absent = use default (⌥1 / ⌥2).
        static let hotkeySolveKeyCode    = "hotkeySolveKeyCode"
        static let hotkeySolveModifiers  = "hotkeySolveModifierFlags"
        static let hotkeyPuzzleKeyCode   = "hotkeyPuzzleKeyCode"
        static let hotkeyPuzzleModifiers = "hotkeyPuzzleModifierFlags"
        // Experimental feature flags.
        // slidePuzzleAutoDetect defaults to true (absent key → enabled).
        // scanNextSpotEnabled defaults to false (absent key → disabled).
        static let slidePuzzleAutoDetect = "slidePuzzleAutoDetectEnabled"
        static let scanNextSpotEnabled   = "scanNextSpotGuidanceEnabled"
        // Teleport IDs the user has opted out of seeing as scan recommendations.
        // Stored as a [String] array; each entry is TeleportSpot.id ("<groupId>.<spotId>").
        static let disabledScanTeleportIds = "disabledScanTeleportIds"
        // Per-group custom keybind pre-steps. Keyed by TeleportSpot.groupId; value is
        // an ordered [String] of display-label steps (e.g. ["P", "⌥5"]).  The known
        // in-game `code` from teleports.json is appended at display time and never stored.
        // UserDefaults persists [String: [String]] natively as a plist dictionary.
        static let teleportGroupSteps = "teleportGroupSteps"
        // Per-spot custom keybind pre-steps for groups where each destination has its
        // own individual in-game keybind (spellbooks, house teleports, etc.).
        // Keyed by TeleportSpot.id ("<groupId>.<spotId>").
        static let teleportSpotSteps  = "teleportSpotSteps"
    }

    // MARK: - Per-spot keybind groups

    /// Groups where each teleport destination has its own in-game keybind and
    /// therefore needs a per-spot instruction rather than a shared group instruction.
    static let perSpotKeybindGroups: Set<String> = [
        "ancientspellook",
        "greenteleport",
        "houseteleports",
        "lunarspellbook",
        "normalspellbook",
    ]

    // MARK: - Debug mode

    /// Whether debug logging and debug image output is active.
    /// Safe to read from any thread.
    static var isDebugEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.debugMode)
    }

    var debugModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.debugMode) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.debugMode) }
    }

    // MARK: - Developer mode
    //
    // Hidden flag for destructive/data-capture affordances (raw training-data
    // dumps, data-collection menu items) that shouldn't be reachable by
    // end users. Deliberately *not* exposed in the Settings UI — enable
    // per-machine from Terminal with:
    //
    //     defaults write <bundle-id> developerModeEnabled -bool true
    //
    // `UserDefaults.standard` reads from the same plist that `defaults`
    // writes, so the flag takes effect on next launch with no code changes.

    /// Whether developer-only menu items and training-data captures are active.
    /// Safe to read from any thread.
    static var isDeveloperEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.developerMode)
    }

    // MARK: - Debug folder

    /// Root folder for all debug output.
    /// Lives in ~/Library/Application Support/Opt1/Debug — never on the Desktop.
    static var debugFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
        return support.appendingPathComponent("Opt1/Debug")
    }

    /// Names of debug sub-folders already cleared during the current run, so
    /// each folder is wiped at most once per run even though detectors call
    /// `debugSubfolder(named:)` many times while writing their images.
    /// All mutations are guarded by `clearedSubfoldersLock`; `nonisolated(unsafe)`
    /// silences the Swift 6 static-var checker since the lock contract is
    /// invisible to the type system.
    private nonisolated(unsafe) static var clearedSubfoldersThisRun = Set<String>()
    private static let clearedSubfoldersLock = NSLock()

    /// Returns a ready-to-use sub-folder inside `debugFolder`, or `nil` if debug mode is off.
    /// Creates the directory on demand, and — the first time a given sub-folder is
    /// requested during the current run — wipes any files left over from the
    /// previous run of that same clue/puzzle type. See `beginDebugRun()`.
    static func debugSubfolder(named name: String) -> URL? {
        guard isDebugEnabled else { return nil }
        let folder = debugFolder.appendingPathComponent(name)
        let fm = FileManager.default

        clearedSubfoldersLock.lock()
        let needsClear = clearedSubfoldersThisRun.insert(name).inserted
        clearedSubfoldersLock.unlock()

        if needsClear {
            // Only wipe files we previously wrote; the folder may not exist
            // yet on the very first run after install, which is fine.
            if let contents = try? fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in contents { try? fm.removeItem(at: url) }
            }
        }

        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Marks the start of a new pipeline run. Any debug sub-folder accessed
    /// after this call will be cleared on its first access, so each clue/puzzle
    /// type only wipes its folder when we're actually about to write to it —
    /// meaning folders for types that aren't hit this run keep their last-run
    /// contents for inspection.
    ///
    /// `opt1.log` lives at the root of `debugFolder` (not in a sub-folder)
    /// and is intentionally untouched here — it has its own size-capped
    /// truncation policy in `DebugLogger`.
    static func beginDebugRun() {
        clearedSubfoldersLock.lock()
        clearedSubfoldersThisRun.removeAll()
        clearedSubfoldersLock.unlock()
    }

    // MARK: - Overlay position

    /// Removes the persisted overlay drag offset, returning the overlay to its default
    /// top-right-of-RS-window position on the next solve.
    func resetOverlayOffset() {
        UserDefaults.standard.removeObject(forKey: Keys.overlayOffsetX)
        UserDefaults.standard.removeObject(forKey: Keys.overlayOffsetY)
    }

    // MARK: - Elite compass overlay size

    /// Default size for the elite compass overlay when the user has never
    /// resized it. Mirrors the value baked into `OverlayMode.preferredSize`.
    static let defaultEliteCompassSize = CGSize(width: 560, height: 535)
    /// Hard floor for the resizable panel — below this the header buttons and
    /// the map become unusable. Matches the panel's `contentMinSize`.
    static let minEliteCompassSize = CGSize(width: 460, height: 420)

    // MARK: - Scan overlay size

    static let defaultScanPanelSize = CGSize(width: 480, height: 560)
    static let minScanPanelSize     = CGSize(width: 300, height: 380)

    var scanPanelSize: CGSize? {
        get {
            let w = UserDefaults.standard.double(forKey: Keys.scanPanelWidth)
            let h = UserDefaults.standard.double(forKey: Keys.scanPanelHeight)
            guard w >= Self.minScanPanelSize.width,
                  h >= Self.minScanPanelSize.height else { return nil }
            return CGSize(width: w, height: h)
        }
        set {
            guard let s = newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.scanPanelWidth)
                UserDefaults.standard.removeObject(forKey: Keys.scanPanelHeight)
                return
            }
            UserDefaults.standard.set(s.width,  forKey: Keys.scanPanelWidth)
            UserDefaults.standard.set(s.height, forKey: Keys.scanPanelHeight)
        }
    }

    /// When true, the elite compass map draws every known surface compass
    /// dig spot. Default-off (`bool(forKey:)` is false when unset).
    static var eliteCompassShowAllDigSpots: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.eliteCompassShowAllDigSpots) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.eliteCompassShowAllDigSpots) }
    }

    /// Last user-chosen size of the elite compass overlay panel, if any.
    /// Returns nil when the user has never resized it (so callers can fall
    /// back to the default size).
    var eliteCompassPanelSize: CGSize? {
        get {
            let w = UserDefaults.standard.double(forKey: Keys.eliteCompassWidth)
            let h = UserDefaults.standard.double(forKey: Keys.eliteCompassHeight)
            guard w >= Self.minEliteCompassSize.width,
                  h >= Self.minEliteCompassSize.height else { return nil }
            return CGSize(width: w, height: h)
        }
        set {
            guard let s = newValue else {
                UserDefaults.standard.removeObject(forKey: Keys.eliteCompassWidth)
                UserDefaults.standard.removeObject(forKey: Keys.eliteCompassHeight)
                return
            }
            UserDefaults.standard.set(s.width,  forKey: Keys.eliteCompassWidth)
            UserDefaults.standard.set(s.height, forKey: Keys.eliteCompassHeight)
        }
    }

    // MARK: - Puzzle guidance speed

    /// Baseline cadence, in seconds, at which the puzzle-box overlay advances
    /// between moves when the speed multiplier is 1.0. Matches the historical
    /// hard-coded value so existing behaviour is preserved when the user has
    /// never touched the slider.
    static let basePuzzleGuidanceInterval: TimeInterval = 0.7

    static let defaultPuzzleGuidanceSpeed: Double = 1.0
    static let minPuzzleGuidanceSpeed:     Double = 0.25
    static let maxPuzzleGuidanceSpeed:     Double = 2.5

    /// Multiplier applied to the base step interval. Higher = faster guidance.
    /// Unset or out-of-range values fall back to the default so a corrupted
    /// preference can never produce a divide-by-zero or seizure-rate interval.
    var puzzleGuidanceSpeed: Double {
        get {
            let raw = UserDefaults.standard.object(forKey: Keys.puzzleGuidanceSpeed) as? Double
            guard let raw, raw.isFinite, raw > 0 else {
                return Self.defaultPuzzleGuidanceSpeed
            }
            return min(max(raw, Self.minPuzzleGuidanceSpeed), Self.maxPuzzleGuidanceSpeed)
        }
        set {
            let clamped = min(max(newValue, Self.minPuzzleGuidanceSpeed), Self.maxPuzzleGuidanceSpeed)
            UserDefaults.standard.set(clamped, forKey: Keys.puzzleGuidanceSpeed)
        }
    }

    /// Seconds between consecutive step highlights in the puzzle-box overlay,
    /// derived from `puzzleGuidanceSpeed`.
    var puzzleGuidanceStepInterval: TimeInterval {
        Self.basePuzzleGuidanceInterval / puzzleGuidanceSpeed
    }

    /// Restores the puzzle guidance speed to its default multiplier (1.0×).
    func resetPuzzleGuidanceSpeed() {
        UserDefaults.standard.removeObject(forKey: Keys.puzzleGuidanceSpeed)
    }

    // MARK: - RuneScape UI scale (slider puzzle detection)
    //
    // The slider auto-locator NCC's the captured screenshot against per-UI-scale
    // anchor PNGs of the close-X glyph. Without a hint we'd have to test all
    // 13 anchors and pick the highest scorer — but that's fragile: a noisy
    // off-scale anchor can outscore the correct one and produce a geometrically
    // wrong puzzle rect (different scale → different TL offsets → solver fails
    // on a misaligned crop).
    //
    // Pinning the user's UI scale lets us only accept matches from a tight
    // bracket (claimed ± 1 step) and lower the confidence threshold safely,
    // since false-positive lookalikes outside the bracket are excluded.

    /// RS NXT UI scale percentages we ship anchor needles for. Order matters —
    /// adjacency in this array defines the "± 1 step" bracket used by the
    /// slider locator. RS exposes 70/80/90/100/110/120/135/150/175/200/225/
    /// 250/275/300 in-game; 300 renders identically to 275 on tested setups
    /// so it is intentionally absent (users at 300 pick 275).
    static let supportedPuzzleUIScales: [Int] =
        [70, 80, 90, 100, 110, 120, 135, 150, 175, 200, 225, 250, 275]

    /// Default UI scale assumed for new installs and any unset / corrupted
    /// preference value. 100 % is RS's own default and the most common.
    static let defaultPuzzleUIScale: Int = 100

    /// User's claimed RuneScape NXT UI scale (in percent). Read by the slider
    /// auto-locator to restrict template-matching to the user's bracket.
    /// Out-of-list values fall back to the default rather than failing
    /// detection silently.
    var puzzleUIScalePercent: Int {
        get {
            let raw = UserDefaults.standard.object(forKey: Keys.puzzleUIScale) as? Int
            guard let raw, Self.supportedPuzzleUIScales.contains(raw) else {
                return Self.defaultPuzzleUIScale
            }
            return raw
        }
        set {
            // Coerce to nearest supported scale so the locator never sees an
            // unanchored value (would force fallback every time).
            let nearest = Self.supportedPuzzleUIScales
                .min(by: { abs($0 - newValue) < abs($1 - newValue) })
                ?? Self.defaultPuzzleUIScale
            UserDefaults.standard.set(nearest, forKey: Keys.puzzleUIScale)
        }
    }

    /// Thread-safe read for the detection pipeline.
    static var puzzleUIScalePercent: Int {
        let raw = UserDefaults.standard.object(forKey: Keys.puzzleUIScale) as? Int
        guard let raw, supportedPuzzleUIScales.contains(raw) else {
            return defaultPuzzleUIScale
        }
        return raw
    }

    // MARK: - Experimental feature flags

    /// Whether the Opt+1 pipeline should attempt NCC-based slider auto-detection.
    /// Defaults to `true` when the key has never been written (absent key means enabled).
    static var isSlidePuzzleAutoDetectEnabled: Bool {
        guard UserDefaults.standard.object(forKey: Keys.slidePuzzleAutoDetect) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: Keys.slidePuzzleAutoDetect)
    }

    /// Whether the scan overlay should compute and display the "next best spot"
    /// recommendation. Defaults to `false` (absent key → disabled).
    static var isScanNextSpotEnabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.scanNextSpotEnabled)
    }

    // MARK: - Disabled scan teleports

    /// IDs of teleport spots excluded from scan next-spot recommendations,
    /// keyed by `TeleportSpot.id` (`"<groupId>.<spotId>"`).
    /// Stored as a `[String]` array — UserDefaults natively round-trips these.
    static var disabledScanTeleportIds: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Keys.disabledScanTeleportIds) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Keys.disabledScanTeleportIds)
        }
    }

    /// Adds a teleport ID to the disabled-scan set.
    static func disableScanTeleport(id: String) {
        var ids = disabledScanTeleportIds
        ids.insert(id)
        disabledScanTeleportIds = ids
    }

    /// Removes a teleport ID from the disabled-scan set, re-enabling it.
    static func enableScanTeleport(id: String) {
        var ids = disabledScanTeleportIds
        ids.remove(id)
        disabledScanTeleportIds = ids
    }

    // MARK: - Teleport group keybind steps

    /// Custom keybind pre-steps keyed by TeleportSpot.groupId.
    /// Each value is an ordered array of display-label strings (e.g. ["P", "⌥5"]).
    /// The known in-game `code` from teleports.json is appended at display time
    /// and is never stored here.
    static var teleportGroupSteps: [String: [String]] {
        get { (UserDefaults.standard.object(forKey: Keys.teleportGroupSteps) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.teleportGroupSteps) }
    }

    /// Saves an ordered list of keybind step labels for a teleport group.
    /// Passing an empty array removes the entry entirely.
    static func setGroupSteps(_ steps: [String], forGroupId groupId: String) {
        var map = teleportGroupSteps
        if steps.isEmpty {
            map.removeValue(forKey: groupId)
        } else {
            map[groupId] = steps
        }
        teleportGroupSteps = map
    }

    /// Removes the custom keybind steps for a teleport group.
    static func removeGroupSteps(forGroupId groupId: String) {
        var map = teleportGroupSteps
        map.removeValue(forKey: groupId)
        teleportGroupSteps = map
    }

    // MARK: - Per-spot keybind steps

    /// Custom keybind pre-steps keyed by TeleportSpot.id ("<groupId>.<spotId>").
    /// Used for groups listed in `perSpotKeybindGroups` where each destination
    /// has its own individual in-game keybind.
    static var teleportSpotSteps: [String: [String]] {
        get { (UserDefaults.standard.object(forKey: Keys.teleportSpotSteps) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.teleportSpotSteps) }
    }

    /// Saves an ordered list of keybind step labels for an individual teleport spot.
    /// Passing an empty array removes the entry entirely.
    static func setSpotSteps(_ steps: [String], forSpotId spotId: String) {
        var map = teleportSpotSteps
        if steps.isEmpty {
            map.removeValue(forKey: spotId)
        } else {
            map[spotId] = steps
        }
        teleportSpotSteps = map
    }

    /// Removes the custom keybind steps for an individual teleport spot.
    static func removeSpotSteps(forSpotId spotId: String) {
        var map = teleportSpotSteps
        map.removeValue(forKey: spotId)
        teleportSpotSteps = map
    }

    /// Returns the correct custom pre-steps for a teleport spot, choosing
    /// per-spot storage for spellbook-style groups and per-group storage for all others.
    static func resolvedSteps(for spot: TeleportSpot) -> [String] {
        if perSpotKeybindGroups.contains(spot.groupId) {
            return teleportSpotSteps[spot.id] ?? []
        } else {
            return teleportGroupSteps[spot.groupId] ?? []
        }
    }

    // MARK: - World-map overlays

    /// Whether teleport sprites are painted on top of the bundled RS world
    /// map (in solution cards / scan list / elite compass triangulation).
    /// Read-mostly; safe from any thread.
    static var areTeleportsShown: Bool {
        // Default-on so first-launch users see them without a settings dive.
        // UserDefaults returns false for unset Bool keys, so we invert the
        // explicit `hideTeleports` semantics by storing the suppressed state
        // — i.e. the key is set to `true` only when the user has toggled
        // OFF in settings.
        let raw = UserDefaults.standard.object(forKey: Keys.showTeleports) as? Bool
        return raw ?? true
    }

    var showTeleports: Bool {
        get { Self.areTeleportsShown }
        set { UserDefaults.standard.set(newValue, forKey: Keys.showTeleports) }
    }

    // MARK: - Auto-triangulation
    //
    // Stores two user-calibrated RS3 game-tile coordinates that the elite
    // compass clue pipeline uses as bearing-line origins (replacing the
    // two map double-clicks). The toggle is independent of the saved
    // points: turning it off keeps the points so re-enabling does not
    // require recalibration.
    //
    // `autoTriPoint{1,2}Set` is a separate explicit flag rather than
    // sniffing for non-zero coords because (0, 0) is technically a valid
    // (if useless) tile and we want to distinguish "never set" from
    // "user calibrated to origin tile".

    /// Raw toggle, independent of whether the points are calibrated. The
    /// orchestrator should use `isAutoTriangulationEnabled` instead, which
    /// also requires both points to be set.
    static var isAutoTriToggleOn: Bool {
        UserDefaults.standard.bool(forKey: Keys.autoTriEnabled)
    }

    /// True when the user has opted in *and* both calibration points are
    /// saved — the only condition under which the orchestrator should
    /// auto-anchor bearing origins.
    static var isAutoTriangulationEnabled: Bool {
        isAutoTriToggleOn && autoTriPoint1 != nil && autoTriPoint2 != nil
    }

    /// First saved triangulation point in RS3 game-tile coordinates, or
    /// nil if the user has not calibrated it.
    static var autoTriPoint1: (x: Int, y: Int)? {
        guard UserDefaults.standard.bool(forKey: Keys.autoTriPoint1Set) else { return nil }
        let x = UserDefaults.standard.integer(forKey: Keys.autoTriPoint1X)
        let y = UserDefaults.standard.integer(forKey: Keys.autoTriPoint1Y)
        return (x, y)
    }

    /// Second saved triangulation point in RS3 game-tile coordinates, or
    /// nil if the user has not calibrated it.
    static var autoTriPoint2: (x: Int, y: Int)? {
        guard UserDefaults.standard.bool(forKey: Keys.autoTriPoint2Set) else { return nil }
        let x = UserDefaults.standard.integer(forKey: Keys.autoTriPoint2X)
        let y = UserDefaults.standard.integer(forKey: Keys.autoTriPoint2Y)
        return (x, y)
    }

    static func saveAutoTriPoint1(x: Int, y: Int) {
        let d = UserDefaults.standard
        d.set(x, forKey: Keys.autoTriPoint1X)
        d.set(y, forKey: Keys.autoTriPoint1Y)
        d.set(true, forKey: Keys.autoTriPoint1Set)
    }

    static func saveAutoTriPoint2(x: Int, y: Int) {
        let d = UserDefaults.standard
        d.set(x, forKey: Keys.autoTriPoint2X)
        d.set(y, forKey: Keys.autoTriPoint2Y)
        d.set(true, forKey: Keys.autoTriPoint2Set)
    }

    // MARK: - Arc (Eastern Lands) Auto-triangulation
    //
    // A parallel set of calibration points for master compass clues whose
    // region label reads "EASTERN LANDS". Completely independent of the
    // surface auto-tri points so the user can calibrate both separately.

    /// Raw toggle for Arc auto-triangulation, independent of saved points.
    static var isArcAutoTriToggleOn: Bool {
        UserDefaults.standard.bool(forKey: Keys.arcAutoTriEnabled)
    }

    /// True when the Arc toggle is on *and* both Arc calibration points are
    /// saved — the condition under which the orchestrator should auto-anchor
    /// Arc bearing origins.
    static var isArcAutoTriangulationEnabled: Bool {
        isArcAutoTriToggleOn && arcAutoTriPoint1 != nil && arcAutoTriPoint2 != nil
    }

    /// First saved Arc triangulation point in RS3 game-tile coordinates.
    static var arcAutoTriPoint1: (x: Int, y: Int)? {
        guard UserDefaults.standard.bool(forKey: Keys.arcAutoTriPoint1Set) else { return nil }
        let x = UserDefaults.standard.integer(forKey: Keys.arcAutoTriPoint1X)
        let y = UserDefaults.standard.integer(forKey: Keys.arcAutoTriPoint1Y)
        return (x, y)
    }

    /// Second saved Arc triangulation point in RS3 game-tile coordinates.
    static var arcAutoTriPoint2: (x: Int, y: Int)? {
        guard UserDefaults.standard.bool(forKey: Keys.arcAutoTriPoint2Set) else { return nil }
        let x = UserDefaults.standard.integer(forKey: Keys.arcAutoTriPoint2X)
        let y = UserDefaults.standard.integer(forKey: Keys.arcAutoTriPoint2Y)
        return (x, y)
    }

    static func saveArcAutoTriPoint1(x: Int, y: Int) {
        let d = UserDefaults.standard
        d.set(x, forKey: Keys.arcAutoTriPoint1X)
        d.set(y, forKey: Keys.arcAutoTriPoint1Y)
        d.set(true, forKey: Keys.arcAutoTriPoint1Set)
    }

    static func saveArcAutoTriPoint2(x: Int, y: Int) {
        let d = UserDefaults.standard
        d.set(x, forKey: Keys.arcAutoTriPoint2X)
        d.set(y, forKey: Keys.arcAutoTriPoint2Y)
        d.set(true, forKey: Keys.arcAutoTriPoint2Set)
    }

    // MARK: - Hotkey bindings

    /// The hotkey binding for the "Solve Clue" action.
    /// Defaults to ⌥1 when no custom binding has been saved.
    var solveHotkey: HotkeyBinding {
        get {
            let d = UserDefaults.standard
            guard let rawCode = d.object(forKey: Keys.hotkeySolveKeyCode) as? Int,
                  let rawMods = d.object(forKey: Keys.hotkeySolveModifiers) as? Int else {
                return .defaultSolve
            }
            return HotkeyBinding(keyCode: UInt16(rawCode),
                                 modifiers: NSEvent.ModifierFlags(rawValue: UInt(rawMods)))
        }
        set {
            let d = UserDefaults.standard
            d.set(Int(newValue.keyCode), forKey: Keys.hotkeySolveKeyCode)
            d.set(Int(newValue.modifiers.rawValue), forKey: Keys.hotkeySolveModifiers)
        }
    }

    /// The hotkey binding for the "Solve Puzzle Snip" action.
    /// Defaults to ⌥2 when no custom binding has been saved.
    var puzzleHotkey: HotkeyBinding {
        get {
            let d = UserDefaults.standard
            guard let rawCode = d.object(forKey: Keys.hotkeyPuzzleKeyCode) as? Int,
                  let rawMods = d.object(forKey: Keys.hotkeyPuzzleModifiers) as? Int else {
                return .defaultPuzzle
            }
            return HotkeyBinding(keyCode: UInt16(rawCode),
                                 modifiers: NSEvent.ModifierFlags(rawValue: UInt(rawMods)))
        }
        set {
            let d = UserDefaults.standard
            d.set(Int(newValue.keyCode), forKey: Keys.hotkeyPuzzleKeyCode)
            d.set(Int(newValue.modifiers.rawValue), forKey: Keys.hotkeyPuzzleModifiers)
        }
    }

    /// Resets both hotkey bindings to their factory defaults (⌥1 / ⌥2).
    func resetHotkeys() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.hotkeySolveKeyCode)
        d.removeObject(forKey: Keys.hotkeySolveModifiers)
        d.removeObject(forKey: Keys.hotkeyPuzzleKeyCode)
        d.removeObject(forKey: Keys.hotkeyPuzzleModifiers)
    }
}
