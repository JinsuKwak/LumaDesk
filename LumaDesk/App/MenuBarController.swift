import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let appState: AppStateStore
    private let onOpenSettings: () -> Void
    private let menuContentSize = NSSize(width: 330, height: 122)
    private var cancellables = Set<AnyCancellable>()

    init(appState: AppStateStore, onOpenSettings: @escaping () -> Void) {
        self.appState = appState
        self.onOpenSettings = onOpenSettings
        super.init()
        configureStatusItem()
        bindStatusIcon()
    }

    @objc private func handleStatusItemPress(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else {
            showControlMenu()
            return
        }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            showControlMenu()
        }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        updateStatusIcon(for: appState.connectionState)
        button.target = self
        button.action = #selector(handleStatusItemPress(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func bindStatusIcon() {
        appState.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.updateStatusIcon(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateStatusIcon(for state: ConnectionState) {
        guard let button = statusItem.button else { return }

        let assetName: String
        switch state {
        case .connected:
            assetName = "MenuBarConnected"
        case .disconnected, .scanning, .connecting, .error:
            assetName = "MenuBarDisconnected"
        }

        let image = NSImage(named: assetName) ?? fallbackStatusIcon(for: state)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = state.compactLabel
    }

    private func fallbackStatusIcon(for state: ConnectionState) -> NSImage? {
        let symbolName: String
        switch state {
        case .connected:
            symbolName = "lightswitch.on.square.fill"
        case .disconnected, .scanning, .connecting, .error:
            symbolName = "lightswitch.off.square"
        }

        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "LumaDesk")
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func showControlMenu() {
        let menu = NSMenu()
        menu.minimumWidth = menuContentSize.width

        let hostingView = NSHostingView(
            rootView: PopoverRootView()
                .environmentObject(appState)
        )
        hostingView.frame = NSRect(origin: .zero, size: menuContentSize)

        let item = NSMenuItem()
        item.view = hostingView
        menu.addItem(item)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
}
