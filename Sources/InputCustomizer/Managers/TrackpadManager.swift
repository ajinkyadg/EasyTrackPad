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
    private var monitors: [Any] = []
    private let multitouchEngine = MultitouchGestureEngine()
    private let gestureRecognizer = GestureRecognizer()
    private var cancellables: Set<AnyCancellable> = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
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
                self?.fire(gesture: kind)
            }
        }
        multitouchEngine.onFrame = { [weak self] frame in
            // Runs on MultitouchSupport's own callback thread, not main —
            // see MultitouchGestureEngine.onFrame's doc comment.
            self?.gestureRecognizer.process(frame)
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

        multitouchEngine.start()
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        multitouchEngine.stop()
    }

    private func handleMagnify(_ event: NSEvent) {
        fire(gesture: event.magnification > 0 ? .pinchOut : .pinchIn)
    }

    private func handleRotate(_ event: NSEvent) {
        fire(gesture: event.rotation > 0 ? .rotateCounterClockwise : .rotateClockwise)
    }

    private func fire(gesture: Trigger.GestureKind) {
        let matches = settingsStore.rules(for: .trackpad).filter {
            if case let .trackpadGesture(ruleGesture) = $0.trigger { return ruleGesture == gesture }
            return false
        }
        NSLog("InputCustomizer: trackpad gesture \(gesture.rawValue) matched \(matches.count) rule(s)")
        for rule in matches {
            apply(action: rule.action)
        }
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
        case let .remapToKey(keyCode, modifiers):
            ActionRunner.sendKeyPress(keyCode: keyCode, modifiers: modifiers)
        case .none:
            break
        }
    }
}
