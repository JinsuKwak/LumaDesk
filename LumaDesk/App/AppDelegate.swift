import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let container = AppContainer.shared
    private var menuBarController: MenuBarController?
    private var settingsWindowController: SettingsWindowController?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        settingsWindowController = SettingsWindowController(appState: container.appState)
        menuBarController = MenuBarController(
            appState: container.appState,
            onOpenSettings: { [weak self] in
                self?.settingsWindowController?.show()
            }
        )
        container.appState.bootstrap()
        registerSystemObservers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        container.appState.handleApplicationTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func registerSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let sleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.container.appState.handleSystemSleep()
            }
        }

        observers.append(sleepObserver)

        let wakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.container.appState.handleSystemWake()
            }
        }

        observers.append(wakeObserver)
    }
}
