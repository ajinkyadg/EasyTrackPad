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
            HStack {
                Text(app.displayName)
                Spacer()
                Button(role: .destructive) {
                    onRemove(app)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        Button("Add App…") { addApp() }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundleIdentifier = Bundle(url: url)?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
        guard !apps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let displayName = FileManager.default.displayName(atPath: url.path)
        onAdd(AppReference(bundleIdentifier: bundleIdentifier, displayName: displayName))
    }
}
