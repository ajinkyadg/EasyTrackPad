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
    public var repeatsByDistance: Bool = false

    public var id: String { name }

    public init(name: String, device: InputDevice, trigger: Trigger, action: Action, repeatsWhileHeld: Bool = false, repeatsByDistance: Bool = false) {
        self.name = name
        self.device = device
        self.trigger = trigger
        self.action = action
        self.repeatsWhileHeld = repeatsWhileHeld
        self.repeatsByDistance = repeatsByDistance
    }

    /// The name a rule created from this preset gets. Preset names carry a
    /// gesture note — "Close Tab (4-Finger Double Tap)" — so the preset
    /// *menu* can tell look-alikes apart; on a saved rule that note just
    /// repeats the trigger line shown under the name, so it's dropped.
    public var ruleName: String { Self.strippingGestureNote(from: name) }

    /// Removes a trailing "(…)" that describes a gesture, click, or device
    /// — not an arbitrary user parenthetical like "(work)".
    public static func strippingGestureNote(from name: String) -> String {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
        let note = name[name.index(after: open)..<name.index(before: name.endIndex)]
        let gestureWords = ["Finger", "Click", "Pinch", "Rotate", "Scroll", "Trackpad", "Magic Mouse"]
        guard gestureWords.contains(where: { note.localizedCaseInsensitiveContains($0) }) else { return name }
        let stripped = name[..<open].trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? name : stripped
    }
}

public enum GesturePresets {
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

    /// Control + Shift, same dual-purpose numeric alignment as
    /// `controlModifier` above — paired with `controlModifier` for
    /// Control+Tab / Control+Shift+Tab, the tab-switching shortcut that
    /// works across virtually every tabbed app (Safari, Chrome, Firefox,
    /// Terminal, Xcode, VS Code), not just browsers.
    private static let controlShiftModifier: UInt = 393_216

    /// Command alone, same dual-purpose numeric alignment as
    /// `controlModifier`/`commandShiftModifier` above.
    private static let commandModifier: UInt = 1_048_576

    /// Control + Command combined, same dual-purpose numeric alignment as
    /// the other modifier constants above.
    private static let controlCommandModifier: UInt = 1_310_720

