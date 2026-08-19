import AppKit
import Foundation
import Combine
import InputModels

/// The app's window/menu appearance — independent of `NSApp.effectiveAppearance`,
/// which just reflects whatever this resolves to. `.system` means "don't
/// override" (`nsAppearance` returns `nil`, and AppKit falls back to
/// following the OS setting on its own); `.light`/`.dark` pin it
/// regardless of the OS-wide setting, same as most native Mac apps'
/// "Appearance" preference.
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Single source of truth for all profiles/rules. Persists to a JSON file
/// in Application Support so rules survive app restarts and are easy to
/// back up, diff, or hand-edit — deliberately not using a database, to
/// keep this hackable and simple to debug.
final class SettingsStore: ObservableObject {
    /// All profiles, each a self-contained named set of rules. Always has
    /// at least one — `deleteProfile` refuses to remove the last one, and
    /// `load()` never leaves this empty even on a decode failure.
    @Published var profiles: [Profile] = [Profile(name: "Default")] {
        didSet {
            save()
            recomputeActiveProfile()
        }
    }
    /// The user's manual/durable choice of profile — what `RuleListView`
    /// edits, and what matching falls back to when no profile's
    /// `autoActivateApps` claims the current frontmost app. Persisted.
    @Published var selectedProfileID = UUID() {
        didSet {
            save()
            recomputeActiveProfile()
        }
    }
    /// The profile actually consulted by `rules(for:)` right now — equal
    /// to `selectedProfileID` unless a profile's `autoActivateApps`
    /// claims the current frontmost app, in which case that profile
    /// *temporarily* overrides the manual selection without changing it
    /// (see `Profile.resolveActiveProfile`). Deliberately NOT persisted —
    /// recomputed live from `profiles` + `selectedProfileID` + the
    /// current frontmost app, never written to disk.
    @Published private(set) var activeProfileID = UUID()
    private var lastFrontmostBundleIdentifier: String?

    var selectedProfile: Profile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    /// Forces the app's windows/menus into Light or Dark regardless of the
    /// OS-wide setting, or `.system` to just follow it — applied by
    /// `AppDelegate` via `NSApp.appearance` whenever this changes.
    @Published var appearance: AppAppearance = {
        let raw = UserDefaults.standard.string(forKey: "appearance")
        return raw.flatMap(AppAppearance.init(rawValue:)) ?? .system
    }() {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance") }
    }

