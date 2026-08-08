import Foundation

/// A named, self-contained set of rules — the unit profiles switch
/// between. Rules are nested directly (not a `profileID` foreign key
/// into one flat array) so that exporting a profile is just encoding one
/// `Profile` value, and so an inactive profile's rules are never even
/// touched by the managers' per-event matching code (see
/// `SettingsStore.rules(for:)`).
struct Profile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var rules: [CustomizationRule] = []
    /// Apps that, when frontmost, temporarily make this profile the
    /// effective active one regardless of the manually selected profile
    /// — reverts the instant the app is no longer frontmost. Empty means
    /// this profile only ever becomes active by manual selection. An app
    /// can only be claimed by one profile at a time — enforced by
    /// `SettingsStore.assignAutoActivateApp(_:toProfile:)` at the point
    /// of assignment, not left as an undefined conflict.
    var autoActivateApps: [AppReference] = []

    /// Pure decision of which profile should actually be firing rules
    /// right now — no manual selection, since a frontmost-app match
    /// always wins while it's true. Falls back to `selectedProfileID` (or
    /// the first profile, if even that's stale/missing) otherwise.
    /// Testable without touching `NSWorkspace` — the real frontmost app
    /// is looked up once by the caller and passed in.
    static func resolveActiveProfile(
        profiles: [Profile],
        selectedProfileID: UUID,
        frontmostBundleIdentifier: String?
    ) -> UUID {
        if let bundleID = frontmostBundleIdentifier,
           let autoProfile = profiles.first(where: { profile in
               profile.autoActivateApps.contains { $0.bundleIdentifier == bundleID }
           }) {
            return autoProfile.id
        }
        if profiles.contains(where: { $0.id == selectedProfileID }) {
            return selectedProfileID
        }
        return profiles.first?.id ?? selectedProfileID
    }

    /// Used on import: never trust ids from an external file, even a
    /// self-exported one — mints fresh ids for the profile and every
    /// nested rule so they can never collide with an existing profile's
    /// identities (SwiftUI `List` diffing, `SettingsStore.updateRule`'s
    /// find-by-id lookup).
    func freshCopyWithNewIdentities() -> Profile {
        var copy = self
        copy.id = UUID()
        copy.rules = rules.map { rule in
            var freshRule = rule
            freshRule.id = UUID()
            return freshRule
        }
        return copy
    }
}

/// Disambiguates `base` against `existing` names by appending " 2", " 3",
/// etc. until it's unique — used when importing a profile whose name
/// collides with one already present.
func uniqueName(base: String, existing: [String]) -> String {
    guard existing.contains(base) else { return base }
    var suffix = 2
    while existing.contains("\(base) \(suffix)") {
        suffix += 1
    }
    return "\(base) \(suffix)"
}

/// Top-level shape of the persisted settings file (`rules.json`) as of
/// the introduction of profiles. See `SettingsStore.load()` for the
/// migration cascade that upgrades a pre-profiles file (a bare
/// `[CustomizationRule]` array) into this shape exactly once.
struct PersistedState: Codable {
    var schemaVersion = 1
    var profiles: [Profile]
    var selectedProfileID: UUID
}

/// The shape of a `.json` file produced by exporting a single profile —
/// deliberately separate from `PersistedState` (the whole app's file)
/// even though they'd overlap today, so the two can evolve independently
/// (e.g. export gaining a "source app version" field later without that
/// leaking into the main persisted state's schema).
struct ProfileExportFile: Codable {
    var schemaVersion = 1
    var exportedAt = Date()
    var profile: Profile
}
