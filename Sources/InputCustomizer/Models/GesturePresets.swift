import Foundation

/// A one-click starting point for a common rule. Deliberately has no
/// `id` — picking the same preset twice must produce two independent
/// rules, not a shared identity that would confuse `SettingsStore
/// .updateRule`'s find-by-id lookup.
struct RulePreset: Identifiable {
    let name: String
    let device: InputDevice
    let trigger: Trigger
    let action: Action
    var repeatsWhileHeld: Bool = false
    var repeatsByDistance: Bool = false

    var id: String { name }
}

enum GesturePresets {
    /// `262144` below is both `CGEventFlags.maskControl.rawValue` (what
    /// `ActionRunner.sendKeyPress` actually posts) and
    /// `NSEvent.ModifierFlags.control.rawValue` (what `KeyCodeMap` uses to
    /// display the rule as "⌃") — the two flag systems align numerically
    /// by design. Don't change one without the other.
    private static let controlModifier: UInt = 262144

    /// Command + Shift, as both `CGEventFlags` and `NSEvent.ModifierFlags`
    /// raw values — see `controlModifier`'s comment above for why the two
    /// flag systems align numerically. Cmd+Shift+[ / Cmd+Shift+] is the
    /// cross-browser (Safari/Chrome/Firefox) previous/next-tab shortcut.
    private static let commandShiftModifier: UInt = 1_179_648

    static let all: [RulePreset] = [
        // "Smoogler" — the app's signature gesture: a 3-finger swipe that
        // keeps switching tabs for as long as you keep sliding, firing
        // again per increment of travel rather than on a fixed timer (see
        // CustomizationRule.repeatsByDistance). Featured first so it's
        // the first thing people see in "Add from Preset".
        RulePreset(
            name: "Smoogler: Next Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeRight),
            action: .remapToKey(keyCode: 30, modifiers: commandShiftModifier), // "]" + Command + Shift
            repeatsWhileHeld: true,
            repeatsByDistance: true
        ),
        RulePreset(
            name: "Smoogler: Previous Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .remapToKey(keyCode: 33, modifiers: commandShiftModifier), // "[" + Command + Shift
            repeatsWhileHeld: true,
            repeatsByDistance: true
        ),
        RulePreset(
            name: "Mission Control",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeUp),
            action: .missionControl
        ),
        RulePreset(
            name: "Previous Space",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .remapToKey(keyCode: 123, modifiers: controlModifier) // Left Arrow + Control
        ),
        RulePreset(
            name: "Next Space",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeRight),
            action: .remapToKey(keyCode: 124, modifiers: controlModifier) // Right Arrow + Control
        ),
        RulePreset(
            name: "Play/Pause",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerTap),
            action: .sendMediaKey(.playPause)
        ),
        RulePreset(
            name: "Browser Back",
            device: .mouse,
            trigger: .mouseButton(number: 3, modifiers: 0),
            action: .remapToKey(keyCode: 33, modifiers: 1_048_576) // "[" + Command
        ),
        RulePreset(
            name: "Browser Forward",
            device: .mouse,
            trigger: .mouseButton(number: 4, modifiers: 0),
            action: .remapToKey(keyCode: 30, modifiers: 1_048_576) // "]" + Command
        )
    ]

    static func presets(for device: InputDevice) -> [RulePreset] {
        all.filter { $0.device == device }
    }
}
