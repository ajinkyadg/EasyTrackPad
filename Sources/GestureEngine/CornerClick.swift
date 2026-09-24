import CoreGraphics
import Foundation
import os

// Trackpad corner click, v2. A corner click is an ordinary physical click
// whose single finger *landed* in a top corner of the trackpad and stayed
// put — not "wherever the touch centroid happens to be when any click
// arrives", which the first version used and which fired on ordinary
// pointing, resting thumbs, and clicks from other mice. Everything here is
// pure logic (no event taps, no AppKit) so each rule of the contract has a
// synthetic-input test.

/// One finger's history since it landed, as seen by `TouchSnapshotTracker`.
public struct TrackedContact: Equatable {
    public let id: Int32
    /// Normalized 0...1 position where the finger first touched down
    /// (x: left → right, y: bottom → top, MultitouchSupport's convention).
    public let landing: CGPoint
    public let current: CGPoint
    public let landedAt: TimeInterval
    /// Total distance travelled since landing, in mm (0 when the surface
    /// size is unknown — the resolver rejects that case anyway).
    public let pathLengthMM: CGFloat

    public init(id: Int32, landing: CGPoint, current: CGPoint, landedAt: TimeInterval, pathLengthMM: CGFloat) {
        self.id = id
        self.landing = landing
        self.current = current
        self.landedAt = landedAt
        self.pathLengthMM = pathLengthMM
    }
}

/// What the trackpad looked like at the most recent frame — published by
/// the multitouch callback thread, read by the mouse event tap.
public struct TouchSnapshot: Equatable {
    /// `ProcessInfo.systemUptime` when the frame was processed — the same
    /// clock the click handler reads, so staleness is a plain subtraction.
    public let capturedAt: TimeInterval
    /// Fingers currently touching.
    public let contacts: [TrackedContact]
    /// Most fingers down at once since the first finger of this touch
    /// session landed — a second finger that came and went still counts.
    public let peakContactCount: Int
    public let surfaceMM: CGSize?

    public init(capturedAt: TimeInterval, contacts: [TrackedContact], peakContactCount: Int, surfaceMM: CGSize?) {
        self.capturedAt = capturedAt
        self.contacts = contacts
        self.peakContactCount = peakContactCount
        self.surfaceMM = surfaceMM
    }
}

/// Feeds on raw frames and keeps per-finger landing/travel history, which
/// `GestureRecognizer`'s centroid-based state can't provide. Thread-safe:
/// `process` runs on MultitouchSupport's callback thread, `snapshot()` on
/// the main thread's event tap.
public final class TouchSnapshotTracker {
    public var surfaceSizeMM: CGSize?
    /// A zero-touch report shorter than this is driver flicker, not a lift
    /// — the session (and each finger's landing point) survives it. Same
    /// value as `GestureRecognizer.endGracePeriod`.
    public var dropoutGrace: TimeInterval = 0.03
    private let now: () -> TimeInterval

    private struct State {
        var contacts: [Int32: TrackedContact] = [:]
        /// Distinct touch ids seen this session, not just the most at once:
        /// a finger the driver re-issues under a new id after a brief
        /// dropout reads as a second finger rather than a fresh landing.
        var seenIDs: Set<Int32> = []
        var peak = 0
        var lastFrameAt: TimeInterval?
        var emptySince: TimeInterval?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let touchingStates: Set<Int32> = [3, 4]

