import Cocoa
import CoreGraphics

/// Intercepts mouse button events (including extra buttons 3+, e.g. side
/// buttons on gaming/productivity mice) system-wide via a CGEventTap.
final class MouseManager {
    private let settingsStore: SettingsStore
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let modifiers = UInt(event.flags.rawValue) & relevantModifierMask

        for rule in settingsStore.rules(for: .mouse) {
            guard case let .mouseButton(ruleButton, ruleModifiers) = rule.trigger,
                  ruleButton == buttonNumber,
                  UInt(ruleModifiers) == modifiers else { continue }

            apply(action: rule.action)
            return Unmanaged.passRetained(event) // consumed; swap for `nil` to also pass through
        }
        return nil
    }

    private var relevantModifierMask: UInt {
        UInt(CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue)
    }

    private func apply(action: Action) {
        switch action {
        case let .runShellCommand(command):
            ActionRunner.run(command: command)
        case let .launchApp(bundleIdentifier):
            ActionRunner.launch(bundleIdentifier: bundleIdentifier)
        case let .sendMediaKey(key):
            ActionRunner.send(mediaKey: key)
        case .missionControl:
            ActionRunner.showMissionControl()
        case .remapToKey, .none:
            break // remapping a button to a keypress is handled in a later iteration
        }
    }
}
