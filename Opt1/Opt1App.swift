import SwiftUI

@main
struct Opt1App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // This app is menu-bar only; the Settings window is managed manually by AppDelegate
        // to avoid the macOS 14+ "Please use SettingsLink" warning from showSettingsWindow:.
        Settings {
            EmptyView()
        }
    }
}
