import Cocoa
import Combine
import GestureEngine
import InputModels
import ActionExecution

/// Listens for gestures via two complementary sources:
/// - N-finger swipes and taps come from raw multitouch frames
///   (`MultitouchGestureEngine` + `GestureRecognizer`), since AppKit's
///   public API has no concept of finger count and can't detect taps at
///   all. This is what makes finger-count-specific rules (2/3/4-finger
///   swipes, 2-5-finger taps) possible, matching what BetterTouchTool-style
///   tools do — at the cost of depending on the private, undocumented
///   MultitouchSupport.framework (see Sources/CMultitouchSupport).
/// - Pinch/rotate stay on AppKit's public `NSEvent` gesture monitors:
///   they're inherently two-finger gestures already, so the extra
///   complexity of computing scale/angle from raw touches ourselves
///   wouldn't buy anything, and the public API is one less thing that can
///   break on a macOS update. Only meaningful for `.trackpad` — Magic
///   Mouse has no OS-level pinch/rotate gesture at all.
///
/// Runs the built-in trackpad and an external Magic Mouse *simultaneously*
/// — one `MultitouchGestureEngine`/`GestureRecognizer` pair per device,
/// each bound to its own physical device's IOService via
/// `MTDeviceCreateFromService` (see that class's doc comment). An earlier
/// version of this app only ever read one physical device at a time,
/// switchable in Settings — that limitation traced back to the private
/// enumeration API (`MTDeviceCreateList`/`MTDeviceIsBuiltIn`) never
/// reliably delivering frames for a Magic Mouse; targeting each device's
/// exact IOService directly sidesteps that entirely, so there's no longer
/// a reason to keep them mutually exclusive.
final class TrackpadManager {
    private let settingsStore: SettingsStore
    private let visualizerModel: TouchVisualizerModel
    private let activityLog: ActivityLog
    private var monitors: [Any] = []

    private let trackpadEngine = MultitouchGestureEngine()
    private let trackpadRecognizer = GestureRecognizer()
    private let magicMouseEngine = MultitouchGestureEngine()
    private let magicMouseRecognizer = GestureRecognizer()
    /// "Repeat while held" state, kept independently per device — a
    /// trackpad swipe-and-hold in progress must be unaffected by an
    /// unrelated Magic Mouse gesture starting its own repeat, and vice
    /// versa, now that both can be mid-gesture at the same time.
    private var trackpadRepeatSession: RepeatSession!
    private var magicMouseRepeatSession: RepeatSession!

    private var cancellables: Set<AnyCancellable> = []

    /// Last known finger position on the *trackpad* surface — `MouseManager`
    /// reads this to gate corner-click rules, which only ever apply to
    /// `.trackpad` (see `InputDevice.magicMouse`'s doc comment). See
    /// `GestureRecognizer.lastTouchPosition`'s doc comment for the
    /// thread-safety reasoning.
    var lastTouchPosition: CGPoint? { trackpadRecognizer.lastTouchPosition }

    init(settingsStore: SettingsStore, visualizerModel: TouchVisualizerModel, activityLog: ActivityLog) {
        self.settingsStore = settingsStore
        self.visualizerModel = visualizerModel
        self.activityLog = activityLog
        // Palm-rejection across any finger count — only on the trackpad's
        // own recognizer. A Magic Mouse's much smaller shell means
        // genuine multi-finger touches there sit naturally closer
        // together than this threshold allows, and it isn't exposed to
        // stray palm contact while typing the way a laptop's built-in
        // trackpad is. See GestureRecognizer.minimumFingerSeparation's
        // doc comment.
        trackpadRecognizer.minimumFingerSeparation = 0.08
        trackpadRepeatSession = RepeatSession(
            settingsStore: settingsStore, activityLog: activityLog, label: "trackpad",
            isTouching: { [trackpadRecognizer] in trackpadRecognizer.isTouching },
            apply: { [weak self] action in self?.apply(action: action) }
        )
        magicMouseRepeatSession = RepeatSession(
            settingsStore: settingsStore, activityLog: activityLog, label: "magic mouse",
            isTouching: { [magicMouseRecognizer] in magicMouseRecognizer.isTouching },
            apply: { [weak self] action in self?.apply(action: action) }
        )
    }

    func start() {
        let magnify = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            self?.handleMagnify(event)
        }
        let rotate = NSEvent.addGlobalMonitorForEvents(matching: .rotate) { [weak self] event in
            self?.handleRotate(event)
        }
        monitors = [magnify, rotate].compactMap { $0 }

