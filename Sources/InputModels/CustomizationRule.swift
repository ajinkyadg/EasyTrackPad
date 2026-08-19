import Foundation
import GestureEngine

/// Which physical device a rule listens on. `.magicMouse` is organizational,
/// not a separate detection mechanism — a Magic Mouse's shell reports raw
/// multitouch frames through the exact same `GestureRecognizer` pipeline a
/// trackpad does (see `TrackpadManager`), and its physical click still goes
/// through the same `CGEventTap` a plain mouse's does (see `MouseManager`).
/// Splitting it out just keeps Magic-Mouse-flavored rules (the split-swipe/
/// split-tap gestures its touch shell enables, plus corner-gated clicks)
/// organized in their own tab instead of mixed into "Trackpad"/"Mouse".
///
/// `.trackpad` and `.magicMouse` are read *simultaneously* — `TrackpadManager`
/// runs one `MultitouchGestureEngine` per device, each bound directly to
/// its own IOService via `MTDeviceCreateFromService`.
public enum InputDevice: String, Codable, CaseIterable, Identifiable {
    case keyboard, mouse, magicMouse, trackpad
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .magicMouse: return "Magic Mouse"
        case .trackpad: return "Trackpad"
        }
    }

    public var iconSymbolName: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .magicMouse: return "magicmouse.fill"
        case .trackpad: return "hand.draw"
        }
    }
}

/// The trigger that activates a rule. Kept as a flat, Codable-friendly enum
/// so rules can be saved/loaded/shared as JSON.
public enum Trigger: Codable, Hashable {
    /// The vocabulary of recognizable trackpad/Magic-Mouse gestures lives
    /// in the lower-level `GestureEngine` module (it's the module that
    /// actually produces these values) — re-exposed here under its
    /// original name so every existing `Trigger.GestureKind` call site
    /// keeps working unchanged.
    public typealias GestureKind = GestureEngine.GestureKind

    case keyCombo(keyCode: UInt16, modifiers: UInt) // keyCode + NSEvent.ModifierFlags rawValue
    case mouseButton(number: Int, modifiers: UInt)
    /// An ordinary mouse click, but only counted if a finger was resting
    /// near `corner` on the touch surface at the moment it happened — see
    /// `MouseCorner`. `number`/`modifiers` mean the same thing as
    /// `mouseButton`'s.
    case mouseCornerClick(corner: MouseCorner, number: Int, modifiers: UInt)
    case trackpadGesture(GestureKind)
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
    public var supportsRepeatWhileHeld: Bool {
        if case let .trackpadGesture(kind) = self { return kind.category == .swipe || kind.category == .splitSwipe }
        return false
    }
}

/// The resulting action a rule performs.
public enum Action: Codable, Hashable {
    case remapToKey(keyCode: UInt16, modifiers: UInt)
    case runShellCommand(String)
    case launchApp(bundleIdentifier: String)
    case sendMediaKey(MediaKey)
    case missionControl
    case none

    public enum MediaKey: String, Codable, CaseIterable {
        case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    }

    /// Short human-readable summary for the live activity console
    /// (`ActivityLog`) — not meant for the rule list UI, which already
    /// shows the trigger; this labels what's actually executing.
    public var shortDescription: String {
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
public struct AppReference: Codable, Hashable, Identifiable {
    public var bundleIdentifier: String
    public var displayName: String
    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// A single user-defined customization: "when X happens on device Y, do Z".
public struct CustomizationRule: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    public var device: InputDevice
    public var trigger: Trigger
    public var action: Action
    public var isEnabled: Bool = true
    /// Trackpad swipes only: keep re-applying `action` on a fixed timer
    /// (see `SettingsStore.repeatWhileHeldInterval`/`repeatWhileHeldDelay`)
    /// for as long as the swiping fingers stay down, instead of firing
    /// once. Useful for things like "swipe-and-hold to keep switching
    /// tabs". Defaults to false so existing saved rules (and non-swipe
    /// triggers) are unaffected — Swift's Codable synthesis falls back to
    /// a property's default when the key is missing from older JSON.
    public var repeatsWhileHeld: Bool = false
    /// Empty (default) means the rule applies everywhere. Non-empty scopes
    /// it to only fire while one of these apps is frontmost — e.g. a
    /// browser-only tab-switching gesture that doesn't also fire in
    /// Finder. Defaults to empty so existing saved rules are unaffected.
    public var restrictedToApps: [AppReference] = []

    public init(
        id: UUID = UUID(),
        name: String,
        device: InputDevice,
        trigger: Trigger,
        action: Action,
        isEnabled: Bool = true,
        repeatsWhileHeld: Bool = false,
        restrictedToApps: [AppReference] = []
    ) {
        self.id = id
        self.name = name
        self.device = device
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
        self.repeatsWhileHeld = repeatsWhileHeld
        self.restrictedToApps = restrictedToApps
    }

    /// `currentBundleIdentifier` is passed in rather than queried here so
    /// this stays pure and unit-testable — see `ActiveApp` for the real
    /// `NSWorkspace` query used at runtime.
    public func applies(whileFrontmostAppIs currentBundleIdentifier: String?) -> Bool {
        guard !restrictedToApps.isEmpty else { return true }
        // Fail open: an unknown frontmost app shouldn't silently disable
        // every app-scoped rule.
        guard let currentBundleIdentifier else { return true }
        return restrictedToApps.contains { $0.bundleIdentifier == currentBundleIdentifier }
    }
}
