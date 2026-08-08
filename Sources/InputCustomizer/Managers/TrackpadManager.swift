import Cocoa
import Combine

/// Listens for trackpad gestures via two complementary sources:
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
///   break on a macOS update.
final class TrackpadManager {
    private let settingsStore: SettingsStore
    private let visualizerModel: TouchVisualizerModel
    private let activityLog: ActivityLog
    private var monitors: [Any] = []
    private let multitouchEngine = MultitouchGestureEngine()
    private let gestureRecognizer = GestureRecognizer()
    private var cancellables: Set<AnyCancellable> = []
    /// "Repeat while held" timers for whichever rule(s) matched the swipe
    /// that's currently in progress — started when it first fires, torn
    /// down on `onTouchEnded`. One touch session is never mid-gesture for
    /// two different swipes at once, so a plain array (not keyed by rule)
    /// is enough.
    private var repeatTimers: [Timer] = []
    /// Actions for matched rule(s) with `repeatsWhileHeld && repeatsByDistance`
    /// — driven purely by `gestureRecognizer.onSwipeTick`, no `Timer` of
    /// its own. Cleared in `stopRepeating()` alongside the timer state so
    /// a stray tick after fingers lift can't fire anything.
    private var pendingDistanceActions: [Action] = []
    /// The delayed, cancelable start of repeating (see
    /// `SettingsStore.repeatWhileHeldDelay`) — needs to be cancelable
    /// separately from `repeatTimers` because fingers can lift before the
    /// delay elapses, in which case repeating should never start at all.
    private var pendingRepeatStart: DispatchWorkItem?
    /// Separate from `repeatTimers`, at a fixed fast interval rather than
    /// the user-tunable `repeatInterval` — see `beginRepeating` for why.
    private var repeatWatchdog: Timer?
    private var repeatSessionStart: Date?
    private let repeatWatchdogInterval: TimeInterval = 0.1
    /// Absolute ceiling on a single repeat-while-held session, regardless
    /// of touch state — see `beginRepeating`'s doc comment for why this
    /// exists as a last resort on top of the touch-based stop signals.
    private let maxRepeatDuration: TimeInterval = 20
    /// Read fresh each time a hold starts (see `SettingsStore.repeatWhileHeldInterval`/
    /// `repeatWhileHeldDelay`, both tunable via the Preferences sliders) —
    /// a `Timer`'s interval can't be changed after it's created, so an
    /// adjustment mid-hold only takes effect on the *next* swipe-and-hold,
    /// not the one in progress.
    private var repeatInterval: TimeInterval { settingsStore.repeatWhileHeldInterval }
    private var repeatDelay: TimeInterval { settingsStore.repeatWhileHeldDelay }

    init(settingsStore: SettingsStore, visualizerModel: TouchVisualizerModel, activityLog: ActivityLog) {
        self.settingsStore = settingsStore
        self.visualizerModel = visualizerModel
        self.activityLog = activityLog
    }

    func start() {
        let magnify = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            self?.handleMagnify(event)
        }
        let rotate = NSEvent.addGlobalMonitorForEvents(matching: .rotate) { [weak self] event in
            self?.handleRotate(event)
        }
        monitors = [magnify, rotate].compactMap { $0 }

