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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settingsStore = SettingsStore()
    let touchVisualizerModel = TouchVisualizerModel()
    let activityLog = ActivityLog()
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var pauseMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var profileSwitchMenuItem: NSMenuItem?
    private var statusLineMenuItem: NSMenuItem?
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
        item.button?.image = Self.statusIcon(isPaused: settingsStore.isPaused)

        let menu = NSMenu()
        menu.delegate = self

        // Disabled, informational — "Active — 5 rules" / "Paused" — so
        // the current state is readable without opening Settings.
        let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        statusLineMenuItem = statusLine

        let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
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
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit InputCustomizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        refreshStatusLine()
    }

    /// The app icon's mark — a trackpad outline with three staggered
    /// fingers — as an 18pt template image; paused adds a slash (with a
    /// knocked-out gap) so the "off" state reads as off at a glance. Drawn
    /// in code from the same geometry as Assets/MenuBarIcon*.svg, so it
    /// needs no bundled resource and renders crisply at any scale.
    private static func statusIcon(isPaused: Bool) -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            let pad = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5), xRadius: 2.75, yRadius: 2.75)
            pad.lineWidth = 1.5
            pad.stroke()
            for (x, y) in [(5.6, 10.2), (9.0, 7.8), (12.4, 10.2)] {
                NSBezierPath(ovalIn: NSRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)).fill()
            }
            if isPaused {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.2, y: 1.2))
                slash.line(to: NSPoint(x: 16.8, y: 16.8))
                slash.lineCapStyle = .round
                // Knock-out gap first, then the slash itself on top.
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 3.2
                slash.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isPaused ? "InputCustomizer (paused)" : "InputCustomizer"
        return image
    }

    /// Refreshed on every menu open rather than on every store change —
    /// it's only visible while the menu is.
    private func refreshStatusLine() {
        let activeProfile = settingsStore.profiles.first(where: { $0.id == settingsStore.activeProfileID })
        if settingsStore.isPaused {
            statusLineMenuItem?.title = "Paused"
        } else {
            let count = activeProfile?.rules.filter(\.isEnabled).count ?? 0
            statusLineMenuItem?.title = "Active — \(count) rule\(count == 1 ? "" : "s")"
        }
        let isAuto = settingsStore.activeProfileID != settingsStore.selectedProfileID
        profileSwitchMenuItem?.title = "Profile: \(activeProfile?.name ?? "None")\(isAuto ? " (auto)" : "")"
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusLine()
    }

    /// Keeps the menu checkmark and status-bar icon in sync when
    /// `isPaused` changes from the Preferences window's toggle too.
    private func observePauseState() {
        settingsStore.$isPaused
            .sink { [weak self] isPaused in
                self?.pauseMenuItem?.state = isPaused ? .on : .off
                self?.statusItem?.button?.image = Self.statusIcon(isPaused: isPaused)
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
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                // .fullSizeContentView lets the NavigationSplitView sidebar
                // run up under the unified toolbar, like System Settings.
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "InputCustomizer Settings"
            let hostingController = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(settingsStore)
                    .environmentObject(touchVisualizerModel)
                    .environmentObject(activityLog)
            )
            // Only the view's minimum size constrains the window — the
            // default also pins it to the SwiftUI ideal size, which fights
            // manual resizing.
            hostingController.sizingOptions = [.minSize]
            // SwiftUI fills an existing NSToolbar with the view's
            // `.toolbar` items; without one on the window (this is an
            // AppKit-created window, not a SwiftUI scene) they'd never
            // appear on macOS 13. Set before the content so the hosting
            // view finds it when it moves into the window.
            window.toolbar = NSToolbar(identifier: "SettingsToolbar")
            window.toolbarStyle = .unified
            window.contentViewController = hostingController
            window.contentMinSize = NSSize(width: 780, height: 500)
            window.setContentSize(NSSize(width: 980, height: 640))
            window.isReleasedWhenClosed = false // keep our reference valid after the user closes it
            // NOT setting .fullScreenPrimary here: combined with this
            // window presenting sheets (Add/Edit Rule), it caused a
            // persistent, reproducible chrome glitch — the sheet
            // appearing detached/overlapping the parent's title bar
            // instead of properly docked under it. .resizable alone (for
            // the green button's plain zoom, and for manual drag-resize)
            // doesn't have that problem.
            window.center()
            window.setFrameAutosaveName("InputCustomizerSettingsWindow")
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
