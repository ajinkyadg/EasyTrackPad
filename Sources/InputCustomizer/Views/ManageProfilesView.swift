import SwiftUI
import UniformTypeIdentifiers

/// Create, rename, duplicate, delete, export, and import profiles, and
/// edit each profile's `autoActivateApps`. Opened from `SettingsView`'s
/// profile switcher menu ("Manage Profiles…").
struct ManageProfilesView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Profiles").font(.headline)
                Spacer()
                Button {
                    settingsStore.addProfile(name: "New Profile")
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                Button {
                    importProfile()
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
            }
            .padding()

            Divider()

            Form {
                ForEach(settingsStore.profiles) { profile in
                    profileSection(profile)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 560)
    }

    @ViewBuilder
    private func profileSection(_ profile: Profile) -> some View {
        Section {
            HStack {
                TextField("Name", text: nameBinding(for: profile))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(profile.rules.count) rule\(profile.rules.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .fixedSize()
            }

            AppReferenceListEditor(
                apps: profile.autoActivateApps,
                onAdd: { settingsStore.assignAutoActivateApp($0, toProfile: profile.id) },
                onRemove: { settingsStore.removeAutoActivateApp($0, fromProfile: profile.id) }
            )
        } header: {
            Text("Auto-Activate For")
        } footer: {
            Text(profile.autoActivateApps.isEmpty
                ? "Manual only — this profile becomes active only when you select it from the profile switcher."
                : "Automatically becomes active while one of these apps is frontmost, then reverts to your manually selected profile when you switch away.")
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
        let export = ProfileExportFile(profile: profile)
        guard let data = try? JSONEncoder().encode(export) else { return }
        try? data.write(to: url)
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(ProfileExportFile.self, from: data) else { return }
        settingsStore.importProfile(export.profile)
    }
}
