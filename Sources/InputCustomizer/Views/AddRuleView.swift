import SwiftUI

struct AddRuleView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let device: InputDevice

    @State private var name: String = ""
    @State private var gesture: Trigger.GestureKind = .twoFingerSwipeLeft
    @State private var mouseButtonNumber: Int = 3
    @State private var keyCode: UInt16 = KeyCodeMap.unset
    @State private var keyModifiers: UInt = 0
    @State private var actionKind: ActionKind = .missionControl
    @State private var shellCommand: String = ""
    @State private var bundleIdentifier: String = ""
    @State private var mediaKey: Action.MediaKey = .playPause
    @State private var remapKeyCode: UInt16 = KeyCodeMap.unset
    @State private var remapModifiers: UInt = 0

    enum ActionKind: String, CaseIterable, Identifiable {
        case missionControl = "Mission Control"
        case shellCommand = "Run Shell Command"
        case launchApp = "Launch App"
        case mediaKey = "Media Key"
        case remapToKey = "Remap to Key"
        var id: String { rawValue }
    }

    private var canAdd: Bool {
        if device == .keyboard && keyCode == KeyCodeMap.unset { return false }
        if actionKind == .remapToKey && remapKeyCode == KeyCodeMap.unset { return false }
        return true
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)

            switch device {
            case .trackpad:
                Picker("Gesture", selection: $gesture) {
                    ForEach(Trigger.GestureKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            case .mouse:
                Stepper("Button number: \(mouseButtonNumber)", value: $mouseButtonNumber, in: 0...31)
            case .keyboard:
                LabeledContent("Key combo") {
                    KeyCaptureField(keyCode: $keyCode, modifiers: $keyModifiers)
                }
            }

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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { addRule() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func addRule() {
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

        let rule = CustomizationRule(
            name: name.isEmpty ? "Untitled rule" : name,
            device: device,
            trigger: trigger,
            action: action
        )
        settingsStore.addRule(rule)
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
