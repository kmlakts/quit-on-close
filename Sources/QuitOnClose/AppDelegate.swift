import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let permissions = Permissions()
    private let loginItem = LoginItem()
    private lazy var watcher = WindowWatcher(settings: settings)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateStatusItem()
        observeSettings()

        if permissions.isTrusted {
            watcher.start()
        } else {
            permissions.request()
            showSettings()
            Task {
                await permissions.waitUntilTrusted()
                watcher.start()
            }
        }
    }

    /// Launching the app again while it runs opens settings — the way back when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Menu bar

    private func observeSettings() {
        withObservationTracking {
            _ = settings.showMenuBarIcon
            _ = settings.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeSettings()
            }
        }
    }

    private func updateStatusItem() {
        guard settings.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }

        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let symbol = settings.isEnabled ? "xmark.circle" : "pause.circle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Quit on Close")

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Quit Apps on Last Window Close", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = settings.isEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Quit on Close", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != #selector(NSApplication.terminate(_:)) {
            menuItem.target = self
        }
        item.menu = menu
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    // MARK: Settings window

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings, permissions: permissions, loginItem: loginItem)))
            window.title = "Quit on Close"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
