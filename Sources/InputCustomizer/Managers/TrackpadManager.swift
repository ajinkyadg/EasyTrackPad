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
///   swipes, 2-5-finger taps) possible.
/// - Pinch/rotate stay on AppKit's public `NSEvent` gesture monitors:
///   they're inherently two-finger gestures already, so the extra
///   complexity of computing scale/angle from raw touches ourselves
///   wouldn't buy anything. Only meaningful for `.trackpad` — Magic
///   Mouse has no OS-level pinch/rotate gesture at all.
///
/// Runs the built-in trackpad and an external Magic Mouse *simultaneously*
/// — one `MultitouchGestureEngine`/`GestureRecognizer` pair per device,
/// each bound to its own physical device's IOService via
/// `MTDeviceCreateFromService` (see that class's doc comment).
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
    /// versa, since both can be mid-gesture at the same time.
    private var trackpadRepeatSession: RepeatSession!
    private var magicMouseRepeatSession: RepeatSession!

    private var cancellables: Set<AnyCancellable> = []

    /// Last known finger position on the *trackpad* surface — `MouseManager`
    /// reads this to gate corner-click rules, which only ever apply to
    /// `.trackpad`. See `GestureRecognizer.lastTouchPosition`'s doc
    /// comment for the thread-safety reasoning.
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
            TrackpadManager.logFingerDistanceForCalibration(frame)
            self?.trackpadRecognizer.process(frame)
            self?.publishToVisualizer(frame, device: .trackpad)
        }
        magicMouseEngine.onFrame = { [weak self] frame in
            self?.magicMouseRecognizer.process(frame)
            self?.publishToVisualizer(frame, device: .magicMouse)
        }

        // Applies the Preferences sensitivity slider live, no restart
        // needed — shared across both devices rather than tuned
        // separately.
        settingsStore.$gestureSensitivity
            .sink { [weak self] value in
                self?.trackpadRecognizer.sensitivity = value
                self?.magicMouseRecognizer.sensitivity = value
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
        // scalars; not worth a lock for this.
        guard visualizerModel.isActive, visualizerModel.previewDevice == device else { return }
        DispatchQueue.main.async { [weak self] in
            self?.visualizerModel.update(touches: frame.touches)
        }
    }

    private func wire(recognizer: GestureRecognizer, device: InputDevice, repeatSession: RepeatSession) {
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

    // MARK: - TEMPORARY: finger-distance calibration
    //
    // Figures out what unit MTTouch's `absoluteVector` is actually in, by
    // comparing it against `normalizedVector` while two fingers are a
    // physically-known distance apart on the trackpad. Once that's
    // confirmed, this becomes the basis for a real mm-based proximity
    // threshold (e.g. "only fire this split-swipe/split-tap gesture when
    // the two fingers are within 5mm") — see GestureRecognizer's
    // `hasImplausiblyClosePair`, which already does the equivalent check
    // in normalized units for palm rejection, but normalized units alone
    // can't express a real "5mm" without knowing the exact trackpad's
    // physical width, which varies by Mac model.
    //
    // DELETE this whole method (and its call site in trackpadEngine.onFrame
    // above) once the unit is confirmed and a real threshold is wired up.
    private static var lastCalibrationLogTime: TimeInterval = 0

    private static func logFingerDistanceForCalibration(_ frame: MultitouchGestureEngine.Frame) {
        let touching = frame.touches.filter { $0.state == 3 || $0.state == 4 }
        guard touching.count == 2 else { return }
        guard frame.timestamp - lastCalibrationLogTime > 0.5 else { return } // throttle to 2/sec
        lastCalibrationLogTime = frame.timestamp

        let a = touching[0], b = touching[1]
        let normalizedDistance = hypot(a.position.x - b.position.x, a.position.y - b.position.y)
        let absoluteDistance = hypot(a.absolutePosition.x - b.absolutePosition.x, a.absolutePosition.y - b.absolutePosition.y)
        NSLog("InputCustomizer: [calibration] 2 fingers — normalized distance=\(normalizedDistance), absolute distance=\(absoluteDistance)")
    }
}

