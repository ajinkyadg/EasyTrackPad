import SwiftUI
import ServiceManagement
import Combine

@main
struct InputCustomizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window-bearing scene here on purpose: this is a menu-bar-only
        // (.accessory) app with no other window ever open, and SwiftUI's
        // `Settings` scene shows itself via a responder-chain action
        // (`showSettingsWindow:`) that isn't reliably delivered in that
        // configuration — "Preferences…" would silently no-op. The
        // AppDelegate manages its own NSWindow instead; see openPreferences().
        Settings {
            EmptyView()
        }
    }
}

/// Owns the long-lived engines (keyboard/mouse/trackpad) and the menu bar item.
/// Kept as an NSApplicationDelegate so the app can run as a background
/// "accessory" app (no Dock icon) with just a status bar item, like BTT.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore = SettingsStore()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    private lazy var keyboardManager = KeyboardManager(settingsStore: settingsStore)
    private lazy var mouseManager = MouseManager(settingsStore: settingsStore)
    private lazy var trackpadManager = TrackpadManager(settingsStore: settingsStore)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observePauseState()
        checkPermissionsAndStart()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "InputCustomizer")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(title: "Pause All Rules", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.state = settingsStore.isPaused ? .on : .off
        menu.addItem(pauseItem)
        pauseMenuItem = pauseItem

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        launchAtLoginMenuItem = loginItem

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit InputCustomizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// Keeps the menu checkmark and status-bar icon in sync when
    /// `isPaused` changes from the Preferences window's toggle too.
    private func observePauseState() {
        settingsStore.$isPaused
            .sink { [weak self] isPaused in
                self?.pauseMenuItem?.state = isPaused ? .on : .off
                self?.statusItem?.button?.image = NSImage(
                    systemSymbolName: isPaused ? "hand.tap.fill" : "hand.tap",
                    accessibilityDescription: "InputCustomizer"
                )
            }
            .store(in: &cancellables)
    }

    @objc private func togglePause() {
        settingsStore.isPaused.toggle()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("InputCustomizer: failed to toggle launch at login: \(error)")
        }
        launchAtLoginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        if preferencesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "InputCustomizer Preferences"
            window.contentView = NSHostingView(
                rootView: SettingsView().environmentObject(settingsStore)
            )
            window.isReleasedWhenClosed = false // keep our reference valid after the user closes it
            window.center()
            preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
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
