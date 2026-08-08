import CMultitouchSupport
import CoreGraphics
import Foundation

/// Thin Swift wrapper around the private MultitouchSupport.framework C API
/// (see Sources/CMultitouchSupport). Delivers raw per-finger touch frames;
/// all gesture interpretation (finger counts, swipe direction, taps) lives
/// in `GestureRecognizer`, which is plain logic and testable without a
/// real trackpad.
final class MultitouchGestureEngine {
    struct Touch {
        let id: Int32
        /// Normalized 0...1 position over the trackpad surface.
        let position: CGPoint
        let state: Int32
    }

    struct Frame {
        let touches: [Touch]
        let timestamp: TimeInterval
    }

    /// The C callback has no userInfo/refcon parameter, so it can't capture
    /// `self` — route frames through this single static hook instead. Only
    /// one engine is ever active at a time (owned by TrackpadManager).
    fileprivate static var current: MultitouchGestureEngine?

    /// Called on whatever background thread MultitouchSupport delivers
    /// frames on (not main) — frames arrive at up to ~120Hz while
    /// touching, and hopping to main for every single one made the whole
    /// app (and perceptibly, the system) feel laggy. `GestureRecognizer`'s
    /// state is only ever touched from this callback, so staying off-main
    /// here is safe; callers must dispatch to main themselves before
    /// touching UI or posting synthetic events from `onGesture`.
    var onFrame: ((Frame) -> Void)?

    private var device: MTDeviceRef?

    /// Returns whether a multitouch device was actually found and started —
    /// `false` means the private MultitouchSupport.framework has changed
    /// or disappeared on this macOS version (an accepted, real risk of
    /// depending on it; see README). Callers use this to degrade
    /// gracefully: finger-count swipe/tap detection needs this, but
    /// pinch/rotate (public `NSEvent` monitors) and keyboard/mouse
    /// remapping (public `CGEventTap`) don't depend on this at all and
    /// keep working regardless.
    @discardableResult
    func start() -> Bool {
        guard let device = MTDeviceCreateDefault() else {
            NSLog("InputCustomizer: MTDeviceCreateDefault() returned nil — no multitouch device found, or MultitouchSupport.framework is unavailable on this macOS version. Trackpad swipe/tap gestures will not fire; pinch, rotate, mouse, and keyboard rules are unaffected.")
            return false
        }
        NSLog("InputCustomizer: multitouch device created, starting callback registration")
        self.device = device
        MultitouchGestureEngine.current = self

        MTRegisterContactFrameCallback(device) { _, touchesPtr, numTouches, timestamp, _ in
            guard let engine = MultitouchGestureEngine.current, let touchesPtr else { return 0 }
            var touches: [Touch] = []
            touches.reserveCapacity(Int(numTouches))
            for i in 0..<Int(numTouches) {
                let raw = touchesPtr[i]
                touches.append(Touch(
                    id: raw.identifier,
                    position: CGPoint(x: CGFloat(raw.normalizedVector.position.x), y: CGFloat(raw.normalizedVector.position.y)),
                    state: raw.state
                ))
            }
            let frame = Frame(touches: touches, timestamp: timestamp)
            engine.onFrame?(frame)
            return 0
        }
        MTDeviceStart(device, 0)
        NSLog("InputCustomizer: MTDeviceStart called")
        return true
    }

    func stop() {
        guard let device else { return }
        // Not calling MTUnregisterContactFrameCallback: our callback is a
        // capture-less closure, so there's no stored function pointer value
        // to pass back, and passing the wrong one risks undefined behavior
        // in this undocumented API. Stopping + releasing the device is
        // sufficient to halt delivery.
        MTDeviceStop(device)
        MTDeviceRelease(device)
        self.device = nil
        MultitouchGestureEngine.current = nil
    }

    deinit {
        stop()
    }
}
