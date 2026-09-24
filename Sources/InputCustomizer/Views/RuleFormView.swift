import SwiftUI
import UniformTypeIdentifiers
import GestureEngine
import InputModels

/// Add, edit, or preset-prefill a rule — one form for all three, since
/// they only differ in what the `@State` starts as and whether saving
/// calls `addRule` or `updateRule`.
struct RuleFormView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var visualizerModel: TouchVisualizerModel
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
    @State private var touchDeviceTriggerKind: TouchDeviceTriggerKind
    @State private var mouseCorner: MouseCorner
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
    // Each of the four global sensitivity/repeat sliders (Gesture Tuning)
    // can be overridden per rule instead — an `Enabled` flag plus a
    // bound `Value` rather than a single `Double?`, since a Slider needs
    // a concrete non-optional binding regardless of whether the override
    // is actually turned on. `nil` (override off) is what gets saved
    // when `Enabled` is false, regardless of whatever `Value` last held.
    @State private var sensitivityOverrideEnabled: Bool
    @State private var sensitivityOverrideValue: Double
    @State private var repeatIntervalOverrideEnabled: Bool
    @State private var repeatIntervalOverrideValue: Double
    @State private var repeatDelayOverrideEnabled: Bool
    @State private var repeatDelayOverrideValue: Double
    @State private var repeatByDistanceSensitivityOverrideEnabled: Bool
    @State private var repeatByDistanceSensitivityOverrideValue: Double
    /// Starts expanded only when the rule already uses an override, so
    /// existing customizations are never hidden behind a closed disclosure.
    @State private var showsAdvanced: Bool

    /// Picker order runs from most common to most powerful — the shell
    /// command sits last since it's the one action that warrants a
    /// warning.
    enum ActionKind: String, CaseIterable, Identifiable {
        case remapToKey = "Keyboard shortcut"
        case mediaKey = "Media key"
        case missionControl = "Mission Control"
        case launchApp = "Open app"
        case shellCommand = "Run shell command"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .remapToKey: return "command"
            case .mediaKey: return "playpause"
            case .missionControl: return "rectangle.3.group"
            case .launchApp: return "app"
            case .shellCommand: return "terminal"
            }
        }
    }

    /// Shared by `.trackpad` and `.magicMouse` — both have a touch
    /// surface, so both need an upfront choice between a multitouch
    /// gesture and an ordinary click, unlike `.mouse` (no touch surface
    /// at all, so it only ever has plain button clicks — see its case in
    /// `body` below). Each device only offers *some* of these cases (see
    /// `availableTriggerKinds`): `.trackpad`'s click flavor is
    /// `.clickCorner` (a Force-Touch stand-in), `.magicMouse`'s is
    /// `.clickAnywhere` (grouping its clicks in this tab rather than the
    /// generic Mouse one — functionally identical to a `.mouse` rule,
    /// purely organizational). Neither device offers the other's click
    /// flavor: a plain click is already caught anywhere by a `.mouse`
    /// rule regardless of which physical device produced it, so
    /// `.magicMouse` never needs `.clickCorner`, and corner-gating a
    /// generic mouse click is physically meaningless (`MouseCorner
    /// .resolve` would always return `nil` with no touch surface to read).
    enum TouchDeviceTriggerKind: String, CaseIterable, Identifiable {
        case gesture = "Multi-touch gesture"
        case clickAnywhere = "Click anywhere"
        case clickCorner = "Click in corner"
        var id: String { rawValue }
    }

    /// One unified, user-facing option in the Trackpad's single "Gesture"
    /// picker — either a real multitouch gesture, or one of the 4 corner
    /// clicks. A corner click isn't something `GestureRecognizer` ever
    /// produces (see `MouseCorner`'s doc comment: it's an ordinary click
    /// gated by finger position, not a gesture), but it reads to a user
    /// as just another answer to "what triggers this rule" — folding it
    /// into the same picker means they never have to first know these
    /// are two different `Trigger` cases (`.trackpadGesture` vs
    /// `.mouseCornerClick`) under the hood. Only `.trackpad` uses this —
    /// `.magicMouse` keeps its separate "Trigger" picker (`.gesture` vs
    /// `.clickAnywhere`, an *un*gated click — see `TouchDeviceTriggerKind`).
    private enum TrackpadTriggerOption: Hashable {
        case gesture(Trigger.GestureKind)
        case cornerClick(MouseCorner)
    }

    /// Reads/writes `touchDeviceTriggerKind` + `gesture`/`mouseCorner`
    /// together as one selection, so the unified picker above can bind
    /// to a single value while the rest of this view keeps working with
    /// those three separate `@State` vars exactly as it already did.
    private var trackpadTriggerOption: Binding<TrackpadTriggerOption> {
        Binding(
            get: { touchDeviceTriggerKind == .clickCorner ? .cornerClick(mouseCorner) : .gesture(gesture) },
            set: { newValue in
                switch newValue {
                case let .gesture(kind):
                    touchDeviceTriggerKind = .gesture
                    gesture = kind
                case let .cornerClick(corner):
                    touchDeviceTriggerKind = .clickCorner
                    mouseCorner = corner
                }
            }
        )
    }

    /// Everything the form's `@State` needs, decoupled from *why* it's
    /// being constructed (blank, from an existing rule, or from a
    /// preset) — the single source of truth the three initializers below
    /// all funnel through.
    private struct FormValues {
        var name = ""
        var gesture: Trigger.GestureKind = .twoFingerSwipeLeft
        var mouseButtonNumber = 3
        var touchDeviceTriggerKind: TouchDeviceTriggerKind = .gesture
        var mouseCorner: MouseCorner = .topLeft
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
        var sensitivityOverride: Double?
        var repeatIntervalOverride: Double?
        var repeatDelayOverride: Double?
        var repeatByDistanceSensitivityOverride: Double?

        static func from(rule: CustomizationRule) -> FormValues {
            var values = FormValues()
            values.name = rule.name
            values.repeatsWhileHeld = rule.repeatsWhileHeld
            values.repeatsByDistance = rule.repeatsByDistance
            values.restrictedToApps = rule.restrictedToApps
            values.sensitivityOverride = rule.sensitivityOverride
            values.repeatIntervalOverride = rule.repeatIntervalOverride
            values.repeatDelayOverride = rule.repeatDelayOverride
            values.repeatByDistanceSensitivityOverride = rule.repeatByDistanceSensitivityOverride
            switch rule.trigger {
            case let .trackpadGesture(kind):
                values.gesture = kind
                values.touchDeviceTriggerKind = .gesture
            case let .mouseButton(number, _):
                values.mouseButtonNumber = number
                values.touchDeviceTriggerKind = .clickAnywhere
            case let .mouseCornerClick(corner, number, _):
                values.mouseButtonNumber = number
                values.mouseCorner = corner
                values.touchDeviceTriggerKind = .clickCorner
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
                name: preset.ruleName,
                device: preset.device,
                trigger: preset.trigger,
                action: preset.action,
                repeatsWhileHeld: preset.repeatsWhileHeld,
                repeatsByDistance: preset.repeatsByDistance
            ))
        }
    }

    init(device: InputDevice) {
        var values = FormValues()
        // FormValues' plain default (3) is meant for `.mouse`'s side
        // buttons, a sensible default there — but `.trackpad`/`.magicMouse`
        // click triggers (Corner Click, Click Anywhere) almost always mean
        // an ordinary primary click, button 0. Leaving 3 as the default
        // for a fresh touch-device click rule meant it silently never
        // matched a real click unless you happened to notice and change
        // the stepper yourself.
        if device == .trackpad || device == .magicMouse {
            values.mouseButtonNumber = 0
        }
        self.init(device: device, values: values, editingRule: nil)
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
        _touchDeviceTriggerKind = State(initialValue: values.touchDeviceTriggerKind)
        _mouseCorner = State(initialValue: values.mouseCorner)
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
        _sensitivityOverrideEnabled = State(initialValue: values.sensitivityOverride != nil)
        _sensitivityOverrideValue = State(initialValue: values.sensitivityOverride ?? 0.5)
        _repeatIntervalOverrideEnabled = State(initialValue: values.repeatIntervalOverride != nil)
        _repeatIntervalOverrideValue = State(initialValue: values.repeatIntervalOverride ?? 0.35)
        _repeatDelayOverrideEnabled = State(initialValue: values.repeatDelayOverride != nil)
        _repeatDelayOverrideValue = State(initialValue: values.repeatDelayOverride ?? 0.3)
        _repeatByDistanceSensitivityOverrideEnabled = State(initialValue: values.repeatByDistanceSensitivityOverride != nil)
        _repeatByDistanceSensitivityOverrideValue = State(initialValue: values.repeatByDistanceSensitivityOverride ?? 0.5)
        _showsAdvanced = State(initialValue: values.sensitivityOverride != nil
            || values.repeatIntervalOverride != nil
            || values.repeatDelayOverride != nil
            || values.repeatByDistanceSensitivityOverride != nil)
    }

    /// `.trackpad` and `.magicMouse` both configure `.trackpadGesture`
    /// triggers through the same gesture picker + live preview — see
    /// `InputDevice.magicMouse`'s doc comment for why they share one
    /// recognition pipeline. Centralized here so the layout branch below
    /// and the width/save logic further down can't drift apart on which
    /// devices this applies to.
    private var usesWideLayout: Bool { device == .trackpad || device == .magicMouse }

    /// Whether the gesture picker + repeat toggles (vs. the button/corner
    /// click fields) should show — both `.trackpad` and `.magicMouse` can
    /// be in either mode now, gated by `touchDeviceTriggerKind`.
    private var showsGestureFields: Bool {
        usesWideLayout && touchDeviceTriggerKind == .gesture
    }

    /// Which `TouchDeviceTriggerKind` cases the Magic Mouse's separate
    /// "Trigger" picker offers — `.trackpad` doesn't use this at all
    /// anymore; its corner-click options are folded directly into its
    /// unified "Gesture" picker instead (see `trackpadTriggerOption`).
    private var availableTriggerKinds: [TouchDeviceTriggerKind] {
        switch device {
        case .magicMouse: return [.gesture, .clickAnywhere]
        case .trackpad, .mouse, .keyboard: return []
        }
    }

    private var canSave: Bool {
        if device == .keyboard && keyCode == KeyCodeMap.unset { return false }
        if actionKind == .remapToKey && remapKeyCode == KeyCodeMap.unset { return false }
        // An empty command or no chosen app would save a rule that
        // silently does nothing (or errors) every time it fires.
        if actionKind == .shellCommand && shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if actionKind == .launchApp && bundleIdentifier.isEmpty { return false }
        return true
    }

    private var formTitle: String {
        if editingRule != nil { return "Edit Rule" }
        return "New \(device.displayName) Rule"
    }

    var body: some View {
        Group {
            if usesWideLayout {
                // Controls on the left, a live touch preview on the
                // right — one visual element, not two. The grouped Form
                // scrolls on its own, so the sheet can stay a fixed size
                // however many conditional rows are showing.
                HStack(alignment: .top, spacing: 0) {
                    form
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live preview").font(.headline)
                        TouchVisualizerView(selectedGesture: $gesture, device: device)
                        Text("Trying a gesture here also runs any rule already assigned to it. Pause all rules first if you don’t want that.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 348)
                    .padding(20)
                }
            } else {
                form
            }
        }
        .frame(width: usesWideLayout ? 800 : 480, height: usesWideLayout ? 580 : 500)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(editingRule == nil ? "Add Rule" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Optional — named after its action"))
            } header: {
                Text(formTitle).font(.title3.weight(.semibold))
            }

            Section("Trigger") {
                switch device {
                case .trackpad:
                    trackpadTriggerFields
                case .magicMouse:
                    magicMouseTriggerFields
                case .mouse:
                    // No touch surface, so no corner-click option here
                    // — see TouchDeviceTriggerKind's doc comment for
                    // where that lives instead.
                    mouseButtonField
                case .keyboard:
                    LabeledContent("Key combo") {
                        KeyCaptureField(keyCode: $keyCode, modifiers: $keyModifiers)
                    }
                }
            }

            Section("Action") {
                actionFields
            }

            appScopeFields

            if showsGestureFields {
                Section("Advanced") {
                    DisclosureGroup("Custom tuning for this rule", isExpanded: $showsAdvanced) {
                        advancedOverrideFields
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var mouseButtonField: some View {
        LabeledContent("Mouse button") {
            Stepper(value: $mouseButtonNumber, in: 0...31) {
                Text(RuleSummary.mouseButtonName(mouseButtonNumber))
                    .monospacedDigit()
            }
        }
    }

    /// `.trackpad`'s trigger fields: one unified picker mixing real
    /// multitouch gestures with the 4 corner clicks (see
    /// `TrackpadTriggerOption`) — no separate "Trigger" type choice.
    /// `showsGestureFields` (driven by the same `touchDeviceTriggerKind`
    /// the picker below sets) still correctly distinguishes "show repeat/
    /// sensitivity controls" from "show the corner-click hint"
    /// regardless of which of the two the unified picker landed on.
    @ViewBuilder private var trackpadTriggerFields: some View {
        Picker("Gesture", selection: trackpadTriggerOption) {
            Section("Multi-touch gestures") {
                ForEach(Trigger.GestureKind.allCases, id: \.self) { kind in
                    Label { Text(kind.displayName) } icon: { GestureGlyphRenderer.image(for: kind) }
                        .tag(TrackpadTriggerOption.gesture(kind))
                }
            }
            Section("Trackpad corner clicks") {
                ForEach(offeredCorners) { corner in
                    Label { Text(corner.displayName) } icon: { MouseCornerGlyphRenderer.image(for: corner) }
                        .tag(TrackpadTriggerOption.cornerClick(corner))
                }
            }
        }
        // Menu-style Pickers on macOS can keep showing a stale selected
        // label when `selection` changes programmatically (e.g. "Use
        // This Gesture" in the Live Preview) rather than via a click on
        // the menu itself, especially with custom icon content. `.id`
        // forces a clean rebuild instead of relying on that diffing.
        .id(gesture)

        if showsGestureFields {
            gestureRepeatToggles
        } else {
            // No button-number field here on purpose: a corner click is
            // just "touch this corner, then click" — one unambiguous
            // physical action, always the primary click (see `save()`,
            // which hardcodes `number: 0`) — not a configurable button
            // like `.mouse`'s side-buttons or `.magicMouse`'s plain
            // "Click anywhere" reasonably still expose.
            cornerClickLiveHint
        }
    }

    /// Corner Click has no equivalent to a real gesture's "recognized!"
    /// feedback in the Live Preview — resolving a click to a corner
    /// happens in `MouseManager`, entirely separate from the multitouch-
    /// frame pipeline `TouchVisualizerModel` listens to, and this
    /// in-progress rule isn't saved yet for `MouseManager` to match
    /// against anyway. This reads the same live touch data the preview's
    /// dots already show and reports whether it's currently near the
    /// selected corner, so there's still *some* live confirmation that
    /// finger position is being read correctly while testing.
    @ViewBuilder private var cornerClickLiveHint: some View {
        if case let .cornerClick(selectedCorner) = trackpadTriggerOption.wrappedValue {
            let isNearSelectedCorner = currentCornerHint == selectedCorner
            Label {
                Text(!CornerZoneSpec.builtInTrackpad.allowed.contains(selectedCorner)
                    ? "Bottom corners no longer trigger rules — that’s where ordinary clicks land. Pick a top corner."
                    : isNearSelectedCorner
                    ? "One finger is in the \(selectedCorner.displayName.lowercased()) — click now to try it."
                    : "Put one finger down in the \(selectedCorner.displayName.lowercased()) and click straight away. The click itself won’t reach the app under the pointer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: isNearSelectedCorner ? "checkmark.circle" : "hand.point.up.left")
                    .foregroundStyle(isNearSelectedCorner ? Color.green : Color.secondary)
            }
        }
    }

    private static let touchingStates: Set<Int32> = [3, 4]

    /// Only the top corners work (see `CornerZoneSpec.allowed`). A rule
    /// saved with a bottom corner by an older version stays selectable
    /// so editing it doesn't silently change its trigger.
    private var offeredCorners: [MouseCorner] {
        var corners = MouseCorner.allCases.filter { CornerZoneSpec.builtInTrackpad.allowed.contains($0) }
        if touchDeviceTriggerKind == .clickCorner, !corners.contains(mouseCorner) { corners.append(mouseCorner) }
        return corners
    }

    /// Which corner zone a *single* resting finger is in — the same zone
    /// `resolveCornerClick` uses, fed from the Live Preview's touch data
    /// since this in-progress rule isn't saved yet. Two or more fingers
    /// never count, matching the real rule.
    private var currentCornerHint: MouseCorner? {
        let touching = visualizerModel.touches.filter { Self.touchingStates.contains($0.state) }
        guard touching.count == 1, let finger = touching.first else { return nil }
        return cornerZone(containing: finger.position, surface: CornerZoneSpec.builtInTrackpadSizeMM, zone: CornerZoneSpec.builtInTrackpad.sizeMM)
    }

    /// `.magicMouse`'s trigger fields: a separate "Trigger" choice
    /// between a real gesture and an *un*gated click anywhere (not a
    /// corner click — that's trackpad-only, see `InputDevice.magicMouse`'s
    /// doc comment) — kept as its own picker rather than folded in with
    /// gestures, since "click anywhere" doesn't read as a "gesture" the
    /// way a corner click's position-gating at least resembles one.
    @ViewBuilder private var magicMouseTriggerFields: some View {
        Picker("Type", selection: $touchDeviceTriggerKind) {
            ForEach(availableTriggerKinds) { Text($0.rawValue).tag($0) }
        }
        if showsGestureFields {
            Picker("Gesture", selection: $gesture) {
                ForEach(Trigger.GestureKind.allCases, id: \.self) { kind in
                    Label { Text(kind.displayName) } icon: { GestureGlyphRenderer.image(for: kind, surface: .mouse) }
                        .tag(kind)
                }
            }
            .id(gesture)
            gestureRepeatToggles
        } else {
            mouseButtonField
        }
    }

    /// Shared by both devices' gesture mode: the repeat-while-held/
    /// repeat-by-distance toggles. Gated directly on the same properties
    /// `save()` clamps against (rather than a hand-copied `category ==
    /// .swipe` check) so this can never silently drift out of sync with
    /// what actually gets persisted — an earlier version of this check
    /// only checked `.swipe`, which meant the toggle never appeared for
    /// `.splitSwipe` gestures (e.g. the anchor+swipe Copy/Paste presets)
    /// even though TrackpadManager fully supports repeating them.
    @ViewBuilder private var gestureRepeatToggles: some View {
        if Trigger.trackpadGesture(gesture).supportsRepeatWhileHeld {
            Toggle("Repeat while held", isOn: $repeatsWhileHeld)
                .help("Keep re-running this rule's action for as long as you hold the swipe, instead of firing once.")
            if repeatsWhileHeld && Trigger.trackpadGesture(gesture).supportsRepeatByDistance {
                Toggle("Repeat by distance instead of time", isOn: $repeatsByDistance)
                    .help("Re-run the action every time you slide the fingers a bit further, like a scroll wheel, instead of on a fixed timer.")
            }
        }
    }

    /// Per-rule overrides of the global Gesture Tuning sliders, tucked
    /// behind a disclosure since most rules never need them. Only the
    /// overrides that `save()` will actually persist for the current
    /// repeat settings are shown.
    @ViewBuilder private var advancedOverrideFields: some View {
        overrideToggleSlider(
            title: "Custom sensitivity",
            help: "How easily this specific gesture triggers, instead of the global sensitivity in Gesture Tuning.",
            enabled: $sensitivityOverrideEnabled,
            value: $sensitivityOverrideValue
        )
        if Trigger.trackpadGesture(gesture).supportsRepeatWhileHeld && repeatsWhileHeld {
            overrideToggleSlider(
                title: "Custom repeat speed",
                help: "How fast this rule re-fires while held, instead of the global repeat speed in Gesture Tuning.",
                enabled: $repeatIntervalOverrideEnabled,
                value: $repeatIntervalOverrideValue,
                range: 0.15...0.75,
                invertedDisplay: true
            )
            overrideToggleSlider(
                title: "Custom repeat delay",
                help: "How long to wait after this rule first fires before it starts repeating, instead of the global repeat delay in Gesture Tuning.",
                enabled: $repeatDelayOverrideEnabled,
                value: $repeatDelayOverrideValue,
                range: 0...1.0
            )
            if Trigger.trackpadGesture(gesture).supportsRepeatByDistance && repeatsByDistance {
                overrideToggleSlider(
                    title: "Custom distance sensitivity",
                    help: "How much travel counts as \"one more repeat\", instead of the global distance sensitivity in Gesture Tuning.",
                    enabled: $repeatByDistanceSensitivityOverrideEnabled,
                    value: $repeatByDistanceSensitivityOverrideValue
                )
            }
        }
    }

    /// A toggle that reveals a slider when on, for one of the four
    /// per-rule overrides of a global Gesture Tuning slider (see
    /// `CustomizationRule`'s doc comment on `sensitivityOverride`).
    /// `enabled == false` is what makes `save()` persist `nil` (use the
    /// global default) regardless of whatever `value` last held.
    @ViewBuilder
    private func overrideToggleSlider(
        title: String,
        help: String,
        enabled: Binding<Bool>,
        value: Binding<Double>,
        range: ClosedRange<Double> = 0...1,
        invertedDisplay: Bool = false
    ) -> some View {
        Toggle(title, isOn: enabled).help(help)
        if enabled.wrappedValue {
            LabeledSlider(
                title: title.replacingOccurrences(of: "Custom ", with: "").capitalizedFirstLetter,
                value: invertedDisplay ? SliderBinding.inverted(value, in: range) : value,
                range: range,
                minimumLabel: invertedDisplay ? "Slower" : "Less",
                maximumLabel: invertedDisplay ? "Faster" : "More"
            )
        }
    }

    @ViewBuilder private var actionFields: some View {
        Picker("Action", selection: $actionKind) {
            ForEach(ActionKind.allCases) { kind in
                Label(kind.rawValue, systemImage: kind.systemImage).tag(kind)
            }
        }
        switch actionKind {
        case .shellCommand:
            LabeledContent("Command") {
                TextField("Command", text: $shellCommand, prompt: Text("open -a Calculator"))
                    .labelsHidden()
                    .font(.body.monospaced())
            }
            Label("Runs with your full user permissions. Only use commands you understand and trust.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .launchApp:
            LabeledContent("App") {
                HStack(spacing: 8) {
                    if bundleIdentifier.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    } else {
                        AppIconView(bundleIdentifier: bundleIdentifier, size: 20)
                        Text(InstalledApp.displayName(for: bundleIdentifier))
                            .help(bundleIdentifier)
                    }
                    Button(bundleIdentifier.isEmpty ? "Choose…" : "Change…") {
                        if let app = InstalledApp.choose() { bundleIdentifier = app.bundleIdentifier }
                    }
                }
            }
        case .mediaKey:
            Picker("Key", selection: $mediaKey) {
                ForEach(Action.MediaKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
        case .remapToKey:
            LabeledContent(device == .keyboard ? "New key" : "Shortcut") {
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
            Text("Apps")
        } footer: {
            Text(restrictedToApps.isEmpty
                ? "Works in every app. Add apps to limit this rule to them."
                : "Only works while one of these apps is in front. For a whole different set of rules per app, use a profile instead (profile menu → Manage Profiles…).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        let trigger: Trigger
        switch device {
        case .trackpad, .magicMouse:
            switch touchDeviceTriggerKind {
            case .gesture: trigger = .trackpadGesture(gesture)
            case .clickAnywhere: trigger = .mouseButton(number: mouseButtonNumber, modifiers: 0)
            // Always the primary click — see trackpadTriggerFields' doc
            // comment on why this isn't user-configurable like the other
            // two trigger flavors' button numbers are.
            case .clickCorner: trigger = .mouseCornerClick(corner: mouseCorner, number: 0, modifiers: 0)
            }
        case .mouse:
            trigger = .mouseButton(number: mouseButtonNumber, modifiers: 0)
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

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let ruleName = trimmedName.isEmpty ? RuleSummary.suggestedName(for: action) : trimmedName
        // Compose off the already-clamped sibling value so the two can't
        // drift apart if supportsRepeatWhileHeld's definition ever changes
        // without someone remembering to mirror it here.
        let clampedRepeatsWhileHeld = trigger.supportsRepeatWhileHeld && repeatsWhileHeld
        let clampedRepeatsByDistance = trigger.supportsRepeatByDistance && clampedRepeatsWhileHeld && repeatsByDistance
        // Each override only actually saves as non-nil if its own toggle
        // is on — `false` always means "use the global default",
        // regardless of whatever the slider was last dragged to while off.
        let sensitivityOverride = sensitivityOverrideEnabled ? sensitivityOverrideValue : nil
        let repeatIntervalOverride = (clampedRepeatsWhileHeld && repeatIntervalOverrideEnabled) ? repeatIntervalOverrideValue : nil
        let repeatDelayOverride = (clampedRepeatsWhileHeld && repeatDelayOverrideEnabled) ? repeatDelayOverrideValue : nil
        let repeatByDistanceSensitivityOverride = (clampedRepeatsByDistance && repeatByDistanceSensitivityOverrideEnabled) ? repeatByDistanceSensitivityOverrideValue : nil

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
                restrictedToApps: restrictedToApps,
                sensitivityOverride: sensitivityOverride,
                repeatIntervalOverride: repeatIntervalOverride,
                repeatDelayOverride: repeatDelayOverride,
                repeatByDistanceSensitivityOverride: repeatByDistanceSensitivityOverride
            ))
        } else {
            settingsStore.addRule(CustomizationRule(
                name: ruleName,
                device: device,
                trigger: trigger,
                action: action,
                repeatsWhileHeld: clampedRepeatsWhileHeld,
                repeatsByDistance: clampedRepeatsByDistance,
                restrictedToApps: restrictedToApps,
                sensitivityOverride: sensitivityOverride,
                repeatIntervalOverride: repeatIntervalOverride,
                repeatDelayOverride: repeatDelayOverride,
                repeatByDistanceSensitivityOverride: repeatByDistanceSensitivityOverride
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
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .frame(minWidth: 110, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isRecording ? Color.accentColor : Color.clear))
            Button(isRecording ? "Cancel" : "Record") {
                isRecording ? stopRecording() : startRecording()
            }
            // Some shortcuts (Mission Control, Spaces, Spotlight, the app
            // switcher, screenshots…) are consumed by macOS itself before
            // a local key monitor ever sees the press, so "Record" can
            // never capture them — this sets them directly instead.
            Menu {
                ForEach(KeyCodeMap.presetShortcuts) { preset in
                    Button(preset.name) {
                        stopRecording()
                        keyCode = preset.keyCode
                        modifiers = preset.modifiers
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("Common system shortcuts")
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick a shortcut that macOS intercepts before it can be recorded")
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

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
