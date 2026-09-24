import XCTest
import GestureEngine
import InputModels

/// The trackpad corner-click v2 contract (CornerClick.swift), one rule per
/// test. Positions are normalized (y = 1 is the top edge) on a 130×80 mm
/// surface, so 0.04 of the width ≈ 5 mm and 0.06 of the height ≈ 5 mm.
final class CornerClickTests: XCTestCase {
    private let surface = CGSize(width: 130, height: 80)
    private let spec = CornerZoneSpec.builtInTrackpad
    private let topRight = CGPoint(x: 0.96, y: 0.94)
    private let topLeft = CGPoint(x: 0.04, y: 0.94)

    private var clock: TimeInterval = 100
    private func makeTracker() -> TouchSnapshotTracker {
        let tracker = TouchSnapshotTracker(now: { [unowned self] in self.clock })
        tracker.surfaceSizeMM = surface
        return tracker
    }
    private func touch(_ id: Int32, _ p: CGPoint) -> MultitouchGestureEngine.Touch {
        MultitouchGestureEngine.Touch(id: id, position: p, state: 4)
    }
    private func frame(_ touches: [MultitouchGestureEngine.Touch], at time: TimeInterval) -> MultitouchGestureEngine.Frame {
        clock = time
        return .init(touches: touches, timestamp: time)
    }
    private func resolve(_ tracker: TouchSnapshotTracker, clickAt time: TimeInterval, clickState: Int = 1, trackpad: Bool = true) -> CornerClickResult {
        resolveCornerClick(snapshot: tracker.snapshot(), clickTime: time, clickState: clickState, eventSubtype: trackpad ? 3 : 0, spec: spec)
    }

    // MARK: - Positive

