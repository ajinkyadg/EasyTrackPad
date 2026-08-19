import Cocoa
import CoreGraphics
import InputModels

/// Executes the non-remap actions a rule can trigger. Centralized here so
/// keyboard/mouse/trackpad managers stay focused on "what triggered" and
/// don't duplicate "how to run a shell command" logic.
public enum ActionRunner {
    public static func run(command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        try? task.run()
    }

    public static func launch(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            NSLog("InputCustomizer: couldn't find app with bundle id \(bundleIdentifier)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    public static func send(mediaKey: Action.MediaKey) {
        // Media keys require NX_KEYTYPE constants + posting an NSEvent with
        // subtype 8; kept as a stub with the mapping documented so it's
        // easy to fill in without hunting for the constants again.
        let keyMap: [Action.MediaKey: Int32] = [
            .playPause: 16,   // NX_KEYTYPE_PLAY
            .nextTrack: 17,   // NX_KEYTYPE_NEXT
            .previousTrack: 18, // NX_KEYTYPE_PREVIOUS
            .volumeUp: 0,     // NX_KEYTYPE_SOUND_UP
            .volumeDown: 1,   // NX_KEYTYPE_SOUND_DOWN
            .mute: 7          // NX_KEYTYPE_MUTE
        ]
        guard let code = keyMap[mediaKey] else { return }
        postMediaKeyEvent(keyCode: code)
    }

    private static func postMediaKeyEvent(keyCode: Int32) {
        for down in [true, false] {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
            let data1 = (Int(keyCode) << 16) | (down ? 0xa00 : 0xb00)
            if let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) {
                event.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    public static func showMissionControl() {
        run(command: "open -a 'Mission Control'")
    }

    /// Left-hand virtual keycode for each modifier bit `sendKeyPress` can
    /// carry — which physical side doesn't matter, only that a real key
    /// transition happens for it (see `sendKeyPress`'s doc comment).
    private static let modifierKeyCodes: [(flag: CGEventFlags, keyCode: UInt16)] = [
        (.maskCommand, 55),
        (.maskShift, 56),
        (.maskAlternate, 58),
        (.maskControl, 59)
    ]

    /// Posts a synthetic key press (down + up) with the given modifiers,
    /// bracketed by real keyDown/keyUp events for each held modifier key
    /// itself (see `postModifierKeyEvent`) — not just `.flags` set on the
    /// main key's own down/up. Used for "remap to key" actions on devices
    /// other than the keyboard itself (mouse buttons, trackpad gestures),
    /// where there's no intercepted keyboard CGEvent to rewrite in place.
    ///
    /// Setting only `.flags` on the main key event is enough for native
    /// macOS apps — they just read the flags field on whatever event they
    /// receive — but anything that tracks modifier-key state
    /// independently of that isn't guaranteed to see it. Concretely:
    /// remote-desktop clients (e.g. Citrix) that forward keys into a
    /// remote Windows session by watching modifier keys' own real
    /// transitions never see a "Control released" if we only ever set a
    /// flags bit and never post a real Control key event — the remote
    /// session is then left believing Control is still held indefinitely
    /// after our synthetic key passes through (reported symptom: trackpad
    /// scroll starts zooming inside a Citrix session, because the remote
    /// side still thinks Control is down, after a 3-finger-swipe rule
    /// mapped to Control+Arrow).
    public static func sendKeyPress(keyCode: UInt16, modifiers: UInt) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: UInt64(modifiers))

        pressHeldModifiers(for: flags, source: source)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        releaseHeldModifiers(for: flags, source: source)
    }

    /// Posts real keyDown events (not just a flags bit) for every held
    /// modifier in `flags`, meant to bracket a key event posted or passed
    /// through right after — pair with `releaseHeldModifiers` once that's
    /// done. Shared by `sendKeyPress` above and by `KeyboardManager`'s
    /// in-place remap of a real intercepted key, so the modifier-keycode
    /// table and "a real transition, not just a flags bit" reasoning live
    /// in exactly one place — see `sendKeyPress`'s doc comment for why
    /// that distinction matters to consumers like Citrix.
    public static func pressHeldModifiers(for flags: CGEventFlags, source: CGEventSource?) {
        var heldFlags: CGEventFlags = []
        for modifier in modifierKeyCodes where flags.contains(modifier.flag) {
            heldFlags.insert(modifier.flag)
            postModifierKeyEvent(keyCode: modifier.keyCode, keyDown: true, flags: heldFlags, source: source)
        }
    }

    /// Releases whatever `pressHeldModifiers(for: flags, ...)` pressed —
    /// pass the same `flags` value both times.
    public static func releaseHeldModifiers(for flags: CGEventFlags, source: CGEventSource?) {
        var heldFlags = flags
        for modifier in modifierKeyCodes.reversed() where flags.contains(modifier.flag) {
            heldFlags.remove(modifier.flag)
            postModifierKeyEvent(keyCode: modifier.keyCode, keyDown: false, flags: heldFlags, source: source)
        }
    }

    private static func postModifierKeyEvent(keyCode: UInt16, keyDown: Bool, flags: CGEventFlags, source: CGEventSource?) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
