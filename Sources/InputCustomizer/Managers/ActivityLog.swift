import Combine
import Foundation

/// Shared live activity feed, shown in `ConsoleView` inside Preferences.
/// Exists because the app's actual diagnostic trail (recognized gestures,
/// rule matches, actions executing) previously only went to `NSLog`,
/// which isn't visible unless the binary is run directly from a
/// terminal — a real, repeatedly-hit friction point documented in the
/// README's troubleshooting sections. This surfaces the same kind of
/// events live, in-window, instead.
final class ActivityLog: ObservableObject {
    enum Kind: String {
        case detected = "Detected"
        case fired = "Fired"
        case executing = "Executing"
        case info = "Info"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let kind: Kind
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    /// Bounded so a long session (especially with a noisy repeat-while-held
    /// rule) doesn't grow this unboundedly — this is a live glance view,
    /// not a persisted log.
    private let maxEntries = 200

    /// Safe to call from any thread (`GestureRecognizer`'s callbacks run
    /// on a background thread) — hops to main for the actual `@Published`
    /// mutation itself.
    func log(_ kind: Kind, _ message: String) {
        let entry = Entry(timestamp: Date(), kind: kind, message: message)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in self?.append(entry) }
        }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
