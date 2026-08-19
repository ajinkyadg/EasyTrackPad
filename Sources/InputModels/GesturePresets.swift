import Foundation

/// A one-click starting point for a common rule. Deliberately has no
/// `id` — picking the same preset twice must produce two independent
/// rules, not a shared identity that would confuse `SettingsStore
/// .updateRule`'s find-by-id lookup.
public struct RulePreset: Identifiable {
    public let name: String
    public let device: InputDevice
    public let trigger: Trigger
    public let action: Action
    public var repeatsWhileHeld: Bool = false

    public var id: String { name }

    public init(name: String, device: InputDevice, trigger: Trigger, action: Action, repeatsWhileHeld: Bool = false) {
        self.name = name
        self.device = device
        self.trigger = trigger
        self.action = action
        self.repeatsWhileHeld = repeatsWhileHeld
    }
}

/// A deliberately small, curated set — one well-chosen preset per common
/// need rather than every permutation of finger-count/direction this app
/// could technically recognize. Fewer, well-tested options are easier to
/// read, easier to pick from, and easier to keep working than a
/// kitchen-sink list.
public enum GesturePresets {
    /// `262144` below is both `CGEventFlags.maskControl.rawValue` (what
    /// `ActionRunner.sendKeyPress` actually posts) and
    /// `NSEvent.ModifierFlags.control.rawValue` (what `KeyCodeMap` uses to
    /// display the rule as "⌃") — the two flag systems align numerically
    /// by design. Don't change one without the other.
    private static let controlModifier: UInt = 262144
    /// Control + Shift, same dual-purpose numeric alignment as
    /// `controlModifier` above — Control+Tab / Control+Shift+Tab is the
    /// tab-switching shortcut that works across virtually every tabbed
    /// app (Safari, Chrome, Terminal, Xcode, VS Code), not just browsers.
    private static let controlShiftModifier: UInt = 393_216
    /// Command alone, same dual-purpose numeric alignment as
    /// `controlModifier` above.
    private static let commandModifier: UInt = 1_048_576
    /// Command + Shift, same dual-purpose numeric alignment as
    /// `controlModifier` above.
    private static let commandShiftModifier: UInt = 1_179_648

    public static let all: [RulePreset] = [
        // MARK: Trackpad
        RulePreset(
            name: "Next Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeRight),
            action: .remapToKey(keyCode: 48, modifiers: controlModifier), // Tab + Control
            repeatsWhileHeld: true
        ),
        RulePreset(
            name: "Previous Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .remapToKey(keyCode: 48, modifiers: controlShiftModifier), // Tab + Control + Shift
            repeatsWhileHeld: true
        ),
        RulePreset(
            name: "Mission Control",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeUp),
            action: .missionControl
        ),
        RulePreset(
            name: "Show Desktop",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeDown),
            action: .remapToKey(keyCode: 103, modifiers: 0) // F11 (native Show Desktop key)
        ),
        RulePreset(
            name: "Play/Pause",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerTap),
            action: .sendMediaKey(.playPause)
        ),
        RulePreset(
            name: "New Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerTap),
            action: .remapToKey(keyCode: 17, modifiers: commandModifier) // "T" + Command
        ),
        // A real trackpad has no Force Touch pressure sensor read here
        // (this app doesn't read pressure at all — see MouseCorner), so
        // this stands in for it: an ordinary click, only counted if a
        // finger was resting near the top-right corner of the surface at
        // the time. Button 0 = left click/tap-to-click.
        RulePreset(
            name: "Close Tab (Corner Click)",
            device: .trackpad,
            trigger: .mouseCornerClick(corner: .topRight, number: 0, modifiers: 0),
            action: .remapToKey(keyCode: 13, modifiers: commandModifier) // "W" + Command
        ),
        RulePreset(
            name: "Zoom In",
            device: .trackpad,
            trigger: .trackpadGesture(.pinchOut),
            action: .remapToKey(keyCode: 24, modifiers: commandModifier) // "=" + Command
        ),
        RulePreset(
            name: "Zoom Out",
            device: .trackpad,
            trigger: .trackpadGesture(.pinchIn),
            action: .remapToKey(keyCode: 27, modifiers: commandModifier) // "-" + Command
        ),
        RulePreset(
            name: "Undo",
            device: .trackpad,
            trigger: .trackpadGesture(.rotateCounterClockwise),
            action: .remapToKey(keyCode: 6, modifiers: commandModifier) // "Z" + Command
        ),

        // MARK: Magic Mouse
        // Its touch shell reports raw multitouch frames the same way a
        // trackpad does, so these use the exact same trigger vocabulary a
        // trackpad rule would (see `InputDevice.magicMouse`'s doc
        // comment). All 2-finger — what native macOS itself uses on a
        // Magic Mouse, so this is the hardware-reliable set.
        RulePreset(
            name: "Copy",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerLeftSwipeDown),
            action: .remapToKey(keyCode: 8, modifiers: commandModifier) // "C" + Command
        ),
        RulePreset(
            name: "Paste",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerRightSwipeDown),
            action: .remapToKey(keyCode: 9, modifiers: commandModifier) // "V" + Command
        ),
        RulePreset(
            name: "Previous Tab (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerLeftTap),
            action: .remapToKey(keyCode: 48, modifiers: controlShiftModifier) // Tab + Control + Shift
        ),
        RulePreset(
            name: "Next Tab (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerRightTap),
            action: .remapToKey(keyCode: 48, modifiers: controlModifier) // Tab + Control
        ),
        RulePreset(
            name: "New Tab (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerTap),
            action: .remapToKey(keyCode: 17, modifiers: commandModifier) // "T" + Command
        ),
        RulePreset(
            name: "Close Tab (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerDoubleTap),
            action: .remapToKey(keyCode: 13, modifiers: commandModifier) // "W" + Command
        ),
        RulePreset(
            name: "Mission Control (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeUp),
            action: .missionControl
        ),
        RulePreset(
            name: "Show Desktop (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeDown),
            action: .remapToKey(keyCode: 103, modifiers: 0) // F11
        ),
        RulePreset(
            name: "Reload Page",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerRightSwipeUp),
            action: .remapToKey(keyCode: 15, modifiers: commandModifier) // "R" + Command
        ),
        RulePreset(
            name: "Reopen Closed Tab",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerLeftSwipeUp),
            action: .remapToKey(keyCode: 17, modifiers: commandShiftModifier) // "T" + Command + Shift
        ),

        // MARK: Mouse (side buttons)
        RulePreset(
            name: "Browser Back",
            device: .mouse,
            trigger: .mouseButton(number: 3, modifiers: 0),
            action: .remapToKey(keyCode: 33, modifiers: commandModifier) // "[" + Command
        ),
        RulePreset(
            name: "Browser Forward",
            device: .mouse,
            trigger: .mouseButton(number: 4, modifiers: 0),
            action: .remapToKey(keyCode: 30, modifiers: commandModifier) // "]" + Command
        )
    ]

    public static func presets(for device: InputDevice) -> [RulePreset] {
        all.filter { $0.device == device }
    }
}