        wire(recognizer: trackpadRecognizer, device: .trackpad, repeatSession: trackpadRepeatSession)
        wire(recognizer: magicMouseRecognizer, device: .magicMouse, repeatSession: magicMouseRepeatSession)

        trackpadEngine.onFrame = { [weak self] frame in
            // Runs on MultitouchSupport's own callback thread, not main —
            // see MultitouchGestureEngine.onFrame's doc comment.
            self?.trackpadRecognizer.process(frame)
            self?.publishToVisualizer(frame, device: .trackpad)
        }
        magicMouseEngine.onFrame = { [weak self] frame in
            self?.magicMouseRecognizer.process(frame)
            self?.publishToVisualizer(frame, device: .magicMouse)
        }

        // Applies the Preferences sensitivity sliders live, no restart
        // needed — shared across both devices rather than tuned
        // separately, matching how these sliders already showed on both
        // the Trackpad and Magic Mouse tabs before dual-device support.
        settingsStore.$gestureSensitivity
            .sink { [weak self] value in
                self?.trackpadRecognizer.sensitivity = value
                self?.magicMouseRecognizer.sensitivity = value
            }
            .store(in: &cancellables)
        settingsStore.$repeatByDistanceSensitivity
            .sink { [weak self] value in
                self?.trackpadRecognizer.distanceRepeatSensitivity = value
                self?.magicMouseRecognizer.distanceRepeatSensitivity = value
            }
            .store(in: &cancellables)

