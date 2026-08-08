import AppKit

/// Notifies on every frontmost-app change, for `SettingsStore.updateFrontmostApp(_:)`
/// (profile auto-activation). Deliberately event-driven rather than
/// polling `ActiveApp.frontmostBundleIdentifier` per keystroke/gesture —
/// switching frontmost app is rare relative to raw input events, so this
/// keeps profile-resolution off the hot path entirely.
final class FrontmostAppObserver {
    private var token: NSObjectProtocol?

    /// Fires once immediately with the current frontmost app (so a fresh
    /// launch doesn't wait for the *next* app switch to pick the right
    /// profile), then on every subsequent switch.
    func start(onChange: @escaping (String?) -> Void) {
        onChange(ActiveApp.frontmostBundleIdentifier)
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            onChange(ActiveApp.frontmostBundleIdentifier)
        }
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    deinit {
        stop()
    }
}
