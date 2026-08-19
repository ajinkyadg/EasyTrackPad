import CoreGraphics
import Foundation
import os

/// Turns a stream of raw multitouch frames into `GestureKind` events
/// (N-finger swipes and taps). Pure logic with no framework dependency,
/// so it can be unit tested by feeding it synthetic frames — useful since
/// finger-count gestures can't be exercised without a real trackpad under
/// a real finger.
public final class GestureRecognizer {
    public var onGesture: ((GestureKind) -> Void)?
    /// Fires once when a touch that was tracked as a gesture actually
    /// lifts off (after the blip-tolerance grace period), regardless of
    /// whether it ended up matching a tap or a swipe. This is the signal
    /// `TrackpadManager` needs to stop a "repeat while held" timer for a
    /// swipe rule — `onGesture` only fires once per touch by design (see
    /// `hasFiredSwipeThisGesture`), so it can't double as an end-of-hold
    /// signal on its own.
    public var onTouchEnded: (() -> Void)?

    /// Cross-thread-safe snapshot of whether any finger is currently on
    /// the glass. `TrackpadManager`'s repeat-while-held timer reads this
    /// once per repeatInterval as a backstop in case a single
    /// `onTouchEnded` notification is ever missed or delayed — that's a
    /// much sparser read than `process()`'s up-to-120Hz write rate, so
    /// (unlike the plain-scalar "benign race" used for `sensitivity`
    /// below, which self-corrects within one frame either way) a stale
    /// read here isn't self-correcting and would mean the backstop
    /// silently fails at the one thing it exists to do. Needs a real
    /// lock, not a plain Bool.
    public var isTouching: Bool { touchingLock.withLock { $0 } }
    private let touchingLock = OSAllocatedUnfairLock(initialState: false)

    /// Cross-thread-safe snapshot of the last known centroid position
    /// (normalized 0...1) while at least one finger was touching. Read by
    /// `MouseManager` to gate corner-click rules — "was a finger resting
    /// near this corner when the physical click happened" — a rare,
    /// one-shot read triggered by a click event, not a per-frame one, so
    /// (same reasoning as `isTouching` above) it needs a real lock rather
    /// than a benign race.
    public var lastTouchPosition: CGPoint? { positionLock.withLock { $0 } }
    private let positionLock = OSAllocatedUnfairLock<CGPoint?>(initialState: nil)

    /// Verbose per-gesture NSLog output for diagnosing "nothing happens" /
    /// "misfiring" reports, since finger-count gestures can't be exercised
    /// except on real hardware. Off by default; flip to true when
    /// troubleshooting.
    public var debugLoggingEnabled = false

    /// Touch states MultitouchSupport reports as an actual finger on the
    /// glass (as opposed to hovering, starting, or lifting).
    private static let touchingStates: Set<Int32> = [3, 4]

    /// Rejects a multi-touch frame as a probable palm/heel-of-hand
    /// contact rather than genuinely separate fingers, if *any* two of
    /// its simultaneously-touching points are closer together than this
    /// (normalized 0...1 surface fraction) — checked across every pair,
    /// not just when exactly 2 are down, since a broad palm resting on
    /// the glass can get split by the driver's blob segmentation into
    /// anywhere from 2 to 5+ touch IDs from one contiguous contact area.
    /// `0` (the default) disables this entirely — every existing test
    /// leaves it unset. `TrackpadManager` sets this only on the
    /// trackpad's recognizer (not the Magic Mouse's, whose much smaller
    /// shell means genuine multi-finger touches there are naturally
    /// closer together, and which isn't exposed to stray palm contact
    /// from typing anyway). The exact value is an estimate (roughly 1cm
    /// on a ~13cm-wide trackpad), not measured against real palm-touch
    /// captures.
    public var minimumFingerSeparation: CGFloat = 0

