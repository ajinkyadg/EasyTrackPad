import Foundation

/// Which physical device a rule listens on.
enum InputDevice: String, Codable, CaseIterable, Identifiable {
    case keyboard, mouse, trackpad
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .trackpad: return "Trackpad"
        }
    }

    var iconSymbolName: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "hand.draw"
        }
    }
}

/// The trigger that activates a rule. Kept as a flat, Codable-friendly enum
/// so rules can be saved/loaded/shared as JSON.
enum Trigger: Codable, Hashable {
    case keyCombo(keyCode: UInt16, modifiers: UInt) // keyCode + NSEvent.ModifierFlags rawValue
    case mouseButton(number: Int, modifiers: UInt)
    case trackpadGesture(GestureKind)

    enum GestureKind: String, Codable, CaseIterable {
        case twoFingerSwipeLeft, twoFingerSwipeRight, twoFingerSwipeUp, twoFingerSwipeDown
        case twoFingerSwipeUpLeft, twoFingerSwipeUpRight, twoFingerSwipeDownLeft, twoFingerSwipeDownRight
        case threeFingerSwipeLeft, threeFingerSwipeRight, threeFingerSwipeUp, threeFingerSwipeDown
        case threeFingerSwipeUpLeft, threeFingerSwipeUpRight, threeFingerSwipeDownLeft, threeFingerSwipeDownRight
        case fourFingerSwipeLeft, fourFingerSwipeRight, fourFingerSwipeUp, fourFingerSwipeDown
        case fourFingerSwipeUpLeft, fourFingerSwipeUpRight, fourFingerSwipeDownLeft, fourFingerSwipeDownRight
        case fiveFingerSwipeLeft, fiveFingerSwipeRight, fiveFingerSwipeUp, fiveFingerSwipeDown
        case fiveFingerSwipeUpLeft, fiveFingerSwipeUpRight, fiveFingerSwipeDownLeft, fiveFingerSwipeDownRight
        case twoFingerTap, threeFingerTap, fourFingerTap, fiveFingerTap
        case twoFingerDoubleTap, threeFingerDoubleTap, fourFingerDoubleTap, fiveFingerDoubleTap
        case pinchIn, pinchOut
        case rotateClockwise, rotateCounterClockwise
        /// Two fingers down, only one of them actually swipes up/down
        /// while the other stays put as an anchor — distinct from
        /// `twoFingerSwipeUp`/`Down`, where both fingers travel together.
        /// "Left"/"Right" is whichever finger is on that side (by x
        /// position) at touch-down, not a specific physical finger.
        case twoFingerLeftSwipeUp, twoFingerLeftSwipeDown
        case twoFingerRightSwipeUp, twoFingerRightSwipeDown

        /// camelCase raw value split on uppercase boundaries, e.g.
        /// "threeFingerSwipeUpLeft" -> ["three","Finger","Swipe","Up","Left"].
        private var rawValueWords: [String] {
            var words: [String] = []
            var current = ""
            for char in rawValue {
                if char.isUppercase, !current.isEmpty {
                    words.append(current)
                    current = String(char)
                } else {
                    current.append(char)
                }
            }
            if !current.isEmpty { words.append(current) }
            return words
        }

        private static let fingerCountNumbers: [String: Int] = ["two": 2, "three": 3, "four": 4, "five": 5]
        private static let directionDegrees: [String: Double] = [
            "Right": 0, "UpRight": 45, "Up": 90, "UpLeft": 135,
            "Left": 180, "DownLeft": 225, "Down": 270, "DownRight": 315
        ]

        /// Coarse gesture family — what `GestureGlyphView` needs to decide
        /// *how* to draw the icon (dots + arrow vs. dots only vs. a pinch/
        /// rotate symbol), independent of finger count or direction.
        enum Category {
            case swipe, splitSwipe, tap, doubleTap, pinchIn, pinchOut, rotateClockwise, rotateCounterClockwise
        }

        private static let splitSwipeCases: Set<GestureKind> = [
            .twoFingerLeftSwipeUp, .twoFingerLeftSwipeDown, .twoFingerRightSwipeUp, .twoFingerRightSwipeDown
        ]

        var category: Category {
            switch self {
            case .pinchIn: return .pinchIn
            case .pinchOut: return .pinchOut
            case .rotateClockwise: return .rotateClockwise
            case .rotateCounterClockwise: return .rotateCounterClockwise
            default:
                if Self.splitSwipeCases.contains(self) { return .splitSwipe }
                if isDoubleTap { return .doubleTap }
                let words = rawValueWords
                if words.count >= 3, words[2] == "Tap" { return .tap }
                return .swipe
            }
        }

