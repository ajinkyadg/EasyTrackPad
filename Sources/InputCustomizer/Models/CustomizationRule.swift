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
        case swipeLeft, swipeRight, swipeUp, swipeDown
        case pinchIn, pinchOut
        case rotateClockwise, rotateCounterClockwise
        case threeFingerTap, fourFingerTap
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