    /// When true, every manager skips rule matching entirely — a quick
    /// "kill switch" without having to disable each rule individually.
    @Published var isPaused: Bool = UserDefaults.standard.bool(forKey: "isPaused") {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "isPaused")
            deviceRulesCache.removeAll()
        }
    }

    /// 0...1 — how easily trackpad swipes/taps trigger. See
    /// `GestureRecognizer.sensitivity` for what it actually tunes.
    @Published var gestureSensitivity: Double = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "gestureSensitivity") != nil ? defaults.double(forKey: "gestureSensitivity") : 0.5
    }() {
        didSet { UserDefaults.standard.set(gestureSensitivity, forKey: "gestureSensitivity") }
    }

    /// Seconds between re-applications of a "repeat while held" swipe
    /// rule's action (see `CustomizationRule.repeatsWhileHeld`). Lower is
    /// faster/more responsive but fires the action more often; 0.35 is
    /// the original fixed value this replaces.
    @Published var repeatWhileHeldInterval: Double = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "repeatWhileHeldInterval") != nil ? defaults.double(forKey: "repeatWhileHeldInterval") : 0.35
    }() {
        didSet { UserDefaults.standard.set(repeatWhileHeldInterval, forKey: "repeatWhileHeldInterval") }
    }

    /// Seconds to wait after a "repeat while held" swipe first fires
    /// before repeating actually begins — mirrors macOS's own "Delay
    /// Until Repeat" keyboard setting, paired with
    /// `repeatWhileHeldInterval` as the "Key Repeat" rate equivalent.
    /// 0 means repeating starts as soon as the interval above elapses,
    /// with no extra pause.
    @Published var repeatWhileHeldDelay: Double = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "repeatWhileHeldDelay") != nil ? defaults.double(forKey: "repeatWhileHeldDelay") : 0.3
    }() {
        didSet { UserDefaults.standard.set(repeatWhileHeldDelay, forKey: "repeatWhileHeldDelay") }
    }

    private let fileURL: URL

    /// `fileURL` is injectable so tests can point at a scratch file instead
    /// of silently reading/overwriting the real user's saved rules.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Deliberately a different directory than the original
            // InputCustomizer app's ("InputCustomizer") — this fork's rule
            // schema has dropped fields (overrides, repeatsByDistance) that
            // the original still writes, so sharing a rules.json would mean
            // whichever app saved last silently strips the other's data.
            let dir = appSupport.appendingPathComponent("InputCustomizerLite", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("rules.json")
        }
        load()
    }

    // MARK: - Rules (operate on the selected profile — what's being edited)

    func addRule(_ rule: CustomizationRule) {
        mutateSelectedProfile { $0.rules.append(rule) }
    }

    func removeRule(id: UUID) {
        mutateSelectedProfile { profile in profile.rules.removeAll { $0.id == id } }
    }

    /// Replaces the rule matching `rule.id` in place, preserving its
    /// position. A no-op if no rule with that id exists — deliberately,
    /// since presets are added via `addRule` and must never be routed
    /// through here with a stale/absent id.
    func updateRule(_ rule: CustomizationRule) {
        mutateSelectedProfile { profile in
            guard let index = profile.rules.firstIndex(where: { $0.id == rule.id }) else { return }
            profile.rules[index] = rule
        }
    }

    private func mutateSelectedProfile(_ mutate: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        mutate(&profiles[index])
    }

    /// Memoizes `rules(for:)`'s per-device filter — cleared by
    /// `recomputeActiveProfile()` and `isPaused`'s didSet, the only two
    /// things that can change what it returns. Matters because
    /// `KeyboardManager`/`MouseManager`/`TrackpadManager` call this from
    /// realtime CGEventTap/multitouch callbacks (keyboard: every single
    /// system-wide keystroke) — re-filtering the active profile's whole
    /// rule list from scratch on every event was measurable, avoidable
    /// work on a latency-sensitive path where a slow callback risks macOS
    /// disabling the event tap outright.
    private var deviceRulesCache: [InputDevice: [CustomizationRule]] = [:]

    /// What the managers actually match against — the *active* profile's
    /// rules (which can differ from the selected/edited one while an
    /// app-triggered auto-activation is live), filtered to this device
    /// and enabled. Empty while paused.
    func rules(for device: InputDevice) -> [CustomizationRule] {
        guard !isPaused else { return [] }
        if let cached = deviceRulesCache[device] { return cached }
        guard let active = profiles.first(where: { $0.id == activeProfileID }) else { return [] }
        let matched = active.rules.filter { $0.device == device && $0.isEnabled }
        deviceRulesCache[device] = matched
        return matched
    }

    // MARK: - Profiles

    @discardableResult
    func addProfile(name: String) -> Profile {
        let profile = Profile(name: uniqueName(base: name, existing: profiles.map(\.name)))
        profiles.append(profile)
        return profile
    }

    func renameProfile(id: UUID, name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let otherNames = profiles.enumerated().filter { $0.offset != index }.map { $0.element.name }
        profiles[index].name = uniqueName(base: name, existing: otherNames)
    }

    /// No-op if `id` is the last remaining profile — there must always be
    /// at least one to select/edit/match against.
    func deleteProfile(id: UUID) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        if selectedProfileID == id {
            selectedProfileID = profiles[0].id
        }
    }

    /// Fresh identities throughout (never shares a rule/profile id with
    /// the original), and deliberately does NOT copy `autoActivateApps`
    /// — a duplicate shouldn't silently steal the original's
    /// auto-activation claim out from under it.
    func duplicateProfile(id: UUID) {
        guard let original = profiles.first(where: { $0.id == id }) else { return }
        var copy = original.freshCopyWithNewIdentities()
        copy.name = uniqueName(base: original.name, existing: profiles.map(\.name))
        copy.autoActivateApps = []
        profiles.append(copy)
    }

    func selectProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
    }

    /// An app can only ever auto-activate one profile — assigning it here
    /// strips it from every other profile first, so the invariant holds
    /// by construction rather than being an undefined conflict.
    func assignAutoActivateApp(_ app: AppReference, toProfile targetID: UUID) {
        for index in profiles.indices {
            profiles[index].autoActivateApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        }
        guard let index = profiles.firstIndex(where: { $0.id == targetID }) else { return }
        profiles[index].autoActivateApps.append(app)
    }

    func removeAutoActivateApp(_ app: AppReference, fromProfile id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].autoActivateApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
    }

    /// Imports a profile (e.g. from `ProfileExportFile`) — always mints
    /// fresh ids (never trusts ids from an external file, even a
    /// self-exported one) and disambiguates a colliding name. Preserves
    /// the imported profile's `autoActivateApps`, but the exclusivity
    /// invariant still holds: those apps are stripped from whichever
    /// local profile currently claims them.
    func importProfile(_ profile: Profile) {
        var fresh = profile.freshCopyWithNewIdentities()
        fresh.name = uniqueName(base: fresh.name, existing: profiles.map(\.name))
        let claimedApps = Set(fresh.autoActivateApps.map(\.bundleIdentifier))
        for index in profiles.indices {
            profiles[index].autoActivateApps.removeAll { claimedApps.contains($0.bundleIdentifier) }
        }
        profiles.append(fresh)
    }

    /// Called whenever the frontmost app changes (see `FrontmostAppObserver`)
    /// — recomputes `activeProfileID`, which may temporarily diverge from
    /// `selectedProfileID` if the new frontmost app is claimed by some
    /// profile's `autoActivateApps`.
    func updateFrontmostApp(_ bundleIdentifier: String?) {
        lastFrontmostBundleIdentifier = bundleIdentifier
        recomputeActiveProfile()
    }

    private func recomputeActiveProfile() {
        activeProfileID = Profile.resolveActiveProfile(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            frontmostBundleIdentifier: lastFrontmostBundleIdentifier
        )
        deviceRulesCache.removeAll()
    }

    // MARK: - Persistence

    /// Three-way cascade: the current `PersistedState` shape (the
    /// steady-state path for every launch after the first post-profiles
    /// one); a legacy bare `[CustomizationRule]` array (what every
    /// pre-profiles user's file actually is — wrapped into one "Default"
    /// profile and immediately re-saved in the new shape, so this branch
    /// can never run twice for the same file); or neither decodes
    /// (genuinely corrupt — backed up loudly instead of discarded,
    /// same discipline this file already had pre-profiles).
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // No file yet (fresh install): keep the single default
            // profile, but make sure selectedProfileID actually points
            // at it instead of the unrelated placeholder UUID it was
            // declared with.
            selectedProfileID = profiles[0].id
            return
        }

        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            profiles = state.profiles.isEmpty ? [Profile(name: "Default")] : state.profiles
            selectedProfileID = profiles.contains(where: { $0.id == state.selectedProfileID }) ? state.selectedProfileID : profiles[0].id
            return
        }

        if let legacyRules = try? JSONDecoder().decode([CustomizationRule].self, from: data) {
            NSLog("InputCustomizer: migrating pre-profiles \(fileURL.lastPathComponent) (\(legacyRules.count) rule(s)) into a \"Default\" profile")
            let backupURL = fileURL.appendingPathExtension("pre-profiles.bak")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            let defaultProfile = Profile(name: "Default", rules: legacyRules)
            profiles = [defaultProfile]
            selectedProfileID = defaultProfile.id
            save() // rewrite in the new format now, so this branch never runs again for this file
            return
        }

        NSLog("InputCustomizer: failed to decode \(fileURL.lastPathComponent) in either the current or legacy format, backing it up instead of discarding it")
        let backupURL = fileURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: fileURL, to: backupURL)
        profiles = [Profile(name: "Default")]
        selectedProfileID = profiles[0].id
    }

    private func save() {
        let state = PersistedState(profiles: profiles, selectedProfileID: selectedProfileID)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
