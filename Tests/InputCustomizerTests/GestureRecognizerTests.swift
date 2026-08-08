import XCTest
@testable import InputCustomizer

final class GestureRecognizerTests: XCTestCase {
    private func touch(_ id: Int32, _ x: Double, _ y: Double, state: Int32 = 4) -> MultitouchGestureEngine.Touch {
        MultitouchGestureEngine.Touch(id: id, position: CGPoint(x: x, y: y), state: state)
    }

    // MARK: - Repeat by distance (onSwipeTick)

    func testDistanceRepeatTicksOncePerAdditionalDistancePerTick() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        var ticks: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }
        recognizer.onSwipeTick = { ticks.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }

        recognizer.process(.init(touches: fingers(0.1), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.25), timestamp: 0.05)) // travel 0.15 > 0.08 threshold: fires
        XCTAssertEqual(fired, [.threeFingerSwipeRight])
        XCTAssertTrue(ticks.isEmpty, "no tick yet — no travel past the fire point")

        recognizer.process(.init(touches: fingers(0.325), timestamp: 0.1)) // +0.075, clearly past distancePerTick (0.07)
        XCTAssertEqual(ticks, [.threeFingerSwipeRight])

        recognizer.process(.init(touches: fingers(0.4), timestamp: 0.15)) // +0.075 again
        XCTAssertEqual(ticks, [.threeFingerSwipeRight, .threeFingerSwipeRight])
    }

    func testDistanceRepeatDoesNotTickBeforeFullIncrementOfTravel() {
        let recognizer = GestureRecognizer()
        var ticks: [Trigger.GestureKind] = []
        recognizer.onSwipeTick = { ticks.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        recognizer.process(.init(touches: fingers(0.1), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.25), timestamp: 0.05)) // fires
        recognizer.process(.init(touches: fingers(0.28), timestamp: 0.1)) // +0.03, short of 0.07

        XCTAssertTrue(ticks.isEmpty)
    }

    func testDistanceRepeatSensitivityScalesTickThreshold() {
        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }

        let lowSensitivity = GestureRecognizer()
        lowSensitivity.sensitivity = 0 // keep the swipe-fire threshold conservative and identical on both sides
        lowSensitivity.distanceRepeatSensitivity = 0
        var lowTicks: [Trigger.GestureKind] = []
        lowSensitivity.onSwipeTick = { lowTicks.append($0) }
        lowSensitivity.process(.init(touches: fingers(0.1), timestamp: 0))
        lowSensitivity.process(.init(touches: fingers(0.3), timestamp: 0.05)) // travel 0.2 > 0.13 threshold: fires
        lowSensitivity.process(.init(touches: fingers(0.328), timestamp: 0.1)) // +0.028, short of distancePerTick (0.12) at sensitivity 0
        XCTAssertTrue(lowTicks.isEmpty, "0.028 extra travel shouldn't cross the least-sensitive distancePerTick (0.12)")

        let highSensitivity = GestureRecognizer()
        highSensitivity.sensitivity = 0
        highSensitivity.distanceRepeatSensitivity = 1
        var highTicks: [Trigger.GestureKind] = []
        highSensitivity.onSwipeTick = { highTicks.append($0) }
        highSensitivity.process(.init(touches: fingers(0.1), timestamp: 0))
        highSensitivity.process(.init(touches: fingers(0.3), timestamp: 0.05))
        highSensitivity.process(.init(touches: fingers(0.328), timestamp: 0.1))
        // Same 0.028 travel: comfortably past the most-sensitive
        // distancePerTick (0.02, margin 0.008) but under two tick-widths
        // (0.04, margin 0.012) — one clean tick either side of exact FP
        // rounding at the boundary.
        XCTAssertEqual(highTicks, [.threeFingerSwipeRight])
    }

    func testSplitSwipeNeverTicksAndOrdinarySwipeStateDoesNotLeakIntoIt() {
        let recognizer = GestureRecognizer()
        var ticks: [Trigger.GestureKind] = []
        recognizer.onGesture = { _ in }
        recognizer.onSwipeTick = { ticks.append($0) }

        // First: an ordinary swipe that fires and ticks, so we can prove
        // any leftover distanceRepeatKind/baseline from this gesture
        // can't bleed into the next, unrelated one.
        let ordinaryFingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        recognizer.process(.init(touches: ordinaryFingers(0.1), timestamp: 0))
        recognizer.process(.init(touches: ordinaryFingers(0.25), timestamp: 0.05)) // fires
        recognizer.process(.init(touches: ordinaryFingers(0.32), timestamp: 0.1)) // ticks once
        XCTAssertEqual(ticks.count, 1)
        recognizer.process(.init(touches: [], timestamp: 0.15))
        recognizer.process(.init(touches: [], timestamp: 0.19)) // lift-off past the grace period

        // Second: a split swipe (left finger up, right anchored) that
        // also continues travelling well past a full distancePerTick.
        recognizer.process(.init(touches: [touch(1, 0.3, 0.5), touch(2, 0.6, 0.5)], timestamp: 0.3))
        recognizer.process(.init(touches: [touch(1, 0.3, 0.8), touch(2, 0.6, 0.5)], timestamp: 0.35)) // fires the split swipe
        recognizer.process(.init(touches: [touch(1, 0.3, 0.95), touch(2, 0.6, 0.5)], timestamp: 0.4)) // continues moving

        XCTAssertEqual(ticks.count, 1, "a split swipe must never produce distance ticks")
    }

    func testTapNeverProducesDistanceTicks() {
        let recognizer = GestureRecognizer()
        var ticks: [Trigger.GestureKind] = []
        recognizer.onSwipeTick = { ticks.append($0) }

        let fingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)]
        recognizer.process(.init(touches: fingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09)) // recognized as a tap

        XCTAssertTrue(ticks.isEmpty)
    }

    func testBurstFrameCapsTicksPerFrameAndDefersTheRemainder() {
        let recognizer = GestureRecognizer()
        var ticks: [Trigger.GestureKind] = []
        recognizer.onSwipeTick = { ticks.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        recognizer.process(.init(touches: fingers(0.1), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.25), timestamp: 0.05)) // fires, baseline = 0.25

        // One big jump covering ~5.3 tick-widths (5.3 * 0.07 ≈ 0.371) at
        // default sensitivity — deliberately not an exact multiple of
        // distancePerTick, so this test isn't sensitive to floating-point
        // rounding at an exact boundary. Uncapped this would tick 5
        // times; capped at maxTicksPerFrame (3), only 3 fire this frame.
        recognizer.process(.init(touches: fingers(0.621), timestamp: 0.1))
        XCTAssertEqual(ticks.count, 3, "capped at maxTicksPerFrame even though the jump covered >5 tick-widths")

        // A later frame at the *same* position (no further finger
        // movement) still has ~2.3 tick-widths of travel left between the
        // deferred baseline and the actual centroid, so it ticks twice
        // more — proving the cap deferred the remainder rather than
        // dropping it.
        recognizer.process(.init(touches: fingers(0.621), timestamp: 0.15))
        XCTAssertEqual(ticks.count, 5)
    }

    func testDistanceRepeatTicksRegardlessOfReverseTravel() {
        let recognizer = GestureRecognizer()
        var ticks: [Trigger.GestureKind] = []
        recognizer.onSwipeTick = { ticks.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        recognizer.process(.init(touches: fingers(0.5), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.65), timestamp: 0.05)) // travel 0.15 > 0.08: fires, baseline 0.65

        // Travel back past the baseline in the *opposite* direction —
        // still reports the original .threeFingerSwipeRight kind, by
        // design (magnitude-only, not direction-gated; see
        // GestureRecognizer.emitDistanceTicks).
        recognizer.process(.init(touches: fingers(0.575), timestamp: 0.1)) // 0.075 back to the left, clear of the 0.07 boundary

        XCTAssertEqual(ticks, [.threeFingerSwipeRight])
    }

    // MARK: - Split swipe (2 fingers down, one anchored, one swipes up/down)

    func testLeftFingerSwipesUpWhileRightFingerStaysAnchored() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: [touch(1, 0.3, 0.5), touch(2, 0.6, 0.5)], timestamp: 0))
        recognizer.process(.init(touches: [touch(1, 0.3, 0.8), touch(2, 0.6, 0.5)], timestamp: 0.05))

        XCTAssertEqual(fired, [.twoFingerLeftSwipeUp])
    }

    func testRightFingerSwipesDownWhileLeftFingerStaysAnchored() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: [touch(1, 0.3, 0.5), touch(2, 0.6, 0.5)], timestamp: 0))
        recognizer.process(.init(touches: [touch(1, 0.3, 0.5), touch(2, 0.6, 0.2)], timestamp: 0.05))

        XCTAssertEqual(fired, [.twoFingerRightSwipeDown])
    }

    /// Role ("left"/"right") is by x-position at touch-down, not touch id
    /// — the previous two tests both happen to use id 1 for the mover;
    /// this one swaps which id is which side to prove it's positional.
    func testSplitSwipeRoleIsByPositionNotTouchId() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        // id 2 starts on the left this time.
        recognizer.process(.init(touches: [touch(2, 0.3, 0.5), touch(1, 0.6, 0.5)], timestamp: 0))
        recognizer.process(.init(touches: [touch(2, 0.3, 0.8), touch(1, 0.6, 0.5)], timestamp: 0.05))

        XCTAssertEqual(fired, [.twoFingerLeftSwipeUp])
    }

    /// Both fingers travelling together must still be read as an ordinary
    /// `twoFingerSwipeUp`, not a split swipe — regression guard for the
    /// centroid-based path split-swipe detection sits in front of.
    func testBothFingersMovingTogetherFiresOrdinaryTwoFingerSwipeNotSplit() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: [touch(1, 0.3, 0.5), touch(2, 0.6, 0.5)], timestamp: 0))
        recognizer.process(.init(touches: [touch(1, 0.3, 0.8), touch(2, 0.6, 0.8)], timestamp: 0.05))

        XCTAssertEqual(fired, [.twoFingerSwipeUp])
    }

    /// A "moving" finger travelling sideways (not predominantly up/down)
    /// doesn't match the split-swipe direction filter, and its solo
    /// movement isn't enough centroid travel to fire an ordinary swipe
    /// either — so nothing should fire.
    func testSidewaysSingleFingerMovementFiresNothing() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: [touch(1, 0.3, 0.5), touch(2, 0.6, 0.5)], timestamp: 0))
        recognizer.process(.init(touches: [touch(1, 0.4, 0.5), touch(2, 0.6, 0.5)], timestamp: 0.05))

        XCTAssertTrue(fired.isEmpty)
    }

    // MARK: - onTouchEnded (drives TrackpadManager's "repeat while held")

    func testOnTouchEndedFiresOnceAtLiftOffAfterASwipe() {
        let recognizer = GestureRecognizer()
        var touchEndedCount = 0
        recognizer.onTouchEnded = { touchEndedCount += 1 }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        recognizer.process(.init(touches: fingers(0.2), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.5), timestamp: 0.05)) // fires the swipe
        XCTAssertEqual(touchEndedCount, 0, "should not fire while fingers are still down")

        recognizer.process(.init(touches: [], timestamp: 0.1))
        recognizer.process(.init(touches: [], timestamp: 0.14)) // past the grace period: real lift-off
        XCTAssertEqual(touchEndedCount, 1)
    }

    /// TrackpadManager relies on this exact ordering: for a swipe,
    /// onGesture fires mid-touch and onTouchEnded fires later at real
    /// lift-off, but a tap only recognizes once fingers have *already*
    /// fully lifted, so onTouchEnded fires first. This asymmetry is why
    /// "repeat while held" must never be allowed on a tap rule — see
    /// Trigger.supportsRepeatWhileHeld.
    func testOnTouchEndedFiresBeforeOnGestureForATap() {
        let recognizer = GestureRecognizer()
        var events: [String] = []
        recognizer.onTouchEnded = { events.append("touchEnded") }
        recognizer.onGesture = { events.append("gesture(\($0.rawValue))") }

        let fingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)]
        recognizer.process(.init(touches: fingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05)) // quick lift, no movement
        recognizer.process(.init(touches: [], timestamp: 0.09)) // past the grace period

        XCTAssertEqual(events, ["touchEnded", "gesture(threeFingerTap)"])
    }

    func testIsTouchingTracksActualContactState() {
        let recognizer = GestureRecognizer()
        XCTAssertFalse(recognizer.isTouching)

        let fingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)]
        recognizer.process(.init(touches: fingers, timestamp: 0))
        XCTAssertTrue(recognizer.isTouching)

        recognizer.process(.init(touches: [], timestamp: 0.05))
        XCTAssertTrue(recognizer.isTouching, "still within the blip-tolerance grace period")

        recognizer.process(.init(touches: [], timestamp: 0.09)) // past the grace period: real lift-off
        XCTAssertFalse(recognizer.isTouching)
    }

    func testOnTouchEndedDoesNotFireWhenOnlySomeFingersLiftDuringAHold() {
        let recognizer = GestureRecognizer()
        var touchEndedCount = 0
        recognizer.onTouchEnded = { touchEndedCount += 1 }

        let threeFingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        recognizer.process(.init(touches: threeFingers(0.2), timestamp: 0))
        recognizer.process(.init(touches: threeFingers(0.5), timestamp: 0.05)) // fires the swipe

        // One of three fingers lifts, two remain down — a "repeat while
        // held" rule must keep repeating through this; only ALL fingers
        // lifting ends the hold.
        let twoFingers = [touch(1, 0.5, 0.5), touch(2, 0.5, 0.55)]
        recognizer.process(.init(touches: twoFingers, timestamp: 0.1))
        XCTAssertEqual(touchEndedCount, 0, "should not fire while some fingers are still down")

        recognizer.process(.init(touches: [], timestamp: 0.2))
        recognizer.process(.init(touches: [], timestamp: 0.24)) // past the grace period: the last finger actually lifted
        XCTAssertEqual(touchEndedCount, 1)
    }

    func testOnTouchEndedDoesNotFireForABlipWithinTheGracePeriod() {
        let recognizer = GestureRecognizer()
        var touchEndedCount = 0
        recognizer.onTouchEnded = { touchEndedCount += 1 }

        let fingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)]
        recognizer.process(.init(touches: fingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.01)) // transient blip, within grace period
        recognizer.process(.init(touches: fingers, timestamp: 0.02)) // fingers back

        XCTAssertEqual(touchEndedCount, 0)
    }

    func testHigherSensitivityTriggersSwipeFromSmallerMovement() {
        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }
        // A short travel (0.05) that the default sensitivity (threshold
        // 0.08) should not consider a swipe.
        let lowSensitivity = GestureRecognizer()
        lowSensitivity.sensitivity = 0
        var lowFired: [Trigger.GestureKind] = []
        lowSensitivity.onGesture = { lowFired.append($0) }
        lowSensitivity.process(.init(touches: fingers(0.2), timestamp: 0))
        lowSensitivity.process(.init(touches: fingers(0.25), timestamp: 0.05))
        XCTAssertTrue(lowFired.isEmpty, "0.05 travel shouldn't cross the least-sensitive threshold (0.13)")

        // The same travel should register at maximum sensitivity
        // (threshold 0.03).
        let highSensitivity = GestureRecognizer()
        highSensitivity.sensitivity = 1
        var highFired: [Trigger.GestureKind] = []
        highSensitivity.onGesture = { highFired.append($0) }
        highSensitivity.process(.init(touches: fingers(0.2), timestamp: 0))
        highSensitivity.process(.init(touches: fingers(0.25), timestamp: 0.05))
        XCTAssertEqual(highFired, [.threeFingerSwipeRight])
    }

    func testThreeFingerSwipeRight() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }

        recognizer.process(.init(touches: fingers(0.2), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.35), timestamp: 0.05))
        recognizer.process(.init(touches: fingers(0.5), timestamp: 0.1)) // 0.3 total travel > threshold
        recognizer.process(.init(touches: [], timestamp: 0.15)) // lift off

        XCTAssertEqual(fired, [.threeFingerSwipeRight])
    }

    func testTwoFingerSwipeUp() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { y in
            [self.touch(1, 0.4, y), self.touch(2, 0.6, y)]
        }

        recognizer.process(.init(touches: fingers(0.2), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.5), timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.1))

        XCTAssertEqual(fired, [.twoFingerSwipeUp])
    }

    func testFourFingerTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45), touch(4, 0.45, 0.45)]

        recognizer.process(.init(touches: fingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05)) // quick lift, no movement
        recognizer.process(.init(touches: [], timestamp: 0.09)) // past the noise-tolerance grace period

        XCTAssertEqual(fired, [.fourFingerTap])
    }

    func testBriefSensorBlipMidSwipeDoesNotFireTwice() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.5), self.touch(2, x, 0.55), self.touch(3, x, 0.6)]
        }

        recognizer.process(.init(touches: fingers(0.2), timestamp: 0))
        // A single frame transiently reports no touching fingers even
        // though the hand never left the glass — real hardware does this.
        recognizer.process(.init(touches: [], timestamp: 0.01))
        // Touches reappear well within the grace period: the gesture
        // should be treated as continuous, not restarted.
        recognizer.process(.init(touches: fingers(0.35), timestamp: 0.02))
        recognizer.process(.init(touches: fingers(0.5), timestamp: 0.07)) // crosses the swipe threshold
        recognizer.process(.init(touches: [], timestamp: 0.12))
        recognizer.process(.init(touches: [], timestamp: 0.16)) // finalize

        XCTAssertEqual(fired, [.threeFingerSwipeRight])
    }

    func testStaggeredFingerLandingDoesNotFireFalseSwipe() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        // Real hardware doesn't report all fingers touching down in the
        // same frame — finger 1 lands first...
        recognizer.process(.init(touches: [touch(1, 0.2, 0.5)], timestamp: 0))
        // ...then fingers 2 and 3 join a few ms later, at very different
        // positions. The averaged centroid jumps a lot right here, but
        // that's the finger count changing, not real travel, and must
        // not be misread as a swipe (previously: an instant, spurious
        // "threeFingerSwipeRight" fired from exactly this centroid jump).
        recognizer.process(.init(touches: [touch(1, 0.2, 0.5), touch(2, 0.6, 0.9), touch(3, 0.6, 0.1)], timestamp: 0.008))
        // Fingers stay put once landed — no real movement follows, so
        // this is a legitimate stationary 3-finger tap, not a swipe.
        recognizer.process(.init(touches: [touch(1, 0.2, 0.5), touch(2, 0.6, 0.9), touch(3, 0.6, 0.1)], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.1))
        recognizer.process(.init(touches: [], timestamp: 0.14))

        XCTAssertEqual(fired, [.threeFingerTap])
    }

    func testLongPressWithoutMovementDoesNotFireTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)]

        recognizer.process(.init(touches: fingers, timestamp: 0))
        recognizer.process(.init(touches: fingers, timestamp: 0.4)) // held past tapMaxDuration
        recognizer.process(.init(touches: [], timestamp: 0.45))

        XCTAssertTrue(fired.isEmpty)
    }

    func testDragTooFarToBeATapDoesNotFire() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        // Small, slow drag: below the swipe threshold, but above the tap
        // movement threshold — should count as neither.
        recognizer.process(.init(touches: [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)], timestamp: 0))
        recognizer.process(.init(touches: [touch(1, 0.42, 0.42), touch(2, 0.47, 0.42), touch(3, 0.42, 0.47)], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.1))

        XCTAssertTrue(fired.isEmpty)
    }

    // MARK: - 5-finger and diagonal swipes

    func testFiveFingerSwipeDown() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers: (Double) -> [MultitouchGestureEngine.Touch] = { y in
            (0..<5).map { self.touch(Int32($0 + 1), 0.4 + Double($0) * 0.02, y) }
        }

        recognizer.process(.init(touches: fingers(0.6), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.3), timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.1))

        XCTAssertEqual(fired, [.fiveFingerSwipeDown])
    }

    func testThreeFingerSwipeUpRight() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        let fingers: (Double, Double) -> [MultitouchGestureEngine.Touch] = { x, y in
            [self.touch(1, x, y), self.touch(2, x + 0.03, y), self.touch(3, x, y + 0.03)]
        }

        recognizer.process(.init(touches: fingers(0.3, 0.3), timestamp: 0))
        recognizer.process(.init(touches: fingers(0.45, 0.45), timestamp: 0.05)) // equal dx/dy -> exactly 45°
        recognizer.process(.init(touches: [], timestamp: 0.1))

        XCTAssertEqual(fired, [.threeFingerSwipeUpRight])
    }

    /// Drift guard: every finger-count x 8-direction combination the
    /// recognizer can construct must correspond to a real `GestureKind`
    /// case. This exercises the actual `process(_:)` path (not a
    /// duplicated lookup table) so a typo in the recognizer's internal
    /// word tables would show up here instead of only on real hardware.
    func testAllFingerCountsAndDirectionsProduceTheExpectedSwipeKind() {
        let directions: [(dx: Double, dy: Double, word: String)] = [
            (0.15, 0, "Right"), (0.11, 0.11, "UpRight"), (0, 0.15, "Up"), (-0.11, 0.11, "UpLeft"),
            (-0.15, 0, "Left"), (-0.11, -0.11, "DownLeft"), (0, -0.15, "Down"), (0.11, -0.11, "DownRight")
        ]
        let counts: [(Int, String)] = [(2, "two"), (3, "three"), (4, "four"), (5, "five")]

        for (count, countWord) in counts {
            for direction in directions {
                let recognizer = GestureRecognizer()
                var fired: [Trigger.GestureKind] = []
                recognizer.onGesture = { fired.append($0) }

                let start = (0..<count).map { self.touch(Int32($0 + 1), 0.4, 0.4 + Double($0) * 0.02) }
                let moved = (0..<count).map {
                    self.touch(Int32($0 + 1), 0.4 + direction.dx, 0.4 + direction.dy + Double($0) * 0.02)
                }

                recognizer.process(.init(touches: start, timestamp: 0))
                recognizer.process(.init(touches: moved, timestamp: 0.05))
                recognizer.process(.init(touches: [], timestamp: 0.1))

                let expected = Trigger.GestureKind(rawValue: "\(countWord)FingerSwipe\(direction.word)")
                XCTAssertNotNil(expected, "no GestureKind case for \(countWord)FingerSwipe\(direction.word)")
                XCTAssertEqual(fired, [expected].compactMap { $0 }, "count=\(count) direction=\(direction.word)")
            }
        }
    }

    // MARK: - Double-tap

    private var threeFingerTapFingers: [MultitouchGestureEngine.Touch] {
        [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4), touch(3, 0.4, 0.45)]
    }

    func testDoubleTapFiresBothSingleAndDoubleTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09)) // tap 1 finalizes

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0.2))
        recognizer.process(.init(touches: [], timestamp: 0.25))
        recognizer.process(.init(touches: [], timestamp: 0.29)) // tap 2 finalizes, within interval+distance of tap 1

        XCTAssertEqual(fired, [.threeFingerTap, .threeFingerTap, .threeFingerDoubleTap])
    }

    func testSlowSecondTapDoesNotFireDoubleTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09))

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 1.0)) // well past doubleTapMaxInterval
        recognizer.process(.init(touches: [], timestamp: 1.05))
        recognizer.process(.init(touches: [], timestamp: 1.09))

        XCTAssertEqual(fired, [.threeFingerTap, .threeFingerTap])
    }

    func testFarApartSecondTapDoesNotFireDoubleTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09))

        let farAway = [touch(1, 0.1, 0.1), touch(2, 0.15, 0.1), touch(3, 0.1, 0.15)]
        recognizer.process(.init(touches: farAway, timestamp: 0.2))
        recognizer.process(.init(touches: [], timestamp: 0.25))
        recognizer.process(.init(touches: [], timestamp: 0.29))

        XCTAssertEqual(fired, [.threeFingerTap, .threeFingerTap])
    }

    func testDifferentFingerCountDoesNotFireDoubleTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09))

        let twoFingers = [touch(1, 0.4, 0.4), touch(2, 0.45, 0.4)]
        recognizer.process(.init(touches: twoFingers, timestamp: 0.2))
        recognizer.process(.init(touches: [], timestamp: 0.25))
        recognizer.process(.init(touches: [], timestamp: 0.29))

        XCTAssertEqual(fired, [.threeFingerTap, .twoFingerTap])
    }

    func testTripleTapFiresOnlyOneDoubleTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09)) // tap 1

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0.2))
        recognizer.process(.init(touches: [], timestamp: 0.25))
        recognizer.process(.init(touches: [], timestamp: 0.29)) // tap 2 -> pairs with tap 1, consumes the pair

        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0.4))
        recognizer.process(.init(touches: [], timestamp: 0.45))
        recognizer.process(.init(touches: [], timestamp: 0.49)) // tap 3 -> no prior pending tap, just a single

        XCTAssertEqual(fired, [.threeFingerTap, .threeFingerTap, .threeFingerDoubleTap, .threeFingerTap])
    }

    func testSwipeBetweenTwoTapsDoesNotProduceAPhantomDoubleTap() {
        let recognizer = GestureRecognizer()
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }

        // Tap 1.
        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0))
        recognizer.process(.init(touches: [], timestamp: 0.05))
        recognizer.process(.init(touches: [], timestamp: 0.09))

        // An unrelated 2-finger swipe happens next — must clear the
        // pending-tap state so it doesn't pair with the tap that follows.
        let swipeFingers: (Double) -> [MultitouchGestureEngine.Touch] = { x in
            [self.touch(1, x, 0.7), self.touch(2, x, 0.75)]
        }
        recognizer.process(.init(touches: swipeFingers(0.1), timestamp: 0.15))
        recognizer.process(.init(touches: swipeFingers(0.3), timestamp: 0.2)) // crosses swipe threshold
        recognizer.process(.init(touches: [], timestamp: 0.25))
        recognizer.process(.init(touches: [], timestamp: 0.29)) // past the grace period: swipe's gesture actually ends

        // Tap 2, same position as tap 1 — but the swipe in between should
        // have reset the pending-tap state regardless of timing.
        recognizer.process(.init(touches: threeFingerTapFingers, timestamp: 0.35))
        recognizer.process(.init(touches: [], timestamp: 0.4))
        recognizer.process(.init(touches: [], timestamp: 0.44))

        XCTAssertEqual(fired, [.threeFingerTap, .twoFingerSwipeRight, .threeFingerTap])
    }
}
