import CoreGraphics
import Foundation

// MARK: - CaptureErrorPresenting

/// Presents the pre-pipeline capture errors: the RuneScape window isn't
/// visible, Screen Recording permission isn't granted, or a generic capture
/// failure. Keeps this mapping out of `ClueOrchestrator` and gives the
/// "open permissions" side effect a concrete owner rather than leaking
/// through an escaping closure on the orchestrator.
@MainActor
protocol CaptureErrorPresenting: AnyObject {
    /// Invoked when `showCaptureError` classifies an error as a Screen
    /// Recording permission denial, after the advisory overlay is shown.
    var onOpenPermissions: (() -> Void)? { get set }

    /// Overlay shown when `WindowFinder` can't locate the RS3 window.
    func showWindowNotFound()

    /// Inspects the error and either prompts the user to grant Screen
    /// Recording permission (invoking `onOpenPermissions`) or shows a
    /// generic capture-error overlay.
    func showCaptureError(_ error: Error)
}

// MARK: - CaptureErrorPresenter

@MainActor
final class CaptureErrorPresenter: CaptureErrorPresenting {
    private let presenter: any OverlayPresenting
    var onOpenPermissions: (() -> Void)?

    init(presenter: any OverlayPresenting) {
        self.presenter = presenter
    }

    func showWindowNotFound() {
        presenter.showOverlay(
            message: "RuneScape not found",
            detail: "Make sure RS3 is running",
            mode: .error
        )
    }

    func showCaptureError(_ error: Error) {
        let nsErr = error as NSError
        if nsErr.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && nsErr.code == -3811 {
            presenter.showOverlay(
                message: "Screen Recording not granted",
                detail: "Open Permissions… in the menu, add Opt1, then restart the app",
                mode: .error
            )
            onOpenPermissions?()
        } else {
            presenter.showOverlay(
                message: "Capture error",
                detail: error.localizedDescription,
                mode: .error
            )
        }
    }
}
