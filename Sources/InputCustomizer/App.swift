import SwiftUI
import ServiceManagement
import Combine
import InputModels

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
    let touchVisualizerModel = TouchVisualizerModel()
    let activityLog = ActivityLog()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var profileSwitchMenuItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []
    private let frontmostAppObserver = FrontmostAppObserver()

    private lazy var keyboardManager = KeyboardManager(settingsStore: settingsStore, activityLog: activityLog)
    private lazy var trackpadManager = TrackpadManager(settingsStore: settingsStore, visualizerModel: touchVisualizerModel, activityLog: activityLog)
    // Reads TrackpadManager's live touch position to gate corner-click
    // rules (see MouseManager.matchDescription) — `trackpadManager` is
    // also `lazy`, so this closure is safe to capture it before it's been
    // instantiated; it only runs once both are up.
    private lazy var mouseManager = MouseManager(
        settingsStore: settingsStore,
        activityLog: activityLog,
        lastTouchPosition: { [weak self] in self?.trackpadManager.lastTouchPosition ?? nil }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observePauseState()
        observeProfiles()
        observeAppearance()
        // Doesn't need Accessibility — plain NSWorkspace notifications —
        // so this starts independent of checkPermissionsAndStart() below.
        frontmostAppObserver.start { [weak self] bundleIdentifier in
            self?.settingsStore.updateFrontmostApp(bundleIdentifier)
        }
        checkPermissionsAndStart()
        GestureGlyphRenderer.prewarm()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: "InputCustomizer")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

        let profileItem = NSMenuItem(title: "Switch Profile", action: nil, keyEquivalent: "")
        let profileSubmenu = NSMenu()
        profileItem.submenu = profileSubmenu
        menu.addItem(profileItem)
        profileSwitchMenuItem = profileItem
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

    /// `$appearance` (a `CurrentValueSubject`-backed `@Published` publisher)
    /// emits its current value immediately on subscribe, so this also
    /// applies the saved setting at launch — no separate "apply once at
    /// startup" call needed.
    private func observeAppearance() {
        settingsStore.$appearance
            .sink { appearance in NSApp.appearance = appearance.nsAppearance }
            .store(in: &cancellables)
    }

    /// Rebuilds the "Switch Profile" submenu whenever the profile list or
    /// manual selection changes (renamed/added/deleted profiles, or
    /// picking a different one), and logs *actual* active-profile
    /// transitions to `ActivityLog` — `removeDuplicates()` matters here
    /// since `activeProfileID` gets reassigned (to the same value) on
    /// every unrelated profile edit, not just real switches.
    private func observeProfiles() {
        settingsStore.$profiles
            .sink { [weak self] _ in self?.rebuildProfileSubmenu() }
            .store(in: &cancellables)
        settingsStore.$selectedProfileID
            .sink { [weak self] _ in self?.rebuildProfileSubmenu() }
            .store(in: &cancellables)
        settingsStore.$activeProfileID
            .removeDuplicates()
            .sink { [weak self] activeID in
                guard let self, let profile = self.settingsStore.profiles.first(where: { $0.id == activeID }) else { return }
                self.activityLog.log(.info, "Active profile: \(profile.name)")
            }
            .store(in: &cancellables)
    }

    private func rebuildProfileSubmenu() {
        guard let submenu = profileSwitchMenuItem?.submenu else { return }
        submenu.removeAllItems()
        for profile in settingsStore.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(selectProfileFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == settingsStore.selectedProfileID ? .on : .off
            submenu.addItem(item)
        }
    }

    @objc private func selectProfileFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        settingsStore.selectProfile(id: id)
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
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "InputCustomizer Preferences"
            window.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(settingsStore)
                    .environmentObject(touchVisualizerModel)
                    .environmentObject(activityLog)
            )
            window.isReleasedWhenClosed = false // keep our reference valid after the user closes it
            // NOT setting .fullScreenPrimary here: combined with this
            // window presenting sheets (Add/Edit Rule), it caused a
            // persistent, reproducible chrome glitch — the sheet
            // appearing detached/overlapping the parent's title bar
            // instead of properly docked under it. .resizable alone (for
            // the green button's plain zoom, and for manual drag-resize)
            // doesn't have that problem.
            window.center()
            preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    private func checkPermissionsAndStart() {
        // Keyboard/mouse remapping needs Accessibility + Input Monitoring.
        // Trackpad gesture callbacks need Accessibility only.
        let trusted = PermissionsHelper.hasAccessibilityPermission()
        NSLog("InputCustomizer: launch permission check — Accessibility trusted = \(trusted)")
        guard trusted else {
            PermissionsHelper.promptForAccessibilityPermission()
            // Poll until granted, then start the engines.
            PermissionsHelper.onAccessibilityGranted { [weak self] in
                NSLog("InputCustomizer: Accessibility permission granted, starting engines")
                self?.startEngines()
            }
            return
        }
        startEngines()
    }

    private func startEngines() {
        NSLog("InputCustomizer: starting keyboard/mouse/trackpad engines")
        keyboardManager.start()
        mouseManager.start()
        trackpadManager.start()
    }
}
