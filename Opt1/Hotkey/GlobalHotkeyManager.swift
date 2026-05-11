import AppKit

enum GlobalHotkeyAction {
    case solveClue
    case solvePuzzleSnip
}

/// Registers a global key-down monitor for Opt1 hotkeys.
/// The active bindings are read from AppSettings at registration time, so
/// calling register() again after a binding change picks up the new combo.
/// Requires Accessibility permission; if not granted, events will not be delivered.
final class GlobalHotkeyManager {

    private var monitor: Any?
    // @MainActor: hotkey actions must be dispatched on the main actor.
    // @Sendable: allows safe capture across concurrency boundaries.
    private let callback: @MainActor @Sendable (GlobalHotkeyAction) -> Void

    init(callback: @escaping @MainActor @Sendable (GlobalHotkeyAction) -> Void) {
        self.callback = callback
    }

    /// Installs the global key-down monitor using the bindings currently stored
    /// in AppSettings. Safe to call multiple times — any existing monitor is torn
    /// down first so we never accumulate duplicates.
    func register() {
        unregister()

        let accessible = AXIsProcessTrusted()

        let solve  = AppSettings.shared.solveHotkey
        let puzzle = AppSettings.shared.puzzleHotkey
        // Capture the callback by value (it is @Sendable) so the monitor closure
        // does not need to reach back through self.
        let cb = callback

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self != nil else { return }
            // Capture only Sendable primitives from the NSEvent before hopping actors.
            let keyCode = event.keyCode
            let rawMods = event.modifierFlags.rawValue
            // NSEvent global monitors fire on the main thread; assumeIsolated lets
            // us call @MainActor code synchronously without a Task allocation.
            MainActor.assumeIsolated {
                // Mask out CapsLock and numpad flags before comparing.
                let stripped = NSEvent.ModifierFlags(rawValue: rawMods)
                    .intersection([.command, .shift, .option, .control])
                if keyCode == solve.keyCode  && stripped == solve.modifiers  {
                    cb(.solveClue)
                } else if keyCode == puzzle.keyCode && stripped == puzzle.modifiers {
                    cb(.solvePuzzleSnip)
                }
            }
        }

        if accessible {
            print("[Opt1] Hotkeys registered (\(solve.displayString) clue, \(puzzle.displayString) puzzle snip)")
        } else {
            print("[Opt1] Hotkey monitor created but Accessibility not granted — key events will not be delivered. Grant access in System Settings > Privacy & Security > Accessibility, then relaunch.")
        }
    }

    /// Removes the currently installed monitor, if any. Idempotent.
    func unregister() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        unregister()
    }
}
