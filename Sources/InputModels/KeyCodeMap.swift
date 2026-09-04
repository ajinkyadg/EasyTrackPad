import Cocoa

/// Maps macOS virtual keyCodes (ANSI US layout) to human-readable labels,
/// and formats a keyCode + modifier-flags combo as a shortcut string like
/// "⌘⇧K" for display in the rules list and Add Rule sheet.
public enum KeyCodeMap {
    /// Sentinel used by the capture UI to mean "nothing recorded yet".
    /// Real keyCodes are 0...127, so UInt16.max is safe to use as "unset".
    public static let unset: UInt16 = .max

    /// The modifier bits we actually match on (see Keyboard/MouseManager).
    public static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    private static let labels: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
        12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
        16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 117: "Forward Delete",
        53: "Escape", 76: "Enter",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 50: "`"
    ]

    public static func label(forKeyCode keyCode: UInt16) -> String {
        labels[keyCode] ?? "Key #\(keyCode)"
    }

    public static func symbols(forModifiers modifiers: UInt) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    public static func describe(keyCode: UInt16, modifiers: UInt) -> String {
        guard keyCode != unset else { return "Not set" }
        return symbols(forModifiers: modifiers) + label(forKeyCode: keyCode)
    }

    /// A ready-made keyCode+modifiers pair for a shortcut that `KeyCaptureField`'s
    /// "Record" button can't capture by pressing it — macOS's WindowServer
    /// intercepts these (Mission Control, Spaces switching, Spotlight, the
    /// app switcher, screenshots…) and acts on them directly, so the
    /// keypress never reaches any app's event monitor, local or global.
    /// Picking one from the menu here sets the same keyCode/modifiers a
    /// successful recording would have produced.
    public struct PresetShortcut: Identifiable {
        public let name: String
        public let keyCode: UInt16
        public let modifiers: UInt
        public var id: String { name }
    }

    public static let presetShortcuts: [PresetShortcut] = [
        PresetShortcut(name: "Mission Control (⌃↑)", keyCode: 126, modifiers: NSEvent.ModifierFlags.control.rawValue),
        PresetShortcut(name: "Application Windows (⌃↓)", keyCode: 125, modifiers: NSEvent.ModifierFlags.control.rawValue),
        PresetShortcut(name: "Move Left a Space (⌃←)", keyCode: 123, modifiers: NSEvent.ModifierFlags.control.rawValue),
        PresetShortcut(name: "Move Right a Space (⌃→)", keyCode: 124, modifiers: NSEvent.ModifierFlags.control.rawValue),
        PresetShortcut(name: "Show Desktop (F11)", keyCode: 103, modifiers: 0),
        PresetShortcut(name: "Spotlight (⌘Space)", keyCode: 49, modifiers: NSEvent.ModifierFlags.command.rawValue),
        PresetShortcut(name: "App Switcher (⌘Tab)", keyCode: 48, modifiers: NSEvent.ModifierFlags.command.rawValue),
        PresetShortcut(name: "Screenshot: Full Screen (⌘⇧3)", keyCode: 20, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue),
        PresetShortcut(name: "Screenshot: Selection (⌘⇧4)", keyCode: 21, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue),
        PresetShortcut(name: "Screenshot: Options (⌘⇧5)", keyCode: 23, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue),
        PresetShortcut(name: "Lock Screen (⌃⌘Q)", keyCode: 12, modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue)
    ]
}