    /// User-facing tuning knob: 0 (least sensitive — requires a larger,
    /// more deliberate swipe, and stricter stillness for a tap) to 1
    /// (most sensitive — small movements trigger easily). Defaults to
    /// 0.5, which reproduces the original fixed thresholds exactly.
    public var sensitivity: Double = 0.5
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
    /// Used for classifying anchor-vs-mover *during* a live split-swipe,
    /// where staying tight matters (too generous and a real two-finger
    /// swipe's slower finger could get misread as "anchored").
    private var splitAnchorMaxMovement: CGFloat { tapMaxMovement }
    /// Separate, more forgiving anchor tolerance used only when resolving
    /// a split *tap* (`resolvePendingSplitTap`) — a held anchor finger
    /// measurably drifts more on a Magic Mouse's small, curved shell over
    /// the course of a lift-and-reland round trip than `splitAnchorMaxMovement`
    /// allows. Doesn't affect `splitSwipeKind`'s anchor/mover classification.
    private var splitTapAnchorMaxMovement: CGFloat { splitAnchorMaxMovement * 1.8 }
    /// Separate, more forgiving window than `tapMaxDuration` for the
    /// "lift, then land again" round trip a split tap resolves over —
    /// reuses `doubleTapMaxInterval`'s already-tuned, comfortable human
    /// timing rather than the much tighter single-tap duration, since
    /// deliberately isolating one finger while re-tapping the other takes
    /// longer than an ordinary tap.
    private var splitTapMaxInterval: TimeInterval { doubleTapMaxInterval }

    /// A candidate "anchor + tap" gesture in progress: one of the two
    /// fingers from `splitReferences` has just lifted off (touch count
    /// dropped 2 -> 1) while the other, `anchor`, is presumed to still be
    /// down. Armed the instant that drop happens; resolved (fired or
    /// discarded) the next time the touch count changes again. `nil`
    /// whenever there's no such pending departure to resolve.
    private struct PendingSplitTap {
        let anchor: FingerReference
        let departedFingerWasLeft: Bool
        let since: TimeInterval
    }
    private var pendingSplitTap: PendingSplitTap?

    public init() {}

