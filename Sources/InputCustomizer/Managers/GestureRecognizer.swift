import CoreGraphics
import Foundation
import os

/// Turns a stream of raw multitouch frames into `Trigger.GestureKind`
/// events (N-finger swipes and taps). Pure logic with no framework
/// dependency, so it can be unit tested by feeding it synthetic frames —
/// useful since finger-count gestures can't be exercised without a real
/// trackpad under a real finger.
final class GestureRecognizer {
    var onGesture: ((Trigger.GestureKind) -> Void)?
    /// Fires once when a touch that was tracked as a gesture actually
    /// lifts off (after the blip-tolerance grace period), regardless of
    /// whether it ended up matching a tap or a swipe. This is the signal
    /// `TrackpadManager` needs to stop a "repeat while held" timer for a
    /// swipe rule — `onGesture` only fires once per touch by design (see
    /// `hasFiredSwipeThisGesture`), so it can't double as an end-of-hold
    /// signal on its own.
    var onTouchEnded: (() -> Void)?

    /// Cross-thread-safe snapshot of whether any finger is currently on
    /// the glass. `TrackpadManager`'s repeat-while-held timer reads this
    /// once per repeatInterval (0.35s) as a backstop in case a single
    /// `onTouchEnded` notification is ever missed or delayed — that's a
    /// much sparser read than `process()`'s up-to-120Hz write rate, so
    /// (unlike the plain-scalar "benign race" used for `sensitivity`
    /// below, which self-corrects within one frame either way) a stale
    /// read here isn't self-correcting and would mean the backstop
    /// silently fails at the one thing it exists to do. Needs a real
    /// lock, not a plain Bool.
    var isTouching: Bool { touchingLock.withLock { $0 } }
    private let touchingLock = OSAllocatedUnfairLock(initialState: false)

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
    /// A second tap within this long, and this close to the first tap's
    /// position, upgrades to a double-tap. Both the single tap (fired
    /// immediately, as always) and the double-tap (fired in addition, on
    /// the second tap) end up firing — buffering every tap to check for a
    /// follow-up would add latency to normal taps, which isn't worth it.
    private let doubleTapMaxInterval: TimeInterval = 0.35
    private let doubleTapMaxDistance: CGFloat = 0.05

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

    private var lastTapTime: TimeInterval?
    private var lastTapCentroid: CGPoint?
    private var lastTapFingerCount: Int?

    /// Per-finger touch-down position + left/right role, tracked only
    /// while exactly 2 fingers are down — this is what
    /// `splitSwipeKind(touching:)` needs to tell "both fingers travelling
    /// together" (an ordinary `twoFingerSwipe*`, measured via
    /// `referenceCentroid` above) apart from "one finger anchored, the
    /// other actually swiping" (`.splitSwipe`, e.g. `twoFingerLeftSwipeUp`).
    /// Keyed by touch id so a finger's own displacement is measured
    /// against its own start, not the shared centroid. Repopulated
    /// whenever the touch set transitions to exactly 2 fingers (start or
    /// rebase), same as `referenceCentroid`; empty otherwise.
    private struct FingerReference {
        let position: CGPoint
        let isLeft: Bool
    }
    private var splitReferences: [Int32: FingerReference] = [:]
    /// How little the anchor finger is allowed to drift and still count
    /// as "held still" — reuses the tap-wobble tolerance since it's the
    /// same real-world question ("did this finger basically not move?").
    private var splitAnchorMaxMovement: CGFloat { tapMaxMovement }

