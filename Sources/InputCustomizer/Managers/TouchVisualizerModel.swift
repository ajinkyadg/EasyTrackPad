import Combine
import Foundation

/// Shared live-touch state for the trackpad-gesture preview UI
/// (`TouchVisualizerView`, embedded in `RuleFormView`'s gesture picker).
/// `TrackpadManager` publishes into this on the main thread — but only
/// while `isActive` is true. The visualizer is opt-in specifically so
/// normal (non-debugging) use never pays the cost of hopping every raw
/// touch frame (up to ~120Hz) to main just in case something might be
/// watching; that per-frame main-thread hop was the exact cause of a
/// real "laggy" report earlier in this app's development.
final class TouchVisualizerModel: ObservableObject {
    /// Reference-counted rather than a plain Bool: `TouchVisualizerView`
    /// can be torn down and rebuilt by SwiftUI while logically still on
    /// screen (e.g. the gesture Picker selection changing re-evaluates
    /// its conditional branch), and a new instance's `onAppear` isn't
    /// guaranteed to run before the old instance's `onDisappear`. With a
    /// plain Bool, that ordering could leave it stuck `false` — TrackpadManager
    /// then stops pushing fresh touches, and the view is left showing a
    /// stale last-known frame (a real symptom: a lingering touch dot with
    /// the status text simultaneously claiming nothing is touching).
    private var activeCount = 0
    var isActive: Bool { activeCount > 0 }

    @Published private(set) var touches: [MultitouchGestureEngine.Touch] = []
    @Published private(set) var lastGesture: Trigger.GestureKind?
    /// Whether `MultitouchGestureEngine` actually found a device and
    /// started at launch — `false` means the private MultitouchSupport
    /// framework has changed/disappeared on this macOS version, so
    /// finger-count swipe/tap/split-swipe rules won't fire. Surfaced in
    /// Preferences so this fails visibly instead of silently; pinch,
    /// rotate, mouse, and keyboard rules don't depend on it and are
    /// unaffected either way.
    @Published private(set) var isMultitouchAvailable = true

    func setMultitouchAvailable(_ available: Bool) {
        isMultitouchAvailable = available
    }

    func activate() { activeCount += 1 }
    func deactivate() { activeCount = max(0, activeCount - 1) }

    func update(touches: [MultitouchGestureEngine.Touch]) {
        self.touches = touches
    }

    /// Shows the recognized gesture and keeps it showing — no auto-clear
    /// timer. An earlier version cleared this after 1.5s, but that was
    /// often shorter than the time it takes to actually notice the
    /// result and move the mouse to "Use This Gesture", so the button
    /// would grey out before it could be clicked. Performing a new
    /// gesture simply overwrites this with the new one; `clearRecognized`
    /// is the explicit "try again" reset.
    func recognized(gesture: Trigger.GestureKind) {
        lastGesture = gesture
    }

    /// Explicit "try again" reset, so the user isn't stuck waiting out a
    /// timer (or re-performing a gesture) just to clear a mis-detected
    /// result before trying again.
    func clearRecognized() {
        lastGesture = nil
    }
}
