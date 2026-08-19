import SwiftUI
import InputModels

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var visualizerModel: TouchVisualizerModel
    @EnvironmentObject var activityLog: ActivityLog
    @State private var selectedDevice: InputDevice = .trackpad
    @State private var showingManageProfiles = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                RuleListView(device: selectedDevice)
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                ConsoleView()
                    .frame(width: 300)
            }
        }
        .frame(width: 960, height: 600)
        .environmentObject(settingsStore)
        .environmentObject(visualizerModel)
        .environmentObject(activityLog)
        .sheet(isPresented: $showingManageProfiles) {
            ManageProfilesView()
                .environmentObject(settingsStore)
        }
    }

    private var topBar: some View {
        HStack {
            profileSwitcher
            Divider().frame(height: 16)
            Toggle("Pause all rules", isOn: $settingsStore.isPaused)
            Spacer()
            Picker("Appearance", selection: $settingsStore.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName).tag(appearance)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding()
    }

    /// Shows the *effective* active profile (which can diverge from the
    /// manually selected one while an app-triggered auto-activation is
    /// live — flagged with a bolt icon so that's never a silent
    /// surprise). Picking a different profile here sets the manual
    /// selection; auto-activation can still override it moments later if
    /// the frontmost app changes.
    private var profileSwitcher: some View {
        Menu {
            ForEach(settingsStore.profiles) { profile in
                Button {
                    settingsStore.selectProfile(id: profile.id)
                } label: {
                    if profile.id == settingsStore.selectedProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button("Manage Profiles…") { showingManageProfiles = true }
        } label: {
            let isAutoOverride = settingsStore.activeProfileID != settingsStore.selectedProfileID
            let activeName = settingsStore.profiles.first(where: { $0.id == settingsStore.activeProfileID })?.name ?? "Profile"
            Label(isAutoOverride ? "\(activeName) (auto)" : activeName, systemImage: isAutoOverride ? "bolt.fill" : "person.crop.rectangle.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Device navigation rail — replaces the previous top `TabView`.
    /// Scales better as more per-device content (sliders, presets) piles
    /// up, and reads as more "app," less "dialog."
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(InputDevice.allCases) { device in
                Button {
                    selectedDevice = device
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: device.iconSymbolName)
                            .frame(width: 18)
                        Text(device.displayName)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedDevice == device ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .foregroundStyle(selectedDevice == device ? Color.accentColor : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 150)
    }
}

struct RuleListView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var visualizerModel: TouchVisualizerModel
    let device: InputDevice
    @State private var showingAddSheet = false
    @State private var editingRule: CustomizationRule?
    @State private var presetTemplate: RulePreset?

    /// Bounds for the "repeat while held" interval slider, in seconds —
    /// 0.15 (fast, closer to key-repeat speed) to 0.75 (slow, deliberate).
    private static let repeatIntervalRange: ClosedRange<Double> = 0.15...0.75
    /// Bounds for the "repeat while held" delay slider, in seconds — 0
    /// (repeating starts as soon as the interval above elapses, no extra
    /// pause) to 1.0 (a full second before the first repeat).
    private static let repeatDelayRange: ClosedRange<Double> = 0...1.0

    private var rulesForDevice: [CustomizationRule] {
        (settingsStore.selectedProfile?.rules ?? []).filter { $0.device == device }
    }

    var body: some View {
        VStack {
            // The trackpad and a Magic Mouse are both read simultaneously
            // (see `TrackpadManager`'s doc comment) — the sensitivity/repeat
            // sliders below tune both engines at once, so they show on
            // both tabs.
            if device == .trackpad || device == .magicMouse {
                if !visualizerModel.isMultitouchAvailable(for: device) {
                    Label(
                        device == .magicMouse
                            ? "No Magic Mouse detected — its swipe/tap/split-swipe rules won't fire until one is connected. Mouse click and keyboard rules are unaffected."
                            : "Gesture detection isn't available right now — swipe, tap, and split-swipe/split-tap rules won't fire. Pinch, rotate, mouse clicks, and keyboard rules are unaffected.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.top, 4)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Gesture Sensitivity").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("Less").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $settingsStore.gestureSensitivity, in: 0...1)
                        Text("More").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat While Held Speed").font(.caption).foregroundStyle(.secondary)
                        .help("How often a \"repeat while held\" swipe rule re-runs its action for as long as you keep holding it.")
                    HStack {
                        Text("Slower").font(.caption2).foregroundStyle(.secondary)
                        // Inverted: the slider's left-to-right "slower to
                        // faster" reads naturally, but a *smaller* interval
                        // is what's actually faster, so the bound value is
                        // max+min-interval rather than interval directly.
                        Slider(
                            value: Binding(
                                get: { Self.repeatIntervalRange.upperBound + Self.repeatIntervalRange.lowerBound - settingsStore.repeatWhileHeldInterval },
                                set: { settingsStore.repeatWhileHeldInterval = Self.repeatIntervalRange.upperBound + Self.repeatIntervalRange.lowerBound - $0 }
                            ),
                            in: Self.repeatIntervalRange
                        )
                        Text("Faster").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Repeat Delay").font(.caption).foregroundStyle(.secondary)
                        .help("How long to wait after a \"repeat while held\" swipe first fires before repeating actually begins.")
                    HStack {
                        Text("Instant").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $settingsStore.repeatWhileHeldDelay, in: Self.repeatDelayRange)
                        Text("Long").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            List {
                ForEach(rulesForDevice) { rule in
                    HStack(spacing: 10) {
                        // Purely a visual "at a glance" indicator — the
                        // Toggle right after it is the actual accessible
                        // control, so this doesn't duplicate its function.
                        Circle()
                            .fill(rule.isEnabled ? Color.green : Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)

                        Toggle("", isOn: bindingForEnabled(rule))
                            .labelsHidden()

                        Button {
                            editingRule = rule
                        } label: {
                            HStack(spacing: 10) {
                                // No device check needed beyond the trigger
                                // pattern match itself — `rulesForDevice`
                                // already scoped this row to the current
                                // tab, and both `.trackpad` and
                                // `.magicMouse` rules can carry a
                                // `.trackpadGesture` trigger.
                                if case let .trackpadGesture(kind) = rule.trigger {
                                    GestureIconView(kind: kind)
                                } else if case let .mouseCornerClick(corner, _, _) = rule.trigger {
                                    MouseCornerIconView(corner: corner)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name).font(.system(size: 13, weight: .semibold))
                                    Text(describe(rule.trigger)).font(.caption).foregroundStyle(.secondary)
                                    if !rule.restrictedToApps.isEmpty {
                                        Text("Only in: \(rule.restrictedToApps.map(\.displayName).joined(separator: ", "))")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                        Button(role: .destructive) {
                            settingsStore.removeRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 5)
                }
            }
            HStack {
                Spacer()
                let presets = GesturePresets.presets(for: device)
                if !presets.isEmpty {
                    Menu {
                        ForEach(presets) { preset in
                            Button(preset.name) { presetTemplate = preset }
                        }
                    } label: {
                        Label("Add from Preset", systemImage: "wand.and.stars")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            RuleFormView(device: device)
                .environmentObject(settingsStore)
                .environmentObject(visualizerModel)
        }
        .sheet(item: $editingRule) { rule in
            RuleFormView(device: device, editingRule: rule)
                .environmentObject(settingsStore)
                .environmentObject(visualizerModel)
        }
        .sheet(item: $presetTemplate) { preset in
            RuleFormView(device: device, presetTemplate: preset)
                .environmentObject(settingsStore)
                .environmentObject(visualizerModel)
        }
    }

    private func bindingForEnabled(_ rule: CustomizationRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { newValue in
                var updated = rule
                updated.isEnabled = newValue
                settingsStore.updateRule(updated)
            }
        )
    }

    private func describe(_ trigger: Trigger) -> String {
        switch trigger {
        case let .keyCombo(keyCode, modifiers): return KeyCodeMap.describe(keyCode: keyCode, modifiers: modifiers)
        case let .mouseButton(number, _): return "Button \(number)"
        case let .mouseCornerClick(corner, number, _): return "Button \(number), \(corner.displayName)"
        case let .trackpadGesture(kind): return kind.displayName
        }
    }
}