    public init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    public func process(_ frame: MultitouchGestureEngine.Frame) {
        let time = now()
        let surface = surfaceSizeMM
        // First report wins on a duplicate id — the driver is untrusted input.
        var firstReports: [Int32: CGPoint] = [:]
        for touch in frame.touches where Self.touchingStates.contains(touch.state) && firstReports[touch.id] == nil {
            firstReports[touch.id] = touch.position
        }
        let touching = firstReports
        let dropoutGrace = self.dropoutGrace
        state.withLock { s in
            s.lastFrameAt = time
            if touching.isEmpty {
                if s.emptySince == nil { s.emptySince = time }
                if time - s.emptySince! >= dropoutGrace { s = State(lastFrameAt: time) }
                return
            }
            s.emptySince = nil
            var next: [Int32: TrackedContact] = [:]
            for (id, position) in touching {
                if let previous = s.contacts[id] {
                    var step: CGFloat = 0
                    if let surface {
                        step = hypot((position.x - previous.current.x) * surface.width, (position.y - previous.current.y) * surface.height)
                    }
                    next[id] = TrackedContact(id: id, landing: previous.landing, current: position, landedAt: previous.landedAt, pathLengthMM: previous.pathLengthMM + step)
                } else {
                    next[id] = TrackedContact(id: id, landing: position, current: position, landedAt: time, pathLengthMM: 0)
                }
            }
            s.contacts = next
            s.seenIDs.formUnion(next.keys)
            s.peak = max(s.peak, next.count, s.seenIDs.count)
        }
    }

    /// `nil` once every finger has lifted (past the dropout grace) or after
    /// `reset()` — never a stale "finger still there" that outlives the
    /// touch, which is what let the first version fire on any later click.
    public func snapshot() -> TouchSnapshot? {
        let surface = surfaceSizeMM
        return state.withLock { s in
            guard let at = s.lastFrameAt, s.peak > 0 else { return nil }
            // Mid-dropout: nothing is actually touching right now.
            let contacts = s.emptySince == nil ? Array(s.contacts.values) : []
            return TouchSnapshot(capturedAt: at, contacts: contacts, peakContactCount: s.peak, surfaceMM: surface)
        }
    }

    /// Call when the engine stops or the device goes away.
    public func reset() {
        state.withLock { $0 = State() }
    }
}

/// Tunables for `resolveCornerClick`. Every value is a guess until tuned
/// from the rejection reasons logged to the Activity console.
public struct CornerZoneSpec: Equatable {
    /// How far in from the top edge and the side edge the finger must land.
    public var sizeMM: CGSize
    /// Extra room the finger may drift past the zone after landing.
    public var exitMarginMM: CGFloat
    public var maxTravelMM: CGFloat
    /// A finger resting in the corner longer than this before clicking is
    /// a resting finger, not a corner click.
    public var maxContactAge: TimeInterval
    public var maxStaleness: TimeInterval
    /// Top corners only: the bottom edge is where people normally click,
    /// and macOS's "secondary click in bottom corner" setting lives there.
    public var allowed: Set<MouseCorner>

    public init(sizeMM: CGSize, exitMarginMM: CGFloat, maxTravelMM: CGFloat, maxContactAge: TimeInterval, maxStaleness: TimeInterval, allowed: Set<MouseCorner>) {
        self.sizeMM = sizeMM
        self.exitMarginMM = exitMarginMM
        self.maxTravelMM = maxTravelMM
        self.maxContactAge = maxContactAge
        self.maxStaleness = maxStaleness
        self.allowed = allowed
    }

    /// The built-in trackpad's glass, measured on a 14" MacBook Pro.
    public static let builtInTrackpadSizeMM = CGSize(width: 130, height: 80)

    /// The surface size corner clicks may assume: the built-in pad's only
    /// when the engine really bound the built-in device. Otherwise `nil`,
    /// so corner clicks fail closed (`.unknownSurface`) rather than using
    /// wrong millimetres on a Magic Trackpad.
    public static func surfaceMM(engineBoundToBuiltIn: Bool) -> CGSize? {
        engineBoundToBuiltIn ? builtInTrackpadSizeMM : nil
    }

    public static let builtInTrackpad = CornerZoneSpec(
        sizeMM: CGSize(width: 15, height: 15), exitMarginMM: 3, maxTravelMM: 4,
        maxContactAge: 0.8, maxStaleness: 0.05, allowed: [.topLeft, .topRight]
    )
}

public enum CornerClickRejection: Equatable {
    case noSnapshot
    case noContact
    case stale(TimeInterval)
    case notTrackpadSource(subtype: Int)
    case unknownSurface
    case fingerCount(Int)
    case landedOutside
    case leftZone
    case travelled(CGFloat)
    case heldTooLong(TimeInterval)
    case multiClick
    case cornerNotAllowed