    public func process(_ frame: MultitouchGestureEngine.Frame) {
        var touching = frame.touches.filter { Self.touchingStates.contains($0.state) }
        if touching.count >= 2, minimumFingerSeparation > 0, Self.hasImplausiblyClosePair(touching, minimumSeparation: minimumFingerSeparation) {
            // At least one pair of simultaneously-touching points is too
            // close together to plausibly be two separate fingers — treat
            // this whole frame as if nothing relevant is touching at all,
            // rather than as an N-finger gesture candidate. The existing
            // blip-tolerance grace period (`endGracePeriod`) already
            // absorbs an isolated frame like this without disturbing a
            // real gesture in progress, the same way it already absorbs
            // any other transient zero-touch report.
            touching = []
        }
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
                pendingSplitTap = nil
            } else if count != activeFingerCount {
                // A finger joined or left since the last frame — rebase
                // rather than measure "travel" across the count change.
                // Before rebasing, see whether this change resolves (or
                // starts) a pending "anchor + tap": a departed finger
                // landing again shortly, while the other stayed put.
                if let kind = resolvePendingSplitTap(touching: touching, timestamp: frame.timestamp) {
                    // A tap can repeat (unlike a swipe, which only fires
                    // once per hold) — hasFiredSwipeThisGesture is
                    // deliberately left untouched so the anchor+tap can
                    // fire again on a later re-tap, and so it doesn't
                    // block an ordinary/split swipe later in this hold.
                    lastTapTime = nil
                    lastTapCentroid = nil
                    lastTapFingerCount = nil
                    if debugLoggingEnabled { NSLog("InputCustomizer: recognized split tap \(kind.rawValue)") }
                    onGesture?(kind)
                }
                if activeFingerCount == 2, count == 1, let onlyTouch = touching.first,
                   let survivor = splitReferences[onlyTouch.id] {
                    pendingSplitTap = PendingSplitTap(anchor: survivor, departedFingerWasLeft: !survivor.isLeft, since: frame.timestamp)
                } else {
                    pendingSplitTap = nil
                }
                referenceCentroid = centroid
                maxFingerCountThisGesture = max(maxFingerCountThisGesture, count)
                splitReferences = Self.splitReferences(for: touching)
            } else if !hasFiredSwipeThisGesture, let ref = referenceCentroid {
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
                    if hypot(dx, dy) > swipeDistanceThreshold, let kind = Self.swipeKind(dx: dx, dy: dy, fingerCount: count) {
                        hasFiredSwipeThisGesture = true
                        // A swipe means this contact was never a tap —
                        // don't let a later tap spuriously pair with
                        // whatever the last real tap was.
                        lastTapTime = nil
                        lastTapCentroid = nil
                        lastTapFingerCount = nil
                        if debugLoggingEnabled { NSLog("InputCustomizer: recognized swipe \(kind.rawValue)") }
                        onGesture?(kind)
                    }
                }
            }
            lastCentroid = centroid
            activeFingerCount = count
            touchingLock.withLock { $0 = true }
            positionLock.withLock { $0 = centroid }
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
            pendingSplitTap = nil
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

    private func centroid(of touches: [MultitouchGestureEngine.Touch]) -> CGPoint {
        let sum = touches.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y) }
        let n = CGFloat(touches.count)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    /// `true` if any two of `touches` sit closer together than
    /// `minimumSeparation` — see `minimumFingerSeparation`'s doc comment.
    /// At most 5 simultaneous touches in practice, so the full O(n²) pair
    /// check (10 pairs at 5 touches) is trivial regardless of running at
    /// up to ~120Hz.
    private static func hasImplausiblyClosePair(_ touches: [MultitouchGestureEngine.Touch], minimumSeparation: CGFloat) -> Bool {
        for i in touches.indices {
            for j in touches.indices where j > i {
                let a = touches[i].position, b = touches[j].position
                if hypot(a.x - b.x, a.y - b.y) < minimumSeparation { return true }
            }
        }
        return false
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

    /// Resolves a pending "anchor + tap": `pendingSplitTap` was armed the
    /// moment one of two down fingers lifted, recording the other as the
    /// presumed-still-down anchor. If the touch count is back to 2 soon
    /// enough (`splitTapMaxInterval`) and one of the two currently-touching
    /// fingers is still close to where the anchor started
    /// (`splitTapAnchorMaxMovement`), the departed finger counts as having
    /// tapped. Doesn't care which id the second finger has when it lands —
    /// a lifted-and-relanded contact isn't guaranteed to keep the same
    /// MultitouchSupport identifier.
    private func resolvePendingSplitTap(touching: [MultitouchGestureEngine.Touch], timestamp: TimeInterval) -> GestureKind? {
        guard let pending = pendingSplitTap, touching.count == 2 else { return nil }
        guard timestamp - pending.since < splitTapMaxInterval else { return nil }
        let anchorStillPresent = touching.contains {
            hypot($0.position.x - pending.anchor.position.x, $0.position.y - pending.anchor.position.y) < splitTapAnchorMaxMovement
        }
        guard anchorStillPresent else { return nil }
        let side = pending.departedFingerWasLeft ? "Left" : "Right"
        return GestureKind(rawValue: "twoFinger\(side)Tap")
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
    private func splitSwipeKind(touching: [MultitouchGestureEngine.Touch]) -> GestureKind? {
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
        return GestureKind(rawValue: "twoFinger\(side)Swipe\(vertical)")
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
    /// of `dy > 0` meaning "up" — do NOT flip the sign of `dy` here to
    /// "correct for" screen coordinates being y-down; that would silently
    /// invert Up and Down.
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

    private static func swipeKind(dx: CGFloat, dy: CGFloat, fingerCount: Int) -> GestureKind? {
        guard let countWord = fingerCountWords[fingerCount] else { return nil }
        let directionWord = direction(dx: dx, dy: dy).word
        return GestureKind(rawValue: "\(countWord)FingerSwipe\(directionWord)")
    }

    private static func tapKind(fingerCount: Int) -> GestureKind? {
        guard let countWord = fingerCountWords[fingerCount] else { return nil }
        return GestureKind(rawValue: "\(countWord)FingerTap")
    }

    private static func doubleTapKind(fingerCount: Int) -> GestureKind? {
        guard let countWord = fingerCountWords[fingerCount] else { return nil }
        return GestureKind(rawValue: "\(countWord)FingerDoubleTap")
    }
}