        gestureRecognizer.onGesture = { [weak self] kind in
            // A recognized gesture is rare relative to raw frame delivery
            // (up to ~120Hz) — only this hop actually needs the main
            // thread, since firing an action can post CGEvents / touch UI.
            DispatchQueue.main.async {
                let matches = self?.fire(gesture: kind) ?? []
                self?.startRepeating(matches)
                if self?.visualizerModel.isActive == true {
                    self?.visualizerModel.recognized(gesture: kind)
                }
            }
        }
        gestureRecognizer.onTouchEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.stopRepeating()
            }
        }
        gestureRecognizer.onSwipeTick = { [weak self] _ in
            DispatchQueue.main.async {
                self?.pendingDistanceActions.forEach { self?.apply(action: $0) }
            }
        }
        multitouchEngine.onFrame = { [weak self] frame in
            // Runs on MultitouchSupport's own callback thread, not main —
            // see MultitouchGestureEngine.onFrame's doc comment.
            self?.gestureRecognizer.process(frame)

            // Only hop to main for live touch dots while the preview UI
            // is actually open — `isActive` read cross-thread here is a
            // benign race for a Bool flag, same trade-off already made
            // for `sensitivity` above; not worth a lock for this.
            if self?.visualizerModel.isActive == true {
                DispatchQueue.main.async {
                    self?.visualizerModel.update(touches: frame.touches)
                }
            }
        }

        // Applies the Preferences sensitivity slider live, no restart
        // needed. `sensitivity` is a plain Double read from the
        // multitouch callback thread and written here from main — a
        // benign race for a coarse tuning knob, not worth a lock for.
        settingsStore.$gestureSensitivity
            .sink { [weak self] value in
                self?.gestureRecognizer.sensitivity = value
            }
            .store(in: &cancellables)
        settingsStore.$repeatByDistanceSensitivity
            .sink { [weak self] value in
                self?.gestureRecognizer.distanceRepeatSensitivity = value
            }
            .store(in: &cancellables)

        visualizerModel.setMultitouchAvailable(multitouchEngine.start())
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        multitouchEngine.stop()
        stopRepeating()
    }

    private func handleMagnify(_ event: NSEvent) {
        _ = fire(gesture: event.magnification > 0 ? .pinchOut : .pinchIn)
    }

    private func handleRotate(_ event: NSEvent) {
        _ = fire(gesture: event.rotation > 0 ? .rotateCounterClockwise : .rotateClockwise)
    }

    @discardableResult
    private func fire(gesture: Trigger.GestureKind) -> [CustomizationRule] {
        let currentApp = ActiveApp.frontmostBundleIdentifier
        let matches = settingsStore.rules(for: .trackpad).filter {
            guard case let .trackpadGesture(ruleGesture) = $0.trigger, ruleGesture == gesture else { return false }
            return $0.applies(whileFrontmostAppIs: currentApp)
        }
        NSLog("InputCustomizer: trackpad gesture \(gesture.rawValue) matched \(matches.count) rule(s)")
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
    private func startRepeating(_ matches: [CustomizationRule]) {
        stopRepeating()
        // `$0.trigger.supportsRepeatWhileHeld` is defense in depth on top
        // of RuleFormView.save() already clamping this at persist time —
        // also covers a rule that reaches this some other way (hand-edited
        // JSON from before that fix, a future preset). It matters
        // structurally, not just cosmetically: a tap fires onTouchEnded
        // *before* onGesture (see GestureRecognizer.process), so a tap
        // rule that incorrectly carried repeatsWhileHeld=true would start
        // a timer with no future lift-off left to stop it.
        let repeatCandidates = matches.filter { $0.repeatsWhileHeld && $0.trigger.supportsRepeatWhileHeld }
        guard !repeatCandidates.isEmpty else { return }

        let distanceActions = repeatCandidates
            .filter { $0.repeatsByDistance && $0.trigger.supportsRepeatByDistance }
            .map(\.action)
        let timerActions = repeatCandidates
            .filter { !($0.repeatsByDistance && $0.trigger.supportsRepeatByDistance) }
            .map(\.action)

        if !distanceActions.isEmpty {
            pendingDistanceActions = distanceActions
            NSLog("InputCustomizer: repeat-by-distance armed for \(distanceActions.count) action(s)")
            activityLog.log(.info, "Repeat by distance armed (\(distanceActions.count) action(s))")
            armWatchdog()
        }

        guard !timerActions.isEmpty else { return }
        let delay = repeatDelay
        NSLog("InputCustomizer: repeat-while-held armed for \(timerActions.count) action(s), starting in \(delay)s")
        activityLog.log(.info, "Repeat while held armed (\(timerActions.count) action(s), starting in \(String(format: "%.2f", delay))s)")
        let workItem = DispatchWorkItem { [weak self] in self?.beginRepeating(timerActions) }
        pendingRepeatStart = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func beginRepeating(_ actions: [Action]) {
        pendingRepeatStart = nil
        NSLog("InputCustomizer: repeat-while-held started for \(actions.count) action(s)")
        activityLog.log(.info, "Repeat while held started (\(actions.count) action(s))")

        repeatTimers = actions.map { action in
            Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.apply(action: action)
            }
        }
        armWatchdog() // idempotent — already armed if distance-repeat also matched this gesture
    }

    /// Two independent safety nets, separate from the primary stop path
    /// (`GestureRecognizer.onTouchEnded`) and from each other, shared by
    /// both the timer and distance-repeat mechanisms:
    ///  - `isTouching`, checked at a fixed fast interval rather than the
    ///    user-tunable `repeatInterval` (now sliderable up to 0.75s), so a
    ///    missed/delayed `onTouchEnded` notification is caught quickly
    ///    regardless of how that slider is set. This is the one that
    ///    matters concretely for distance-repeat too: if `onTouchEnded` is
    ///    ever missed while frames keep arriving with a stuck/phantom
    ///    touch whose reported centroid still wanders, ticks would
    ///    otherwise keep firing with nothing to clear
    ///    `pendingDistanceActions` short of the ceiling below.
    ///  - a hard time ceiling, because `isTouching` itself depends on
    ///    `process()` ever receiving a fresh zero-touch frame — if a real
    ///    multitouch driver quirk stalls frame delivery entirely for a
    ///    long stationary hold, neither `onTouchEnded` nor `isTouching` can
    ///    update, and only an unconditional ceiling guarantees this ever
    ///    stops. Doesn't really apply to distance-repeat the same way (no
    ///    `Timer` of its own — if frames stop, ticks stop, for free) but
    ///    kept as cheap insurance against sustained sensor-noise drift at
    ///    max sensitivity over a very long hold.
    private func armWatchdog() {
        guard repeatWatchdog == nil else { return }
        repeatSessionStart = Date()
        repeatWatchdog = Timer.scheduledTimer(withTimeInterval: repeatWatchdogInterval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if !self.gestureRecognizer.isTouching {
                self.stopRepeating(reason: "backstop (onTouchEnded never arrived)")
            } else if let start = self.repeatSessionStart, Date().timeIntervalSince(start) > self.maxRepeatDuration {
                self.stopRepeating(reason: "max duration reached (\(Int(self.maxRepeatDuration))s)")
            }
        }
    }

    private func stopRepeating(reason: String = "onTouchEnded") {
        pendingRepeatStart?.cancel()
        pendingRepeatStart = nil
        repeatWatchdog?.invalidate()
        repeatWatchdog = nil
        repeatSessionStart = nil
        let hadDistanceActions = !pendingDistanceActions.isEmpty
        pendingDistanceActions.removeAll()
        guard !repeatTimers.isEmpty || hadDistanceActions else { return }
        NSLog("InputCustomizer: repeat-while-held stopped (\(reason))")
        activityLog.log(.info, "Repeat while held stopped (\(reason))")
        repeatTimers.forEach { $0.invalidate() }
        repeatTimers.removeAll()
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