        let trackpadAvailable = trackpadEngine.start(preferring: .builtIn)
        let magicMouseAvailable = magicMouseEngine.start(preferring: .external)
        visualizerModel.setMultitouchAvailable(trackpad: trackpadAvailable, magicMouse: magicMouseAvailable)
        activityLog.log(.info, "Trackpad multitouch \(trackpadAvailable ? "available" : "unavailable"); Magic Mouse multitouch \(magicMouseAvailable ? "available" : "unavailable")")
    }

    private func publishToVisualizer(_ frame: MultitouchGestureEngine.Frame, device: InputDevice) {
        // Only hop to main for live touch dots while the preview UI is
        // actually open AND currently showing this device — `previewDevice`/
        // `isActive` read cross-thread here is a benign race for plain
        // scalars, same trade-off already made for `sensitivity` above; not
        // worth a lock for this.
        guard visualizerModel.isActive, visualizerModel.previewDevice == device else { return }
        DispatchQueue.main.async { [weak self] in
            self?.visualizerModel.update(touches: frame.touches)
        }
    }

    private func wire(recognizer: GestureRecognizer, device: InputDevice, repeatSession: RepeatSession) {
        // Per-gesture-kind overrides — see CustomizationRule.sensitivityOverride's
        // doc comment. Looks up whichever rule on this device is bound to
        // the kind being evaluated (in practice at most one — a
        // `.trackpadGesture` trigger carries no other discriminator, so
        // two rules sharing one would already be redundant) and reads its
        // override, falling back to `nil` (global default) if unset or if
        // no rule exists for that kind at all.
        recognizer.sensitivityOverride = { [weak self] kind in
            self?.overrideValue(for: kind, device: device, \.sensitivityOverride)
        }
        recognizer.distanceRepeatSensitivityOverride = { [weak self] kind in
            self?.overrideValue(for: kind, device: device, \.repeatByDistanceSensitivityOverride)
        }
        recognizer.onGesture = { [weak self] kind in
            // A recognized gesture is rare relative to raw frame delivery
            // (up to ~120Hz) — only this hop actually needs the main
            // thread, since firing an action can post CGEvents / touch UI.
            DispatchQueue.main.async {
                guard let self else { return }
                let matches = self.fire(gesture: kind, device: device)
                repeatSession.startRepeating(matches)
                if self.visualizerModel.isActive, self.visualizerModel.previewDevice == device {
                    self.visualizerModel.recognized(gesture: kind)
                }
            }
        }
        recognizer.onTouchEnded = {
            DispatchQueue.main.async {
                repeatSession.stopRepeating()
            }
        }
        recognizer.onSwipeTick = { _ in
            DispatchQueue.main.async {
                repeatSession.tickDistanceActions()
            }
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        trackpadEngine.stop()
        magicMouseEngine.stop()
        trackpadRepeatSession.stopRepeating()
        magicMouseRepeatSession.stopRepeating()
    }

    private func handleMagnify(_ event: NSEvent) {
        // Pinch is trackpad-only — Magic Mouse has no OS-level pinch
        // gesture at all (see this file's top doc comment).
        _ = fire(gesture: event.magnification > 0 ? .pinchOut : .pinchIn, device: .trackpad)
    }

    private func handleRotate(_ event: NSEvent) {
        _ = fire(gesture: event.rotation > 0 ? .rotateCounterClockwise : .rotateClockwise, device: .trackpad)
    }

    private func overrideValue(for kind: Trigger.GestureKind, device: InputDevice, _ keyPath: KeyPath<CustomizationRule, Double?>) -> Double? {
        settingsStore.rules(for: device).first {
            if case let .trackpadGesture(ruleKind) = $0.trigger { return ruleKind == kind }
            return false
        }?[keyPath: keyPath]
    }

    @discardableResult
    private func fire(gesture: Trigger.GestureKind, device: InputDevice) -> [CustomizationRule] {
        let currentApp = ActiveApp.frontmostBundleIdentifier
        let matches = settingsStore.rules(for: device).filter {
            guard case let .trackpadGesture(ruleGesture) = $0.trigger, ruleGesture == gesture else { return false }
            return $0.applies(whileFrontmostAppIs: currentApp)
        }
        NSLog("InputCustomizer: \(device.rawValue) gesture \(gesture.rawValue) matched \(matches.count) rule(s)")
        if matches.isEmpty {
            activityLog.log(.detected, "\(gesture.displayName) — no matching trigger")
        } else {
            for rule in matches {
                activityLog.log(.fired, "\(gesture.displayName) → \(rule.action.shortDescription)")
            }
        }
        for rule in matches {
            apply(action: rule.action)
        }
        return matches
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

/// Owns "repeat while held" state (timers, watchdog, distance-repeat
/// bookkeeping) for exactly one device's `GestureRecognizer` — see
/// `TrackpadManager`'s `trackpadRepeatSession`/`magicMouseRepeatSession`.
/// Pulled out of `TrackpadManager` itself specifically so this state is
/// per-device rather than one shared set of properties implicitly
/// assuming only one touch session can ever be active — with the
/// trackpad and a Magic Mouse both live at once, a finger can genuinely
/// be down on both surfaces at the same time.
private final class RepeatSession {
    private let settingsStore: SettingsStore
    private let activityLog: ActivityLog
    private let label: String
    /// Cross-thread-safe "is this device's recognizer still touching" —
    /// used by the watchdog backstop, not the primary stop path.
    private let isTouching: () -> Bool
    private let apply: (Action) -> Void

    private var repeatTimers: [Timer] = []
    private var pendingDistanceActions: [Action] = []
    /// One pending delayed-start per timer-repeat rule now, not a single
    /// shared one — each rule can carry its own `repeatDelayOverride`
    /// (see `CustomizationRule`'s doc comment), so a batch of matched
    /// rules can legitimately start repeating at different moments.
    private var pendingRepeatStarts: [DispatchWorkItem] = []
    private var repeatWatchdog: Timer?
    private var repeatSessionStart: Date?
    private let repeatWatchdogInterval: TimeInterval = 0.1
    private let maxRepeatDuration: TimeInterval = 20

    init(settingsStore: SettingsStore, activityLog: ActivityLog, label: String, isTouching: @escaping () -> Bool, apply: @escaping (Action) -> Void) {
        self.settingsStore = settingsStore
        self.activityLog = activityLog
        self.label = label
        self.isTouching = isTouching
        self.apply = apply
    }

    /// Arms "repeat while held" for whichever matched rule(s) opted into
    /// it (see `CustomizationRule.repeatsWhileHeld`) — most rules won't
    /// have it set, so this is a no-op for them. Splits into two
    /// independent mechanisms depending on `repeatsByDistance`:
    /// distance-repeat actions are armed immediately (no delay — the
    /// delay slider is a fixed-timer concept, and gating distance-repeat
    /// behind it would silently discard swipe travel that happens during
    /// the delay window, contradicting "repeat by sliding further, like a
    /// scroll wheel"), while timer actions wait `repeatDelay` before
    /// actually starting, cancelably — if fingers lift before the delay
    /// elapses, `stopRepeating()` cancels this and repeating never begins.
    func startRepeating(_ matches: [CustomizationRule]) {
        stopRepeating()
        let repeatCandidates = matches.filter { $0.repeatsWhileHeld && $0.trigger.supportsRepeatWhileHeld }
        guard !repeatCandidates.isEmpty else { return }

        let distanceCandidates = repeatCandidates.filter { $0.repeatsByDistance && $0.trigger.supportsRepeatByDistance }
        let timerCandidates = repeatCandidates.filter { !($0.repeatsByDistance && $0.trigger.supportsRepeatByDistance) }

        if !distanceCandidates.isEmpty {
            pendingDistanceActions = distanceCandidates.map(\.action)
            NSLog("InputCustomizer: [\(label)] repeat-by-distance armed for \(distanceCandidates.count) action(s)")
            activityLog.log(.info, "Repeat by distance armed (\(distanceCandidates.count) action(s))")
            armWatchdog()
        }

        // Each timer-repeat rule gets its own delayed start, using its own
        // `repeatIntervalOverride`/`repeatDelayOverride` if set (else the
        // global Preferences default) — see CustomizationRule's doc
        // comment. A batch of matched rules can legitimately want
        // different speeds/delays from each other.
        for rule in timerCandidates {
            let delay = rule.repeatDelayOverride ?? settingsStore.repeatWhileHeldDelay
            let interval = rule.repeatIntervalOverride ?? settingsStore.repeatWhileHeldInterval
            let action = rule.action
            NSLog("InputCustomizer: [\(label)] repeat-while-held armed, starting in \(delay)s at \(interval)s/tick")
            activityLog.log(.info, "Repeat while held armed, starting in \(String(format: "%.2f", delay))s")
            let workItem = DispatchWorkItem { [weak self] in self?.beginRepeating(action: action, interval: interval) }
            pendingRepeatStarts.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func beginRepeating(action: Action, interval: TimeInterval) {
        NSLog("InputCustomizer: [\(label)] repeat-while-held started (interval \(interval)s)")
        activityLog.log(.info, "Repeat while held started")

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.apply(action)
        }
        repeatTimers.append(timer)
        armWatchdog() // idempotent — already armed if distance-repeat also matched this gesture
    }

    /// Two independent safety nets, separate from the primary stop path
    /// (`GestureRecognizer.onTouchEnded`) and from each other, shared by
    /// both the timer and distance-repeat mechanisms:
    ///  - `isTouching`, checked at a fixed fast interval rather than the
    ///    user-tunable `repeatInterval` (now sliderable up to 0.75s), so a
    ///    missed/delayed `onTouchEnded` notification is caught quickly
    ///    regardless of how that slider is set.
    ///  - a hard time ceiling, because `isTouching` itself depends on
    ///    `process()` ever receiving a fresh zero-touch frame — if a real
    ///    multitouch driver quirk stalls frame delivery entirely for a
    ///    long stationary hold, neither `onTouchEnded` nor `isTouching` can
    ///    update, and only an unconditional ceiling guarantees this ever
    ///    stops.
    private func armWatchdog() {
        guard repeatWatchdog == nil else { return }
        repeatSessionStart = Date()
        repeatWatchdog = Timer.scheduledTimer(withTimeInterval: repeatWatchdogInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !self.isTouching() {
                self.stopRepeating(reason: "backstop (onTouchEnded never arrived)")
            } else if let start = self.repeatSessionStart, Date().timeIntervalSince(start) > self.maxRepeatDuration {
                self.stopRepeating(reason: "max duration reached (\(Int(self.maxRepeatDuration))s)")
            }
        }
    }

    func stopRepeating(reason: String = "onTouchEnded") {
        pendingRepeatStarts.forEach { $0.cancel() }
        pendingRepeatStarts.removeAll()
        repeatWatchdog?.invalidate()
        repeatWatchdog = nil
        repeatSessionStart = nil
        let hadDistanceActions = !pendingDistanceActions.isEmpty
        pendingDistanceActions.removeAll()
        guard !repeatTimers.isEmpty || hadDistanceActions else { return }
        NSLog("InputCustomizer: [\(label)] repeat-while-held stopped (\(reason))")
        activityLog.log(.info, "Repeat while held stopped (\(reason))")
        repeatTimers.forEach { $0.invalidate() }
        repeatTimers.removeAll()
    }

    func tickDistanceActions() {
        pendingDistanceActions.forEach(apply)
    }
}