/// Owns "repeat while held" state (timer + watchdog) for exactly one
/// device's `GestureRecognizer` — see `TrackpadManager`'s
/// `trackpadRepeatSession`/`magicMouseRepeatSession`. Pulled out of
/// `TrackpadManager` itself specifically so this state is per-device
/// rather than one shared set of properties implicitly assuming only one
/// touch session can ever be active — with the trackpad and a Magic
/// Mouse both live at once, a finger can genuinely be down on both
/// surfaces at the same time.
private final class RepeatSession {
    private let settingsStore: SettingsStore
    private let activityLog: ActivityLog
    private let label: String
    /// Cross-thread-safe "is this device's recognizer still touching" —
    /// used by the watchdog backstop, not the primary stop path.
    private let isTouching: () -> Bool
    private let apply: (Action) -> Void

    private var repeatTimers: [Timer] = []
    private var pendingRepeatStart: DispatchWorkItem?
    private var repeatWatchdog: Timer?
    private var repeatSessionStart: Date?
    private let repeatWatchdogInterval: TimeInterval = 0.1
    private let maxRepeatDuration: TimeInterval = 20
    private var repeatInterval: TimeInterval { settingsStore.repeatWhileHeldInterval }
    private var repeatDelay: TimeInterval { settingsStore.repeatWhileHeldDelay }

    init(settingsStore: SettingsStore, activityLog: ActivityLog, label: String, isTouching: @escaping () -> Bool, apply: @escaping (Action) -> Void) {
        self.settingsStore = settingsStore
        self.activityLog = activityLog
        self.label = label
        self.isTouching = isTouching
        self.apply = apply
    }

    /// Arms "repeat while held" for whichever matched rule(s) opted into
    /// it (see `CustomizationRule.repeatsWhileHeld`) — most rules won't
    /// have it set, so this is a no-op for them. Waits `repeatDelay`
    /// before actually starting, cancelably — if fingers lift before the
    /// delay elapses, `stopRepeating()` cancels this and repeating never
    /// begins.
    func startRepeating(_ matches: [CustomizationRule]) {
        stopRepeating()
        let repeatCandidates = matches.filter { $0.repeatsWhileHeld && $0.trigger.supportsRepeatWhileHeld }
        guard !repeatCandidates.isEmpty else { return }

        let actions = repeatCandidates.map(\.action)
        let delay = repeatDelay
        NSLog("InputCustomizer: [\(label)] repeat-while-held armed for \(actions.count) action(s), starting in \(delay)s")
        activityLog.log(.info, "Repeat while held armed (\(actions.count) action(s), starting in \(String(format: "%.2f", delay))s)")
        let workItem = DispatchWorkItem { [weak self] in self?.beginRepeating(actions) }
        pendingRepeatStart = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func beginRepeating(_ actions: [Action]) {
        pendingRepeatStart = nil
        NSLog("InputCustomizer: [\(label)] repeat-while-held started for \(actions.count) action(s)")
        activityLog.log(.info, "Repeat while held started (\(actions.count) action(s))")

        repeatTimers = actions.map { action in
            Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.apply(action)
            }
        }
        armWatchdog()
    }

    /// Two independent safety nets, separate from the primary stop path
    /// (`GestureRecognizer.onTouchEnded`):
    ///  - `isTouching`, checked at a fixed fast interval rather than the
    ///    user-tunable `repeatInterval`, so a missed/delayed
    ///    `onTouchEnded` notification is caught quickly regardless of how
    ///    that slider is set.
    ///  - a hard time ceiling, because `isTouching` itself depends on
    ///    `process()` ever receiving a fresh zero-touch frame — if a real
    ///    multitouch driver quirk stalls frame delivery entirely for a
    ///    long stationary hold, only an unconditional ceiling guarantees
    ///    this ever stops.
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
        pendingRepeatStart?.cancel()
        pendingRepeatStart = nil
        repeatWatchdog?.invalidate()
        repeatWatchdog = nil
        repeatSessionStart = nil
        guard !repeatTimers.isEmpty else { return }
        NSLog("InputCustomizer: [\(label)] repeat-while-held stopped (\(reason))")
        activityLog.log(.info, "Repeat while held stopped (\(reason))")
        repeatTimers.forEach { $0.invalidate() }
        repeatTimers.removeAll()
    }
}
