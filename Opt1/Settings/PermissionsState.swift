import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import ScreenCaptureKit

/// Observable wrapper around the two TCC permissions Opt1 needs at launch.
/// Drives the onboarding window's UI: cards flip from "Not granted" to
/// "Granted" without the user having to relaunch (or guess) when they come
/// back from System Settings.
///
/// Polling is the simplest reliable signal — there's no public KVO/notification
/// for TCC grant changes, and `CGRequestScreenCaptureAccess()` doesn't have a
/// callback. A 1 s tick is cheap (`AXIsProcessTrusted()` and
/// `CGPreflightScreenCaptureAccess()` are both fast bool reads).
@MainActor
final class PermissionsState: ObservableObject {

    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var screenRecordingGranted: Bool

    /// True once the user has granted Screen Recording during this app session.
    /// SCK streams created before the grant may continue using stale TCC state,
    /// so we surface a relaunch nudge once this flips.
    @Published private(set) var screenRecordingGrantedThisSession: Bool = false

    private var timer: Timer?
    /// Guards against stacking multiple in-flight `SCShareableContent` checks
    /// from rapid polling ticks — they're cheap but no need to pile up.
    private var deepCheckInFlight: Bool = false

    init() {
        self.accessibilityGranted = AXIsProcessTrusted()
        self.screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    var allGranted: Bool {
        accessibilityGranted && screenRecordingGranted
    }

    /// Begins polling. Safe to call multiple times — replaces the existing timer.
    func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// One-shot read of both permissions. Exposed for callers that want to
    /// react to e.g. `applicationDidBecomeActive` without waiting for the tick.
    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibilityGranted {
            accessibilityGranted = ax
        }
        // Fast path. `CGPreflightScreenCaptureAccess()` is cheap but its
        // result is cached per-process by macOS; on Sequoia/Tahoe the cache
        // can stay `false` even after the user toggles the permission on
        // (especially when they added Opt1 manually via the `+` button
        // rather than going through `CGRequestScreenCaptureAccess()`'s
        // prompt). So preflight only positively *confirms* a grant.
        if CGPreflightScreenCaptureAccess() && !screenRecordingGranted {
            screenRecordingGranted = true
            screenRecordingGrantedThisSession = true
            return
        }
        // Slow path: when preflight says no, ask SCShareableContent for the
        // current shareable content. If TCC has flipped to allow we get a
        // real result back and treat that as ground truth, bypassing the
        // stale preflight cache. Throws → still no permission.
        deepCheckScreenRecordingAccess()
    }

    private func deepCheckScreenRecordingAccess() {
        guard !screenRecordingGranted, !deepCheckInFlight else { return }
        deepCheckInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.deepCheckInFlight = false }
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let self else { return }
                if !self.screenRecordingGranted {
                    self.screenRecordingGranted = true
                    self.screenRecordingGrantedThisSession = true
                }
            } catch {
                // Still not granted — leave state alone.
            }
        }
    }

    // MARK: - Actions

    /// Triggers the system Accessibility prompt. The first call shows a
    /// system-modal dialog with an "Open System Settings" button that
    /// deep-links into Privacy → Accessibility. Subsequent calls (after the
    /// user dismisses) silently reopen the prompt.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens Privacy → Accessibility directly (used when the system prompt
    /// has already been shown once and clicking the button should jump
    /// straight to Settings without showing the dialog again).
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Forces TCC to register Opt1 in Privacy → Screen Recording, then opens
    /// the pane so the user can flip the toggle.
    ///
    /// `CGRequestScreenCaptureAccess()` alone is unreliable for getting the
    /// app to *appear* in the Screen Recording list — TCC only registers the
    /// bundle ID once a real screen-capture API has been touched. We force
    /// that by asking `SCShareableContent` for the current shareable
    /// content; the user not having granted yet causes it to throw, but the
    /// side effect (TCC adding Opt1 to the Screen Recording pane with its
    /// toggle off) is what we actually want. Then we open the pane so the
    /// row is visible and toggleable.
    func requestScreenRecording() {
        Task { @MainActor in
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
            } catch {
                // Expected on first run — the throw means TCC saw the
                // request and registered Opt1 in the SR list, which is the
                // whole point of this call.
            }
            // Belt-and-braces: also nudges TCC. Safe to call repeatedly;
            // on macOS 15+ this also re-presents the system prompt.
            CGRequestScreenCaptureAccess()
            self.openScreenRecordingSettings()
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Clears any prior Screen Recording denial for Opt1 from TCC, then
    /// re-runs the request flow. Useful when the user previously revoked
    /// the permission — TCC remembers denials and silently no-ops
    /// `CGRequestScreenCaptureAccess()` for denied bundles, leaving them
    /// out of the System Settings list. `tccutil` doesn't require admin
    /// auth and only touches the specified bundle.
    func resetScreenRecordingTCC() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
            print("[Opt1] tccutil reset ScreenCapture \(bundleID) → status \(task.terminationStatus)")
        } catch {
            print("[Opt1] tccutil reset failed: \(error)")
        }
        // After resetting, re-run the registration + open Settings flow.
        requestScreenRecording()
    }

    /// Reveals the running Opt1 .app in Finder so the user can drag it into
    /// the Screen Recording list (or use the `+` button → Applications →
    /// Opt1) when auto-registration has failed.
    func revealAppInFinder() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Restarts the app. Required after granting Screen Recording so SCK
    /// picks up the new TCC entry on a fresh process. We spawn a detached
    /// shell that sleeps briefly then re-opens the bundle, so the current
    /// process can fully exit before macOS launches the replacement (avoids
    /// a "Opt1 is already open" race).
    func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 0.5 && /usr/bin/open \"\(bundlePath)\""]
        do {
            try task.run()
        } catch {
            print("[Opt1] Relaunch failed: \(error)")
        }
        NSApp.terminate(nil)
    }
}
