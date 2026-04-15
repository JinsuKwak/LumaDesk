import SwiftUI

@main
struct LumaDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appState = AppContainer.shared.appState

    var body: some Scene {
        Settings {
            SettingsRootView()
                .environmentObject(appState)
        }
    }
}
