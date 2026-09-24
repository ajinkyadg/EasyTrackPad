import SwiftUI
import InputModels

/// The settings window: a native sidebar of devices, each device's rule
/// list as the detail, and a unified toolbar for the things that apply
/// across every device (profile, pause, tuning, activity).
struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var visualizerModel: TouchVisualizerModel
    @EnvironmentObject var activityLog: ActivityLog
    @State private var selectedDevice: InputDevice? = .trackpad
    @State private var showingManageProfiles = false
    @State private var showingTuning = false
    /// Remembered across launches — the activity feed is a debugging aid
    /// most people never need, so it starts hidden, but someone who does
    /// use it shouldn't have to reopen it every time.
    @AppStorage("showsActivityPane") private var showsActivity = false
    /// Read-only mirror of the system Accessibility grant, polled while
    /// the window is open so the banner disappears on its own the moment
    /// the user flips the switch in System Settings.
    @State private var hasAccessibility = PermissionsHelper.hasAccessibilityPermission()
    private let permissionPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .frame(minWidth: 780, idealWidth: 980, minHeight: 500, idealHeight: 640)
        .sheet(isPresented: $showingManageProfiles) {
            ManageProfilesView()
                .environmentObject(settingsStore)
        }
        .onReceive(permissionPoll) { _ in
            let granted = PermissionsHelper.hasAccessibilityPermission()
            if granted != hasAccessibility { hasAccessibility = granted }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedDevice) {
            Section("Devices") {
                ForEach(InputDevice.sidebarOrder) { device in
                    Label(device.displayName, systemImage: device.outlineSymbolName)
                        .badge(ruleCount(for: device))
                        .tag(device)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    }

    private func ruleCount(for device: InputDevice) -> Int {
        (settingsStore.selectedProfile?.rules ?? []).filter { $0.device == device }.count
    }

    // MARK: Detail

    private var detail: some View {
        let device = selectedDevice ?? .trackpad
        return VStack(spacing: 0) {
            if !hasAccessibility {
                NoticeBanner(
                    style: .warning,
                    systemImage: "lock.shield",
                    title: "Accessibility access needed",
                    message: "InputCustomizer can’t respond to gestures, clicks, or keys until you allow it in System Settings → Privacy & Security → Accessibility."
                ) {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
                    }
                    .controlSize(.large)
                }
            }
            if settingsStore.isPaused {
                NoticeBanner(
                    style: .info,
                    systemImage: "pause.circle",
                    title: "All rules are paused",
                    message: "Your trackpad, mice, and keyboard behave normally until you resume."
                ) {
                    Button("Resume") { settingsStore.isPaused = false }
                }
            }
            RuleListView(device: device)
        }
        .navigationTitle(device.displayName)
        .navigationSubtitle(settingsStore.selectedProfile.map { "Profile: \($0.name)" } ?? "")
        .modifier(ActivityPane(isPresented: $showsActivity))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            profileSwitcher

            Toggle(isOn: $settingsStore.isPaused) {
                Label(settingsStore.isPaused ? "Resume" : "Pause", systemImage: "pause.circle")
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Pause all rules")
            .help(settingsStore.isPaused ? "Resume all rules" : "Pause all rules")

            Button {
                showingTuning.toggle()
            } label: {
                Label("Tuning", systemImage: "slider.horizontal.3")
            }
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("Gesture tuning")
            .help("Gesture sensitivity, repeat speed, and appearance")
            .popover(isPresented: $showingTuning, arrowEdge: .bottom) {
                GestureTuningView()
                    .environmentObject(settingsStore)
            }

            Toggle(isOn: $showsActivity) {
                Label("Activity", systemImage: "waveform.path.ecg.rectangle")
            }
            .labelStyle(.titleAndIcon)
            .help(showsActivity ? "Hide activity" : "Show activity")
        }
    }

    /// Shows the *effective* active profile (which can diverge from the
    /// manually selected one while an app-triggered auto-activation is
    /// live — flagged with a bolt icon so that's never a silent
    /// surprise). Picking a different profile here sets the manual
    /// selection; auto-activation can still override it moments later if
    /// the frontmost app changes.
    private var profileSwitcher: some View {
        let isAutoOverride = settingsStore.activeProfileID != settingsStore.selectedProfileID
        let activeName = settingsStore.profiles.first(where: { $0.id == settingsStore.activeProfileID })?.name ?? "Profile"
        return Menu {
            Section("Profiles") {
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
            }
            Divider()
            Button("Manage Profiles…") { showingManageProfiles = true }
        } label: {
            Label(isAutoOverride ? "\(activeName) (auto)" : activeName, systemImage: isAutoOverride ? "bolt" : "rectangle.stack")
                .labelStyle(.titleAndIcon)
        }
        .help(isAutoOverride ? "\(activeName) is active automatically for the frontmost app" : "Switch profile")
        .accessibilityLabel("Profile: \(activeName)")
    }
}

