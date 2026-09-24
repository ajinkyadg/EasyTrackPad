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
    /// The trackpad's per-finger touch history, for `.mouseCornerClick`
    /// rules — sourced from `TrackpadManager.touchSnapshot`, kept as a
    /// closure so this class doesn't depend on the multitouch pipeline.
    private let touchSnapshot: () -> TouchSnapshot?
    private let cornerSpec = CornerZoneSpec.builtInTrackpad
    /// Main-thread only (the tap's run loop), like everything in `handle`.
    private var suppressor = ClickSuppressor<CustomizationRule>()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(settingsStore: SettingsStore, activityLog: ActivityLog, touchSnapshot: @escaping () -> TouchSnapshot? = { nil }) {
        self.settingsStore = settingsStore
        self.activityLog = activityLog
        self.touchSnapshot = touchSnapshot
    }

    private static let downTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let upTypes: [CGEventType] = [.leftMouseUp, .rightMouseUp, .otherMouseUp]
    private static let dragTypes: [CGEventType] = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    func start() {
        // Ups and drags are only needed to swallow the rest of a matched
        // corner click's sequence; every other one passes straight through.
        let mask = (Self.downTypes + Self.upTypes + Self.dragTypes).reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                // Pass-through returns the event *unretained*: the tap
                // doesn't own it, and a retained return leaks one event
                // per click. `nil` swallows it.
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<MouseManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
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
        suppressor.cancel()
    }

    /// Plain `.mouseButton` rules can live on any of these devices — a
    /// trackpad click and a mouse click are indistinguishable at this
    /// level. Corner clicks are trackpad-only and handled separately.
    private static let candidateDevices: [InputDevice] = [.mouse, .magicMouse, .trackpad]

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS switches a slow or interrupted tap off; without this
            // every mouse rule would silently stop until relaunch.
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            suppressor.cancel()
            activityLog.log(.info, "Mouse event tap was disabled by macOS — re-enabled")
            return passThrough
        }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let time = ProcessInfo.processInfo.systemUptime

        if Self.dragTypes.contains(type) {
            let delta = hypot(event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY))
            return suppressor.drag(button: button, at: time, deltaPoints: CGFloat(delta)) ? nil : passThrough
        }
        if Self.upTypes.contains(type) {
            switch suppressor.up(button: button, at: time) {
            case .passThrough:
                return passThrough
            case let .swallow(fire: rule):
                if let rule {
                    activityLog.log(.fired, "Trackpad corner click → \(rule.action.shortDescription)")
                    apply(action: rule.action)
                } else {
                    activityLog.log(.info, "Corner click swallowed without running: held over \(Int(suppressor.maxHold * 1000))ms, dragged over \(Int(suppressor.maxDragPoints))pt, or a quick second click")
                }
                return nil
            }
        }
        guard Self.downTypes.contains(type) else { return passThrough }

        suppressor.noteDown(button: button)
        let clickState = Int(event.getIntegerValueField(.mouseEventClickState))
        if suppressor.swallowFollowUp(button: button, clickState: clickState, at: time, doubleClickInterval: NSEvent.doubleClickInterval) {
            // The system counts the swallowed corner click toward this
            // one's clickState; letting it through would land as a
            // double-click on whatever is under the pointer.
            return nil
        }

        let modifiers = UInt(event.flags.rawValue) & relevantModifierMask
        if let rule = matchCornerClick(event: event, button: button, modifiers: modifiers, time: time) {
            // Swallow the click itself; the action runs on a quick, still
            // release (see ClickSuppressor), never on a drag or long press.
            suppressor.begin(button: button, at: time, payload: rule)
            return nil
        }

        // `ActiveApp.frontmostBundleIdentifier` is deliberately checked
        // only once a rule has already matched by button+modifiers — an
        // ordinary click that isn't bound to anything shouldn't pay for an
        // NSWorkspace query it'll never use.
        for device in Self.candidateDevices {
            for rule in settingsStore.rules(for: device) {
                guard case let .mouseButton(ruleButton, ruleModifiers) = rule.trigger,
                      ruleButton == button, UInt(ruleModifiers) == modifiers,
                      rule.applies(whileFrontmostAppIs: ActiveApp.frontmostBundleIdentifier) else { continue }

                activityLog.log(.fired, "Button \(button) → \(rule.action.shortDescription)")
                apply(action: rule.action)
                return passThrough
            }
        }
        return passThrough
    }

    /// The first enabled trackpad corner-click rule this click satisfies
    /// under the v2 contract (`resolveCornerClick`), or `nil`. Rejections
    /// are logged only when a finger actually landed in a corner, so the
    /// Activity console explains near-misses without narrating every
    /// ordinary click.
    private func matchCornerClick(event: CGEvent, button: Int, modifiers: UInt, time: TimeInterval) -> CustomizationRule? {
        let candidates = settingsStore.rules(for: .trackpad).filter {
            guard case let .mouseCornerClick(_, ruleButton, ruleModifiers) = $0.trigger else { return false }
            return ruleButton == button && UInt(ruleModifiers) == modifiers
        }
        guard !candidates.isEmpty else { return nil }

        let snapshot = touchSnapshot()
        let result = resolveCornerClick(
            snapshot: snapshot,
            clickTime: time,
            clickState: Int(event.getIntegerValueField(.mouseEventClickState)),
            eventSubtype: Int(event.getIntegerValueField(.mouseEventSubtype)),
            spec: cornerSpec
        )
        switch result {
        case let .match(corner):
            let rule = candidates.first {
                guard case let .mouseCornerClick(ruleCorner, _, _) = $0.trigger else { return false }
                return ruleCorner == corner && $0.applies(whileFrontmostAppIs: ActiveApp.frontmostBundleIdentifier)
            }
            if rule != nil { activityLog.log(.detected, "\(corner.displayName) click") }
            return rule
        case let .reject(reason):
            if let snapshot, let surface = snapshot.surfaceMM,
               snapshot.contacts.contains(where: { cornerZone(containing: $0.landing, surface: surface, zone: cornerSpec.sizeMM) != nil }) {
                activityLog.log(.info, "Corner click ignored: \(reason.explanation)")
            }
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
