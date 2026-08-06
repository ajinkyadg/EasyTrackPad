import Cocoa

/// Listens for trackpad gestures using AppKit's public NSEvent monitoring
/// (swipe/magnify/rotate). This deliberately avoids the private
/// MultitouchSupport.framework: it's less powerful (no raw finger-count
/// taps out of the box) but won't break across macOS versions or risk
/// App Store / notarization issues. See README "Trackpad gestures" for
/// how to extend this with raw multitouch data later if you need it.
final class TrackpadManager {
    private let settingsStore: SettingsStore
    private var monitors: [Any] = []

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        let swipe = NSEvent.addGlobalMonitorForEvents(matching: .swipe) { [weak self] event in
            self?.handleSwipe(event)
        }
        let magnify = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { [weak self] event in
            self?.handleMagnify(event)
        }
        let rotate = NSEvent.addGlobalMonitorForEvents(matching: .rotate) { [weak self] event in
            self?.handleRotate(event)
        }
        monitors = [swipe, magnify, rotate].compactMap { $0 }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func handleSwipe(_ event: NSEvent) {
        let kind: Trigger.GestureKind
        switch (event.deltaX, event.deltaY) {
        case let (dx, _) where dx > 0: kind = .swipeLeft
        case let (dx, _) where dx < 0: kind = .swipeRight
        case let (_, dy) where dy > 0: kind = .swipeUp
        default: kind = .swipeDown
        }
        fire(gesture: kind)
    }

    private func handleMagnify(_ event: NSEvent) {
        fire(gesture: event.magnification > 0 ? .pinchOut : .pinchIn)
    }

    private func handleRotate(_ event: NSEvent) {
        fire(gesture: event.rotation > 0 ? .rotateCounterClockwise : .rotateClockwise)
    }

    private func fire(gesture: Trigger.GestureKind) {
        for rule in settingsStore.rules(for: .trackpad) {
            guard case let .trackpadGesture(ruleGesture) = rule.trigger, ruleGesture == gesture else { continue }
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
        case .remapToKey, .none:
            break
        }
    }
}
