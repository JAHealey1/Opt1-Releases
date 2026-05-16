import AppKit
import SwiftUI

// MARK: - Display helper

/// Builds the full keybind sequence string shown to the user.
/// Custom pre-steps (e.g. ["P", "⌥5"]) are joined first; the known
/// in-game `code` from teleports.json (e.g. "2") is appended last.
/// Returns nil when there is nothing to show.
func keybindSequence(steps: [String], code: String?) -> String? {
    let trimmed = steps.filter { !$0.isEmpty }
    let all: [String]
    if let code, !code.isEmpty {
        all = trimmed + [code]
    } else {
        all = trimmed
    }
    return all.isEmpty ? nil : all.joined(separator: " > ")
}

// MARK: - StepKeyRecorderView

/// A one-shot key-capture control used to record a single keybind step.
/// Unlike `KeyRecorderView`, any key is valid — bare letters/numbers,
/// Shift-only combos, and modifier+key combos are all accepted.
/// The view auto-enters recording mode when it first appears.
/// Escape cancels; any other key commits and calls `onCapture`.
struct StepKeyRecorderView: NSViewRepresentable {

    var onCapture: (String) -> Void
    var onCancel:  () -> Void

    func makeNSView(context: Context) -> StepRecorderLabel {
        let view = StepRecorderLabel()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: StepRecorderLabel, context: Context) {
        if !nsView.hasStarted {
            nsView.hasStarted = true
            context.coordinator.startRecording(in: nsView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: Coordinator

    final class Coordinator {
        var parent: StepKeyRecorderView
        private var monitor: Any?

        init(parent: StepKeyRecorderView) { self.parent = parent }

        func startRecording(in view: StepRecorderLabel) {
            view.isRecording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                guard let self, let view else { return event }
                if event.keyCode == 53 {       // Escape → cancel
                    self.stop(in: view)
                    self.parent.onCancel()
                    return nil
                }
                let label = Self.stepLabel(for: event)
                self.stop(in: view)
                self.parent.onCapture(label)
                return nil
            }
        }

        private func stop(in view: StepRecorderLabel) {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            view.isRecording = false
        }

        static func stepLabel(for event: NSEvent) -> String {
            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            var result = ""
            if mods.contains(.control) { result += "⌃" }
            if mods.contains(.option)  { result += "⌥" }
            if mods.contains(.shift)   { result += "⇧" }
            if mods.contains(.command) { result += "⌘" }
            result += HotkeyBinding.keyName(for: event.keyCode)
            return result
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

// MARK: - StepRecorderLabel (NSView)

/// Pill-shaped visual indicator shown while a step is being recorded.
final class StepRecorderLabel: NSView {

    weak var coordinator: StepKeyRecorderView.Coordinator?
    var hasStarted = false

    var isRecording = false { didSet { needsDisplay = true; applyColors() } }

    private let label = NSTextField(labelWithString: "Press a key…")

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = NSColor(OverlayTheme.gold).withAlphaComponent(0.15).cgColor
        layer?.borderColor     = NSColor(OverlayTheme.gold).cgColor
        label.textColor        = NSColor(OverlayTheme.gold)
    }

    override func draw(_ dirtyRect: NSRect) { super.draw(dirtyRect); applyColors() }

    override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 26) }
    override var acceptsFirstResponder: Bool { false }
}

// MARK: - TeleportInstructionSheet

/// Sheet for recording and saving custom keybind pre-steps for a teleport.
/// For most groups steps are stored per `groupId`; for spellbook-style groups
/// (listed in `AppSettings.perSpotKeybindGroups`) they are stored per spot id.
/// The known in-game `code` (from teleports.json) is shown in the preview
/// but is never stored — it is always appended at display time.
struct TeleportInstructionSheet: View {

    /// Storage key: either a `groupId` or a `TeleportSpot.id`, depending on `isSpotLevel`.
    let scopeId:     String
    /// Primary display name shown in the sheet header.
    let scopeName:   String
    /// Secondary context line, e.g. "All Skills Necklace teleports" or "Camelot · Lunar Spellbook".
    let contextLine: String
    let knownCode:   String?
    /// When true, reads/writes `AppSettings.teleportSpotSteps`; otherwise uses `teleportGroupSteps`.
    let isSpotLevel: Bool

    @Environment(\.dismiss) private var dismiss

    @State private var steps:       [String] = []
    @State private var isRecording: Bool     = false

    init(scopeId: String, scopeName: String, contextLine: String, knownCode: String?, isSpotLevel: Bool) {
        self.scopeId     = scopeId
        self.scopeName   = scopeName
        self.contextLine = contextLine
        self.knownCode   = knownCode
        self.isSpotLevel = isSpotLevel
        let existing = isSpotLevel
            ? AppSettings.teleportSpotSteps[scopeId] ?? []
            : AppSettings.teleportGroupSteps[scopeId] ?? []
        _steps = State(initialValue: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {

            // MARK: Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom keybind")
                    .font(.headline)
                    .foregroundStyle(OverlayTheme.gold)
                Text(scopeName)
                    .font(.subheadline)
                    .foregroundStyle(OverlayTheme.textPrimary)
                Text(contextLine)
                    .font(.caption)
                    .foregroundStyle(OverlayTheme.textSecondary)
            }

            // MARK: Step builder
            VStack(alignment: .leading, spacing: 8) {
                Text("Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OverlayTheme.gold.opacity(0.8))
                    .textCase(.uppercase)

                stepChipsRow
            }

            // MARK: Preview
            if let seq = keybindSequence(steps: steps, code: knownCode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OverlayTheme.gold.opacity(0.8))
                        .textCase(.uppercase)
                    Text(seq)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(OverlayTheme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(OverlayTheme.bgDeep)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(OverlayTheme.goldBorder.opacity(0.3), lineWidth: 1)
                                )
                        )
                }
            }

            Spacer()

            // MARK: Action buttons
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(OverlayTheme.textSecondary)

                Spacer()

                if !steps.isEmpty {
                    Button("Clear") {
                        steps = []
                        isRecording = false
                        save(steps: [])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(OverlayTheme.textSecondary)
                }

                Button("Save") {
                    save(steps: steps)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OverlayTheme.bgDeep)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(OverlayTheme.gold.opacity(0.8))
                )
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(OverlayTheme.bgPrimary)
        .foregroundStyle(OverlayTheme.textPrimary)
    }

    // MARK: Step chips

    @ViewBuilder
    private var stepChipsRow: some View {
        HStack(spacing: 6) {
            // Existing step chips
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepChip(step, index: index)
            }

            // Recording control or add button
            if isRecording {
                StepKeyRecorderView(
                    onCapture: { label in
                        steps.append(label)
                        isRecording = false
                    },
                    onCancel: {
                        isRecording = false
                    }
                )
                .frame(width: 140, height: 26)
            } else {
                Button {
                    isRecording = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Record step")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(OverlayTheme.gold.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(OverlayTheme.gold.opacity(0.10))
                            .overlay(Capsule().strokeBorder(OverlayTheme.goldBorder.opacity(0.4), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OverlayTheme.bgDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(OverlayTheme.goldBorder.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func stepChip(_ label: String, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(OverlayTheme.textPrimary)
            Button {
                steps.remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(OverlayTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(OverlayTheme.bgPrimary)
                .overlay(Capsule().strokeBorder(OverlayTheme.goldBorder.opacity(0.5), lineWidth: 0.5))
        )
    }

    private func save(steps: [String]) {
        if isSpotLevel {
            AppSettings.setSpotSteps(steps, forSpotId: scopeId)
        } else {
            AppSettings.setGroupSteps(steps, forGroupId: scopeId)
        }
    }
}
