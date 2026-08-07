import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var selectedDevice: InputDevice = .trackpad

    var body: some View {
        VStack(spacing: 0) {
            Toggle("Pause all rules", isOn: $settingsStore.isPaused)
                .padding([.horizontal, .top])

            TabView(selection: $selectedDevice) {
                RuleListView(device: .trackpad)
                    .tabItem { Label("Trackpad", systemImage: "hand.draw") }
                    .tag(InputDevice.trackpad)

                RuleListView(device: .mouse)
                    .tabItem { Label("Mouse", systemImage: "computermouse") }
                    .tag(InputDevice.mouse)

                RuleListView(device: .keyboard)
                    .tabItem { Label("Keyboard", systemImage: "keyboard") }
                    .tag(InputDevice.keyboard)
            }
        }
        .frame(width: 520, height: 420)
        .environmentObject(settingsStore)
    }
}

struct RuleListView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    let device: InputDevice
    @State private var showingAddSheet = false

    private var rulesForDevice: [CustomizationRule] {
        settingsStore.rules.filter { $0.device == device }
    }

    var body: some View {
        VStack {
            if device == .trackpad {
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
            }
            List {
                ForEach(rulesForDevice) { rule in
                    HStack {
                        Toggle("", isOn: bindingForEnabled(rule))
                            .labelsHidden()
                        VStack(alignment: .leading) {
                            Text(rule.name).bold()
                            Text(describe(rule.trigger)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settingsStore.removeRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                .padding()
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddRuleView(device: device)
                .environmentObject(settingsStore)
        }
    }

    private func bindingForEnabled(_ rule: CustomizationRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { newValue in
                if let idx = settingsStore.rules.firstIndex(where: { $0.id == rule.id }) {
                    settingsStore.rules[idx].isEnabled = newValue
                }
            }
        )
    }

    private func describe(_ trigger: Trigger) -> String {
        switch trigger {
        case let .keyCombo(keyCode, modifiers): return KeyCodeMap.describe(keyCode: keyCode, modifiers: modifiers)
        case let .mouseButton(number, _): return "Button \(number)"
        case let .trackpadGesture(kind): return kind.displayName
        }
    }
}
