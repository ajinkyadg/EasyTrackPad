import Cocoa
import CoreGraphics
import GestureEngine
import InputModels
import ActionExecution

/// Intercepts mouse button events (including extra buttons 3+, e.g. side
/// buttons on gaming/productivity mice) system-wide via a CGEventTap.
final class MouseManager {
    private let settingsStore: SettingsStore
    private let activityLog: ActivityLog
    /// Supplies the last known finger position on the trackpad surface, for
    /// gating `.mouseCornerClick` rules — sourced from `TrackpadManager
    /// .lastTouchPosition`, kept as a closure (rather than a direct
    /// dependency on TrackpadManager) so this class doesn't need to know
    /// anything about multitouch/gesture recognition.
    private let lastTouchPosition: () -> CGPoint?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(settingsStore: SettingsStore, activityLog: ActivityLog, lastTouchPosition: @escaping () -> CGPoint? = { nil }) {
        self.settingsStore = settingsStore
        self.activityLog = activityLog
        self.lastTouchPosition = lastTouchPosition
    }

    func start() {
        let mask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<MouseManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event) ?? Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("InputCustomizer: failed to create mouse event tap — check Accessibility permission.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
    }

    /// `.mouse`, `.magicMouse`, and `.trackpad` can all generate ordinary
    /// click events through this same CGEventTap — a trackpad click and a
    /// mouse click are indistinguishable at this level, and `.trackpad` is
    /// now where corner-click rules live (see `InputDevice.magicMouse`'s
    /// doc comment) — so all three device's rules are live candidates for
    /// any click.
    private static let candidateDevices: [InputDevice] = [.mouse, .magicMouse, .trackpad]

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let modifiers = UInt(event.flags.rawValue) & relevantModifierMask

        // `ActiveApp.frontmostBundleIdentifier` is deliberately checked
        // only once a rule has already matched by button+modifiers/corner
        // — an ordinary click that isn't bound to anything shouldn't pay
        // for an NSWorkspace query it'll never use, and iterating three
        // devices in place (rather than `a + b + c`) skips concatenating
        // fresh arrays on every click.
        for device in Self.candidateDevices {
            for rule in settingsStore.rules(for: device) {
                guard let description = matchDescription(for: rule.trigger, device: rule.device, buttonNumber: buttonNumber, modifiers: modifiers),
                      rule.applies(whileFrontmostAppIs: ActiveApp.frontmostBundleIdentifier) else { continue }

                activityLog.log(.fired, "\(description) → \(rule.action.shortDescription)")
                apply(action: rule.action)
                return Unmanaged.passRetained(event) // consumed; swap for `nil` to also pass through
            }
        }
        return nil
    }

    /// Returns a short description of the match (for the activity log) if
    /// `trigger` matches this click, `nil` otherwise. `.mouseCornerClick`
    /// additionally needs a finger to have actually been resting near that
    /// corner; with no touch data at all (multitouch unavailable, or no
    /// finger currently tracked), it simply never matches, rather than
    /// falling back to firing unconditionally. Corner-click rules only
    /// ever live on `.trackpad` (see `InputDevice.magicMouse`'s doc
    /// comment), so `lastTouchPosition` always means the trackpad's.
    private func matchDescription(for trigger: Trigger, device: InputDevice, buttonNumber: Int, modifiers: UInt) -> String? {
        switch trigger {
        case let .mouseButton(ruleButton, ruleModifiers):
            guard ruleButton == buttonNumber, UInt(ruleModifiers) == modifiers else { return nil }
            return "Button \(buttonNumber)"
        case let .mouseCornerClick(corner, ruleButton, ruleModifiers):
            guard ruleButton == buttonNumber, UInt(ruleModifiers) == modifiers,
                  let position = lastTouchPosition(), MouseCorner.resolve(from: position) == corner else { return nil }
            return "Button \(buttonNumber), \(corner.displayName)"
        case .keyCombo, .trackpadGesture:
            return nil
        }
    }

    private var relevantModifierMask: UInt {
        UInt(CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue)
    }

    private func apply(action: Action) {
        activityLog.log(.executing, action.shortDescription)
        switch action {
        case let .runShellCommand(command):
            ActionRunner.run(command: command)
        case let .launchApp(bundleIdentifier):
            ActionRunner.launch(bundleIdentifier: bundleIdentifier)
        case let .sendMediaKey(key):
            ActionRunner.send(mediaKey: key)
        case .missionControl:
            ActionRunner.showMissionControl()
        case let .remapToKey(keyCode, modifiers):
            ActionRunner.sendKeyPress(keyCode: keyCode, modifiers: modifiers)
        case .none:
            break
        }
    }
}
