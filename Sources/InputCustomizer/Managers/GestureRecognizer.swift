import CoreGraphics
import Foundation

/// Turns a stream of raw multitouch frames into `Trigger.GestureKind`
/// events (N-finger swipes and taps). Pure logic with no framework
/// dependency, so it can be unit tested by feeding it synthetic frames —
/// useful since finger-count gestures can't be exercised without a real
/// trackpad under a real finger.
final class GestureRecognizer {
    var onGesture: ((Trigger.GestureKind) -> Void)?

    /// Verbose per-gesture NSLog output for diagnosing "nothing happens" /
    /// "misfiring" reports, since finger-count gestures can't be exercised
    /// except on real hardware. Off by default; flip to true when
    /// troubleshooting (see README's Trackpad gestures section).
    var debugLoggingEnabled = false

    /// Touch states MultitouchSupport reports as an actual finger on the
    /// glass (as opposed to hovering, starting, or lifting).
    private static let touchingStates: Set<Int32> = [3, 4]

    /// User-facing tuning knob: 0 (least sensitive — requires a larger,
    /// more deliberate swipe, and stricter stillness for a tap) to 1
    /// (most sensitive — small movements trigger easily). Defaults to
    /// 0.5, which reproduces the original fixed thresholds exactly.
    var sensitivity: Double = 0.5
    private var clampedSensitivity: Double { min(max(sensitivity, 0), 1) }

    /// Minimum centroid travel (as a fraction of the trackpad surface)
    /// before a gesture counts as a swipe rather than noise. Ranges from
    /// 0.13 (sensitivity 0) to 0.03 (sensitivity 1).
    private var swipeDistanceThreshold: CGFloat { CGFloat(0.13 - clampedSensitivity * 0.10) }
    /// Above this much total travel, a short gesture counts as a drag
    /// rather than a tap. Ranges from 0.015 (sensitivity 0) to 0.035
    /// (sensitivity 1) — more sensitive tolerates more wobble in a tap.
    private var tapMaxMovement: CGFloat { CGFloat(0.015 + clampedSensitivity * 0.02) }
    private let tapMaxDuration: TimeInterval = 0.2
    /// Real touch data is noisy: a frame or two mid-swipe can transiently
    /// report zero touching fingers even though the hand never left the
    /// glass. Without tolerance for that, one continuous physical gesture
    /// gets read as "end, then a brand-new gesture" and can fire twice.
    /// Zero-touch frames within this window are treated as a blip and
    /// bridged over rather than ending the gesture.
    private let endGracePeriod: TimeInterval = 0.03

    private var activeFingerCount = 0
    /// Baseline centroid that swipe travel is measured against. Rebased
    /// every time the finger count changes mid-gesture (see `process`) —
    /// fingers land on the glass staggered by a few ms, not all at once,
    /// so without rebasing, the centroid jump from "1 finger" to "3
    /// fingers averaged" reads as a big instant "swipe" that never
    /// actually happened.
    private var referenceCentroid: CGPoint?
    private var lastCentroid: CGPoint?
    /// From the very first touch — used for tap duration, which should
    /// span the whole contact, not just the post-rebase window.
    private var gestureStartTime: TimeInterval?
    private var maxFingerCountThisGesture = 0
    private var hasFiredSwipeThisGesture = false
    private var pendingEndSince: TimeInterval?

    func process(_ frame: MultitouchGestureEngine.Frame) {
        let touching = frame.touches.filter { Self.touchingStates.contains($0.state) }
        let count = touching.count

        if count > 0 {
            pendingEndSince = nil // touches are back; any pending end was just a blip
            let centroid = centroid(of: touching)
            if activeFingerCount == 0 {
                if debugLoggingEnabled { NSLog("InputCustomizer: gesture start, \(count) finger(s)") }
                referenceCentroid = centroid
                gestureStartTime = frame.timestamp
                maxFingerCountThisGesture = count
                hasFiredSwipeThisGesture = false
            } else if count != activeFingerCount {
                // A finger joined or left since the last frame — rebase
                // rather than measure "travel" across the count change.
                referenceCentroid = centroid
                maxFingerCountThisGesture = max(maxFingerCountThisGesture, count)
            } else {
                if !hasFiredSwipeThisGesture, let ref = referenceCentroid {
                    let dx = centroid.x - ref.x
                    let dy = centroid.y - ref.y
                    if max(abs(dx), abs(dy)) > swipeDistanceThreshold,
                       let kind = Self.swipeKind(dx: dx, dy: dy, fingerCount: count) {
                        hasFiredSwipeThisGesture = true
                        if debugLoggingEnabled { NSLog("InputCustomizer: recognized swipe \(kind.rawValue)") }
                        onGesture?(kind)
                    }
                }
            }
            lastCentroid = centroid
            activeFingerCount = count
            return
        }

        guard activeFingerCount > 0 else { return }
        if pendingEndSince == nil {
            pendingEndSince = frame.timestamp
        }
        guard frame.timestamp - pendingEndSince! >= endGracePeriod else {
            return // still within the blip-tolerance window
        }

        defer {
            activeFingerCount = 0
            referenceCentroid = nil
            lastCentroid = nil
            gestureStartTime = nil
            maxFingerCountThisGesture = 0
            hasFiredSwipeThisGesture = false
            pendingEndSince = nil
        }
        guard !hasFiredSwipeThisGesture,
              let start = gestureStartTime,
              frame.timestamp - start < tapMaxDuration,
              let ref = referenceCentroid,
              let endCentroid = lastCentroid,
              hypot(endCentroid.x - ref.x, endCentroid.y - ref.y) < tapMaxMovement,
              let kind = Self.tapKind(fingerCount: maxFingerCountThisGesture) else {
            if debugLoggingEnabled, let start = gestureStartTime {
                NSLog("InputCustomizer: gesture ended without a match (maxFingers=\(maxFingerCountThisGesture), duration=\(frame.timestamp - start)s, firedSwipe=\(hasFiredSwipeThisGesture))")
            }
            return
        }
        if debugLoggingEnabled { NSLog("InputCustomizer: recognized tap \(kind.rawValue)") }
        onGesture?(kind)
    }

    private func centroid(of touches: [MultitouchGestureEngine.Touch]) -> CGPoint {
        let sum = touches.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y) }
        let n = CGFloat(touches.count)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    private static func swipeKind(dx: CGFloat, dy: CGFloat, fingerCount: Int) -> Trigger.GestureKind? {
        let horizontal = abs(dx) > abs(dy)
        switch fingerCount {
        case 2:
            if horizontal { return dx > 0 ? .twoFingerSwipeRight : .twoFingerSwipeLeft }
            return dy > 0 ? .twoFingerSwipeUp : .twoFingerSwipeDown
        case 3:
            if horizontal { return dx > 0 ? .threeFingerSwipeRight : .threeFingerSwipeLeft }
            return dy > 0 ? .threeFingerSwipeUp : .threeFingerSwipeDown
        case 4:
            if horizontal { return dx > 0 ? .fourFingerSwipeRight : .fourFingerSwipeLeft }
            return dy > 0 ? .fourFingerSwipeUp : .fourFingerSwipeDown
        default:
            return nil
        }
    }

    private static func tapKind(fingerCount: Int) -> Trigger.GestureKind? {
        switch fingerCount {
        case 2: return .twoFingerTap
        case 3: return .threeFingerTap
        case 4: return .fourFingerTap
        case 5: return .fiveFingerTap
        default: return nil
        }
    }
}