    /// One line for the Activity console — the tuning diagnostic.
    public var explanation: String {
        switch self {
        case .noSnapshot: return "no finger on the trackpad"
        case let .stale(age): return "touch data \(Int(age * 1000))ms old"
        case let .notTrackpadSource(subtype): return "click didn’t come from the trackpad (event subtype \(subtype))"
        case .noContact: return "no finger was down at the click"
        case .unknownSurface: return "trackpad size unknown"
        case let .fingerCount(n): return "\(n) fingers touched"
        case .landedOutside: return "finger didn’t land in a top corner"
        case .leftZone: return "finger slid out of the corner"
        case let .travelled(mm): return "finger moved \(String(format: "%.1f", mm))mm"
        case let .heldTooLong(age): return "finger rested \(Int(age * 1000))ms before clicking"
        case .multiClick: return "double-click"
        case .cornerNotAllowed: return "corner not allowed"
        }
    }
}

public enum CornerClickResult: Equatable {
    case match(MouseCorner)
    case reject(CornerClickRejection)
}

/// The whole corner-click contract as one pure decision. `clickTime` is on
/// the same clock as `TouchSnapshot.capturedAt`.
public func resolveCornerClick(
    snapshot: TouchSnapshot?,
    clickTime: TimeInterval,
    clickState: Int,
    eventSubtype: Int,
    spec: CornerZoneSpec
) -> CornerClickResult {
    // NSEvent.EventSubtype.touch — set on clicks from a multitouch
    // trackpad, not on mouse clicks. Unverified on every model, so the raw
    // value is carried into the rejection for the Activity console.
    guard eventSubtype == 3 else { return .reject(.notTrackpadSource(subtype: eventSubtype)) }
    guard clickState == 1 else { return .reject(.multiClick) }
    guard let snapshot else { return .reject(.noSnapshot) }
    let age = clickTime - snapshot.capturedAt
    guard age <= spec.maxStaleness else { return .reject(.stale(age)) }
    guard let surface = snapshot.surfaceMM else { return .reject(.unknownSurface) }
    guard !snapshot.contacts.isEmpty else {
        return .reject(snapshot.peakContactCount > 1 ? .fingerCount(snapshot.peakContactCount) : .noContact)
    }
    guard snapshot.peakContactCount == 1, snapshot.contacts.count == 1, let finger = snapshot.contacts.first else {
        return .reject(.fingerCount(max(snapshot.peakContactCount, snapshot.contacts.count)))
    }
    guard let corner = cornerZone(containing: finger.landing, surface: surface, zone: spec.sizeMM) else {
        return .reject(.landedOutside)
    }
    guard spec.allowed.contains(corner) else { return .reject(.cornerNotAllowed) }
    let widened = CGSize(width: spec.sizeMM.width + spec.exitMarginMM, height: spec.sizeMM.height + spec.exitMarginMM)
    guard cornerZone(containing: finger.current, surface: surface, zone: widened) == corner else {
        return .reject(.leftZone)
    }
    guard finger.pathLengthMM <= spec.maxTravelMM else { return .reject(.travelled(finger.pathLengthMM)) }
    let contactAge = clickTime - finger.landedAt
    guard contactAge <= spec.maxContactAge else { return .reject(.heldTooLong(contactAge)) }
    return .match(corner)
}

/// Which corner (if any) a normalized point sits in, with the zone measured
/// in mm from the two nearest edges.
public func cornerZone(containing point: CGPoint, surface: CGSize, zone: CGSize) -> MouseCorner? {
    let fromLeft = point.x * surface.width
    let fromRight = (1 - point.x) * surface.width
    let fromTop = (1 - point.y) * surface.height
    let fromBottom = point.y * surface.height
    let left = fromLeft <= zone.width, right = fromRight <= zone.width
    let top = fromTop <= zone.height, bottom = fromBottom <= zone.height
    switch (left, right, top, bottom) {
    case (true, _, true, _): return .topLeft
    case (_, true, true, _): return .topRight
    case (true, _, _, true): return .bottomLeft
    case (_, true, _, true): return .bottomRight
    default: return nil
    }
}

/// Swallows a matched corner click's whole down → drag → up sequence so
/// the ordinary click never reaches the app under the pointer, and decides
/// on mouse-up whether the action runs: only for a quick, still press —
/// a drag or long-press that happened to start in a corner loses its click
/// but never fires the action.
public struct ClickSuppressor<Payload> {
    public var maxHold: TimeInterval = 0.4
    public var maxDragPoints: CGFloat = 8
    /// Stop suppressing if the matching mouse-up never arrives.
    public var abandonAfter: TimeInterval = 2

