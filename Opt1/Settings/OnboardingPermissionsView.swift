import AppKit
import SwiftUI

/// First-run permissions onboarding. Two cards (Accessibility, Screen
/// Recording) with live status pills that update as the user grants each
/// permission in System Settings, plus a relaunch nudge for the SCK case.
///
/// Also reused outside first-run as the "Permissions…" menu destination so
/// users can re-open the same panel to re-grant a revoked permission.
struct OnboardingPermissionsView: View {

    @ObservedObject var state: PermissionsState
    /// Invoked when the user clicks the dismiss/done button. Owner closes
    /// the hosting window.
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            permissionCard(
                title: "Accessibility",
                reason: "Lets Opt1 register the global hotkey (⌥1 / ⌥2) so you can solve clues without switching to the menu bar.",
                granted: state.accessibilityGranted,
                isActive: !state.accessibilityGranted,
                buttonTitle: state.accessibilityGranted ? "Open Settings" : "Grant Accessibility",
                action: {
                    if state.accessibilityGranted {
                        state.openAccessibilitySettings()
                    } else {
                        state.requestAccessibility()
                    }
                }
            )

            permissionCard(
                title: "Screen Recording",
                reason: "Lets Opt1 see the RuneScape window so it can read clue text, detect puzzles, and place the overlay accurately.",
                granted: state.screenRecordingGranted,
                // Step 2 is gated on Step 1 to keep the ordering obvious; a
                // power user who's already granted Accessibility can act on
                // Step 2 immediately.
                isActive: state.accessibilityGranted && !state.screenRecordingGranted,
                disabled: !state.accessibilityGranted && !state.screenRecordingGranted,
                buttonTitle: state.screenRecordingGranted ? "Open Settings" : "Grant Screen Recording",
                action: {
                    if state.screenRecordingGranted {
                        state.openScreenRecordingSettings()
                    } else {
                        state.requestScreenRecording()
                    }
                }
            )

            if state.accessibilityGranted && !state.screenRecordingGranted {
                screenRecordingTroubleshooter
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 460)
        .background(OverlayTheme.bgPrimary)
        .foregroundStyle(OverlayTheme.textPrimary)
        .onAppear { state.startPolling() }
        .onDisappear { state.stopPolling() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Opt1")
                .font(.title2.weight(.semibold))
                .foregroundStyle(OverlayTheme.textPrimary)
            Text("Opt1 needs two macOS permissions to work. Grant them and then restart the app")
                .font(.callout)
                .foregroundStyle(OverlayTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - SR troubleshooter

    /// Surfaces a manual escape hatch for the (common) case where macOS
    /// hasn't auto-registered Opt1 in the Screen Recording list — typically
    /// because the user previously revoked the permission, or because a
    /// Debug build's signing identity differs from a previously-listed
    /// Release build. `tccutil reset` clears the prior denial; the `+`
    /// button + Reveal-in-Finder is the always-works manual path.
    @ViewBuilder
    private var screenRecordingTroubleshooter: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("If Opt1 isn't in the Screen Recording list, try this in order:")
                    .font(.callout)
                    .foregroundStyle(OverlayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(OverlayTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reset the permission and try again.")
                            .font(.callout)
                            .foregroundStyle(OverlayTheme.textPrimary)
                        Text("Clears any prior denial macOS remembers for Opt1, then re-runs the request. Most reliable fix.")
                            .font(.caption)
                            .foregroundStyle(OverlayTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Reset & Retry") { state.resetScreenRecordingTCC() }
                            .controlSize(.small)
                            .tint(OverlayTheme.gold)
                            .padding(.top, 2)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(OverlayTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add Opt1 manually.")
                            .font(.callout)
                            .foregroundStyle(OverlayTheme.textPrimary)
                        Text("In the Screen Recording panel, click the + button at the bottom-left, then drag Opt1 from the Finder window we'll open for you.")
                            .font(.caption)
                            .foregroundStyle(OverlayTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Reveal Opt1 in Finder") { state.revealAppInFinder() }
                                .controlSize(.small)
                                .tint(OverlayTheme.gold)
                            Button("Open Screen Recording Settings") { state.openScreenRecordingSettings() }
                                .controlSize(.small)
                                .tint(OverlayTheme.gold)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Don't see Opt1 in the list?")
                .font(.callout)
                .foregroundStyle(OverlayTheme.textSecondary)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Permission card

    private func permissionCard(
        title: String,
        reason: String,
        granted: Bool,
        isActive: Bool,
        disabled: Bool = false,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            statusGlyph(granted: granted, isActive: isActive)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(OverlayTheme.textPrimary)
                    statusPill(granted: granted)
                }
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(OverlayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(OverlayTheme.gold)
                .controlSize(.regular)
                .disabled(disabled)
                .opacity(granted ? 0.7 : 1.0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OverlayTheme.bgDeep)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isActive
                        ? OverlayTheme.gold.opacity(0.5)
                        : OverlayTheme.goldBorder.opacity(0.15),
                        lineWidth: isActive ? 1.5 : 1)
        )
    }

    private func statusGlyph(granted: Bool, isActive: Bool) -> some View {
        Group {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if isActive {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(OverlayTheme.gold)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(OverlayTheme.textSecondary)
            }
        }
        .font(.title3)
        .accessibilityHidden(true)
    }

    private func statusPill(granted: Bool) -> some View {
        Text(granted ? "Granted" : "Not granted")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(granted
                               ? OverlayTheme.gold.opacity(0.18)
                               : OverlayTheme.textSecondary.opacity(0.15))
            )
            .foregroundStyle(granted ? OverlayTheme.gold : OverlayTheme.textSecondary)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        if state.allGranted {
            VStack(alignment: .leading, spacing: 8) {
                if state.screenRecordingGrantedThisSession {
                    Label {
                        Text("Recommended: relaunch Opt1 so screen capture picks up the new permission.")
                            .font(.callout)
                            .foregroundStyle(OverlayTheme.textSecondary)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(OverlayTheme.textSecondary)
                    }
                } else {
                    Label {
                        Text("All set — you're ready to use Opt1.")
                            .font(.callout)
                            .foregroundStyle(OverlayTheme.textSecondary)
                    } icon: {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Spacer()
                    if state.screenRecordingGrantedThisSession {
                        Button("Quit Opt1") { NSApp.terminate(nil) }
                            .tint(OverlayTheme.gold)
                            .keyboardShortcut(.cancelAction)
                        Button("Quit & Relaunch") { state.relaunch() }
                            .buttonStyle(.borderedProminent)
                            .tint(OverlayTheme.gold)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Done", action: onDismiss)
                            .buttonStyle(.borderedProminent)
                            .tint(OverlayTheme.gold)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        } else {
            HStack(spacing: 12) {
                Text("This panel updates automatically — leave it open while you grant in System Settings.")
                    .font(.caption)
                    .foregroundStyle(OverlayTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Close", action: onDismiss)
                    .tint(OverlayTheme.gold)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

#Preview("Both missing") {
    OnboardingPermissionsView(state: PermissionsState(), onDismiss: {})
}
