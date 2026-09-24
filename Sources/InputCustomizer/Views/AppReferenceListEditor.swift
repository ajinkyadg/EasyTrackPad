import SwiftUI
import UniformTypeIdentifiers
import InputModels

/// Shared "pick apps from /Applications" row fragment — used by
/// `RuleFormView` (a single rule's `restrictedToApps`) and
/// `ManageProfilesView` (a profile's `autoActivateApps`). Deliberately
/// just rows, not its own `Section` (so callers can put other rows, like
/// a name field, in the same `Section` alongside it — SwiftUI doesn't
/// nest `Section` inside `Section` cleanly). Mutation is delegated via
/// closures rather than a raw `Binding<[AppReference]>` because the two
/// callers need different semantics on add: a rule's scoping is a simple
/// local append, while a profile's auto-activation needs `SettingsStore`
/// to enforce that an app can only be claimed by one profile at a time.
struct AppReferenceListEditor: View {
    let apps: [AppReference]
    let onAdd: (AppReference) -> Void
    let onRemove: (AppReference) -> Void

    var body: some View {
        ForEach(apps) { app in
            HStack(spacing: 8) {
                AppIconView(bundleIdentifier: app.bundleIdentifier)
                Text(app.displayName)
                Spacer()
                Button(role: .destructive) {
                    onRemove(app)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(app.displayName)")
                .accessibilityLabel("Remove \(app.displayName)")
            }
        }
        Button {
            addApp()
        } label: {
            Label("Add App…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }

    private func addApp() {
        guard let app = InstalledApp.choose(),
              !apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        onAdd(app)
    }
}