    private struct Pending {
        let button: Int
        let downAt: TimeInterval
        var dragged: CGFloat = 0
        /// `nil` for a follow-up click that's swallowed but never fires.
        let payload: Payload?
    }
    private var pending: Pending?
    /// When each button's last swallowed down happened — the system still
    /// counts a swallowed click toward the next click's clickState.
    private var lastSwallowedDown: [Int: TimeInterval] = [:]

    public init() {}

    public var isSuppressing: Bool { pending != nil }

    /// Every mouse-down, before matching. A new down on the button that's
    /// still suppressed means its up never arrived: stop suppressing, so
    /// this ordinary click's up isn't eaten.
    public mutating func noteDown(button: Int) {
        if pending?.button == button { pending = nil }
    }

    /// A matched mouse-down: start suppressing this button's sequence.
    public mutating func begin(button: Int, at time: TimeInterval, payload: Payload) {
        pending = Pending(button: button, downAt: time, payload: payload)
        lastSwallowedDown[button] = time
    }

    /// A multi-click down (clickState > 1) arriving within the double-click
    /// interval of a swallowed corner click would reach the app as a
    /// double-click (open a file, zoom a window). Returns `true` when it's
    /// such a follow-up: its whole sequence is swallowed and nothing fires.
    public mutating func swallowFollowUp(button: Int, clickState: Int, at time: TimeInterval, doubleClickInterval: TimeInterval) -> Bool {
        guard clickState > 1, let last = lastSwallowedDown[button], time - last <= doubleClickInterval else { return false }
        pending = Pending(button: button, downAt: time, payload: nil)
        lastSwallowedDown[button] = time
        return true
    }

    /// `true` if this drag belongs to a suppressed sequence (swallow it).
    public mutating func drag(button: Int, at time: TimeInterval, deltaPoints: CGFloat) -> Bool {
        expireIfAbandoned(at: time)
        guard var p = pending, p.button == button else { return false }
        p.dragged += deltaPoints
        pending = p
        return true
    }

    /// For a suppressed sequence's mouse-up: `.swallow(fire:)` with the
    /// payload to run, or `nil` for the action when it was a drag or a
    /// long press. `.passThrough` for any unrelated mouse-up.
    public enum UpDecision { case passThrough, swallow(fire: Payload?) }

    public mutating func up(button: Int, at time: TimeInterval) -> UpDecision {
        expireIfAbandoned(at: time)
        guard let p = pending, p.button == button else { return .passThrough }
        pending = nil
        let quick = time - p.downAt <= maxHold
        let still = p.dragged <= maxDragPoints
        return .swallow(fire: quick && still ? p.payload : nil)
    }

    public mutating func cancel() {
        pending = nil
        lastSwallowedDown = [:]
    }

    private mutating func expireIfAbandoned(at time: TimeInterval) {
        if let p = pending, time - p.downAt > abandonAfter { pending = nil }
    }
}
