import AppKit
import CoreGraphics
import ScreenCaptureKit
import Sparkle
import SwiftUI
import Opt1Matching

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private var hotkeyManager: GlobalHotkeyManager?

    private let captureManager = ScreenCaptureManager()
    private let statusBanner = PipelineStatusBanner()
    private let puzzleBoxOverlay = PuzzleBoxOverlayController()
    private let puzzleSnipOverlay = PuzzleSnipOverlayController()

    private let clueDatabase = ClueDatabase.shared
    private let sessionState = AppSessionState()
    private lazy var presenter = OverlayPresenter(clueProvider: clueDatabase)
    private lazy var captureErrorPresenter = CaptureErrorPresenter(presenter: presenter)
    private lazy var orchestrator = ClueOrchestrator(
        captureManager: captureManager,
        statusBanner: statusBanner,
        puzzleBoxOverlay: puzzleBoxOverlay,
        puzzleSnipOverlay: puzzleSnipOverlay,
        presenter: presenter,
        clueProvider: clueDatabase,
        captureErrorPresenter: captureErrorPresenter,
        sessionState: sessionState
    )

    private var puzzleDataCollectionController: PuzzleDataCollectionController?
    private var celticKnotDataCollectionController: CelticKnotDataCollectionController?
    private var sliderAnchorCollectionController: SliderAnchorCollectionController?
    private var settingsWindowController: NSWindowController?
    private var calibrationWindowController: NSWindowController?
    private var arcCalibrationWindowController: NSWindowController?
    private var permissionsWindowController: NSWindowController?

    /// Single source of truth for AX + Screen Recording grant state. Owned by
    /// AppDelegate so the same instance backs both the first-run onboarding
    /// window and the "Permissions…" menu re-open.
    private let permissionsState = PermissionsState()

    private lazy var updaterController: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }()
    /// Shared navigation state
    private let settingsNavigation = SettingsNavigationModel()

    private var debugOnlyMenuItems: [NSMenuItem] = []
    private var developerOnlyMenuItems: [NSMenuItem] = []

    /// References to the two primary action menu items so their titles can be refreshed when the user changes their hotkey bindings in Settings
    private var solveMenuItem: NSMenuItem?
    private var puzzleMenuItem: NSMenuItem?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        showOnboardingIfNeeded()
        setupHotkey()
        clueDatabase.load()
        TeleportCatalogue.shared.load()

        captureErrorPresenter.onOpenPermissions = { [weak self] in self?.openPermissions() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        permissionsState.refresh()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.title = "Opt1"
        button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)

        let menu = NSMenu()
        menu.delegate = self
        let solveItem = menu.addItem(withTitle: "", action: #selector(triggerSolve), keyEquivalent: "")
        let puzzleItem = menu.addItem(withTitle: "", action: #selector(triggerPuzzleSnip), keyEquivalent: "")
        solveMenuItem  = solveItem
        puzzleMenuItem = puzzleItem
        refreshMenuTitles()

        let puzzleCollect  = menu.addItem(withTitle: "Puzzle Data Collection…", action: #selector(triggerPuzzleDataCollection), keyEquivalent: "")
        let celticCollect  = menu.addItem(withTitle: "Celtic Knot Data Collection…", action: #selector(triggerCelticKnotDataCollection), keyEquivalent: "")
        let anchorCollect  = menu.addItem(withTitle: "Slider Anchor Collection…", action: #selector(triggerSliderAnchorCollection), keyEquivalent: "")
        let debugWindows   = menu.addItem(withTitle: "Debug: List Windows", action: #selector(debugListWindows), keyEquivalent: "")
        developerOnlyMenuItems = [puzzleCollect, celticCollect, anchorCollect]
        debugOnlyMenuItems = [debugWindows]

        menu.addItem(NSMenuItem.separator())
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = self
        menu.addItem(checkForUpdates)
        menu.addItem(withTitle: "Permissions...", action: #selector(openPermissions), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Credits & Licenses…", action: #selector(openCredits), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Opt1", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Permissions onboarding

    private func showOnboardingIfNeeded() {
        permissionsState.refresh()
        let needsOnboarding = !permissionsState.accessibilityGranted
                              || !permissionsState.screenRecordingGranted
        if needsOnboarding {
            print("[Opt1] Missing permissions - showing onboarding window")
            showPermissionsWindow()
        } else {
            print("[Opt1] Accessibility + Screen Recording already granted")
        }
    }

    private func showPermissionsWindow() {
        if permissionsWindowController == nil {
            let view = OnboardingPermissionsView(
                state: permissionsState,
                onDismiss: { [weak self] in self?.permissionsWindowController?.close() }
            )
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Opt1 Permissions"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(OverlayTheme.bgPrimary)
            permissionsWindowController = NSWindowController(window: window)
        }
        permissionsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        showSettingsWindow(route: nil)
    }

    @objc func openCredits() {
        showSettingsWindow(route: .credits)
    }

    private func showSettingsWindow(route: SettingsRoute?) {
        if settingsWindowController == nil {
            let view = SettingsView(
                navigation: settingsNavigation,
                onOpenCalibration: { [weak self] in self?.openCalibrationWindow() },
                onOpenArcCalibration: { [weak self] in self?.openArcCalibrationWindow() },
                onHotkeyChanged: { [weak self] in
                    self?.hotkeyManager?.register()
                    self?.refreshMenuTitles()
                }
            )
            let host = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: host)
            window.title = "Opt1 Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(OverlayTheme.bgPrimary)
            settingsWindowController = NSWindowController(window: window)
        }
        if let route {
            settingsNavigation.path = [route]
        } else {
            settingsNavigation.path = []
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func openCalibrationWindow() {
        let view = CalibrationView(
            onClose: { [weak self] in self?.closeCalibrationWindow() }
        )
        let host = NSHostingController(rootView: view)
        host.preferredContentSize = NSSize(width: 620, height: 540)

        let window: NSWindow
        if let existing = calibrationWindowController?.window {
            existing.contentViewController = host
            window = existing
        } else {
            window = NSWindow(contentViewController: host)
            window.title = "Calibrate Triangulation Points"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 540))
            window.center()
            calibrationWindowController = NSWindowController(window: window)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeCalibrationWindow() {
        calibrationWindowController?.close()
    }

    private func openArcCalibrationWindow() {
        let view = CalibrationView(
            variant: .arc,
            onClose: { [weak self] in self?.closeArcCalibrationWindow() }
        )
        let host = NSHostingController(rootView: view)
        host.preferredContentSize = NSSize(width: 620, height: 540)

        let window: NSWindow
        if let existing = arcCalibrationWindowController?.window {
            existing.contentViewController = host
            window = existing
        } else {
            window = NSWindow(contentViewController: host)
            window.title = "Calibrate Arc Triangulation Points"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 620, height: 540))
            window.center()
            arcCalibrationWindowController = NSWindowController(window: window)
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeArcCalibrationWindow() {
        arcCalibrationWindowController?.close()
    }

    @objc func openPermissions() {
        showPermissionsWindow()
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager = GlobalHotkeyManager { [weak self] action in
            Task { @MainActor [weak self] in
                await self?.orchestrator.handleHotkeyAction(action)
            }
        }
        hotkeyManager?.register()
    }

    private func refreshMenuTitles() {
        let s = AppSettings.shared
        solveMenuItem?.title  = "Solve Clue  (\(s.solveHotkey.displayString))"
        puzzleMenuItem?.title = "Solve Puzzle (Snip)  (\(s.puzzleHotkey.displayString))"
    }

    // MARK: - Menu Actions

    @objc private func triggerSolve() {
        Task { await orchestrator.solveClueAction() }
    }

    @objc private func triggerPuzzleSnip() {
        Task { await orchestrator.handleHotkeyAction(.solvePuzzleSnip) }
    }

    @objc private func triggerPuzzleDataCollection() {
        Task { await startPuzzleDataCollection() }
    }

    @objc private func triggerCelticKnotDataCollection() {
        Task { await startCelticKnotDataCollection() }
    }

    @objc private func triggerSliderAnchorCollection() {
        Task { await startSliderAnchorCollection() }
    }

    @objc private func debugListWindows() {
        Task {
            do {
                try await WindowFinder.debugListWindows()
            } catch {
                print("[Opt1] debugListWindows error: \(error)")
            }
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    // MARK: - Data Collection

    private func startPuzzleDataCollection() async {
        if sessionState.isSolveRunning {
            presenter.showOverlay(
                message: "Busy",
                detail: "Wait for current solve to finish before data collection.",
                mode: .phase1Confirmation
            )
            return
        }
        if sessionState.isDataCollectionActive {
            presenter.showOverlay(
                message: "Data collection already active",
                detail: "Use the collector panel to continue or cancel.",
                mode: .phase1Confirmation
            )
            return
        }
        if puzzleDataCollectionController == nil {
            puzzleDataCollectionController = PuzzleDataCollectionController(
                captureManager: captureManager,
                snipOverlay: puzzleSnipOverlay
            ) { [weak self] active in
                self?.sessionState.isDataCollectionActive = active
            }
        }
        await puzzleDataCollectionController?.start()
    }

    private func startSliderAnchorCollection() async {
        if sessionState.isSolveRunning || sessionState.isAnyCollectionActive {
            presenter.showOverlay(
                message: "Busy",
                detail: "Wait for the current operation to finish.",
                mode: .phase1Confirmation
            )
            return
        }
        if sliderAnchorCollectionController == nil {
            sliderAnchorCollectionController = SliderAnchorCollectionController(
                captureManager: captureManager,
                snipOverlay: puzzleSnipOverlay
            ) { [weak self] active in
                self?.sessionState.isDataCollectionActive = active
            }
        }
        await sliderAnchorCollectionController?.start()
    }

    private func startCelticKnotDataCollection() async {
        if sessionState.isSolveRunning {
            presenter.showOverlay(
                message: "Busy",
                detail: "Wait for current solve to finish.",
                mode: .phase1Confirmation
            )
            return
        }
        if sessionState.isAnyCollectionActive {
            presenter.showOverlay(
                message: "Data collection already active",
                detail: "Use the collector panel to continue or cancel.",
                mode: .phase1Confirmation
            )
            return
        }
        if celticKnotDataCollectionController == nil {
            celticKnotDataCollectionController = CelticKnotDataCollectionController(
                captureManager: captureManager,
                snipOverlay: puzzleSnipOverlay
            ) { [weak self] active in
                self?.sessionState.isCelticKnotCollectionActive = active
            }
        }
        await celticKnotDataCollectionController?.start()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        let debugOn = AppSettings.isDebugEnabled
        let developerOn = AppSettings.isDeveloperEnabled
        debugOnlyMenuItems.forEach { $0.isHidden = !debugOn }
        developerOnlyMenuItems.forEach { $0.isHidden = !developerOn }
    }
}
