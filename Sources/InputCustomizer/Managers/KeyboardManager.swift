import Cocoa
import CoreGraphics

/// Intercepts key-down events system-wide via a CGEventTap and either
/// lets them through unmodified or rewrites/consumes them according to
/// the user's rules. Runs on a dedicated tap so it doesn't block the
/// main thread.
final class KeyboardManager {
    private let settingsStore: SettingsStore
    private let activityLog: ActivityLog
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(settingsStore: SettingsStore, activityLog: ActivityLog) {
        self.settingsStore = settingsStore
        self.activityLog = activityLog
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<KeyboardManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(event: event) ?? Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("InputCustomizer: failed to create keyboard event tap — check Accessibility permission.")
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

    /// Returns nil to pass the event through untouched, or a replacement
    /// (possibly the same event, mutated) to consume/rewrite it.
    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.rawValue
        let currentApp = ActiveApp.frontmostBundleIdentifier

        // Only ever logs on an actual match, never per keystroke — this
        // tap sees every key-down system-wide, and logging all of them
        // (matched or not) would both flood the console and leak
        // unrelated keystrokes into it.
        for rule in settingsStore.rules(for: .keyboard) {
            guard case let .keyCombo(ruleKeyCode, ruleModifiers) = rule.trigger,
                  ruleKeyCode == keyCode,
                  UInt64(ruleModifiers) == modifiers & relevantModifierMask,
                  rule.applies(whileFrontmostAppIs: currentApp) else { continue }

            activityLog.log(.fired, "\(KeyCodeMap.describe(keyCode: keyCode, modifiers: UInt(modifiers & relevantModifierMask))) → \(rule.action.shortDescription)")
            apply(action: rule.action, to: event)
            return Unmanaged.passRetained(event)
        }
        return nil
    }

    private var relevantModifierMask: UInt64 {
        CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
    }

    private func apply(action: Action, to event: CGEvent) {
        activityLog.log(.executing, action.shortDescription)
        switch action {
        case let .remapToKey(keyCode, modifiers):
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            event.flags = CGEventFlags(rawValue: UInt64(modifiers))
        case let .runShellCommand(command):
            ActionRunner.run(command: command)
        case let .launchApp(bundleIdentifier):
            ActionRunner.launch(bundleIdentifier: bundleIdentifier)
        case let .sendMediaKey(key):
            ActionRunner.send(mediaKey: key)
        case .missionControl:
            ActionRunner.showMissionControl()
        case .none:
            break
        }
    }
}