        /// For `.splitSwipe` kinds only: which finger (by left/right
        /// position at touch-down) is the one that actually moves, while
        /// the other stays down as an anchor. `nil` for every other
        /// category.
        var splitSwipeMovingFingerIsLeft: Bool? {
            switch self {
            case .twoFingerLeftSwipeUp, .twoFingerLeftSwipeDown: return true
            case .twoFingerRightSwipeUp, .twoFingerRightSwipeDown: return false
            default: return nil
            }
        }

        /// Direction of travel in degrees (0 = right, 90 = up, going
        /// counterclockwise) — matches `GestureRecognizer`'s `atan2(dy,
        /// dx)` convention exactly, so the drawn arrow points the same way
        /// the recognizer actually measures it. `nil` for non-swipe kinds.
        var swipeAngleDegrees: Double? {
            switch self {
            case .twoFingerLeftSwipeUp, .twoFingerRightSwipeUp: return 90
            case .twoFingerLeftSwipeDown, .twoFingerRightSwipeDown: return 270
            default: break
            }
            guard category == .swipe else { return nil }
            let words = rawValueWords
            guard words.count >= 4 else { return nil }
            return Self.directionDegrees[words[3...].joined()]
        }

        /// 2...5 for swipe/tap/double-tap cases; nil for pinch/rotate, which
        /// are implicitly two-finger and don't need a UI badge for it.
        var fingerCount: Int? {
            guard let first = rawValueWords.first else { return nil }
            return Self.fingerCountNumbers[first]
        }

        var isDoubleTap: Bool {
            let words = rawValueWords
            return words.count >= 4 && words[2] == "Double" && words[3] == "Tap"
        }

        /// Human-readable label for pickers/rule lists, e.g. "3-Finger Swipe
        /// Up-Left" or "4-Finger Double Tap". Detects the gesture *kind*
        /// (Swipe/Tap/DoubleTap) explicitly rather than positionally —
        /// DoubleTap splits into two camelCase words ("Double","Tap"), not
        /// one, so a purely positional scheme misparses it.
        var displayName: String {
            switch self {
            case .pinchIn: return "Pinch In"
            case .pinchOut: return "Pinch Out"
            case .rotateClockwise: return "Rotate Clockwise"
            case .rotateCounterClockwise: return "Rotate Counter-Clockwise"
            case .twoFingerLeftSwipeUp: return "2-Finger, Left Swipes Up"
            case .twoFingerLeftSwipeDown: return "2-Finger, Left Swipes Down"
            case .twoFingerRightSwipeUp: return "2-Finger, Right Swipes Up"
            case .twoFingerRightSwipeDown: return "2-Finger, Right Swipes Down"
            default: break
            }
            let words = rawValueWords
            guard let count = fingerCount else { return rawValue }
            if isDoubleTap { return "\(count)-Finger Double Tap" }
            if words.count >= 3, words[2] == "Tap" { return "\(count)-Finger Tap" }
            if words.count >= 4, words[2] == "Swipe" {
                return "\(count)-Finger Swipe \(words[3...].joined(separator: "-"))"
            }
            return rawValue
        }

        /// SF Symbol name for `GestureIconView`. Swipe directions map to
        /// the matching `arrow.*` symbol (e.g. "UpLeft" -> "arrow.up.left");
        /// tap/double-tap share `hand.tap.fill` (already used for the
        /// paused menu-bar icon in App.swift, so it's proven to render).
        var iconSymbolName: String {
            switch self {
            case .pinchIn: return "minus.magnifyingglass"
            case .pinchOut: return "plus.magnifyingglass"
            case .rotateClockwise: return "arrow.clockwise"
            case .rotateCounterClockwise: return "arrow.counterclockwise"
            case .twoFingerLeftSwipeUp, .twoFingerRightSwipeUp: return "arrow.up"
            case .twoFingerLeftSwipeDown, .twoFingerRightSwipeDown: return "arrow.down"
            default: break
            }
            let words = rawValueWords
            if words.count >= 3, words[2] == "Tap" || isDoubleTap { return "hand.tap.fill" }
            if words.count >= 4, words[2] == "Swipe" {
                let direction = words[3...].joined(separator: ".").lowercased()
                return "arrow.\(direction)"
            }
            return "questionmark"
        }
    }
}