/// Presents the activity feed as a trailing pane: a native inspector on
/// macOS 14+, a resizable split on macOS 13.
private struct ActivityPane: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.inspector(isPresented: $isPresented) {
                ConsoleView()
                    .inspectorColumnWidth(min: 240, ideal: 300, max: 440)
            }
        } else {
            HSplitView {
                content.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                if isPresented {
                    ConsoleView()
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 440, maxHeight: .infinity)
                }
            }
        }
    }
}

// MARK: - Gesture tuning

/// The global sensitivity/repeat sliders (plus appearance), opened from
/// the toolbar. These apply to every trackpad and Magic Mouse rule that
/// doesn't set its own override in the rule form.
struct GestureTuningView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    /// Bounds for the "repeat while held" interval slider, in seconds —
    /// 0.15 (fast, closer to key-repeat speed) to 0.75 (slow, deliberate).
    static let repeatIntervalRange: ClosedRange<Double> = 0.15...0.75
    /// Bounds for the "repeat while held" delay slider, in seconds — 0
    /// (repeating starts as soon as the interval above elapses, no extra
    /// pause) to 1.0 (a full second before the first repeat).
    static let repeatDelayRange: ClosedRange<Double> = 0...1.0

    var body: some View {
        Form {
            Section {
                LabeledSlider(title: "Sensitivity", value: $settingsStore.gestureSensitivity)
                    .help("How easily swipes, taps, pinches, and rotations trigger.")
            } header: {
                Text("Gestures")
            } footer: {
                Text("Applies to the trackpad and Magic Mouse. Individual rules can override these in their Advanced section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Repeat while held") {
                LabeledSlider(
                    title: "Speed",
                    value: SliderBinding.inverted($settingsStore.repeatWhileHeldInterval, in: Self.repeatIntervalRange),
                    range: Self.repeatIntervalRange,
                    minimumLabel: "Slower",
                    maximumLabel: "Faster"
                )
                .help("How often a \"repeat while held\" rule re-runs its action while you keep holding it.")
                LabeledSlider(
                    title: "Delay",
                    value: $settingsStore.repeatWhileHeldDelay,
                    range: Self.repeatDelayRange,
                    minimumLabel: "None",
                    maximumLabel: "Long"
                )
                .help("How long to wait after a \"repeat while held\" rule first fires before repeating begins.")
                LabeledSlider(title: "Distance sensitivity", value: $settingsStore.repeatByDistanceSensitivity)
                    .help("How much travel counts as \"one more repeat\" for a rule with \"Repeat by distance\" on — like a scroll wheel.")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settingsStore.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 440)
    }
}

// MARK: - Rule list

struct RuleListView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var visualizerModel: TouchVisualizerModel
    let device: InputDevice
    @State private var showingAddSheet = false
    @State private var editingRule: CustomizationRule?
    @State private var presetTemplate: RulePreset?
    @State private var selection: Set<UUID> = []
    /// Non-empty while the delete confirmation is up.
    @State private var pendingDeletion: [CustomizationRule] = []

    private var rulesForDevice: [CustomizationRule] {
        (settingsStore.selectedProfile?.rules ?? []).filter { $0.device == device }
    }

    private var presets: [RulePreset] { GesturePresets.presets(for: device) }

    /// The app's signature presets, surfaced ahead of the rest.
    private var featuredPresets: [RulePreset] { presets.filter { $0.name.hasPrefix("Smoogler") } }

    var body: some View {
        VStack(spacing: 0) {
            // The trackpad and a Magic Mouse are both read simultaneously
            // (see `TrackpadManager`'s doc comment), each with its own
            // multitouch connection that can independently be missing.
            if (device == .trackpad || device == .magicMouse) && !visualizerModel.isMultitouchAvailable(for: device) {
                NoticeBanner(
                    style: .warning,
                    systemImage: "exclamationmark.triangle.fill",
                    title: device == .magicMouse ? "No Magic Mouse detected" : "Gesture detection unavailable",
                    message: device == .magicMouse
                        ? "Swipe, tap, and split-swipe rules won’t fire until one is connected. Click and keyboard rules are unaffected."
                        : "Swipe, tap, and split-swipe/split-tap rules won’t fire right now. Pinch, rotate, clicks, and keyboard rules are unaffected."
                )
            }

            if rulesForDevice.isEmpty {
                RuleEmptyState(
                    device: device,
                    presets: presets,
                    featuredPresets: featuredPresets,
                    onAddRule: { showingAddSheet = true },
                    onPreset: { presetTemplate = $0 },
                    onAddFeatured: addFeaturedPresets
                )
            } else {
                ruleList
            }
        }
        .onChange(of: device) { _ in selection = [] }
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
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                for rule in pendingDeletion { settingsStore.removeRule(id: rule.id) }
                selection.subtract(pendingDeletion.map(\.id))
                pendingDeletion = []
            }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var ruleList: some View {
        List(selection: $selection) {
            ForEach(rulesForDevice) { rule in
                RuleRow(rule: rule, isEnabled: bindingForEnabled(rule), onEdit: { editingRule = rule })
                    .tag(rule.id)
            }
        }
        .listStyle(.inset)
        // Rules still look switched on while everything's paused — dim
        // the list so it matches the "All rules are paused" banner.
        .opacity(settingsStore.isPaused ? 0.5 : 1)
        .contextMenu(forSelectionType: UUID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click / Return opens the editor.
            if ids.count == 1, let rule = rule(withID: ids.first) { editingRule = rule }
        }
        .onDeleteCommand { requestDeletion(of: selection) }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let rules = rulesForDevice.filter { ids.contains($0.id) }
        if rules.count == 1, let rule = rules.first {
            Button("Edit…") { editingRule = rule }
            Button("Duplicate") {
                var copy = rule
                copy.id = UUID()
                copy.name = RuleSummary.displayName(for: rule) + " copy"
                settingsStore.addRule(copy)
            }
        }
        if !rules.isEmpty {
            let allEnabled = rules.allSatisfy(\.isEnabled)
            Button(allEnabled ? "Disable" : "Enable") {
                for var rule in rules {
                    rule.isEnabled = !allEnabled
                    settingsStore.updateRule(rule)
                }
            }
            Divider()
            Button(rules.count == 1 ? "Delete…" : "Delete \(rules.count) Rules…", role: .destructive) {
                requestDeletion(of: ids)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                showingAddSheet = true
            } label: {
                Label("Add Rule", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            if !presets.isEmpty {
                PresetMenu(presets: presets, featuredPresets: featuredPresets, onPreset: { presetTemplate = $0 })
                    .fixedSize()
            }
            Spacer()
            Text("\(rulesForDevice.count) rule\(rulesForDevice.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1
            ? "Delete “\(pendingDeletion[0].name)”?"
            : "Delete \(pendingDeletion.count) rules?"
    }

    private func rule(withID id: UUID?) -> CustomizationRule? {
        rulesForDevice.first { $0.id == id }
    }

    private func requestDeletion(of ids: Set<UUID>) {
        pendingDeletion = rulesForDevice.filter { ids.contains($0.id) }
    }

    /// One click adds every featured (Smoogler) preset as-is — they come
    /// as a matched next/previous pair that's only useful together.
    private func addFeaturedPresets() {
        for preset in featuredPresets {
            settingsStore.addRule(CustomizationRule(
                name: preset.ruleName,
                device: device,
                trigger: preset.trigger,
                action: preset.action,
                repeatsWhileHeld: preset.repeatsWhileHeld,
                repeatsByDistance: preset.repeatsByDistance
            ))
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
}

/// "Add from Preset" pull-down, with the featured presets in their own
/// section at the top.
private struct PresetMenu: View {
    let presets: [RulePreset]
    let featuredPresets: [RulePreset]
    let onPreset: (RulePreset) -> Void

    var body: some View {
        Menu {
            if !featuredPresets.isEmpty {
                Section("Featured") {
                    ForEach(featuredPresets) { preset in
                        Button(preset.name) { onPreset(preset) }
                    }
                }
            }
            Section(featuredPresets.isEmpty ? "Presets" : "More presets") {
                ForEach(presets.filter { preset in !featuredPresets.contains { $0.id == preset.id } }) { preset in
                    Button(preset.name) { onPreset(preset) }
                }
            }
        } label: {
            Label("Add from Preset", systemImage: "wand.and.stars")
        }
    }
}

// MARK: - Rule row

private struct RuleRow: View {
    let rule: CustomizationRule
    @Binding var isEnabled: Bool
    let onEdit: () -> Void

    private var displayName: String { RuleSummary.displayName(for: rule) }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                RuleGlyph(trigger: rule.trigger, device: rule.device)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(RuleSummary.line(for: rule))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !rule.restrictedToApps.isEmpty {
                        Label("Only in \(rule.restrictedToApps.map(\.displayName).joined(separator: ", "))", systemImage: "macwindow")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .opacity(rule.isEnabled ? 1 : 0.45)

            Spacer(minLength: 8)

            Button(action: onEdit) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Edit rule")
            .accessibilityLabel("Edit \(displayName)")

            Toggle("Enabled", isOn: $isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(rule.isEnabled ? "Turn off this rule" : "Turn on this rule")
                .accessibilityLabel("\(displayName) enabled")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// The leading glyph for a rule row: the custom gesture/corner glyph for
/// touch triggers, an SF Symbol in the same frame and tint otherwise, so
/// every row's text starts at the same x.
struct RuleGlyph: View {
    let trigger: Trigger
    let device: InputDevice
    var height: CGFloat = 28

    var body: some View {
        Group {
            switch trigger {
            case let .trackpadGesture(kind):
                GestureIconView(kind: kind, height: height)
            case let .mouseCornerClick(corner, _, _):
                MouseCornerIconView(corner: corner, height: height)
            case .keyCombo:
                symbol("keyboard")
            case .mouseButton:
                symbol(device == .magicMouse ? "magicmouse" : "computermouse")
            }
        }
        .frame(width: height * 1.3, height: height)
    }

    /// Same rounded tile as `GestureIconView`'s, so mouse and keyboard
    /// rows line up visually with gesture rows.
    private func symbol(_ name: String) -> some View {
        let tile = RoundedRectangle(cornerRadius: height * 0.26, style: .continuous)
        return Image(systemName: name)
            .font(.system(size: height * 0.55))
            .foregroundStyle(Color.accentColor)
            .frame(width: height * 1.3, height: height)
            .background(tile.fill(Color.accentColor.opacity(0.10)))
            .overlay(tile.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

// MARK: - Empty state

private struct RuleEmptyState: View {
    let device: InputDevice
    let presets: [RulePreset]
    let featuredPresets: [RulePreset]
    let onAddRule: () -> Void
    let onPreset: (RulePreset) -> Void
    let onAddFeatured: () -> Void

    private var explanation: String {
        switch device {
        case .trackpad: return "Turn multi-finger swipes, taps, pinches, and corner clicks into shortcuts, media keys, or app launches."
        case .magicMouse: return "Turn swipes and taps on your Magic Mouse’s surface into shortcuts, media keys, or app launches."
        case .mouse: return "Give extra mouse buttons, like back and forward, a shortcut or action of your choice."
        case .keyboard: return "Remap a key or shortcut to a different key, a media key, or an app."
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: device.outlineSymbolName)
                    .font(.system(.largeTitle))
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("No rules yet")
                        .font(.title2.weight(.semibold))
                    Text(explanation)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }

                HStack(spacing: 12) {
                    Button(action: onAddRule) {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
                    if !presets.isEmpty {
                        PresetMenu(presets: presets, featuredPresets: featuredPresets, onPreset: onPreset)
                            .fixedSize()
                    }
                }
                .controlSize(.large)

                if !featuredPresets.isEmpty {
                    featuredCard
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Built from the preset's own trigger, so the Magic Mouse card (a
    /// 2-finger swipe) doesn't claim three fingers like the trackpad one.
    private var featuredDescription: String {
        var fingers = "Swipe"
        if case let .trackpadGesture(kind) = featuredPresets[0].trigger, let count = kind.fingerCount {
            let words = [2: "two", 3: "three", 4: "four", 5: "five"]
            fingers = "Swipe \(words[count] ?? "\(count)") fingers"
        }
        return "\(fingers) left or right and keep sliding to flip through tabs, like a scroll wheel. Adds \(featuredPresets.count) rules."
    }

    private var featuredCard: some View {
        HStack(spacing: 14) {
            if case let .trackpadGesture(kind) = featuredPresets[0].trigger {
                GestureIconView(kind: kind, height: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Try Smoogler").font(.headline)
                Text(featuredDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Add Smoogler", action: onAddFeatured)
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}