    func testCornerClickFiresOnLandAndClickTopRight() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([touch(1, topRight)], at: 100.2))
        XCTAssertEqual(resolve(tracker, clickAt: 100.21), .match(.topRight))
    }

    func testCornerClickFiresTopLeft() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topLeft)], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01), .match(.topLeft))
    }

    // MARK: - Everyday activity must not fire

    func testPointerSlideIntoCornerRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, CGPoint(x: 0.5, y: 0.5))], at: 100))
        tracker.process(frame([touch(1, CGPoint(x: 0.8, y: 0.8))], at: 100.1))
        tracker.process(frame([touch(1, topRight)], at: 100.2))
        XCTAssertEqual(resolve(tracker, clickAt: 100.21), .reject(.landedOutside))
    }

    func testRestingThumbPlusClickingFingerRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, CGPoint(x: 0.08, y: 0.06)), touch(2, CGPoint(x: 0.45, y: 0.45))], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01), .reject(.fingerCount(2)))
    }

    func testSecondFingerDuringLifetimeRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([touch(1, topRight), touch(2, CGPoint(x: 0.5, y: 0.5))], at: 100.05))
        tracker.process(frame([touch(1, topRight)], at: 100.1))
        XCTAssertEqual(resolve(tracker, clickAt: 100.11), .reject(.fingerCount(2)))
    }

    func testBottomCornersNeverMatch() {
        for point in [CGPoint(x: 0.04, y: 0.04), CGPoint(x: 0.96, y: 0.04)] {
            let tracker = makeTracker()
            tracker.process(frame([touch(1, point)], at: 100))
            XCTAssertEqual(resolve(tracker, clickAt: 100.01), .reject(.cornerNotAllowed), "\(point)")
        }
    }

    func testTravelOverCapRejected() {
        let tracker = makeTracker()
        // Wiggles inside the zone: 4 × ~1.3 mm = ~5.2 mm of travel.
        let a = CGPoint(x: 0.95, y: 0.94), b = CGPoint(x: 0.96, y: 0.94)
        tracker.process(frame([touch(1, a)], at: 100))
        for (i, p) in [b, a, b, a].enumerated() {
            tracker.process(frame([touch(1, p)], at: 100 + Double(i + 1) * 0.02))
        }
        guard case let .reject(.travelled(mm)) = resolve(tracker, clickAt: 100.09) else {
            return XCTFail("expected a travel rejection")
        }
        XCTAssertGreaterThan(mm, spec.maxTravelMM)
    }

    func testSlidingOutOfTheZoneRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([touch(1, CGPoint(x: 0.8, y: 0.94))], at: 100.1)) // ~21 mm from the right edge
        let result = resolve(tracker, clickAt: 100.11)
        XCTAssertTrue(result == .reject(.leftZone) || { if case .reject(.travelled) = result { return true }; return false }(), "\(result)")
    }

    func testLongRestThenClickRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([touch(1, topRight)], at: 101.5))
        XCTAssertEqual(resolve(tracker, clickAt: 101.5), .reject(.heldTooLong(1.5)))
    }

    func testStaleSnapshotRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        guard case .reject(.stale) = resolve(tracker, clickAt: 100.1) else { return XCTFail("expected stale") }
    }

    func testNoSnapshotAfterReset() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.reset()
        XCTAssertEqual(resolve(tracker, clickAt: 100.01), .reject(.noSnapshot))
    }

    func testNoSnapshotAfterLift() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([], at: 100.01))
        tracker.process(frame([], at: 100.05)) // past the 30 ms dropout grace
        XCTAssertEqual(resolve(tracker, clickAt: 100.06), .reject(.noSnapshot))
    }

    func testLiftedFingerInGraceRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([], at: 100.01)) // still within the dropout grace
        XCTAssertEqual(resolve(tracker, clickAt: 100.02), .reject(.noContact), "no finger is actually down")
    }

    func testNonTrackpadSourceRejected() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01, trackpad: false), .reject(.notTrackpadSource(subtype: 0)))
    }

    func testUnknownSurfaceRejected() {
        let tracker = TouchSnapshotTracker(now: { [unowned self] in self.clock })
        tracker.process(frame([touch(1, topRight)], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01), .reject(.unknownSurface))
    }

    func testDoubleClickSecondDownIsNotAMatch() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01, clickState: 2), .reject(.multiClick))
    }

    // MARK: - Driver robustness

    func testOneFrameDropoutKeepsTheLandingPoint() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([], at: 100.01)) // 10 ms blip
        tracker.process(frame([touch(1, topRight)], at: 100.02))
        XCTAssertEqual(resolve(tracker, clickAt: 100.03), .match(.topRight))
    }

    func testOneFramePhantomSecondContactRejects() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight)], at: 100))
        tracker.process(frame([touch(1, topRight), touch(9, CGPoint(x: 0.9, y: 0.9))], at: 100.01))
        tracker.process(frame([touch(1, topRight)], at: 100.02))
        XCTAssertEqual(resolve(tracker, clickAt: 100.03), .reject(.fingerCount(2)))
    }

    func testDuplicateTouchIdsDoNotTrapOrCountTwice() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, topRight), touch(1, CGPoint(x: 0.5, y: 0.5))], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01), .match(.topRight))
    }

    func testReissuedIdWithinDropoutCountsAsSecondFinger() {
        let tracker = makeTracker()
        tracker.process(frame([touch(1, CGPoint(x: 0.5, y: 0.5))], at: 100))
        tracker.process(frame([], at: 100.01)) // 10 ms blip…
        tracker.process(frame([touch(2, topRight)], at: 100.02)) // …and the driver re-issues a new id in the corner
        XCTAssertEqual(resolve(tracker, clickAt: 100.03), .reject(.fingerCount(2)))
    }

    // MARK: - Surface size

    func testSurfaceNilWhenEngineNotBuiltIn() {
        XCTAssertNil(CornerZoneSpec.surfaceMM(engineBoundToBuiltIn: false))
        XCTAssertEqual(CornerZoneSpec.surfaceMM(engineBoundToBuiltIn: true), CornerZoneSpec.builtInTrackpadSizeMM)
        let tracker = TouchSnapshotTracker(now: { [unowned self] in self.clock })
        tracker.surfaceSizeMM = CornerZoneSpec.surfaceMM(engineBoundToBuiltIn: false)
        tracker.process(frame([touch(1, topRight)], at: 100))
        XCTAssertEqual(resolve(tracker, clickAt: 100.01), .reject(.unknownSurface))
    }

    // MARK: - Click suppression

    func testSecondQuickCornerClickSwallowedWithoutFiring() {
        var suppressor = ClickSuppressor<String>()
        suppressor.noteDown(button: 0)
        suppressor.begin(button: 0, at: 10, payload: "close tab")
        guard case .swallow(fire: "close tab") = suppressor.up(button: 0, at: 10.08) else { return XCTFail("first click fires") }
        // The system counts the swallowed click, so the next quick down is clickState 2.
        suppressor.noteDown(button: 0)
        XCTAssertTrue(suppressor.swallowFollowUp(button: 0, clickState: 2, at: 10.25, doubleClickInterval: 0.5))
        guard case .swallow(fire: nil) = suppressor.up(button: 0, at: 10.3) else { return XCTFail("follow-up swallowed, not fired") }
        // A real double-click long afterwards is left alone.
        XCTAssertFalse(suppressor.swallowFollowUp(button: 0, clickState: 2, at: 20, doubleClickInterval: 0.5))
    }

    func testSameButtonDownWhilePendingCancelsSuppression() {
        var suppressor = ClickSuppressor<String>()
        suppressor.begin(button: 0, at: 10, payload: "close tab") // its up never arrives
        suppressor.noteDown(button: 0) // an ordinary click starts
        guard case .passThrough = suppressor.up(button: 0, at: 10.5) else { return XCTFail("ordinary up must pass through") }
    }

    func testSuppressorFiresOnceOnAQuickStillRelease() {
        var suppressor = ClickSuppressor<String>()
        suppressor.begin(button: 0, at: 10, payload: "close tab")
        XCTAssertTrue(suppressor.drag(button: 0, at: 10.05, deltaPoints: 2))
        guard case .swallow(fire: "close tab") = suppressor.up(button: 0, at: 10.1) else { return XCTFail("expected fire") }
        guard case .passThrough = suppressor.up(button: 0, at: 10.2) else { return XCTFail("second up must pass through") }
    }

    func testSuppressorDoesNotFireOnLongPress() {
        var suppressor = ClickSuppressor<String>()
        suppressor.begin(button: 0, at: 10, payload: "close tab")
        guard case .swallow(fire: nil) = suppressor.up(button: 0, at: 10.6) else { return XCTFail("long press swallows without firing") }
    }

    func testSuppressorDoesNotFireOnDrag() {
        var suppressor = ClickSuppressor<String>()
        suppressor.begin(button: 0, at: 10, payload: "close tab")
        _ = suppressor.drag(button: 0, at: 10.05, deltaPoints: 20)
        guard case .swallow(fire: nil) = suppressor.up(button: 0, at: 10.1) else { return XCTFail("drag swallows without firing") }
    }

    func testSuppressorIgnoresOtherButtonsAndAbandonsAfterTimeout() {
        var suppressor = ClickSuppressor<String>()
        suppressor.begin(button: 0, at: 10, payload: "close tab")
        guard case .passThrough = suppressor.up(button: 1, at: 10.1) else { return XCTFail("other button passes") }
        XCTAssertFalse(suppressor.drag(button: 0, at: 13, deltaPoints: 1), "abandoned after 2 s")
        guard case .passThrough = suppressor.up(button: 0, at: 13.1) else { return XCTFail("unpaired up passes") }
    }
}
