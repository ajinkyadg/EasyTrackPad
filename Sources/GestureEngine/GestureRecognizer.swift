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
    /// once per repeatInterval (0.35s) as a backstop in case a single
    /// `onTouchEnded` notification is ever missed or delayed — that's a
    /// much sparser read than `process()`'s up-to-120Hz write rate, so
    /// (unlike the plain-scalar "benign race" used for `sensitivity`
    /// below, which self-corrects within one frame either way) a stale
    /// read here isn't self-correcting and would mean the backstop
    /// silently fails at the one thing it exists to do. Needs a real
    /// lock, not a plain Bool.
    public var isTouching: Bool { touchingLock.withLock { $0 } }
    private let touchingLock = OSAllocatedUnfairLock(initialState: false)

    // No centroid position is published for corner clicks any more: they
    // need per-finger landing history (see TouchSnapshotTracker in
    // CornerClick.swift), and a centroid gate fires on resting thumbs.

    /// Verbose per-gesture NSLog output for diagnosing "nothing happens" /
    /// "misfiring" reports, since finger-count gestures can't be exercised
    /// except on real hardware. Off by default; flip to true when
    /// troubleshooting (see README's Trackpad gestures section).
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
    /// That's a real, confirmed failure mode here: a resting palm
    /// segmented into 5 touch IDs while typing was triggering this app's
    /// own 5-finger tap/double-tap presets (Copy/Paste) — a check scoped
    /// to only the 2-finger case entirely missed it. `0` (the default)
    /// disables this entirely — every existing test leaves it unset.
    /// `TrackpadManager` sets this only on the trackpad's recognizer (not
    /// the Magic Mouse's, whose much smaller shell means genuine
    /// multi-finger touches there are naturally closer together, and
    /// which isn't exposed to stray palm contact from typing anyway).
    /// The exact value is an estimate (roughly 1cm on a ~13cm-wide
    /// trackpad), not measured against real palm-touch captures — same
    /// "reverse-engineered, tune if it misbehaves" caveat as this file's
    /// other geometry constants.
    public var minimumFingerSeparation: CGFloat = 0

    /// Real-world trackpad surface size, in millimeters — converts
    /// normalized touch-position deltas into actual physical distance for
    /// `maxSplitGestureFingerDistanceMM`. `nil` (the default) disables the
    /// proximity gate entirely, so a split-swipe/split-tap fires
    /// regardless of how far apart the two fingers started (today's
    /// behavior, and what every existing test still gets since none of
    /// them set this). Apple doesn't publish trackpad glass dimensions;
    /// `TrackpadManager` sets this from a physically-measured value
    /// (ruler, not a spec sheet) for the trackpad only — not Magic Mouse,
    /// whose shell is a very different size and shape.
    public var surfaceSizeMM: CGSize?

    /// Maximum distance apart (in mm, via `surfaceSizeMM`) the two
    /// fingers' touch-down positions can be for a split-swipe/split-tap
    /// (one anchored, the other swipes or re-taps) to be recognized at
    /// all — requires the fingers to have started genuinely close
    /// together, not just any two-finger-down posture. No minimum: any
    /// distance from fingers directly touching (0mm) up to this ceiling
    /// counts — a min floor was tried and dropped, since there's no real
    /// reason near-zero/overlapping contact should be treated as
    /// *invalid* rather than just "as close as it gets." Measured at
    /// touch-down, not held continuously — the swipe variant requires the
    /// mover to travel past its swipe threshold, which necessarily
    /// carries it away from the anchor, so a continuous closeness
    /// requirement would make the swipe case unsatisfiable by
    /// construction. Only takes effect when `surfaceSizeMM` is set.
    ///
    /// 35mm, not the originally-tried 5mm: two real fingertips pressed
    /// directly against each other still typically measure roughly one
    /// finger-width apart center-to-center rather than under 5mm —
    /// confirmed on real hardware, where a 5mm ceiling never fired even
    /// with fingers deliberately touching.
    public var maxSplitGestureFingerDistanceMM: CGFloat = 35

    /// Maximum distance apart (in mm, via `surfaceSizeMM`) any two of 3+
    /// simultaneously-touching fingers' touch-down positions can be for an
    /// ordinary N-finger swipe or tap (N >= 3) to be recognized at all —
    /// requires the whole set to have landed as one genuine cluster, not
    /// just any N-finger-down posture. Doesn't apply to 2-finger gestures:
    /// plain two-finger swipes/taps have no cluster requirement, and
    /// split-swipe/split-tap use `maxSplitGestureFingerDistanceMM` instead.
    /// Only takes effect when `surfaceSizeMM` is set. 70mm is an estimate,
    /// not yet confirmed against real hardware the way the two-finger
    /// gate's 35mm was — tune it using `onMultiFingerGestureGated`'s
    /// reported distances the same way.
    public var maxMultiFingerGestureSpreadMM: CGFloat = 70

    /// Fires with the finger count and the actual measured max pairwise
    /// distance (mm) whenever an N-finger (N >= 3) gesture got suppressed
    /// for exceeding `maxMultiFingerGestureSpreadMM` — lets `TrackpadManager`
    /// surface real numbers in its Console view instead of guessing at what
    /// ceiling is realistic. Diagnostic only; never fires when
    /// `surfaceSizeMM` is unset.
    public var onMultiFingerGestureGated: ((Int, CGFloat) -> Void)?

    /// User-facing tuning knob: 0 (least sensitive — requires a larger,
    /// more deliberate swipe, and stricter stillness for a tap) to 1
    /// (most sensitive — small movements trigger easily). Defaults to
    /// 0.5, which reproduces the original fixed thresholds exactly. This
    /// is the *global default* — see `sensitivityOverride` for the
    /// per-gesture-kind knob that takes priority over it.
    public var sensitivity: Double = 0.5
    /// Consulted before falling back to `sensitivity` — returns `nil` to
    /// mean "no override for this kind, use the global default".
    /// `TrackpadManager` sets this to look up a matching rule's own
    /// `CustomizationRule.sensitivityOverride`, if any. Left `nil` (the
    /// default), every kind just uses `sensitivity` — which is also
    /// exactly what happens in every test in this file, none of which
    /// set this closure.
    public var sensitivityOverride: ((GestureKind) -> Double?)?
    private func clampedSensitivity(for kind: GestureKind) -> Double {
        min(max(sensitivityOverride?(kind) ?? sensitivity, 0), 1)
    }

    /// Minimum centroid travel (as a fraction of the trackpad surface)
    /// before a gesture counts as a swipe rather than noise. Ranges from
    /// 0.13 (sensitivity 0) to 0.03 (sensitivity 1).
    private func swipeDistanceThreshold(for kind: GestureKind) -> CGFloat {
        CGFloat(0.13 - clampedSensitivity(for: kind) * 0.10)
    }
    /// The most permissive `swipeDistanceThreshold` could ever be (at
    /// sensitivity 1, override or not) — used as a cheap pre-filter so
    /// `process()` doesn't need to compute a candidate kind (and consult
    /// `sensitivityOverride`) on every single frame of a still-stationary
    /// touch, only once travel is at least plausibly enough to matter.
    private static let minPossibleSwipeDistanceThreshold: CGFloat = 0.03
    /// Above this much total travel, a short gesture counts as a drag
    /// rather than a tap. Ranges from 0.015 (sensitivity 0) to 0.035
    /// (sensitivity 1) — more sensitive tolerates more wobble in a tap.
    private func tapMaxMovement(for kind: GestureKind) -> CGFloat {
        CGFloat(0.015 + clampedSensitivity(for: kind) * 0.02)
    }
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

    /// How close to the bottom edge of the surface (0 = bottom, 1 = top,
    /// same convention `MouseCorner` uses) counts as "about to run out of
    /// physical room to keep scrolling" for `.twoFingerFastScrollToBottomEdge`.
    private static let fastScrollEdgeZone: CGFloat = 0.15
    /// How fast (normalized surface units per second) the fingers need to
    /// be moving downward, while already inside that edge zone, to count
    /// as "actively trying to keep scrolling" rather than just resting
    /// near the edge. An estimate, not measured against real usage —
    /// tune if this over- or under-fires.
    private static let fastScrollVelocityThreshold: CGFloat = 1.2

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
    /// Fires at most once per touch-down session, independent of
    /// `hasFiredSwipeThisGesture` — an ordinary 2-finger scroll is never
    /// treated as a swipe by this recognizer at all (macOS handles it
    /// natively), so this needs its own one-shot flag rather than piggy-
    /// backing on the swipe one. Reset alongside it wherever a gesture
    /// session starts or ends.
    private var hasFiredFastScrollEdgeThisGesture = false
    /// Previous frame's timestamp, used only to compute instantaneous
    /// vertical velocity for `.twoFingerFastScrollToBottomEdge` — plain
    /// frame-to-frame delta rather than a smoothed window, consistent
    /// with how `emitDistanceTicks` elsewhere in this file also just
    /// measures frame-to-frame travel.
    private var lastFrameTimestamp: TimeInterval?
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

    /// Per-finger touch-down position, tracked for every currently-touching
    /// finger (any count) — what `fingersClusteredCloseEnough(count:)` needs
    /// to check an N-finger (N >= 3) gesture's spread. Repopulated on every
    /// start/rebase, same as `splitReferences`.
    private var clusterReferences: [Int32: CGPoint] = [:]
    /// Whether the fingers were clustered close enough
    /// (`fingersClusteredCloseEnough`) at the moment this gesture's finger
    /// count last reached a new peak. Unlike the live swipe check (which can
    /// re-evaluate `clusterReferences` directly, since it only runs while
    /// the touch set is unchanged since the last rebase), a final tap is
    /// classified by `maxFingerCountThisGesture`, which may no longer match
    /// whatever's currently in `clusterReferences` if fingers lifted off one
    /// at a time — so the result has to be captured at the moment that peak
    /// actually happened and carried forward. Reset to `true` at gesture
    /// start.
    private var peakClusterCloseEnough = true
    /// Global-only sensitivity (never a per-kind override) — needed for
    /// thresholds that have to resolve *before* any specific `GestureKind`
    /// is known, like classifying which of two fingers is the anchor
    /// during a live split-swipe. A specific rule's kind (and thus its
    /// override) only becomes knowable once that classification, and the
    /// resulting direction, are already decided.
    private var clampedGlobalSensitivity: Double { min(max(sensitivity, 0), 1) }
    /// How little the anchor finger is allowed to drift and still count
    /// as "held still" — same formula as `tapMaxMovement` (the same
    /// real-world question, "did this finger basically not move?"), but
    /// pinned to the global sensitivity — see `clampedGlobalSensitivity`.
    /// Used for classifying anchor-vs-mover *during* a live split-swipe,
    /// where staying tight matters (too generous and a real two-finger
    /// swipe's slower finger could get misread as "anchored").
    private var splitAnchorMaxMovement: CGFloat { CGFloat(0.015 + clampedGlobalSensitivity * 0.02) }
    /// Separate, more forgiving anchor tolerance used only when resolving
    /// a split *tap* (`resolvePendingSplitTap`) — a held anchor finger
    /// measurably drifts more on a Magic Mouse's small, curved shell over
    /// the course of a lift-and-reland round trip than `splitAnchorMaxMovement`
    /// allows (confirmed against real capture data), which was silently
    /// dropping legitimate first-attempt anchor+tap gestures. Doesn't
    /// affect `splitSwipeKind`'s anchor/mover classification.
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
        /// Whether the two fingers started close enough together (per
        /// `surfaceSizeMM`/`maxSplitGestureFingerDistanceMM`) to be
        /// eligible at all — computed once, when this is armed, from the
        /// full two-finger `splitReferences` that existed at that moment
        /// (by the time this is resolved, one finger has already lifted,
        /// so there's no later point where both original positions are
        /// still available to check).
        let startedClose: Bool
    }
    private var pendingSplitTap: PendingSplitTap?

    /// Which ordinary swipe kind is currently being distance-repeated,
    /// and the point its next increment of travel is measured from.
    /// Populated only when an ordinary (.swipe-category) swipe fires —
    /// never for `.splitSwipe`, which measures travel per-finger rather
    /// than via the shared centroid this baseline uses (see
    /// `Trigger.supportsRepeatByDistance`). `nil` before the first fire
    /// and after the gesture ends.
    private var distanceRepeatKind: GestureKind?
    private var distanceRepeatBaseline: CGPoint?
    /// `true` from the moment a distance-repeat session (re)starts (the
    /// initial swipe fire, or a mid-hold direction change) until its
    /// first tick actually emits — see `emitDistanceTicks`'s doc comment
    /// for why the very first tick needs a bigger travel requirement than
    /// every tick after it. Reported symptom this fixes: a single,
    /// deliberate "just switch one tab over" swipe would often
    /// immediately fire a second switch too, because ordinary follow-
    /// through in one continuous swipe motion easily exceeds the (smaller,
    /// by design) per-tick distance right after crossing the swipe
    /// threshold that fired the first switch.
    private var isAwaitingFirstDistanceTick = false
    /// When an *extra* finger (beyond the count the repeating swipe fired
    /// with) landed mid-hold — `nil` while the count matches. Reported
    /// symptom this fixes: a 2-finger swipe firing, then a stray third
    /// finger landing in a far corner, used to re-fire as a fresh
    /// `threeFingerSwipe*` through the direction-change path with no
    /// cluster check at all, starting a Smoogler tab run nobody asked for.
    /// A new finger that stays past `extraFingerCancelDelay` cancels the
    /// repeat outright; a shorter one is treated as driver count flicker.
    private var extraFingerSince: TimeInterval?
    private static let extraFingerCancelDelay: TimeInterval = 0.05
    /// Minimum angle between the repeating direction and a candidate new
    /// one before a mid-hold direction change fires. 60° rules out the
    /// adjacent compass sector (45° away) — a natural wrist arc during a
    /// horizontal Smoogler slide used to re-fire as a diagonal kind —
    /// while still allowing a genuine reversal or a 90° turn.
    private static let minDirectionChangeDegrees: Double = 60
    /// How much larger the very first distance-repeat tick's travel
    /// requirement is than a normal tick's — deliberately a big margin
    /// (not just "a bit more"), so continuous multi-tab repeating only
    /// engages after a clearly separate, deliberate continued slide, and
    /// an ordinary single "switch one tab" swipe is very unlikely to
    /// bleed into it. An estimate, not measured against real swipes,
    /// same "tune if it misbehaves" caveat as this file's other geometry
    /// constants.
    private static let firstDistanceTickGraceMultiplier: CGFloat = 3.0
    /// User-facing tuning knob for "repeat by distance" — same 0...1
    /// convention as `sensitivity`, and the same override pattern (see
    /// `sensitivityOverride`'s doc comment).
    public var distanceRepeatSensitivity: Double = 0.5
    public var distanceRepeatSensitivityOverride: ((GestureKind) -> Double?)?
    private func clampedDistanceRepeatSensitivity(for kind: GestureKind) -> Double {
        min(max(distanceRepeatSensitivityOverride?(kind) ?? distanceRepeatSensitivity, 0), 1)
    }
    /// How much *additional* centroid travel counts as "one more repeat"
    /// once a swipe is already held, in the same units as
    /// `swipeDistanceThreshold`. Ranges from 0.12 (sensitivity 0) down to
    /// 0.02 (sensitivity 1) — deliberately a bit under
    /// `swipeDistanceThreshold`'s own range so the first repeat feels
    /// like a comparable amount of travel to the swipe that already fired.
    private func distancePerTick(for kind: GestureKind) -> CGFloat {
        CGFloat(0.12 - clampedDistanceRepeatSensitivity(for: kind) * 0.10)
    }
    /// Fires again for each `distancePerTick` of travel past the swipe
    /// that already fired — the "repeat while held" rules that opted into
    /// distance mode use this instead of a fixed timer to re-fire.
    public var onSwipeTick: ((GestureKind) -> Void)?
    /// Fires when a repeating swipe is cancelled mid-hold because the
    /// finger set changed underneath it (an extra finger landed and stayed,
    /// or the fingers came back no longer clustered) — `TrackpadManager`
    /// stops its repeat-while-held timer here, since `onTouchEnded` won't
    /// arrive until every finger actually lifts.
    public var onRepeatCancelled: (() -> Void)?
    /// One processed frame can occasionally cover several tick-widths at
    /// once (a fast real swipe, or a noise burst) — capped so a single
    /// noisy frame can't fire an unbounded number of real side effects
    /// (a shell command, a CGEvent post) at once. `emitDistanceTicks`
    /// advances the baseline by exactly one tick's worth each time rather
    /// than jumping to the current position, so a capped burst just
    /// defers the remainder to the next frame instead of losing it.
    private static let maxTicksPerFrame = 3

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
                hasFiredFastScrollEdgeThisGesture = false
                lastFrameTimestamp = frame.timestamp
                splitReferences = Self.splitReferences(for: touching)
                clusterReferences = Self.clusterReferences(for: touching)
                peakClusterCloseEnough = fingersClusteredCloseEnough(count: count)
                pendingSplitTap = nil
                distanceRepeatKind = nil
                distanceRepeatBaseline = nil
                extraFingerSince = nil
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
                    pendingSplitTap = PendingSplitTap(
                        anchor: survivor,
                        departedFingerWasLeft: !survivor.isLeft,
                        since: frame.timestamp,
                        startedClose: splitFingersStartedCloseEnough()
                    )
                } else {
                    pendingSplitTap = nil
                }
                referenceCentroid = centroid
                let isNewPeak = count > maxFingerCountThisGesture
                maxFingerCountThisGesture = max(maxFingerCountThisGesture, count)
                splitReferences = Self.splitReferences(for: touching)
                clusterReferences = Self.clusterReferences(for: touching)
                if isNewPeak {
                    peakClusterCloseEnough = fingersClusteredCloseEnough(count: count)
                }
                if let repeatCount = distanceRepeatKind?.fingerCount {
                    distanceRepeatBaseline = centroid
                    if count > repeatCount {
                        if extraFingerSince == nil { extraFingerSince = frame.timestamp }
                    } else {
                        extraFingerSince = nil
                        // Back to the swipe's own finger count (after a
                        // flicker or a finger lifting and landing again):
                        // the re-landed finger has to sit in the cluster
                        // too, or it's a palm/stray finger elsewhere.
                        if count == repeatCount, !fingersClusteredCloseEnough(count: count) {
                            cancelDistanceRepeat()
                        }
                    }
                }
            } else {
                if !hasFiredSwipeThisGesture, let ref = referenceCentroid {
                    switch splitSwipeKind(touching: touching) {
                    case .recognized(let kind):
                        hasFiredSwipeThisGesture = true
                        lastTapTime = nil
                        lastTapCentroid = nil
                        lastTapFingerCount = nil
                        if debugLoggingEnabled { NSLog("InputCustomizer: recognized split swipe \(kind.rawValue)") }
                        onGesture?(kind)
                    case .matchedButGated:
                        // Consume the gesture without firing anything —
                        // see SplitSwipeMatch.matchedButGated's doc
                        // comment for why this must not fall through to
                        // the ordinary swipe check below.
                        hasFiredSwipeThisGesture = true
                        if debugLoggingEnabled { NSLog("InputCustomizer: split swipe shape matched but fingers started too far apart — suppressed") }
                    case .noMatch:
                        let dx = centroid.x - ref.x
                        let dy = centroid.y - ref.y
                        // Direction (and so `kind`) only depends on the
                        // angle of travel, not its magnitude — computed
                        // *before* the magnitude check below so that check
                        // can use this specific kind's own threshold
                        // (per-rule sensitivity override, if any) rather
                        // than a single global one. Still gated behind a
                        // cheap, override-independent floor first so a
                        // near-stationary touch doesn't compute a
                        // meaningless direction from noise every frame.
                        if hypot(dx, dy) > Self.minPossibleSwipeDistanceThreshold,
                           let kind = Self.swipeKind(dx: dx, dy: dy, fingerCount: count),
                           hypot(dx, dy) > swipeDistanceThreshold(for: kind) {
                            if fingersClusteredCloseEnough(count: count) {
                                hasFiredSwipeThisGesture = true
                                // A swipe means this contact was never a
                                // tap — don't let a later tap spuriously
                                // pair with whatever the last real tap was.
                                lastTapTime = nil
                                lastTapCentroid = nil
                                lastTapFingerCount = nil
                                distanceRepeatKind = kind
                                distanceRepeatBaseline = centroid
                                isAwaitingFirstDistanceTick = true
                                if debugLoggingEnabled { NSLog("InputCustomizer: recognized swipe \(kind.rawValue)") }
                                onGesture?(kind)
                            } else {
                                // Shape matched but the fingers started too
                                // spread out — consume without firing, same
                                // reasoning as SplitSwipeMatch.matchedButGated:
                                // there's no separate "ordinary swipe"
                                // fallback to defer to here.
                                hasFiredSwipeThisGesture = true
                                if debugLoggingEnabled { NSLog("InputCustomizer: \(count)-finger swipe shape matched but fingers started too spread out — suppressed") }
                            }
                        }
                    }
                } else if let currentKind = distanceRepeatKind, currentKind.fingerCount != count {
                    // The finger set no longer matches the swipe that's
                    // repeating — pause ticks and direction changes rather
                    // than reinterpret the new set as a different-count
                    // swipe. A lifted finger just pauses (a repeat-while-
                    // held timer deliberately survives it; see
                    // `onTouchEnded`); an extra finger that stays cancels.
                    if let since = extraFingerSince, frame.timestamp - since >= Self.extraFingerCancelDelay {
                        cancelDistanceRepeat()
                    }
                } else if let currentKind = distanceRepeatKind, let baseline = distanceRepeatBaseline {
                    // Re-run the same angle-first-then-magnitude check
                    // used to fire the original swipe, but measured from
                    // the distance-repeat baseline instead of the
                    // gesture's start — if the fingers have travelled far
                    // enough in a *different* direction to count as a new
                    // swipe there, this is a mid-hold reversal (e.g.
                    // swiping right, then left again without lifting).
                    // Without this, `emitDistanceTicks` below is
                    // magnitude-only and would just keep repeating the
                    // original direction's action forever no matter which
                    // way the fingers actually kept moving.
                    let dx = centroid.x - baseline.x
                    let dy = centroid.y - baseline.y
                    if hypot(dx, dy) > Self.minPossibleSwipeDistanceThreshold,
                       let candidateKind = Self.swipeKind(dx: dx, dy: dy, fingerCount: count),
                       candidateKind != currentKind,
                       Self.angleBetween(candidateKind, currentKind) > Self.minDirectionChangeDegrees,
                       hypot(dx, dy) > swipeDistanceThreshold(for: candidateKind) {
                        distanceRepeatKind = candidateKind
                        distanceRepeatBaseline = centroid
                        isAwaitingFirstDistanceTick = true
                        lastTapTime = nil
                        lastTapCentroid = nil
                        lastTapFingerCount = nil
                        if debugLoggingEnabled { NSLog("InputCustomizer: distance-repeat direction changed to \(candidateKind.rawValue)") }
                        // Re-fires through the normal onGesture path (not
                        // a bespoke "switch direction" signal) so
                        // TrackpadManager's existing rule-matching and
                        // repeat-session restart handle it exactly like
                        // any fresh swipe — `RepeatSession.startRepeating`
                        // already stops the old timer/session first thing.
                        onGesture?(candidateKind)
                    } else {
                        emitDistanceTicks(kind: currentKind, centroid: centroid)
                    }
                }
            }
            checkFastScrollToBottomEdge(centroid: centroid, count: count, timestamp: frame.timestamp)
            lastCentroid = centroid
            lastFrameTimestamp = frame.timestamp
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
            hasFiredFastScrollEdgeThisGesture = false
            lastFrameTimestamp = nil
            pendingEndSince = nil
            splitReferences = [:]
            clusterReferences = [:]
            peakClusterCloseEnough = true
            pendingSplitTap = nil
            distanceRepeatKind = nil
            distanceRepeatBaseline = nil
            isAwaitingFirstDistanceTick = false
            extraFingerSince = nil
        }
        onTouchEnded?()
        // `kind` only depends on finger count (already fully known), so
        // it's resolved before the movement check below can use its own
        // per-rule sensitivity override rather than a single global one.
        guard !hasFiredSwipeThisGesture,
              let start = gestureStartTime,
              frame.timestamp - start < tapMaxDuration,
              let ref = referenceCentroid,
              let endCentroid = lastCentroid,
              let kind = Self.tapKind(fingerCount: maxFingerCountThisGesture),
              hypot(endCentroid.x - ref.x, endCentroid.y - ref.y) < tapMaxMovement(for: kind),
              peakClusterCloseEnough else {
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

    /// Checks for `.twoFingerFastScrollToBottomEdge` — see that case's
    /// doc comment. Runs independently of the swipe-detection logic
    /// above: an ordinary 2-finger touch never reaches this app's own
    /// swipe path via any current preset (2-finger is reserved for
    /// native scrolling on a trackpad), but nothing stops a custom rule
    /// from binding an ordinary 2-finger swipe too, so this can't assume
    /// it's mutually exclusive with that and just runs unconditionally
    /// for any 2-finger touch.
    private func checkFastScrollToBottomEdge(centroid: CGPoint, count: Int, timestamp: TimeInterval) {
        guard count == 2, !hasFiredFastScrollEdgeThisGesture,
              let lastCentroid, let lastFrameTimestamp else { return }
        let dt = timestamp - lastFrameTimestamp
        guard dt > 0 else { return }
        let dy = centroid.y - lastCentroid.y // negative = moving down (this file's dy>0-is-up convention)
        guard dy < 0, centroid.y < Self.fastScrollEdgeZone else { return }
        let velocity = abs(dy) / dt
        guard velocity > Self.fastScrollVelocityThreshold else { return }
        hasFiredFastScrollEdgeThisGesture = true
        if debugLoggingEnabled { NSLog("InputCustomizer: recognized fast-scroll-to-bottom-edge") }
        onGesture?(.twoFingerFastScrollToBottomEdge)
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
    ///
    /// The very first tick of a session (`isAwaitingFirstDistanceTick`)
    /// requires `firstDistanceTickGraceMultiplier` times the normal
    /// distance instead of a plain `perTick` — `distancePerTick` is
    /// deliberately smaller than the swipe-trigger threshold that just
    /// fired ("so the first repeat feels like a comparable amount of
    /// travel to the swipe that already fired"), which means ordinary
    /// follow-through in one continuous, single-tab-intended swipe could
    /// already clear it and fire an unwanted second switch immediately.
    /// The bigger first-tick requirement gives that follow-through room
    /// without needing it for every subsequent tick, so genuine held
    /// scrolling still feels the same once past that initial buffer.
    private func emitDistanceTicks(kind: GestureKind, centroid: CGPoint) {
        guard var baseline = distanceRepeatBaseline else { return }
        let perTick = distancePerTick(for: kind)
        for tickIndex in 0..<Self.maxTicksPerFrame {
            let threshold = (isAwaitingFirstDistanceTick && tickIndex == 0)
                ? perTick * Self.firstDistanceTickGraceMultiplier
                : perTick
            let dx = centroid.x - baseline.x
            let dy = centroid.y - baseline.y
            let travel = hypot(dx, dy)
            guard travel >= threshold else { break }
            let scale = threshold / travel
            baseline = CGPoint(x: baseline.x + dx * scale, y: baseline.y + dy * scale)
            isAwaitingFirstDistanceTick = false
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
        guard pending.startedClose else { return nil }
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
    /// average.
    private enum SplitSwipeMatch {
        /// A clean anchor+mover pattern, close enough together to count.
        case recognized(GestureKind)
        /// The anchor+mover *shape* matched (one finger held still, the
        /// other swiped a qualifying vertical distance), but the two
        /// fingers started further apart than `maxSplitGestureFingerDistanceMM`
        /// allows. Deliberately distinct from `.noMatch`: the caller must
        /// NOT fall back to the ordinary centroid-based swipe check here —
        /// centroid travel alone can't tell "both fingers moved" from
        /// "only one moved either", so falling back would just fire an
        /// un-split `twoFingerSwipeUp`/`Down` from the same single-finger
        /// movement, defeating the whole point of the proximity gate.
        case matchedButGated
        /// No anchor+mover pattern at all — the caller should fall back
        /// to the ordinary centroid-based `swipeKind` check.
        case noMatch
    }

    private func splitSwipeKind(touching: [MultitouchGestureEngine.Touch]) -> SplitSwipeMatch {
        guard touching.count == 2, splitReferences.count == 2 else { return .noMatch }
        var anchor: FingerReference?
        var mover: (ref: FingerReference, dx: CGFloat, dy: CGFloat)?
        for touch in touching {
            guard let ref = splitReferences[touch.id] else { return .noMatch }
            let dx = touch.position.x - ref.position.x
            let dy = touch.position.y - ref.position.y
            if hypot(dx, dy) < splitAnchorMaxMovement {
                anchor = ref
            } else {
                mover = (ref, dx, dy)
            }
        }
        // Direction only depends on angle, resolved before the magnitude
        // check below so it can use this specific kind's own threshold
        // (per-rule sensitivity override, if any).
        guard anchor != nil, let mover else { return .noMatch }
        let direction = Self.direction(dx: mover.dx, dy: mover.dy)
        guard direction == .up || direction == .down else { return .noMatch }
        let side = mover.ref.isLeft ? "Left" : "Right"
        let vertical = direction == .up ? "Up" : "Down"
        guard let kind = GestureKind(rawValue: "twoFinger\(side)Swipe\(vertical)"),
              hypot(mover.dx, mover.dy) > swipeDistanceThreshold(for: kind) else { return .noMatch }
        guard splitFingersStartedCloseEnough() else { return .matchedButGated }
        return .recognized(kind)
    }

    /// Real measured distance (mm) between the two fingers currently in
    /// `splitReferences`, or `nil` if `surfaceSizeMM` is unset (gate
    /// disabled) or there aren't exactly 2 references to compare.
    private func splitFingersDistanceMM() -> CGFloat? {
        guard let surfaceSizeMM, splitReferences.count == 2 else { return nil }
        let positions: [CGPoint] = splitReferences.values.map(\.position)
        let dx = (positions[0].x - positions[1].x) * surfaceSizeMM.width
        let dy = (positions[0].y - positions[1].y) * surfaceSizeMM.height
        return hypot(dx, dy)
    }

    /// Fires with the actual measured distance (mm) whenever a
    /// split-swipe's anchor+mover shape matched but got gated for
    /// exceeding `maxSplitGestureFingerDistanceMM` — lets `TrackpadManager`
    /// surface real numbers in its Console view instead of guessing at
    /// what ceiling is realistic. Diagnostic only; never fires when
    /// `surfaceSizeMM` is unset.
    public var onSplitGestureGated: ((CGFloat) -> Void)?

    /// Whether the two fingers currently in `splitReferences` started
    /// close enough together (per `surfaceSizeMM`/
    /// `maxSplitGestureFingerDistanceMM`) for a split-swipe/split-tap to
    /// be eligible at all. `true` whenever `surfaceSizeMM` is unset (or
    /// there aren't exactly 2 references to compare) — the gate is
    /// opt-in, matching `minimumFingerSeparation`'s default-off
    /// convention above.
    private func splitFingersStartedCloseEnough() -> Bool {
        guard let distance = splitFingersDistanceMM() else { return true }
        let closeEnough = distance <= maxSplitGestureFingerDistanceMM
        if !closeEnough { onSplitGestureGated?(distance) }
        return closeEnough
    }

    /// Builds fresh touch-down references for every currently-touching
    /// finger, regardless of count — unlike `splitReferences(for:)`, which
    /// only populates at exactly 2.
    private static func clusterReferences(for touching: [MultitouchGestureEngine.Touch]) -> [Int32: CGPoint] {
        // `uniquingKeysWith`, not `uniqueKeysWithValues` — the latter traps
        // on a duplicate touch id, and this runs on MultitouchSupport's
        // callback thread against whatever the private driver reports.
        Dictionary(touching.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
    }

    /// Ends the current distance-repeat session without ending the hold —
    /// `hasFiredSwipeThisGesture` stays set, so nothing else fires until
    /// every finger lifts. See `extraFingerSince`.
    private func cancelDistanceRepeat() {
        if debugLoggingEnabled, let kind = distanceRepeatKind { NSLog("InputCustomizer: finger set changed mid-hold — cancelled repeat of \(kind.rawValue)") }
        distanceRepeatKind = nil
        distanceRepeatBaseline = nil
        isAwaitingFirstDistanceTick = false
        extraFingerSince = nil
        onRepeatCancelled?()
    }

    /// Smallest angle (0...180°) between two swipe kinds' directions; 180
    /// when either has no direction, so the caller's check never blocks on
    /// missing data.
    private static func angleBetween(_ a: GestureKind, _ b: GestureKind) -> Double {
        guard let x = a.swipeAngleDegrees, let y = b.swipeAngleDegrees else { return 180 }
        let diff = abs(x - y).truncatingRemainder(dividingBy: 360)
        return min(diff, 360 - diff)
    }

    /// Whether every pair among `count` fingers currently in
    /// `clusterReferences` (captured at touch-down) sits within
    /// `maxMultiFingerGestureSpreadMM` of each other. `true` whenever
    /// `surfaceSizeMM` is unset (gate disabled), `count < 3` (2-finger
    /// gestures aren't clustered by this gate — see
    /// `maxMultiFingerGestureSpreadMM`'s doc comment), or `clusterReferences`
    /// doesn't actually hold `count` entries (fails open rather than
    /// blocking on stale/mismatched data).
    private func fingersClusteredCloseEnough(count: Int) -> Bool {
        guard count >= 3, let surfaceSizeMM else { return true }
        let positions = Array(clusterReferences.values)
        guard positions.count == count else { return true }
        for i in positions.indices {
            for j in positions.indices where j > i {
                let dx = (positions[i].x - positions[j].x) * surfaceSizeMM.width
                let dy = (positions[i].y - positions[j].y) * surfaceSizeMM.height
                let distance = hypot(dx, dy)
                if distance > maxMultiFingerGestureSpreadMM {
                    onMultiFingerGestureGated?(count, distance)
                    return false
                }
            }
        }
        return true
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
