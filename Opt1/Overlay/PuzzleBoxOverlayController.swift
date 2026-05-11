import AppKit
import SwiftUI
import Opt1Solvers

// MARK: - Model

@MainActor
final class PuzzleBoxOverlayModel: ObservableObject {
    enum Phase { case ready, stepping }

    @Published var phase: Phase = .ready
    @Published var puzzleName: String = ""
    @Published var moveCount: Int = 0
    @Published var currentStep: Int = 0
    @Published var currentRow: Int = 0
    @Published var currentCol: Int = 0

    var onStart:  (() -> Void)?
    var onCancel: (() -> Void)?
}

// MARK: - Stop control (shown in a separate interactive panel during stepping)

private struct PuzzleBoxStopControlView: View {
    var onStop: () -> Void

    var body: some View {
        Button(action: onStop) {
            Text("Stop")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Color(red: 0.72, green: 0.67, blue: 0.53))
                .padding(.horizontal, 24)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color(red: 0.07, green: 0.05, blue: 0.02).opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color(red: 0.90, green: 0.70, blue: 0.22).opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Grid view (Ready + Stepping phases)

private struct PuzzleBoxGridView: View {
    @ObservedObject var model: PuzzleBoxOverlayModel

    var body: some View {
        ZStack {
            if model.phase == .stepping {
                Canvas { ctx, size in
                    let cw = size.width  / 5
                    let ch = size.height / 5
                    let cellRect = CGRect(
                        x: CGFloat(model.currentCol) * cw + 2,
                        y: CGFloat(model.currentRow) * ch + 2,
                        width:  cw - 4,
                        height: ch - 4
                    )
                    let path = Path(roundedRect: cellRect, cornerRadius: 4)
                    ctx.fill(path,   with: .color(.yellow.opacity(0.30)))
                    ctx.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 4))
                }
            }

                if model.phase == .ready {
                    VStack(spacing: 10) {
                        Text(model.puzzleName)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.95, green: 0.90, blue: 0.78))
                        Text("\(model.moveCount) moves")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(red: 0.72, green: 0.67, blue: 0.53))
                        Button(action: { model.onStart?() }) {
                            Text("Start")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(Color(red: 0.07, green: 0.05, blue: 0.02))
                                .padding(.horizontal, 28)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color(red: 1.00, green: 0.80, blue: 0.25))
                                )
                        }
                        .buttonStyle(.plain)
                        Button(action: { model.onCancel?() }) {
                            Text("Cancel")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundColor(Color(red: 0.72, green: 0.67, blue: 0.53))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color(red: 0.07, green: 0.05, blue: 0.02).opacity(0.6))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Color(red: 0.90, green: 0.70, blue: 0.22).opacity(0.40), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                    .background(Color(red: 0.10, green: 0.08, blue: 0.04).opacity(0.92))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(red: 0.90, green: 0.70, blue: 0.22).opacity(0.45), lineWidth: 1)
                    )
                }

            if model.phase == .stepping {
                Text("\(model.currentStep) / \(model.moveCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(red: 1.00, green: 0.80, blue: 0.25))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color(red: 0.07, green: 0.05, blue: 0.02).opacity(0.85))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(red: 0.90, green: 0.70, blue: 0.22).opacity(0.4), lineWidth: 0.5))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Controller

/// Manages the grid overlay that appears on top of the physical puzzle box:
/// the "Ready" panel (puzzle name, move count, Start/Cancel) and the
/// "Stepping" phase that highlights each tile in sequence.
///
/// Pipeline progress messages ("Detecting…", "Solving…") are handled
/// separately by `PipelineStatusBanner`.
@MainActor
final class PuzzleBoxOverlayController {

    private var gridPanel:   NSPanel?
    private var gridHosting: NSHostingView<AnyView>?
    private var stopPanel:   NSPanel?
    private var stopHosting: NSHostingView<AnyView>?
    private var timer:       Timer?
    private var stepIndex:   Int = 0
    private var solution:    PuzzleBoxSolution?
    private var model        = PuzzleBoxOverlayModel()
    private var onSteppingStarted: (() -> Void)?

    private static let stopPanelSize = CGSize(width: 140, height: 44)
    private static let stopPanelGap: CGFloat = 8

    // MARK: - Ready state

    func showReady(solution: PuzzleBoxSolution, onSteppingStarted: (() -> Void)? = nil) {
        timer?.invalidate()
        timer = nil
        dismissAllPanels()

        self.solution  = solution
        self.stepIndex = 0
        self.onSteppingStarted = onSteppingStarted

        model           = PuzzleBoxOverlayModel()
        model.phase     = .ready
        model.puzzleName = solution.puzzleName
        model.moveCount  = solution.moves.count
        model.onStart  = { [weak self] in self?.startStepping() }
        model.onCancel = { [weak self] in self?.cancel() }

        let panel = makePanel(frame: PuzzleSnipDesktop.cgRectToAppKit(solution.gridBoundsOnScreen), passthrough: false)
        let hosting = NSHostingView(rootView: AnyView(PuzzleBoxGridView(model: model)))
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        panel.orderFront(nil)

        gridPanel   = panel
        gridHosting = hosting
    }

    // MARK: - Cancel

    func cancel() {
        timer?.invalidate()
        timer = nil
        dismissAllPanels()
        solution  = nil
        stepIndex = 0
        onSteppingStarted = nil
    }

    // MARK: - Stepping

    private func startStepping() {
        guard let sol = solution, !sol.moves.isEmpty else { return }
        // Notify observers (e.g. PuzzleBoxCoordinator) that the user has committed
        // to this route, before any side effects — so they can cancel background
        // refinement before a late improvement lands and resets the overlay.
        onSteppingStarted?()
        onSteppingStarted = nil

        model.phase = .stepping
        gridPanel?.ignoresMouseEvents = true
        presentStopPanel(for: sol)
        updateStep(0)
        let interval = AppSettings.shared.puzzleGuidanceStepInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self else { t.invalidate(); return }
                self.advance(timer: t)
            }
        }
    }

    private func presentStopPanel(for solution: PuzzleBoxSolution) {
        let gridAppKit = PuzzleSnipDesktop.cgRectToAppKit(solution.gridBoundsOnScreen)
        let size = Self.stopPanelSize
        let gap = Self.stopPanelGap

        let screenFrame: NSRect = NSScreen.screens.first(where: {
            $0.frame.contains(CGPoint(x: gridAppKit.midX, y: gridAppKit.midY))
        })?.visibleFrame ?? (NSScreen.main?.visibleFrame ?? gridAppKit.insetBy(dx: -size.width, dy: -size.height))

        // Prefer above the grid visually (larger AppKit Y). If that would spill
        // past the top of the screen, place below instead; as a last resort
        // clamp inside the screen.
        let aboveY = gridAppKit.maxY + gap
        let belowY = gridAppKit.minY - size.height - gap
        var originY: CGFloat
        if aboveY + size.height <= screenFrame.maxY {
            originY = aboveY
        } else if belowY >= screenFrame.minY {
            originY = belowY
        } else {
            originY = min(max(aboveY, screenFrame.minY), screenFrame.maxY - size.height)
        }

        var originX = gridAppKit.midX - size.width / 2
        originX = min(max(originX, screenFrame.minX), screenFrame.maxX - size.width)

        let frame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        let panel = makePanel(frame: frame, passthrough: false)
        let hosting = NSHostingView(
            rootView: AnyView(PuzzleBoxStopControlView(onStop: { [weak self] in self?.cancel() }))
        )
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        panel.orderFront(nil)

        stopPanel = panel
        stopHosting = hosting
    }

    private func advance(timer t: Timer) {
        guard let sol = solution else { t.invalidate(); return }
        stepIndex += 1
        if stepIndex >= sol.moves.count {
            t.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.cancel()
            }
            return
        }
        updateStep(stepIndex)
    }

    private func updateStep(_ step: Int) {
        guard let sol = solution, step < sol.moves.count else { return }
        let move = sol.moves[step]
        model.currentStep = step + 1
        model.currentRow  = move.row
        model.currentCol  = move.col
    }

    // MARK: - Helpers

    private func dismissAllPanels() {
        gridPanel?.orderOut(nil)
        gridPanel?.close()
        gridPanel   = nil
        gridHosting = nil
        stopPanel?.orderOut(nil)
        stopPanel?.close()
        stopPanel   = nil
        stopHosting = nil
    }

    private func makePanel(frame: NSRect, passthrough: Bool) -> NSPanel {
        OverlayPanelFactory.makeFloatingPanel(frame: frame, passthrough: passthrough)
    }

}