    /// Which ordinary swipe kind is currently being distance-repeated,
    /// and the point its next increment of travel is measured from.
    /// Populated only when an ordinary (.swipe-category) swipe fires —
    /// never for `.splitSwipe`, which measures travel per-finger rather
    /// than via the shared centroid this baseline uses (see
    /// `Trigger.supportsRepeatByDistance`). `nil` before the first fire
    /// and after the gesture ends.
    private var distanceRepeatKind: Trigger.GestureKind?
    private var distanceRepeatBaseline: CGPoint?
    /// User-facing tuning knob for "repeat by distance" — same 0...1
    /// convention as `sensitivity`.
    var distanceRepeatSensitivity: Double = 0.5
    private var clampedDistanceRepeatSensitivity: Double { min(max(distanceRepeatSensitivity, 0), 1) }
    /// How much *additional* centroid travel counts as "one more repeat"
    /// once a swipe is already held, in the same units as
    /// `swipeDistanceThreshold`. Ranges from 0.12 (sensitivity 0) down to
    /// 0.02 (sensitivity 1) — deliberately a bit under
    /// `swipeDistanceThreshold`'s own range so the first repeat feels
    /// like a comparable amount of travel to the swipe that already fired.
    private var distancePerTick: CGFloat { CGFloat(0.12 - clampedDistanceRepeatSensitivity * 0.10) }
    /// Fires again for each `distancePerTick` of travel past the swipe
    /// that already fired — the "repeat while held" rules that opted into
    /// distance mode use this instead of a fixed timer to re-fire.
    var onSwipeTick: ((Trigger.GestureKind) -> Void)?
    /// One processed frame can occasionally cover several tick-widths at
    /// once (a fast real swipe, or a noise burst) — capped so a single
    /// noisy frame can't fire an unbounded number of real side effects
    /// (a shell command, a CGEvent post) at once. `emitDistanceTicks`
    /// advances the baseline by exactly one tick's worth each time rather
    /// than jumping to the current position, so a capped burst just
    /// defers the remainder to the next frame instead of losing it.
    private static let maxTicksPerFrame = 3

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
                splitReferences = Self.splitReferences(for: touching)
                distanceRepeatKind = nil
                distanceRepeatBaseline = nil
            } else if count != activeFingerCount {
                // A finger joined or left since the last frame — rebase
                // rather than measure "travel" across the count change.
                referenceCentroid = centroid
                maxFingerCountThisGesture = max(maxFingerCountThisGesture, count)
                splitReferences = Self.splitReferences(for: touching)
                if distanceRepeatKind != nil {
                    distanceRepeatBaseline = centroid
                }
            } else {
                if !hasFiredSwipeThisGesture, let ref = referenceCentroid {
                    if let kind = splitSwipeKind(touching: touching) {
                        hasFiredSwipeThisGesture = true
                        lastTapTime = nil
                        lastTapCentroid = nil
                        lastTapFingerCount = nil
                        if debugLoggingEnabled { NSLog("InputCustomizer: recognized split swipe \(kind.rawValue)") }
                        onGesture?(kind)
                    } else {
                        let dx = centroid.x - ref.x
                        let dy = centroid.y - ref.y
                        if hypot(dx, dy) > swipeDistanceThreshold,
                           let kind = Self.swipeKind(dx: dx, dy: dy, fingerCount: count) {
                            hasFiredSwipeThisGesture = true
                            // A swipe means this contact was never a tap —
                            // don't let a later tap spuriously pair with
                            // whatever the last real tap was.
                            lastTapTime = nil
                            lastTapCentroid = nil
                            lastTapFingerCount = nil
                            distanceRepeatKind = kind
                            distanceRepeatBaseline = centroid
                            if debugLoggingEnabled { NSLog("InputCustomizer: recognized swipe \(kind.rawValue)") }
                            onGesture?(kind)
                        }
                    }
                } else if let kind = distanceRepeatKind, distanceRepeatBaseline != nil {
                    emitDistanceTicks(kind: kind, centroid: centroid)
                }
            }
            lastCentroid = centroid
            activeFingerCount = count
            touchingLock.withLock { $0 = true }
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
            touchingLock.withLock { $0 = false }
            referenceCentroid = nil
            lastCentroid = nil
            gestureStartTime = nil
            maxFingerCountThisGesture = 0
            hasFiredSwipeThisGesture = false
            pendingEndSince = nil
            splitReferences = [:]
            distanceRepeatKind = nil
            distanceRepeatBaseline = nil
        }
        onTouchEnded?()
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
            // Not a tap (held too long, dragged too far, or an
            // unsupported finger count) — don't let a later tap
            // spuriously pair with an unrelated prior tap across this
            // non-tap gesture.
            lastTapTime = nil
            lastTapCentroid = nil
            lastTapFingerCount = nil
            return
        }
        if debugLoggingEnabled { NSLog("InputCustomizer: recognized tap \(kind.rawValue)") }
        onGesture?(kind)

        if let lastTime = lastTapTime, let lastFingerCount = lastTapFingerCount, let lastPos = lastTapCentroid,
           lastFingerCount == maxFingerCountThisGesture,
           frame.timestamp - lastTime < doubleTapMaxInterval,
           hypot(endCentroid.x - lastPos.x, endCentroid.y - lastPos.y) < doubleTapMaxDistance,
           let doubleKind = Self.doubleTapKind(fingerCount: maxFingerCountThisGesture) {
            if debugLoggingEnabled { NSLog("InputCustomizer: recognized double tap \(doubleKind.rawValue)") }
            onGesture?(doubleKind)
            // Consume the pair so a third quick tap starts fresh instead
            // of chaining into a second, incorrect double-tap.
            lastTapTime = nil
            lastTapCentroid = nil
            lastTapFingerCount = nil
        } else {
            lastTapTime = frame.timestamp
            lastTapCentroid = endCentroid
            lastTapFingerCount = maxFingerCountThisGesture
        }
    }

    /// Fires `onSwipeTick` once per full `distancePerTick` of travel
    /// accumulated since the last tick, advancing the baseline by exactly
    /// that much each time (not jumping straight to `centroid`) so a
    /// frame covering, say, 3.4 tick-widths emits 3 ticks now and keeps
    /// the leftover 0.4 as credit for the next frame — a scroll wheel
    /// doesn't lose fractional detents. Capped at `maxTicksPerFrame`
    /// (deferred, not dropped, thanks to the exact-advance above).
    /// Magnitude-only, not direction-gated: travel that reverses back
    /// past the baseline still ticks, matching how `swipeDistanceThreshold`/
    /// `tapMaxMovement` elsewhere in this file are magnitude-only too.
    private func emitDistanceTicks(kind: Trigger.GestureKind, centroid: CGPoint) {
        guard var baseline = distanceRepeatBaseline else { return }
        let perTick = distancePerTick
        for _ in 0..<Self.maxTicksPerFrame {
            let dx = centroid.x - baseline.x
            let dy = centroid.y - baseline.y
            let travel = hypot(dx, dy)
            guard travel >= perTick else { break }
            let scale = perTick / travel
            baseline = CGPoint(x: baseline.x + dx * scale, y: baseline.y + dy * scale)
            if debugLoggingEnabled { NSLog("InputCustomizer: distance-repeat tick \(kind.rawValue)") }
            onSwipeTick?(kind)
        }
        distanceRepeatBaseline = baseline
    }

    private func centroid(of touches: [MultitouchGestureEngine.Touch]) -> CGPoint {
        let sum = touches.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y) }
        let n = CGFloat(touches.count)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    /// Builds fresh left/right per-finger references when exactly 2
    /// fingers are down; empty otherwise (a 3rd finger, or dropping to 1,
    /// means "two fingers down" no longer holds, so `.splitSwipe` can't
    /// apply until the next rebase back to exactly 2).
    private static func splitReferences(for touching: [MultitouchGestureEngine.Touch]) -> [Int32: FingerReference] {
        guard touching.count == 2 else { return [:] }
        let sorted = touching.sorted { $0.position.x < $1.position.x }
        return [
            sorted[0].id: FingerReference(position: sorted[0].position, isLeft: true),
            sorted[1].id: FingerReference(position: sorted[1].position, isLeft: false)
        ]
    }

    /// Detects "2 fingers down, one stays put, the other swipes up/down"
    /// by measuring each finger's displacement from its own touch-down
    /// position (`splitReferences`) rather than the shared centroid —
    /// centroid travel alone can't tell "both fingers moved together" from
    /// "only one moved", since a single moving finger still shifts the
    /// average. Returns `nil` if there's no current anchor+mover pattern
    /// (both currently-touching ids must have a reference, one within
    /// `splitAnchorMaxMovement` and the other past `swipeDistanceThreshold`
    /// on a predominantly vertical path) — the caller falls back to the
    /// ordinary centroid-based `swipeKind` check in that case.
    private func splitSwipeKind(touching: [MultitouchGestureEngine.Touch]) -> Trigger.GestureKind? {
        guard touching.count == 2, splitReferences.count == 2 else { return nil }
        var anchor: FingerReference?
        var mover: (ref: FingerReference, dx: CGFloat, dy: CGFloat)?
        for touch in touching {
            guard let ref = splitReferences[touch.id] else { return nil }
            let dx = touch.position.x - ref.position.x
            let dy = touch.position.y - ref.position.y
            if hypot(dx, dy) < splitAnchorMaxMovement {
                anchor = ref
            } else {
                mover = (ref, dx, dy)
            }
        }
        guard anchor != nil, let mover, hypot(mover.dx, mover.dy) > swipeDistanceThreshold else { return nil }
        let direction = Self.direction(dx: mover.dx, dy: mover.dy)
        guard direction == .up || direction == .down else { return nil }
        let side = mover.ref.isLeft ? "Left" : "Right"
        let vertical = direction == .up ? "Up" : "Down"
        return Trigger.GestureKind(rawValue: "twoFinger\(side)Swipe\(vertical)")
    }

    /// 8 compass directions, ordered to match `Int((angle + 22.5) / 45) % 8`
    /// sector indexing below — index 0 is the sector centered on 0°
    /// (right), going counterclockwise.
    private enum Direction: Int, CaseIterable {
        case right, upRight, up, upLeft, left, downLeft, down, downRight

        var word: String {
            switch self {
            case .right: return "Right"
            case .upRight: return "UpRight"
            case .up: return "Up"
            case .upLeft: return "UpLeft"
            case .left: return "Left"
            case .downLeft: return "DownLeft"
            case .down: return "Down"
            case .downRight: return "DownRight"
            }
        }
    }

    private static let fingerCountWords: [Int: String] = [2: "two", 3: "three", 4: "four", 5: "five"]

    /// Classifies travel into one of 8 compass directions via the angle of
    /// motion. `atan2(dy, dx)` matches this codebase's existing convention
    /// of `dy > 0` meaning "up" (see `testTwoFingerSwipeUp`) — do NOT flip
    /// the sign of `dy` here to "correct for" screen coordinates being
    /// y-down; that would silently invert Up and Down.
    ///
    /// Only ever called after the caller has confirmed `hypot(dx, dy)` is
    /// above the swipe threshold, so the degenerate `dx == dy == 0` case
    /// (which `atan2` maps to 0°/"right") never actually reaches here.
    private static func direction(dx: CGFloat, dy: CGFloat) -> Direction {
        let degrees = atan2(dy, dx) * 180 / .pi
        let normalized = degrees < 0 ? degrees + 360 : degrees // [0, 360)
        let sectorIndex = Int((normalized + 22.5) / 45) % 8
        return Direction(rawValue: sectorIndex) ?? .right
    }

    private static func swipeKind(dx: CGFloat, dy: CGFloat, fingerCount: Int) -> Trigger.GestureKind? {
        guard let countWord = fingerCountWords[fingerCount] else { return nil }
        let directionWord = direction(dx: dx, dy: dy).word
        return Trigger.GestureKind(rawValue: "\(countWord)FingerSwipe\(directionWord)")
    }

    private static func tapKind(fingerCount: Int) -> Trigger.GestureKind? {
        guard let countWord = fingerCountWords[fingerCount] else { return nil }
        return Trigger.GestureKind(rawValue: "\(countWord)FingerTap")
    }

    private static func doubleTapKind(fingerCount: Int) -> Trigger.GestureKind? {
        guard let countWord = fingerCountWords[fingerCount] else { return nil }
        return Trigger.GestureKind(rawValue: "\(countWord)FingerDoubleTap")
    }
}
