import ApplicationServices
import Foundation

/// Wraps the macOS permission checks the app needs:
/// - Accessibility (System Settings → Privacy & Security → Accessibility)
///   required to install a CGEventTap and to read gesture events.
/// - Input Monitoring is requested implicitly the first time a low-level
///   event tap is created; macOS will prompt automatically.
enum PermissionsHelper {
    static func hasAccessibilityPermission() -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false]
        return AXIsProcessTrustedWithOptions(options)
    }

    static func promptForAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Polls every 2s until the permission is granted, then fires `handler` once.
    static func onAccessibilityGranted(_ handler: @escaping () -> Void) {
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { t in
            if hasAccessibilityPermission() {
                t.invalidate()
                timer = nil
                DispatchQueue.main.async { handler() }
            }
        }
    }
}
