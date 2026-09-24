import SwiftUI
import UniformTypeIdentifiers
import InputModels

/// Create, rename, duplicate, delete, export, and import profiles, and
/// edit each profile's `autoActivateApps`. Opened from `SettingsView`'s
/// profile switcher menu ("Manage Profiles…").
struct ManageProfilesView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    /// Set by `importProfile()` when the picked file contains at least one
    /// shell-command or app-launch action — held here until the user
    /// confirms via `.alert` below, since a profile is just JSON that can
    /// be shared/downloaded from anyone, and those two action kinds run
    /// with the user's full permissions the instant their gesture/key
    /// fires. A profile with neither skips this and imports immediately;
    /// this isn't a general "review before import" gate, only a warning
    /// for the two action kinds that can actually do something to the
    /// system beyond this app itself.
    @State private var pendingImport: PendingImport?

    private struct PendingImport: Identifiable {
        let id = UUID()
        let profile: Profile
        let shellCommandCount: Int
        let appLaunchCount: Int
    }

    /// Set when reading/writing a profile file fails, so the failure is
    /// shown instead of silently doing nothing.
    @State private var fileError: FileError?

    private struct FileError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profiles").font(.title3.weight(.semibold))
                    Text("Each profile is its own set of rules. Switch between them from the toolbar or menu bar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    importProfile()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                Button {
                    settingsStore.addProfile(name: "New Profile")
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                ForEach(settingsStore.profiles) { profile in
                    profileSection(profile)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 580, height: 580)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .alert(item: $pendingImport) { pending in
            Alert(
                title: Text("This profile can run commands on your Mac"),
                message: Text(riskDescription(for: pending) + " Once imported, those specific rules will be disabled until you review and re-enable each one yourself — everything else in \"\(pending.profile.name)\" works immediately. Only re-enable rules from people and sources you trust; a shell command or app launch runs with your full permissions the instant its gesture or key fires."),
                primaryButton: .default(Text("Import")) { commitImport(pending.profile) },
                secondaryButton: .cancel()
            )
        }
        .background(
            // A second `.alert(item:)` on the same view would override
            // the first, so this one hangs off a separate background view.
            Color.clear.alert(item: $fileError) { error in
                Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
        )
    }

    private func riskDescription(for pending: PendingImport) -> String {
        var parts: [String] = []
        if pending.shellCommandCount > 0 {
            parts.append("\(pending.shellCommandCount) shell command rule\(pending.shellCommandCount == 1 ? "" : "s")")
        }
        if pending.appLaunchCount > 0 {
            parts.append("\(pending.appLaunchCount) app-launch rule\(pending.appLaunchCount == 1 ? "" : "s")")
        }
        return "It contains " + parts.joined(separator: " and ") + "."
    }

    @ViewBuilder
    private func profileSection(_ profile: Profile) -> some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: nameBinding(for: profile))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Rules", value: "\(profile.rules.count)")

            Text("Switch to this profile automatically when one of these apps is in front:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            AppReferenceListEditor(
                apps: profile.autoActivateApps,
                onAdd: { settingsStore.assignAutoActivateApp($0, toProfile: profile.id) },
                onRemove: { settingsStore.removeAutoActivateApp($0, fromProfile: profile.id) }
            )
        } header: {
            HStack(spacing: 8) {
                Text(profile.name).font(.headline)
                if profile.id == settingsStore.activeProfileID {
                    Text("Active")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                Menu {
                    Button("Duplicate") { settingsStore.duplicateProfile(id: profile.id) }
                    Button("Export…") { exportProfile(profile) }
                    Divider()
                    Button("Delete", role: .destructive) { settingsStore.deleteProfile(id: profile.id) }
                        .disabled(settingsStore.profiles.count <= 1)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions for \(profile.name)")
            }
        } footer: {
            Text(profile.autoActivateApps.isEmpty
                ? "Manual only — this profile becomes active only when you select it."
                : "Becomes active automatically while one of these apps is in front, then switches back to your selected profile when you leave it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func nameBinding(for profile: Profile) -> Binding<String> {
        Binding(
            get: { profile.name },
            set: { settingsStore.renameProfile(id: profile.id, name: $0) }
        )
    }

    private func exportProfile(_ profile: Profile) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder().encode(ProfileExportFile(profile: profile))
            try data.write(to: url)
        } catch {
            fileError = FileError(title: "Couldn’t export “\(profile.name)”", message: error.localizedDescription)
        }
    }

    /// A profile is just JSON — one anyone could share, and a shell-command
    /// or app-launch rule inside it runs with the user's full permissions
    /// the instant its gesture/key fires, with no review step otherwise.
    /// Rather than only warn, quarantine those two action kinds by force-
    /// disabling them on import regardless of what `isEnabled` was in the
    /// file — the profile's harmless rules (remaps, media keys, Mission
    /// Control) still work immediately; only the two kinds that can
    /// actually do something to the system need the user to open the rule
    /// and explicitly turn it back on after reviewing what it does.
    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let export: ProfileExportFile
        do {
            let data = try Data(contentsOf: url)
            export = try JSONDecoder().decode(ProfileExportFile.self, from: data)
        } catch is DecodingError {
            fileError = FileError(title: "Couldn’t import “\(url.lastPathComponent)”", message: "This file isn’t an InputCustomizer profile, or it was made by an incompatible version.")
            return
        } catch {
            fileError = FileError(title: "Couldn’t import “\(url.lastPathComponent)”", message: error.localizedDescription)
            return
        }

        var profile = export.profile
        var shellCommandCount = 0
        var appLaunchCount = 0
        for index in profile.rules.indices {
            switch profile.rules[index].action {
            case .runShellCommand:
                shellCommandCount += 1
                profile.rules[index].isEnabled = false
            case .launchApp:
                appLaunchCount += 1
                profile.rules[index].isEnabled = false
            default:
                break
            }
        }

        guard shellCommandCount > 0 || appLaunchCount > 0 else {
            commitImport(profile)
            return
        }
        pendingImport = PendingImport(profile: profile, shellCommandCount: shellCommandCount, appLaunchCount: appLaunchCount)
    }

    private func commitImport(_ profile: Profile) {
        settingsStore.importProfile(profile)
    }
}
