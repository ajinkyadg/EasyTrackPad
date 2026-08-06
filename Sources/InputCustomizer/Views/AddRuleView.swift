import SwiftUI

struct AddRuleView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let device: InputDevice

    @State private var name: String = ""
    @State private var gesture: Trigger.GestureKind = .swipeLeft
    @State private var mouseButtonNumber: Int = 3
    @State private var actionKind: ActionKind = .missionControl
    @State private var shellCommand: String = ""
    @State private var bundleIdentifier: String = ""
    @State private var mediaKey: Action.MediaKey = .playPause

    enum ActionKind: String, CaseIterable, Identifiable {
        case missionControl = "Mission Control"
        case shellCommand = "Run Shell Command"
        case launchApp = "Launch App"
        case mediaKey = "Media Key"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)

            switch device {
            case .trackpad:
                Picker("Gesture", selection: $gesture) {
                    ForEach(Trigger.GestureKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            case .mouse:
                Stepper("Button number: \(mouseButtonNumber)", value: $mouseButtonNumber, in: 0...31)
            case .keyboard:
                Text("Keyboard combo capture — record via a key-press listener (TODO, see README).")
                    .font(.caption).foregroundStyle(.secondary)
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
            case .missionControl:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { addRule() }.keyboardShortcut(.defaultAction)
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
        case .keyboard: trigger = .keyCombo(keyCode: 0, modifiers: 0) // placeholder until capture UI exists
        }

        let action: Action
        switch actionKind {
        case .missionControl: action = .missionControl
        case .shellCommand: action = .runShellCommand(shellCommand)
        case .launchApp: action = .launchApp(bundleIdentifier: bundleIdentifier)
        case .mediaKey: action = .sendMediaKey(mediaKey)
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
