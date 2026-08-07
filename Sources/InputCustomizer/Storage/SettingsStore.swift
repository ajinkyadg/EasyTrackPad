import Foundation
import Combine

/// Single source of truth for all rules. Persists to a JSON file in
/// Application Support so rules survive app restarts and are easy to
/// back up, diff, or hand-edit — deliberately not using a database,
/// to keep this hackable and simple to debug.
final class SettingsStore: ObservableObject {
    @Published var rules: [CustomizationRule] = [] {
        didSet { save() }
    }

    /// When true, every manager skips rule matching entirely — a quick
    /// "kill switch" without having to disable each rule individually.
    @Published var isPaused: Bool = UserDefaults.standard.bool(forKey: "isPaused") {
        didSet { UserDefaults.standard.set(isPaused, forKey: "isPaused") }
    }

    /// 0...1 — how easily trackpad swipes/taps trigger. See
    /// `GestureRecognizer.sensitivity` for what it actually tunes.
    @Published var gestureSensitivity: Double = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "gestureSensitivity") != nil ? defaults.double(forKey: "gestureSensitivity") : 0.5
    }() {
        didSet { UserDefaults.standard.set(gestureSensitivity, forKey: "gestureSensitivity") }
    }

    private let fileURL: URL

    /// `fileURL` is injectable so tests can point at a scratch file instead
    /// of silently reading/overwriting the real user's saved rules.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = appSupport.appendingPathComponent("InputCustomizer", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("rules.json")
        }
        load()
    }

    func addRule(_ rule: CustomizationRule) {
        rules.append(rule)
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func rules(for device: InputDevice) -> [CustomizationRule] {
        guard !isPaused else { return [] }
        return rules.filter { $0.device == device && $0.isEnabled }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        rules = (try? JSONDecoder().decode([CustomizationRule].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
