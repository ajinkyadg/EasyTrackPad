import XCTest
@testable import InputCustomizer
import InputModels

final class ProfileTests: XCTestCase {
    private func scratchStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        return SettingsStore(fileURL: url)
    }

    // MARK: - Profile.resolveActiveProfile (pure)

    func testResolveActiveProfileFallsBackToSelectedWhenNoAutoMatch() {
        let work = Profile(name: "Work")
        let gaming = Profile(name: "Gaming")
        let resolved = Profile.resolveActiveProfile(
            profiles: [work, gaming],
            selectedProfileID: gaming.id,
            frontmostBundleIdentifier: "com.apple.Finder"
        )
        XCTAssertEqual(resolved, gaming.id)
    }

    func testResolveActiveProfileUsesAutoActivateMatchOverManualSelection() {
        var work = Profile(name: "Work")
        work.autoActivateApps = [AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")]
        let gaming = Profile(name: "Gaming")
        let resolved = Profile.resolveActiveProfile(
            profiles: [work, gaming],
            selectedProfileID: gaming.id, // manually on Gaming...
            frontmostBundleIdentifier: "com.tinyspeck.slackmacgap" // ...but Slack is frontmost
        )
        XCTAssertEqual(resolved, work.id, "auto-activation should override the manual selection while its app is frontmost")
    }

    func testResolveActiveProfileFallsBackToFirstWhenSelectedIDIsStale() {
        let onlyProfile = Profile(name: "Default")
        let resolved = Profile.resolveActiveProfile(
            profiles: [onlyProfile],
            selectedProfileID: UUID(), // doesn't match anything (deleted profile, hand-edited JSON, etc.)
            frontmostBundleIdentifier: nil
        )
        XCTAssertEqual(resolved, onlyProfile.id)
    }

    func testResolveActiveProfileFailsOpenWhenFrontmostAppIsUnknown() {
        let selected = Profile(name: "Selected")
        var other = Profile(name: "Other")
        other.autoActivateApps = [AppReference(bundleIdentifier: "com.example.app", displayName: "Example")]
        let resolved = Profile.resolveActiveProfile(profiles: [selected, other], selectedProfileID: selected.id, frontmostBundleIdentifier: nil)
        XCTAssertEqual(resolved, selected.id)
    }

    func testResolveActiveProfileFirstMatchWinsForConflictingClaims() {
        // Only reachable via hand-edited JSON — SettingsStore.assignAutoActivateApp
        // enforces exclusivity through the normal UI path, so this tests the
        // pure function's own defined tie-break, not something the app can
        // construct through normal use.
        var first = Profile(name: "First")
        first.autoActivateApps = [AppReference(bundleIdentifier: "com.example.app", displayName: "Example")]
        var second = Profile(name: "Second")
        second.autoActivateApps = [AppReference(bundleIdentifier: "com.example.app", displayName: "Example")]
        let resolved = Profile.resolveActiveProfile(profiles: [first, second], selectedProfileID: first.id, frontmostBundleIdentifier: "com.example.app")
        XCTAssertEqual(resolved, first.id)
    }

    // MARK: - Profile.freshCopyWithNewIdentities / uniqueName (pure)

    func testFreshCopyWithNewIdentitiesMintsNewIdsButPreservesContent() {
        let rule = CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)
        let original = Profile(name: "Work", rules: [rule])

        let copy = original.freshCopyWithNewIdentities()

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.rules.count, 1)
        XCTAssertNotEqual(copy.rules[0].id, rule.id)
        XCTAssertEqual(copy.rules[0].name, rule.name)
        XCTAssertEqual(copy.name, original.name)
    }

    func testUniqueNameDisambiguatesCollisions() {
        XCTAssertEqual(uniqueName(base: "Work", existing: ["Gaming"]), "Work")
        XCTAssertEqual(uniqueName(base: "Work", existing: ["Work"]), "Work 2")
        XCTAssertEqual(uniqueName(base: "Work", existing: ["Work", "Work 2"]), "Work 3")
    }

    // MARK: - SettingsStore profile CRUD

    func testAssignAutoActivateAppEnforcesExclusivity() {
        let store = scratchStore()
        let work = store.addProfile(name: "Work")
        let gaming = store.addProfile(name: "Gaming")
        let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")

        store.assignAutoActivateApp(slack, toProfile: work.id)
        XCTAssertEqual(store.profiles.first(where: { $0.id == work.id })?.autoActivateApps, [slack])

        // Reassigning to Gaming must strip it from Work — an app can only
        // ever claim one profile.
        store.assignAutoActivateApp(slack, toProfile: gaming.id)
        XCTAssertEqual(store.profiles.first(where: { $0.id == work.id })?.autoActivateApps, [])
        XCTAssertEqual(store.profiles.first(where: { $0.id == gaming.id })?.autoActivateApps, [slack])
    }

    func testDeletingSelectedProfileReassignsSelection() {
        let store = scratchStore()
        let defaultID = store.profiles[0].id
        let work = store.addProfile(name: "Work")
        store.selectProfile(id: work.id)
        XCTAssertEqual(store.selectedProfileID, work.id)

        store.deleteProfile(id: work.id)

        XCTAssertEqual(store.selectedProfileID, defaultID)
        XCTAssertEqual(store.profiles.count, 1)
    }

    func testDeletingLastRemainingProfileIsANoOp() {
        let store = scratchStore()
        let onlyID = store.profiles[0].id

        store.deleteProfile(id: onlyID)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, onlyID)
    }

    func testAddProfileDisambiguatesDuplicateNames() {
        let store = scratchStore()
        store.addProfile(name: "Work")
        let second = store.addProfile(name: "Work")
        XCTAssertEqual(second.name, "Work 2")
    }

    // MARK: - rules(for:) with multiple profiles

    func testRulesForDeviceOnlyReflectsTheActiveProfile() {
        let store = scratchStore()
        let defaultID = store.profiles[0].id
        store.addRule(CustomizationRule(name: "Default's rule", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl))

        let work = store.addProfile(name: "Work")
        store.selectProfile(id: work.id)
        store.addRule(CustomizationRule(name: "Work's rule", device: .mouse, trigger: .mouseButton(number: 4, modifiers: 0), action: .missionControl))

        // Active profile is now Work — only its rule should surface.
        XCTAssertEqual(store.rules(for: .mouse).map(\.name), ["Work's rule"])

        store.selectProfile(id: defaultID)
        XCTAssertEqual(store.rules(for: .mouse).map(\.name), ["Default's rule"])
    }

    // MARK: - Export/import round-trip

    func testProfileExportFileRoundTripsThroughJSON() throws {
        let rule = CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)
        let profile = Profile(name: "Work", rules: [rule], autoActivateApps: [AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")])
        let export = ProfileExportFile(profile: profile)

        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(ProfileExportFile.self, from: data)

        XCTAssertEqual(decoded.profile, profile)
    }

    func testImportProfileMintsFreshIdentitiesAndDisambiguatesName() {
        let store = scratchStore()
        store.addProfile(name: "Work") // so the imported "Work" collides

        let rule = CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)
        let imported = Profile(name: "Work", rules: [rule])

        store.importProfile(imported)

        let importedResult = store.profiles.last!
        XCTAssertEqual(importedResult.name, "Work 2")
        XCTAssertNotEqual(importedResult.id, imported.id)
        XCTAssertEqual(importedResult.rules.count, 1)
        XCTAssertNotEqual(importedResult.rules[0].id, rule.id)
        XCTAssertEqual(importedResult.rules[0].name, "A")
    }

    func testImportProfileStripsConflictingAutoActivateClaimsFromExistingProfiles() {
        let store = scratchStore()
        let slack = AppReference(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
        let existing = store.addProfile(name: "Existing")
        store.assignAutoActivateApp(slack, toProfile: existing.id)

        let imported = Profile(name: "Imported", autoActivateApps: [slack])
        store.importProfile(imported)

        XCTAssertEqual(store.profiles.first(where: { $0.id == existing.id })?.autoActivateApps, [])
        XCTAssertEqual(store.profiles.last?.autoActivateApps, [slack])
    }

    // MARK: - Migration from the pre-profiles flat-array format

    func testLoadMigratesLegacyFlatRulesArrayIntoADefaultProfile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("pre-profiles.bak"))
        }
        let legacyRules = [
            CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl),
            CustomizationRule(name: "B", device: .trackpad, trigger: .trackpadGesture(.pinchIn), action: .missionControl)
        ]
        try JSONEncoder().encode(legacyRules).write(to: url)

        let store = SettingsStore(fileURL: url)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Default")
        XCTAssertEqual(store.profiles[0].rules.map(\.name), ["A", "B"])
        XCTAssertEqual(store.selectedProfileID, store.profiles[0].id)

        // The legacy file must be preserved, not just overwritten silently.
        let backupData = try Data(contentsOf: url.appendingPathExtension("pre-profiles.bak"))
        let backedUpRules = try JSONDecoder().decode([CustomizationRule].self, from: backupData)
        XCTAssertEqual(backedUpRules, legacyRules)
    }

    func testMigrationIsIdempotentOnASecondLaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("pre-profiles.bak"))
        }
        let legacyRules = [CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)]
        try JSONEncoder().encode(legacyRules).write(to: url)

        let firstLaunch = SettingsStore(fileURL: url)
        let profileIDAfterMigration = firstLaunch.profiles[0].id

        // A second store constructed off the same now-migrated file must
        // read the new PersistedState shape directly, not re-run the
        // legacy-array migration branch (which would mint a *different*
        // profile id and duplicate the rules).
        let secondLaunch = SettingsStore(fileURL: url)

        XCTAssertEqual(secondLaunch.profiles.count, 1)
        XCTAssertEqual(secondLaunch.profiles[0].id, profileIDAfterMigration)
        XCTAssertEqual(secondLaunch.profiles[0].rules.map(\.name), ["A"])
    }
}