    public static let all: [RulePreset] = [
        // "Smoogler" — the app's signature gesture: a 3-finger swipe that
        // keeps switching tabs for as long as you keep sliding, firing
        // again per increment of travel rather than on a fixed timer (see
        // CustomizationRule.repeatsByDistance). Featured first so it's
        // the first thing people see in "Add from Preset".
        RulePreset(
            name: "Smoogler: Next Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeRight),
            action: .remapToKey(keyCode: 48, modifiers: controlModifier), // Tab + Control
            repeatsWhileHeld: true,
            repeatsByDistance: true
        ),
        RulePreset(
            name: "Smoogler: Previous Tab",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .remapToKey(keyCode: 48, modifiers: controlShiftModifier), // Tab + Control + Shift
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
            action: .remapToKey(keyCode: 33, modifiers: commandModifier) // "[" + Command
        ),
        RulePreset(
            name: "Browser Forward",
            device: .mouse,
            trigger: .mouseButton(number: 4, modifiers: 0),
            action: .remapToKey(keyCode: 30, modifiers: commandModifier) // "]" + Command
        ),

        // A trackpad corner click: one finger lands in the top-right
        // corner and clicks straight away (see resolveCornerClick). The
        // click itself is swallowed, so nothing under the pointer is
        // clicked. Button 0 = the primary click.
        RulePreset(
            name: "Close Tab (Top-Right Trackpad Corner Click)",
            device: .trackpad,
            trigger: .mouseCornerClick(corner: .topRight, number: 0, modifiers: 0),
            action: .remapToKey(keyCode: 13, modifiers: commandModifier) // "W" + Command
        ),

        // More trackpad presets, filling out the same kind of coverage
        // the Magic Mouse set below has. Deliberately 3/4/5-finger and
        // pinch/rotate only, never 2-finger — a trackpad's 2-finger
        // gesture is scroll (read continuously by macOS itself off the
        // same raw touch data this app also reads), so a discrete
        // "2-finger swipe" rule here would fire *alongside* whatever
        // scrolled underneath it rather than replacing it. Magic Mouse
        // doesn't have that conflict the same way, which is why its own
        // preset set below leans on 2-finger gestures instead. Pinch/
        // rotate are trackpad-exclusive — Magic Mouse's shell has no
        // OS-level pinch/rotate gesture at all.
        RulePreset(
            name: "Full Screen Toggle (3-Finger Swipe Up, Trackpad)",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeUp),
            action: .remapToKey(keyCode: 3, modifiers: controlCommandModifier) // "F" + Control + Command
        ),
        RulePreset(
            name: "Show Desktop (3-Finger Swipe Down)",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeDown),
            action: .remapToKey(keyCode: 103, modifiers: 0) // F11 (native Show Desktop key)
        ),
        RulePreset(
            name: "Volume Up (3-Finger Swipe Down-Right)",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeDownRight),
            action: .sendMediaKey(.volumeUp)
        ),
        RulePreset(
            name: "Volume Down (3-Finger Swipe Down-Left)",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeDownLeft),
            action: .sendMediaKey(.volumeDown)
        ),
        RulePreset(
            name: "Screenshot Selection (3-Finger Double Tap, Trackpad)",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerDoubleTap),
            action: .remapToKey(keyCode: 21, modifiers: commandShiftModifier) // "4" + Command + Shift
        ),
        RulePreset(
            name: "Switch Window Forward (4-Finger Swipe Left)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeLeft),
            action: .remapToKey(keyCode: 50, modifiers: commandModifier) // "`" + Command
        ),
        RulePreset(
            name: "Switch Window Backward (4-Finger Swipe Right)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeRight),
            action: .remapToKey(keyCode: 50, modifiers: commandShiftModifier) // "`" + Command + Shift
        ),
        RulePreset(
            name: "Minimize Window (4-Finger Swipe Down)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeDown),
            action: .remapToKey(keyCode: 46, modifiers: commandModifier) // "M" + Command
        ),
        RulePreset(
            name: "New Tab (4-Finger Tap)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerTap),
            action: .remapToKey(keyCode: 17, modifiers: commandModifier) // "T" + Command
        ),
        RulePreset(
            name: "Close Tab (4-Finger Double Tap)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerDoubleTap),
            action: .remapToKey(keyCode: 13, modifiers: commandModifier) // "W" + Command
        ),
        RulePreset(
            name: "Reopen Closed Tab (4-Finger Swipe Up-Left)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeUpLeft),
            action: .remapToKey(keyCode: 17, modifiers: commandShiftModifier) // "T" + Command + Shift
        ),
        RulePreset(
            name: "Reload Page (4-Finger Swipe Up-Right)",
            device: .trackpad,
            trigger: .trackpadGesture(.fourFingerSwipeUpRight),
            action: .remapToKey(keyCode: 15, modifiers: commandModifier) // "R" + Command
        ),
        RulePreset(
            name: "Lock Screen (5-Finger Swipe Up)",
            device: .trackpad,
            trigger: .trackpadGesture(.fiveFingerSwipeUp),
            action: .remapToKey(keyCode: 12, modifiers: controlCommandModifier) // "Q" + Control + Command
        ),
        RulePreset(
            name: "Copy (5-Finger Tap)",
            device: .trackpad,
            trigger: .trackpadGesture(.fiveFingerTap),
            action: .remapToKey(keyCode: 8, modifiers: commandModifier) // "C" + Command
        ),
        RulePreset(
            name: "Paste (5-Finger Double Tap)",
            device: .trackpad,
            trigger: .trackpadGesture(.fiveFingerDoubleTap),
            action: .remapToKey(keyCode: 9, modifiers: commandModifier) // "V" + Command
        ),
        // Pinch = zoom is the obvious physical metaphor; rotate = undo/
        // redo is a deliberate reinterpretation (nothing about rotating
        // two fingers "means" undo) but a memorable, discoverable pairing
        // — same spirit as this app's other creative gesture reuse.
        RulePreset(
            name: "Zoom In (Pinch Out)",
            device: .trackpad,
            trigger: .trackpadGesture(.pinchOut),
            action: .remapToKey(keyCode: 24, modifiers: commandModifier) // "=" + Command
        ),
        RulePreset(
            name: "Zoom Out (Pinch In)",
            device: .trackpad,
            trigger: .trackpadGesture(.pinchIn),
            action: .remapToKey(keyCode: 27, modifiers: commandModifier) // "-" + Command
        ),
        RulePreset(
            name: "Redo (Rotate Clockwise)",
            device: .trackpad,
            trigger: .trackpadGesture(.rotateClockwise),
            action: .remapToKey(keyCode: 6, modifiers: commandShiftModifier) // "Z" + Command + Shift
        ),
        RulePreset(
            name: "Undo (Rotate Counter-Clockwise)",
            device: .trackpad,
            trigger: .trackpadGesture(.rotateCounterClockwise),
            action: .remapToKey(keyCode: 6, modifiers: commandModifier) // "Z" + Command
        ),
        // The other top corner. Bottom corners are deliberately absent:
        // the bottom edge is where ordinary clicks land, and it's where
        // macOS's own "secondary click in corner" setting lives.
        RulePreset(
            name: "Mute (Top-Left Trackpad Corner Click)",
            device: .trackpad,
            trigger: .mouseCornerClick(corner: .topLeft, number: 0, modifiers: 0),
            action: .sendMediaKey(.mute)
        ),
        // Fires mid-scroll (not on lift, like every other preset here) —
        // see GestureKind.twoFingerFastScrollToBottomEdge's doc comment.
        // Cmd+Down jumps to the bottom in most text editors, browsers, and
        // document viewers, though not universally — some apps have their
        // own "end of document" shortcut instead.
        RulePreset(
            name: "Jump to End of Page (Fast Scroll to Bottom Edge)",
            device: .trackpad,
            trigger: .trackpadGesture(.twoFingerFastScrollToBottomEdge),
            action: .remapToKey(keyCode: 125, modifiers: commandModifier) // Down Arrow + Command
        ),

        // Magic Mouse gestures — its touch shell reports raw multitouch
        // frames the same way a trackpad does, so these use the exact
        // same trigger vocabulary a trackpad rule would (see
        // `InputDevice.magicMouse`'s doc comment). "Left"/"Right" is
        // whichever finger sits on that side when the pair first touches
        // down. The 16 "core" presets below use every distinct 2-finger
        // gesture this app can recognize exactly once — 2 fingers is what
        // native macOS itself uses on a Magic Mouse, so this is the
        // hardware-reliable set. The "extended" 10 use 3-finger gestures
        // instead; those are genuinely less certain on a Magic Mouse's
        // small curved shell (3+ simultaneous fingers there isn't
        // something the OS's own Magic Mouse gestures ever ask for) —
        // included at the user's request, but some may not register
        // reliably depending on the physical hardware.
        RulePreset(
            name: "Copy (2-Finger Left Swipe Down)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerLeftSwipeDown),
            action: .remapToKey(keyCode: 8, modifiers: commandModifier) // "C" + Command
        ),
        RulePreset(
            name: "Paste (2-Finger Right Swipe Down)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerRightSwipeDown),
            action: .remapToKey(keyCode: 9, modifiers: commandModifier) // "V" + Command
        ),
        RulePreset(
            name: "Previous Tab (2-Finger Left Tap)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerLeftTap),
            action: .remapToKey(keyCode: 48, modifiers: controlShiftModifier) // Tab + Control + Shift
        ),
        RulePreset(
            name: "Next Tab (2-Finger Right Tap)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerRightTap),
            action: .remapToKey(keyCode: 48, modifiers: controlModifier) // Tab + Control
        ),
        RulePreset(
            name: "New Tab (2-Finger Tap)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerTap),
            action: .remapToKey(keyCode: 17, modifiers: commandModifier) // "T" + Command
        ),
        RulePreset(
            name: "Close Tab (2-Finger Double Tap)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerDoubleTap),
            action: .remapToKey(keyCode: 13, modifiers: commandModifier) // "W" + Command
        ),
        RulePreset(
            name: "Reopen Closed Tab (2-Finger Left Swipe Up)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerLeftSwipeUp),
            action: .remapToKey(keyCode: 17, modifiers: commandShiftModifier) // "T" + Command + Shift
        ),
        RulePreset(
            name: "Reload Page (2-Finger Right Swipe Up)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerRightSwipeUp),
            action: .remapToKey(keyCode: 15, modifiers: commandModifier) // "R" + Command
        ),
        RulePreset(
            name: "Smoogler: Next Tab (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeRight),
            action: .remapToKey(keyCode: 30, modifiers: commandShiftModifier), // "]" + Command + Shift
            repeatsWhileHeld: true,
            repeatsByDistance: true
        ),
        RulePreset(
            name: "Smoogler: Previous Tab (Magic Mouse)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeLeft),
            action: .remapToKey(keyCode: 33, modifiers: commandShiftModifier), // "[" + Command + Shift
            repeatsWhileHeld: true,
            repeatsByDistance: true
        ),
        RulePreset(
            name: "Mission Control (2-Finger Swipe Up)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeUp),
            action: .missionControl
        ),
        RulePreset(
            name: "Show Desktop (2-Finger Swipe Down)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeDown),
            action: .remapToKey(keyCode: 103, modifiers: 0) // F11 (native Show Desktop key)
        ),
        RulePreset(
            name: "Previous Space (2-Finger Swipe Up-Left)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeUpLeft),
            action: .remapToKey(keyCode: 123, modifiers: controlModifier) // Left Arrow + Control
        ),
        RulePreset(
            name: "Next Space (2-Finger Swipe Up-Right)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeUpRight),
            action: .remapToKey(keyCode: 124, modifiers: controlModifier) // Right Arrow + Control
        ),
        RulePreset(
            name: "Volume Up (2-Finger Swipe Down-Right)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeDownRight),
            action: .sendMediaKey(.volumeUp)
        ),
        RulePreset(
            name: "Volume Down (2-Finger Swipe Down-Left)",
            device: .magicMouse,
            trigger: .trackpadGesture(.twoFingerSwipeDownLeft),
            action: .sendMediaKey(.volumeDown)
        ),

        // Extended, 3-finger — see the note above the core set.
        RulePreset(
            name: "Full Screen Toggle (3-Finger Swipe Up)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeUp),
            action: .remapToKey(keyCode: 3, modifiers: controlCommandModifier) // "F" + Control + Command
        ),
        RulePreset(
            name: "Minimize Window (3-Finger Swipe Down)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeDown),
            action: .remapToKey(keyCode: 46, modifiers: commandModifier) // "M" + Command
        ),
        RulePreset(
            name: "Switch Window Forward (3-Finger Swipe Left)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .remapToKey(keyCode: 50, modifiers: commandModifier) // "`" + Command
        ),
        RulePreset(
            name: "Switch Window Backward (3-Finger Swipe Right)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeRight),
            action: .remapToKey(keyCode: 50, modifiers: commandShiftModifier) // "`" + Command + Shift
        ),
        RulePreset(
            name: "Previous Space (3-Finger Swipe Up-Left)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeUpLeft),
            action: .remapToKey(keyCode: 123, modifiers: controlModifier) // Left Arrow + Control
        ),
        RulePreset(
            name: "Next Space (3-Finger Swipe Up-Right)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeUpRight),
            action: .remapToKey(keyCode: 124, modifiers: controlModifier) // Right Arrow + Control
        ),
        RulePreset(
            name: "Zoom In (3-Finger Swipe Down-Right)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeDownRight),
            action: .remapToKey(keyCode: 24, modifiers: commandModifier) // "=" + Command
        ),
        RulePreset(
            name: "Zoom Out (3-Finger Swipe Down-Left)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerSwipeDownLeft),
            action: .remapToKey(keyCode: 27, modifiers: commandModifier) // "-" + Command
        ),
        RulePreset(
            name: "Lock Screen (3-Finger Tap)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerTap),
            action: .remapToKey(keyCode: 12, modifiers: controlCommandModifier) // "Q" + Control + Command
        ),
        RulePreset(
            name: "Screenshot Selection (3-Finger Double Tap)",
            device: .magicMouse,
            trigger: .trackpadGesture(.threeFingerDoubleTap),
            action: .remapToKey(keyCode: 21, modifiers: commandShiftModifier) // "4" + Command + Shift
        )
    ]

    public static func presets(for device: InputDevice) -> [RulePreset] {
        all.filter { $0.device == device }
    }
}
