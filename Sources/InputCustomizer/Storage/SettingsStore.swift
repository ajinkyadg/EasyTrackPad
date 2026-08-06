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

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("InputCustomizer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rules.json")
        load()
    }

    func addRule(_ rule: CustomizationRule) {
        rules.append(rule)
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    func rules(for device: InputDevice) -> [CustomizationRule] {
        rules.filter { $0.device == device && $0.isEnabled }
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
