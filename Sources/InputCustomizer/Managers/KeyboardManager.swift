import Cocoa
import CoreGraphics
import InputModels
import ActionExecution

/// Intercepts key-down *and* key-up events system-wide via a CGEventTap
/// and either lets them through unmodified or rewrites/consumes them
/// according to the user's rules. Runs on a dedicated tap so it doesn't
/// block the main thread.
final class KeyboardManager {
    private let settingsStore: SettingsStore
    private let activityLog: ActivityLog
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Which physical key (by its original, pre-remap keyCode) is
    /// currently mid-remap, and the target keycode/flags it's being
    /// remapped to — keyed so the matching keyUp gets rewritten the same
    /// way the keyDown was, and so the bracketing modifier keys (see
    /// `ActionRunner.pressHeldModifiers`) get released at the right
    /// moment. Without this, only the keyDown half of a `.remapToKey`
    /// rule was ever touched — the physical key's own keyUp passed
    /// through completely unmodified, mismatched against the synthesized
    /// keyDown, and no modifier-key transitions were ever posted at all.
    /// Native macOS apps mostly tolerate that; Citrix's remote keyboard
    /// forwarding apparently doesn't (reported symptom: garbage
    /// characters typed into a Citrix/Windows VDI session after a
    /// keyboard remap rule fires).
    private var activeRemaps: [UInt16: (keyCode: UInt16, flags: CGEventFlags)] = [:]

    init(settingsStore: SettingsStore, activityLog: ActivityLog) {
        self.settingsStore = settingsStore
        self.activityLog = activityLog
    }

    func start() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<KeyboardManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event) ?? Unmanaged.passRetained(event)
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
        activeRemaps.removeAll()
    }

    /// Returns nil to pass the event through untouched, or a replacement
    /// (possibly the same event, mutated) to consume/rewrite it.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // The keyUp half of an in-progress remap — rewrite it to match
        // the keyDown already sent, and release the bracketing modifier
        // keys. A keyUp for anything *not* currently remapped (the
        // overwhelming majority — ordinary typing) just passes through.
        if type == .keyUp {
            guard let remap = activeRemaps.removeValue(forKey: keyCode) else { return nil }
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(remap.keyCode))
            event.flags = remap.flags
            ActionRunner.releaseHeldModifiers(for: remap.flags, source: CGEventSource(stateID: .hidSystemState))
            return Unmanaged.passRetained(event)
        }

        let modifiers = event.flags.rawValue & relevantModifierMask

        // Only ever logs on an actual match, never per keystroke — this
        // tap sees every key-down system-wide, and logging all of them
        // (matched or not) would both flood the console and leak
        // unrelated keystrokes into it.
        //
        // `ActiveApp.frontmostBundleIdentifier` (an NSWorkspace query) is
        // deliberately checked last, only once a keyCombo has already
        // matched by code+modifiers — cheap integer comparisons run for
        // every one of this tap's system-wide keystrokes, but the great
        // majority of them (ordinary typing) match no configured remap at
        // all, so they'd otherwise pay for that query for nothing. This
        // tap runs on a latency-sensitive path: a slow callback risks
        // macOS disabling the event tap outright.
        for rule in settingsStore.rules(for: .keyboard) {
            guard case let .keyCombo(ruleKeyCode, ruleModifiers) = rule.trigger,
                  ruleKeyCode == keyCode,
                  UInt64(ruleModifiers) == modifiers,
                  rule.applies(whileFrontmostAppIs: ActiveApp.frontmostBundleIdentifier) else { continue }

            activityLog.log(.fired, "\(KeyCodeMap.describe(keyCode: keyCode, modifiers: UInt(modifiers))) → \(rule.action.shortDescription)")
            apply(action: rule.action, to: event, originalKeyCode: keyCode)
            return Unmanaged.passRetained(event)
        }
        return nil
    }

    private var relevantModifierMask: UInt64 {
        CGEventFlags([.maskShift, .maskControl, .maskAlternate, .maskCommand]).rawValue
    }

    private func apply(action: Action, to event: CGEvent, originalKeyCode: UInt16) {
        activityLog.log(.executing, action.shortDescription)
        switch action {
        case let .remapToKey(keyCode, modifiers):
            let flags = CGEventFlags(rawValue: UInt64(modifiers))
            // Real modifier keyDown events first (not just a flags bit —
            // see ActionRunner.sendKeyPress's doc comment), then rewrite
            // this keyDown in place. `activeRemaps` remembers the target
            // so the matching keyUp (see `handle`) releases the modifiers
            // the same way once the physical key is actually released.
            ActionRunner.pressHeldModifiers(for: flags, source: CGEventSource(stateID: .hidSystemState))
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
            event.flags = flags
            activeRemaps[originalKeyCode] = (keyCode, flags)
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
