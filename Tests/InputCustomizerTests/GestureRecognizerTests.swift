import XCTest
@testable import InputCustomizer

final class GestureRecognizerTests: XCTestCase {
    private func touch(_ id: Int32, _ x: Double, _ y: Double, state: Int32 = 4) -> MultitouchGestureEngine.Touch {
        MultitouchGestureEngine.Touch(id: id, position: CGPoint(x: x, y: y), state: state)
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
}
