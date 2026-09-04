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
    @State private var restrictedToApps: [AppReference]

    enum ActionKind: String, CaseIterable, Identifiable {
        case missionControl = "Mission Control"
        case shellCommand = "Run Shell Command"
        case launchApp = "Launch App"
        case mediaKey = "Media Key"
        case remapToKey = "Remap to Key"
        var id: String { rawValue }
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
        case gesture = "Multi-Touch Gesture"
        case clickAnywhere = "Click Anywhere"
        case clickCorner = "Click in Corner"
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
        var restrictedToApps: [AppReference] = []

        static func from(rule: CustomizationRule) -> FormValues {
            var values = FormValues()
            values.name = rule.name
            values.repeatsWhileHeld = rule.repeatsWhileHeld
            values.restrictedToApps = rule.restrictedToApps
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
                name: preset.name,
                device: preset.device,
                trigger: preset.trigger,
                action: preset.action,
                repeatsWhileHeld: preset.repeatsWhileHeld
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
        _restrictedToApps = State(initialValue: values.restrictedToApps)
    }

    /// `.trackpad` and `.magicMouse` both configure `.trackpadGesture`
    /// triggers through the same gesture picker + live preview. Centralized
    /// here so the layout branch below and the width/save logic further
    /// down can't drift apart on which devices this applies to.
    private var usesWideLayout: Bool { device == .trackpad || device == .magicMouse }

    /// Whether the gesture picker + repeat toggle (vs. the button/corner
    /// click fields) should show — both `.trackpad` and `.magicMouse` can
    /// be in either mode, gated by `touchDeviceTriggerKind`.
    private var showsGestureFields: Bool {
        usesWideLayout && touchDeviceTriggerKind == .gesture
    }

    /// Which `TouchDeviceTriggerKind` cases the Magic Mouse's separate
    /// "Trigger" picker offers — `.trackpad` doesn't use this at all;
    /// its corner-click options are folded directly into its unified
    /// "Gesture" picker instead (see `trackpadTriggerOption`).
    private var availableTriggerKinds: [TouchDeviceTriggerKind] {
        switch device {
        case .magicMouse: return [.gesture, .clickAnywhere]
        case .trackpad, .mouse, .keyboard: return []
        }
    }

    private var canSave: Bool {
        if device == .keyboard && keyCode == KeyCodeMap.unset { return false }
        if actionKind == .remapToKey && remapKeyCode == KeyCodeMap.unset { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if usesWideLayout {
                // Controls on the left, a live touch preview on the
                // right — one visual element, not two.
                HStack(alignment: .top, spacing: 24) {
                    Form {
                        nameField
                        if device == .trackpad {
                            trackpadTriggerFields
                        } else {
                            magicMouseTriggerFields
                        }
                        actionFields
                        appScopeFields
                    }
                    .frame(width: 300)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Live Preview").font(.headline)
                        TouchVisualizerView(selectedGesture: $gesture, device: device)
                    }
                    .frame(width: 348)
                }
                .padding()
            } else {
                Form {
                    nameField
                    switch device {
                    case .mouse:
                        // No touch surface, so no corner-click option here
                        // — see TouchDeviceTriggerKind's doc comment for
                        // where that lives instead.
                        Stepper("Button number: \(mouseButtonNumber)", value: $mouseButtonNumber, in: 0...31)
                    case .keyboard:
                        LabeledContent("Key combo") {
                            KeyCaptureField(keyCode: $keyCode, modifiers: $keyModifiers)
                        }
                    case .trackpad, .magicMouse:
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
            minWidth: usesWideLayout ? 700 : 420,
            maxWidth: usesWideLayout ? .infinity : 420
        )
    }

    @ViewBuilder private var nameField: some View {
        TextField("Name", text: $name)
    }

    /// `.trackpad`'s trigger fields: one unified "Gesture" picker mixing
    /// real multitouch gestures with the 4 corner clicks (see
    /// `TrackpadTriggerOption`) — no separate "Trigger" type choice.
    /// `showsGestureFields` (driven by the same `touchDeviceTriggerKind`
    /// the picker below sets) still correctly distinguishes "show the
    /// repeat toggle" from "show the corner-click's live hint" regardless
    /// of which of the two the unified picker landed on.
    @ViewBuilder private var trackpadTriggerFields: some View {
        Picker("Gesture", selection: trackpadTriggerOption) {
            Section("Multi-Touch Gesture") {
                ForEach(Trigger.GestureKind.allCases, id: \.self) { kind in
                    Label { Text(kind.displayName) } icon: { GestureGlyphRenderer.image(for: kind) }
                        .tag(TrackpadTriggerOption.gesture(kind))
                }
            }
            Section("Corner Click") {
                ForEach(MouseCorner.allCases) { corner in
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
            gestureRepeatFields
        } else {
            // No button-number field here on purpose: a corner click is
            // just "touch this corner, then click" — one unambiguous
            // physical action, always the primary click (see `save()`,
            // which hardcodes `number: 0`).
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
            HStack(spacing: 6) {
                Image(systemName: isNearSelectedCorner ? "checkmark.circle.fill" : "hand.point.up.left")
                    .foregroundStyle(isNearSelectedCorner ? .green : .secondary)
                Text(isNearSelectedCorner
                    ? "A finger is resting near \(selectedCorner.displayName.lowercased()) right now — that's where a click needs to land."
                    : "Rest a finger near \(selectedCorner.displayName.lowercased()) (shown on the right) to confirm it's being detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let touchingStates: Set<Int32> = [3, 4]

    /// Which corner (if any) the centroid of currently-touching fingers
    /// is near, using the exact same resolution `MouseManager` uses for
    /// a real corner-click rule (`MouseCorner.resolve`) — just fed from
    /// the Live Preview's already-published touch data instead of
    /// `TrackpadManager.lastTouchPosition`, since this in-progress rule
    /// isn't saved for that path to see yet.
    private var currentCornerHint: MouseCorner? {
        let touching = visualizerModel.touches.filter { Self.touchingStates.contains($0.state) }
        guard !touching.isEmpty else { return nil }
        let sum = touching.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y) }
        let centroid = CGPoint(x: sum.x / CGFloat(touching.count), y: sum.y / CGFloat(touching.count))
        return MouseCorner.resolve(from: centroid)
    }

    /// `.magicMouse`'s trigger fields: a separate "Trigger" choice
    /// between a real gesture and an *un*gated click anywhere (not a
    /// corner click — that's trackpad-only) — kept as its own picker
    /// rather than folded in with gestures, since "click anywhere"
    /// doesn't read as a "gesture" the way a corner click's
    /// position-gating at least resembles one.
    @ViewBuilder private var magicMouseTriggerFields: some View {
        Picker("Trigger", selection: $touchDeviceTriggerKind) {
            ForEach(availableTriggerKinds) { Text($0.rawValue).tag($0) }
        }
        if showsGestureFields {
            Picker("Gesture", selection: $gesture) {
                ForEach(Trigger.GestureKind.allCases, id: \.self) { kind in
                    Label { Text(kind.displayName) } icon: { GestureGlyphRenderer.image(for: kind) }
                        .tag(kind)
                }
            }
            .id(gesture)
            gestureRepeatFields
        } else {
            Stepper("Button number: \(mouseButtonNumber)", value: $mouseButtonNumber, in: 0...31)
        }
    }

    /// Shared by both devices' gesture mode: the "repeat while held"
    /// toggle. Gated directly on `supportsRepeatWhileHeld` (rather than a
    /// hand-copied `category == .swipe` check) so this can never silently
    /// drift out of sync with what actually gets persisted.
    @ViewBuilder private var gestureRepeatFields: some View {
        if Trigger.trackpadGesture(gesture).supportsRepeatWhileHeld {
            Toggle("Repeat while held", isOn: $repeatsWhileHeld)
                .help("Keep re-running this rule's action for as long as you hold the swipe, instead of firing once.")
        }
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

        let ruleName = name.isEmpty ? "Untitled rule" : name
        // Compose off the already-clamped sibling value so the two can't
        // drift apart if supportsRepeatWhileHeld's definition ever changes
        // without someone remembering to mirror it here.
        let clampedRepeatsWhileHeld = trigger.supportsRepeatWhileHeld && repeatsWhileHeld

        if let editingRule {
            settingsStore.updateRule(CustomizationRule(
                id: editingRule.id,
                name: ruleName,
                device: device,
                trigger: trigger,
                action: action,
                isEnabled: editingRule.isEnabled,
                repeatsWhileHeld: clampedRepeatsWhileHeld,
                restrictedToApps: restrictedToApps
            ))
        } else {
            settingsStore.addRule(CustomizationRule(
                name: ruleName,
                device: device,
                trigger: trigger,
                action: action,
                repeatsWhileHeld: clampedRepeatsWhileHeld,
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
