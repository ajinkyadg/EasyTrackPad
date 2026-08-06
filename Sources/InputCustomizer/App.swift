import SwiftUI

@main
struct InputCustomizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.settingsStore)
        }
    }
}

/// Owns the long-lived engines (keyboard/mouse/trackpad) and the menu bar item.
/// Kept as an NSApplicationDelegate so the app can run as a background
/// "accessory" app (no Dock icon) with just a status bar item, like BTT.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var statusItem: NSStatusItem?

    private lazy var keyboardManager = KeyboardManager(settingsStore: settingsStore)
    private lazy var mouseManager = MouseManager(settingsStore: settingsStore)
    private lazy var trackpadManager = TrackpadManager(settingsStore: settingsStore)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        checkPermissionsAndStart()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "InputCustomizer")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit InputCustomizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func checkPermissionsAndStart() {
        // Keyboard/mouse remapping needs Accessibility + Input Monitoring.
        // Trackpad gesture callbacks need Accessibility only.
        guard PermissionsHelper.hasAccessibilityPermission() else {
            PermissionsHelper.promptForAccessibilityPermission()
            // Poll until granted, then start the engines.
            PermissionsHelper.onAccessibilityGranted { [weak self] in
                self?.startEngines()
            }
            return
        }
        startEngines()
    }

    private func startEngines() {
        keyboardManager.start()
        mouseManager.start()
        trackpadManager.start()
    }
}
