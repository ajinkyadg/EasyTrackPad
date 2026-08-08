import SwiftUI
import UniformTypeIdentifiers

/// Add, edit, or preset-prefill a rule — one form for all three, since
/// they only differ in what the `@State` starts as and whether saving
/// calls `addRule` or `updateRule`.
struct RuleFormView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let device: InputDevice

    /// Non-nil only when editing an existing rule — its `id`/`isEnabled`
    /// are carried through on save so the edit updates the same rule in
    /// place instead of silently no-op'ing (SettingsStore.updateRule is a
    /// no-op for an unknown id) or resetting `isEnabled` to true.
    private let editingRule: CustomizationRule?

    @State private var name: String
    @State private var gesture: Trigger.GestureKind
    @State private var mouseButtonNumber: Int
    @State private var keyCode: UInt16
    @State private var keyModifiers: UInt
    @State private var actionKind: ActionKind
    @State private var shellCommand: String
    @State private var bundleIdentifier: String
    @State private var mediaKey: Action.MediaKey
    @State private var remapKeyCode: UInt16
    @State private var remapModifiers: UInt
    @State private var repeatsWhileHeld: Bool
    @State private var repeatsByDistance: Bool
    @State private var restrictedToApps: [AppReference]

    enum ActionKind: String, CaseIterable, Identifiable {
        case missionControl = "Mission Control"
        case shellCommand = "Run Shell Command"
        case launchApp = "Launch App"
        case mediaKey = "Media Key"
        case remapToKey = "Remap to Key"
        var id: String { rawValue }
    }

    /// Everything the form's `@State` needs, decoupled from *why* it's
    /// being constructed (blank, from an existing rule, or from a
    /// preset) — the single source of truth the three initializers below
    /// all funnel through.
    private struct FormValues {
        var name = ""
        var gesture: Trigger.GestureKind = .twoFingerSwipeLeft
        var mouseButtonNumber = 3
        var keyCode: UInt16 = KeyCodeMap.unset
        var keyModifiers: UInt = 0
        var actionKind: ActionKind = .missionControl
        var shellCommand = ""
        var bundleIdentifier = ""
        var mediaKey: Action.MediaKey = .playPause
        var remapKeyCode: UInt16 = KeyCodeMap.unset
        var remapModifiers: UInt = 0
        var repeatsWhileHeld = false
        var repeatsByDistance = false
        var restrictedToApps: [AppReference] = []

        static func from(rule: CustomizationRule) -> FormValues {
            var values = FormValues()
            values.name = rule.name
            values.repeatsWhileHeld = rule.repeatsWhileHeld
            values.repeatsByDistance = rule.repeatsByDistance
            values.restrictedToApps = rule.restrictedToApps
            switch rule.trigger {
            case let .trackpadGesture(kind): values.gesture = kind
            case let .mouseButton(number, _): values.mouseButtonNumber = number
            case let .keyCombo(keyCode, modifiers): values.keyCode = keyCode; values.keyModifiers = modifiers
            }
            switch rule.action {
            case .missionControl: values.actionKind = .missionControl
            case let .runShellCommand(command): values.actionKind = .shellCommand; values.shellCommand = command
            case let .launchApp(bundleIdentifier): values.actionKind = .launchApp; values.bundleIdentifier = bundleIdentifier
            case let .sendMediaKey(key): values.actionKind = .mediaKey; values.mediaKey = key
            case let .remapToKey(keyCode, modifiers): values.actionKind = .remapToKey; values.remapKeyCode = keyCode; values.remapModifiers = modifiers
            case .none: break
            }
            return values
        }

        static func from(preset: RulePreset) -> FormValues {
            from(rule: CustomizationRule(
                name: preset.name,
                device: preset.device,
                trigger: preset.trigger,
                action: preset.action,
                repeatsWhileHeld: preset.repeatsWhileHeld,
                repeatsByDistance: preset.repeatsByDistance
            ))
        }
    }

    init(device: InputDevice) {
        self.init(device: device, values: FormValues(), editingRule: nil)
    }

    init(device: InputDevice, editingRule: CustomizationRule) {
        self.init(device: device, values: .from(rule: editingRule), editingRule: editingRule)
    }

    init(device: InputDevice, presetTemplate: RulePreset) {
        self.init(device: device, values: .from(preset: presetTemplate), editingRule: nil)
    }

    private init(device: InputDevice, values: FormValues, editingRule: CustomizationRule?) {
        self.device = device
        self.editingRule = editingRule
        _name = State(initialValue: values.name)
        _gesture = State(initialValue: values.gesture)
        _mouseButtonNumber = State(initialValue: values.mouseButtonNumber)
        _keyCode = State(initialValue: values.keyCode)
        _keyModifiers = State(initialValue: values.keyModifiers)
        _actionKind = State(initialValue: values.actionKind)
        _shellCommand = State(initialValue: values.shellCommand)
        _bundleIdentifier = State(initialValue: values.bundleIdentifier)
        _mediaKey = State(initialValue: values.mediaKey)
        _remapKeyCode = State(initialValue: values.remapKeyCode)
        _remapModifiers = State(initialValue: values.remapModifiers)
        _repeatsWhileHeld = State(initialValue: values.repeatsWhileHeld)
        _repeatsByDistance = State(initialValue: values.repeatsByDistance)
        _restrictedToApps = State(initialValue: values.restrictedToApps)
    }

    private var canSave: Bool {
        if device == .keyboard && keyCode == KeyCodeMap.unset { return false }
        if actionKind == .remapToKey && remapKeyCode == KeyCodeMap.unset { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if device == .trackpad {
                // Controls on the left, a live touch preview on the
                // right — one visual element, not two. An earlier version
                // paired this with a static hand-illustration "Preview"
                // panel above the controls; that made the sheet taller
                // than the window (Form doesn't auto-scroll on macOS) and
                // read as cluttered. Dropping it and letting the sheet
                // size itself to this shorter content fixes both without
                // needing a ScrollView.
                HStack(alignment: .top, spacing: 24) {
                    Form {
                        nameField
                        Picker("Gesture", selection: $gesture) {
                            ForEach(Trigger.GestureKind.allCases, id: \.self) { kind in
                                Label { Text(kind.displayName) } icon: { GestureGlyphRenderer.image(for: kind) }
                                    .tag(kind)
                            }
                        }
                        // Menu-style Pickers on macOS can keep showing a
                        // stale selected label when `selection` changes
                        // programmatically (e.g. "Use This Gesture") rather
                        // than via a click on the menu itself, especially
                        // with custom icon content. `.id(gesture)` forces a
                        // clean rebuild instead of relying on that diffing.
                        .id(gesture)
                        if gesture.category == .swipe {
                            Toggle("Repeat while held", isOn: $repeatsWhileHeld)
                                .help("Keep re-running this rule's action for as long as you hold the swipe, instead of firing once.")
                            if repeatsWhileHeld {
                                Toggle("Repeat by distance instead of time", isOn: $repeatsByDistance)
                                    .help("Re-run the action every time you slide the fingers a bit further, like a scroll wheel, instead of on a fixed timer.")
                                    .padding(.leading, 16)
                            }
                        }
                        actionFields
                        appScopeFields
                    }
                    .frame(width: 300)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live Preview").font(.headline)
                        TouchVisualizerView(selectedGesture: $gesture)
                    }
                    .frame(width: 348)
                }
                .padding()
            } else {
                Form {
                    nameField
                    switch device {
                    case .mouse:
                        Stepper("Button number: \(mouseButtonNumber)", value: $mouseButtonNumber, in: 0...31)
                    case .keyboard:
                        LabeledContent("Key combo") {
                            KeyCaptureField(keyCode: $keyCode, modifiers: $keyModifiers)
                        }
                    case .trackpad:
                        EmptyView() // handled above
                    }
                    actionFields
                    appScopeFields
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(editingRule == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(
            minWidth: device == .trackpad ? 700 : 420,
            maxWidth: device == .trackpad ? .infinity : 420
        )
    }

    @ViewBuilder private var nameField: some View {
        TextField("Name", text: $name)
    }

    @ViewBuilder private var actionFields: some View {
        Picker("Action", selection: $actionKind) {
            ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
        }
        switch actionKind {
        case .shellCommand:
            TextField("Command", text: $shellCommand)
        case .launchApp:
            TextField("Bundle identifier (e.g. com.apple.Safari)", text: $bundleIdentifier)
        case .mediaKey:
            Picker("Key", selection: $mediaKey) {
                ForEach(Action.MediaKey.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        case .remapToKey:
            LabeledContent("New key") {
                KeyCaptureField(keyCode: $remapKeyCode, modifiers: $remapModifiers)
            }
        case .missionControl:
            EmptyView()
        }
    }

    /// Empty by default (applies everywhere). Adding an app scopes the
    /// rule to only fire while one of the listed apps is frontmost — see
    /// `CustomizationRule.applies(whileFrontmostAppIs:)`. For a whole
    /// different set of gestures per app (not just one rule's
    /// condition), Profiles is the other, coarser-grained mechanism —
    /// see the footer text pointing that out where a user would
    /// naturally reach for this instead.
    @ViewBuilder private var appScopeFields: some View {
        Section {
            AppReferenceListEditor(
                apps: restrictedToApps,
                onAdd: { restrictedToApps.append($0) },
                onRemove: { app in restrictedToApps.removeAll { $0.id == app.id } }
            )
        } header: {
            Text("Only in these apps")
        } footer: {
            Text(restrictedToApps.isEmpty
                ? "Applies everywhere."
                : "Only fires while one of these apps is frontmost. For a whole different set of gestures per app, use Profiles instead (Preferences → profile switcher → Manage Profiles…).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        let trigger: Trigger
        switch device {
        case .trackpad: trigger = .trackpadGesture(gesture)
        case .mouse: trigger = .mouseButton(number: mouseButtonNumber, modifiers: 0)
        case .keyboard: trigger = .keyCombo(keyCode: keyCode, modifiers: keyModifiers)
        }

        let action: Action
        switch actionKind {
        case .missionControl: action = .missionControl
        case .shellCommand: action = .runShellCommand(shellCommand)
        case .launchApp: action = .launchApp(bundleIdentifier: bundleIdentifier)
        case .mediaKey: action = .sendMediaKey(mediaKey)
        case .remapToKey: action = .remapToKey(keyCode: remapKeyCode, modifiers: remapModifiers)
        }

        let ruleName = name.isEmpty ? "Untitled rule" : name
        // Compose off the already-clamped sibling value so the two can't
        // drift apart if supportsRepeatWhileHeld's definition ever changes
        // without someone remembering to mirror it here.
        let clampedRepeatsWhileHeld = trigger.supportsRepeatWhileHeld && repeatsWhileHeld
        let clampedRepeatsByDistance = trigger.supportsRepeatByDistance && clampedRepeatsWhileHeld && repeatsByDistance

        if let editingRule {
            settingsStore.updateRule(CustomizationRule(
                id: editingRule.id,
                name: ruleName,
                device: device,
                trigger: trigger,
                action: action,
                isEnabled: editingRule.isEnabled,
                repeatsWhileHeld: clampedRepeatsWhileHeld,
                repeatsByDistance: clampedRepeatsByDistance,
                restrictedToApps: restrictedToApps
            ))
        } else {
            settingsStore.addRule(CustomizationRule(
                name: ruleName,
                device: device,
                trigger: trigger,
                action: action,
                repeatsWhileHeld: clampedRepeatsWhileHeld,
                repeatsByDistance: clampedRepeatsByDistance,
                restrictedToApps: restrictedToApps
            ))
        }
        dismiss()
    }
}

/// A small control that records a single key press (with modifiers) when
/// "Record" is clicked, via a local NSEvent monitor. Used for both keyboard
/// rule triggers and "remap to key" action targets.
struct KeyCaptureField: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(isRecording ? "Press a key…" : KeyCodeMap.describe(keyCode: keyCode, modifiers: modifiers))
                .frame(minWidth: 120, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
            Button(isRecording ? "Cancel" : "Record") {
                isRecording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            keyCode = event.keyCode
            modifiers = UInt(event.modifierFlags.intersection(KeyCodeMap.relevantModifiers).rawValue)
            stopRecording()
            return nil // swallow so it doesn't type into other fields in the sheet
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
