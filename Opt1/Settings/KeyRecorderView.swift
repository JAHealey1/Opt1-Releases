import AppKit
import SwiftUI

// MARK: - KeyRecorderView

/// A button-like control that records a single key-combo from the user.
///
/// Usage:
/// ```swift
/// KeyRecorderView(binding: $solveBinding, onCommit: { newBinding in ... })
/// ```
///
/// - Shows the current binding as a display string (e.g. "⌥1").
/// - On click enters "recording" mode (label: "Type shortcut…"); a local
///   NSEvent monitor captures the next qualifying .keyDown.
/// - Valid combos require at least one of ⌘/⌥/⌃. ⇧ alone is rejected.
/// - Pressing Escape cancels without saving.
struct KeyRecorderView: NSViewRepresentable {

    @Binding var binding: HotkeyBinding
    /// Called after the user successfully records and commits a new combo.
    var onCommit: ((HotkeyBinding) -> Void)?

    func makeNSView(context: Context) -> KeyRecorderButton {
        let button = KeyRecorderButton()
        button.coordinator = context.coordinator
        button.updateLabel(binding.displayString)
        return button
    }

    func updateNSView(_ nsView: KeyRecorderButton, context: Context) {
        if !nsView.isRecording {
            nsView.updateLabel(binding.displayString)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    final class Coordinator {
        var parent: KeyRecorderView
        private var monitor: Any?

        init(parent: KeyRecorderView) {
            self.parent = parent
        }

        func startRecording(in button: KeyRecorderButton) {
            button.isRecording = true
            button.updateLabel("Type shortcut…")

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak button] event in
                guard let self, let button else { return event }

                // Escape → cancel
                if event.keyCode == 53 {
                    self.stopRecording(in: button, commit: nil)
                    return nil
                }

                let stripped = event.modifierFlags.intersection([.command, .shift, .option, .control])

                // Require at least one non-shift modifier
                let hasRequiredModifier = stripped.contains(.command)
                    || stripped.contains(.option)
                    || stripped.contains(.control)

                guard hasRequiredModifier else {
                    // Flash label to hint invalid combo
                    button.flashInvalid()
                    return nil
                }

                let newBinding = HotkeyBinding(keyCode: event.keyCode, modifiers: stripped)
                self.stopRecording(in: button, commit: newBinding)
                return nil
            }
        }

        func stopRecording(in button: KeyRecorderButton, commit newBinding: HotkeyBinding?) {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            button.isRecording = false
            if let newBinding {
                parent.binding = newBinding
                parent.onCommit?(newBinding)
                button.updateLabel(newBinding.displayString)
            } else {
                button.updateLabel(parent.binding.displayString)
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - KeyRecorderButton (NSView)

/// The backing NSView for KeyRecorderView. Draws as a pill-shaped button that
/// highlights when recording and supports keyboard cancellation via Escape.
final class KeyRecorderButton: NSView {

    weak var coordinator: KeyRecorderView.Coordinator?

    var isRecording = false {
        didSet { needsDisplay = true }
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1

        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    func updateLabel(_ text: String) {
        label.stringValue = text
        applyColors()
    }

    func flashInvalid() {
        let original = label.stringValue
        label.stringValue = "Need ⌘/⌥/⌃"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isRecording else { return }
            self.label.stringValue = "Type shortcut…"
            _ = original
        }
    }

    private func applyColors() {
        if isRecording {
            layer?.backgroundColor = NSColor(OverlayTheme.gold).withAlphaComponent(0.15).cgColor
            layer?.borderColor     = NSColor(OverlayTheme.gold).cgColor
            label.textColor        = NSColor(OverlayTheme.gold)
        } else {
            layer?.backgroundColor = NSColor(OverlayTheme.bgDeep).cgColor
            layer?.borderColor     = NSColor(OverlayTheme.goldBorder).withAlphaComponent(0.45).cgColor
            label.textColor        = NSColor(OverlayTheme.textPrimary)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        applyColors()
    }

    @objc private func handleClick() {
        if isRecording {
            coordinator?.stopRecording(in: self, commit: nil)
        } else {
            coordinator?.startRecording(in: self)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 90, height: 26)
    }

    override var acceptsFirstResponder: Bool { true }
}
