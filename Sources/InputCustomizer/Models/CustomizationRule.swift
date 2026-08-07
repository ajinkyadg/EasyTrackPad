import Foundation

/// Which physical device a rule listens on.
enum InputDevice: String, Codable, CaseIterable, Identifiable {
    case keyboard, mouse, trackpad
    var id: String { rawValue }
}

/// The trigger that activates a rule. Kept as a flat, Codable-friendly enum
/// so rules can be saved/loaded/shared as JSON.
enum Trigger: Codable, Hashable {
    case keyCombo(keyCode: UInt16, modifiers: UInt) // keyCode + NSEvent.ModifierFlags rawValue
    case mouseButton(number: Int, modifiers: UInt)
    case trackpadGesture(GestureKind)

    enum GestureKind: String, Codable, CaseIterable {
        case twoFingerSwipeLeft, twoFingerSwipeRight, twoFingerSwipeUp, twoFingerSwipeDown
        case threeFingerSwipeLeft, threeFingerSwipeRight, threeFingerSwipeUp, threeFingerSwipeDown
        case fourFingerSwipeLeft, fourFingerSwipeRight, fourFingerSwipeUp, fourFingerSwipeDown
        case twoFingerTap, threeFingerTap, fourFingerTap, fiveFingerTap
        case pinchIn, pinchOut
        case rotateClockwise, rotateCounterClockwise

        /// Human-readable label for pickers/rule lists, e.g. "3-Finger Swipe Left".
        var displayName: String {
            switch self {
            case .twoFingerSwipeLeft: return "2-Finger Swipe Left"
            case .twoFingerSwipeRight: return "2-Finger Swipe Right"
            case .twoFingerSwipeUp: return "2-Finger Swipe Up"
            case .twoFingerSwipeDown: return "2-Finger Swipe Down"
            case .threeFingerSwipeLeft: return "3-Finger Swipe Left"
            case .threeFingerSwipeRight: return "3-Finger Swipe Right"
            case .threeFingerSwipeUp: return "3-Finger Swipe Up"
            case .threeFingerSwipeDown: return "3-Finger Swipe Down"
            case .fourFingerSwipeLeft: return "4-Finger Swipe Left"
            case .fourFingerSwipeRight: return "4-Finger Swipe Right"
            case .fourFingerSwipeUp: return "4-Finger Swipe Up"
            case .fourFingerSwipeDown: return "4-Finger Swipe Down"
            case .twoFingerTap: return "2-Finger Tap"
            case .threeFingerTap: return "3-Finger Tap"
            case .fourFingerTap: return "4-Finger Tap"
            case .fiveFingerTap: return "5-Finger Tap"
            case .pinchIn: return "Pinch In"
            case .pinchOut: return "Pinch Out"
            case .rotateClockwise: return "Rotate Clockwise"
            case .rotateCounterClockwise: return "Rotate Counter-Clockwise"
            }
        }
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
}

/// A single user-defined customization: "when X happens on device Y, do Z".
struct CustomizationRule: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var device: InputDevice
    var trigger: Trigger
    var action: Action
    var isEnabled: Bool = true
}