extension Trigger {
    /// "Repeat while held" only makes sense for a swipe (or the
    /// anchor+mover `.splitSwipe`, which fires mid-touch the same way) —
    /// see GestureRecognizer.process(): a swipe fires mid-touch with a
    /// real "still held" state after it, while a tap only recognizes once
    /// fingers have *already* fully lifted (nothing left to hold), and
    /// pinch/rotate never go through GestureRecognizer/onTouchEnded at
    /// all. Centralized here so RuleFormView and TrackpadManager can't
    /// independently drift out of sync on which triggers this applies to.
    var supportsRepeatWhileHeld: Bool {
        if case let .trackpadGesture(kind) = self { return kind.category == .swipe || kind.category == .splitSwipe }
        return false
    }

    /// "Repeat by distance" (re-fire per additional travel instead of on
    /// a timer, like a scroll wheel) is scoped to ordinary swipes only,
    /// not `.splitSwipe` — `GestureRecognizer` only tracks a
    /// distance-repeat baseline off the shared centroid, the same
    /// measurement `.swipe` itself uses. `.splitSwipe` measures via
    /// per-finger `splitReferences` instead, which would need its own
    /// separate per-mover-finger baseline to support ticking — not
    /// implemented.
    var supportsRepeatByDistance: Bool {
        if case let .trackpadGesture(kind) = self { return kind.category == .swipe }
        return false
    }
}

/// The resulting action a rule performs.
enum Action: Codable, Hashable {
    case remapToKey(keyCode: UInt16, modifiers: UInt)
    case runShellCommand(String)
    case launchApp(bundleIdentifier: String)
    case sendMediaKey(MediaKey)
    case missionControl
    case none

    enum MediaKey: String, Codable, CaseIterable {
        case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    }

    /// Short human-readable summary for the live activity console
    /// (`ActivityLog`) — not meant for the rule list UI, which already
    /// shows the trigger; this labels what's actually executing.
    var shortDescription: String {
        switch self {
        case let .remapToKey(keyCode, modifiers): return KeyCodeMap.describe(keyCode: keyCode, modifiers: modifiers)
        case let .runShellCommand(command): return "Shell: \(command)"
        case let .launchApp(bundleIdentifier): return "Launch \(bundleIdentifier)"
        case let .sendMediaKey(key): return key.rawValue
        case .missionControl: return "Mission Control"
        case .none: return "No action"
        }
    }
}

/// A specific installed app, identified by bundle identifier (the stable
/// key used for matching) with a cached display name so UI rows don't
/// need to re-resolve it — and still show something sensible if the app
/// is later moved or removed.
struct AppReference: Codable, Hashable, Identifiable {
    var bundleIdentifier: String
    var displayName: String
    var id: String { bundleIdentifier }
}

/// A single user-defined customization: "when X happens on device Y, do Z".
struct CustomizationRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var device: InputDevice
    var trigger: Trigger
    var action: Action
    var isEnabled: Bool = true
    /// Trackpad swipes only: keep re-applying `action` for as long as the
    /// swiping fingers stay down, instead of firing once. Useful for
    /// things like "swipe-and-hold to keep switching tabs". Defaults to
    /// false so existing saved rules (and non-swipe triggers) are
    /// unaffected — Swift's Codable synthesis falls back to a property's
    /// default when the key is missing from older JSON.
    var repeatsWhileHeld: Bool = false
    /// Only meaningful when `repeatsWhileHeld` is true: re-fires per
    /// additional distance the swiping fingers travel (like a scroll
    /// wheel — slide further/faster to fire more often) instead of on a
    /// fixed timer. See `SettingsStore.repeatByDistanceSensitivity` for
    /// how much travel counts as "one more fire". Defaults to false,
    /// keeping the original fixed-timer behavior.
    var repeatsByDistance: Bool = false
    /// Empty (default) means the rule applies everywhere. Non-empty scopes
    /// it to only fire while one of these apps is frontmost — e.g. a
    /// browser-only tab-switching gesture that doesn't also fire in
    /// Finder. Defaults to empty so existing saved rules are unaffected.
    var restrictedToApps: [AppReference] = []

    /// `currentBundleIdentifier` is passed in rather than queried here so
    /// this stays pure and unit-testable — see `ActiveApp` for the real
    /// `NSWorkspace` query used at runtime.
    func applies(whileFrontmostAppIs currentBundleIdentifier: String?) -> Bool {
        guard !restrictedToApps.isEmpty else { return true }
        // Fail open: an unknown frontmost app shouldn't silently disable
        // every app-scoped rule.
        guard let currentBundleIdentifier else { return true }
        return restrictedToApps.contains { $0.bundleIdentifier == currentBundleIdentifier }
    }
}
