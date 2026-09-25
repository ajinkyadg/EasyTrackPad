import XCTest
@testable import InputCustomizer
import GestureEngine
import InputModels

/// Hold-tap: three fingers rest ~17mm apart in a row on a 130×80mm
/// surface; the leftmost or rightmost lifts and taps back down while the
/// other two stay put.
final class HoldTapRecognizerTests: XCTestCase {
    private typealias Touch = MultitouchGestureEngine.Touch

    private func touch(_ id: Int32, _ x: Double, _ y: Double = 0.5) -> Touch {
        Touch(id: id, position: CGPoint(x: x, y: y), state: 4)
    }

    private let leftX = 0.45, middleX = 0.58, rightX = 0.71

    private func three(dx: Double = 0) -> [Touch] {
        [touch(1, leftX + dx), touch(2, middleX + dx), touch(3, rightX + dx)]
    }

    private func recognizer(surface: CGSize? = CGSize(width: 130, height: 80)) -> (GestureRecognizer, () -> [Trigger.GestureKind]) {
        let recognizer = GestureRecognizer()
        recognizer.holdTapSurfaceSizeMM = surface
        var fired: [Trigger.GestureKind] = []
        recognizer.onGesture = { fired.append($0) }
        return (recognizer, { fired })
    }

    /// Feeds `touches(t)` every 10ms over `[from, to)`.
    private func feed(_ r: GestureRecognizer, from: Double, to: Double, _ touches: (Double) -> [Touch]) {
        var t = from
        while t < to - 0.0001 {
            r.process(.init(touches: touches(t), timestamp: t))
            t += 0.01
        }
    }

    private func end(_ r: GestureRecognizer, at t: Double) {
        r.process(.init(touches: [], timestamp: t))
        r.process(.init(touches: [], timestamp: t + 0.1))
    }

    private func holdTapKinds(_ kinds: [Trigger.GestureKind]) -> [Trigger.GestureKind] {
        kinds.filter { $0.category == .holdTap }
    }

    /// Rest 0.3s, right finger up for `liftFor`, back down as a new contact.
    private func rightTap(_ r: GestureRecognizer, relandX: Double? = nil, liftFor: Double = 0.1) {
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.3 + liftFor) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.3 + liftFor, to: 0.6 + liftFor) { _ in
            [self.touch(1, self.leftX), self.touch(2, self.middleX), self.touch(4, relandX ?? self.rightX)]
        }
        end(r, at: 0.6 + liftFor)
    }

    // MARK: - Fires

    func testRightFingerTapFiresExactlyOnce() {
        let (r, fired) = recognizer()
        rightTap(r)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight], "no 3-finger tap when all fingers lift at the end")
    }

    func testLeftFingerTapFires() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.4) { _ in [self.touch(2, self.middleX), self.touch(3, self.rightX)] }
        feed(r, from: 0.4, to: 0.6) { _ in [self.touch(4, self.leftX), self.touch(2, self.middleX), self.touch(3, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(fired(), [.threeFingerHoldTapLeft])
    }

    func testRepeatedTapsEachFire() {
        let (r, fired) = recognizer()
        let anchors = [touch(1, leftX), touch(2, middleX)]
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.4) { _ in anchors }
        feed(r, from: 0.4, to: 0.5) { _ in anchors + [self.touch(4, self.rightX)] }
        feed(r, from: 0.5, to: 0.6) { _ in anchors }
        feed(r, from: 0.6, to: 0.7) { _ in anchors + [self.touch(5, self.rightX)] }
        end(r, at: 0.7)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight, .threeFingerHoldTapRight])
    }

    /// The owner's natural rest: fingers of different lengths in an arc,
    /// ~16.6mm top to bottom (the most measured on real hardware).
    func testNaturalFingerArcFires() {
        let (r, fired) = recognizer()
        let arc = [touch(1, leftX, 0.5), touch(2, middleX, 0.29), touch(3, rightX, 0.47)] // 0.21 × 80mm ≈ 16.8mm
        feed(r, from: 0, to: 0.3) { _ in arc }
        feed(r, from: 0.3, to: 0.4) { _ in Array(arc.prefix(2)) }
        feed(r, from: 0.4, to: 0.6) { _ in Array(arc.prefix(2)) + [self.touch(4, self.rightX, 0.47)] }
        end(r, at: 0.6)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight])
    }

    /// Natural tap-backs measured up to ~390ms on real hardware.
    func testUnhurriedTapFires() {
        let (r, fired) = recognizer()
        rightTap(r, liftFor: 0.39)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight])
    }

    // MARK: - Must not fire

    func testTwentyMillimetreSpreadDoesNotFire() {
        let (r, fired) = recognizer()
        let wide = [touch(1, leftX, 0.5), touch(2, middleX, 0.25), touch(3, rightX, 0.5)] // 0.25 × 80mm = 20mm
        feed(r, from: 0, to: 0.3) { _ in wide }
        feed(r, from: 0.3, to: 0.4) { _ in Array(wide.prefix(2)) }
        feed(r, from: 0.4, to: 0.6) { _ in Array(wide.prefix(2)) + [self.touch(4, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testLiftJustOverTheCapDoesNotFire() {
        let (r, fired) = recognizer()
        rightTap(r, liftFor: 0.43)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    /// Two fingertips resting plus a thumb tucked 24mm lower: the thumb is
    /// the outermost finger in x, but it isn't part of a fingertip row.
    func testThumbPlusTwoFingersDoesNotFire() {
        let (r, fired) = recognizer()
        let hand = [touch(1, leftX, 0.8), touch(2, middleX), touch(3, rightX)] // thumb 0.3 × 80mm = 24mm lower
        feed(r, from: 0, to: 0.3) { _ in hand }
        feed(r, from: 0.3, to: 0.4) { _ in Array(hand.suffix(2)) }
        feed(r, from: 0.4, to: 0.6) { _ in [self.touch(4, self.leftX, 0.8)] + Array(hand.suffix(2)) }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testMiddleFingerTapDoesNotFire() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.4) { _ in [self.touch(1, self.leftX), self.touch(3, self.rightX)] }
        feed(r, from: 0.4, to: 0.6) { _ in [self.touch(1, self.leftX), self.touch(4, self.middleX), self.touch(3, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testLiftBeforeFingersSettledDoesNotFire() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.1) { _ in self.three() }
        feed(r, from: 0.1, to: 0.2) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.2, to: 0.4) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX), self.touch(4, self.rightX)] }
        end(r, at: 0.4)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testOneFrameFlickerDoesNotFire() {
        let (r, fired) = recognizer()
        rightTap(r, liftFor: 0.01)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testLongLiftDoesNotFire() {
        let (r, fired) = recognizer()
        rightTap(r, liftFor: 0.5)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testRelandingFarFromWhereItLiftedDoesNotFire() {
        let (r, fired) = recognizer()
        rightTap(r, relandX: 0.91) // ~26mm to the right
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testAnchorMovingWhileFingerIsUpDoesNotFire() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.4) { t in [self.touch(1, self.leftX), self.touch(2, self.middleX, 0.5 - (t - 0.3) * 0.5)] }
        feed(r, from: 0.4, to: 0.6) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX, 0.45), self.touch(4, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testDragThenPauseThenLiftDoesNotFire() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.1) { t in self.three(dx: t) } // 3-finger drag
        feed(r, from: 0.1, to: 0.5) { _ in self.three(dx: 0.1) } // pause
        feed(r, from: 0.5, to: 0.6) { _ in Array(self.three(dx: 0.1).prefix(2)) }
        feed(r, from: 0.6, to: 0.8) { _ in Array(self.three(dx: 0.1).prefix(2)) + [self.touch(4, self.rightX + 0.1)] }
        end(r, at: 0.8)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testFingersNotInARowDoNotFire() {
        let (r, fired) = recognizer()
        let slanted = [touch(1, leftX, 0.3), touch(2, middleX, 0.5), touch(3, rightX, 0.7)] // 32mm y-spread
        feed(r, from: 0, to: 0.3) { _ in slanted }
        feed(r, from: 0.3, to: 0.4) { _ in Array(slanted.prefix(2)) }
        feed(r, from: 0.4, to: 0.6) { _ in Array(slanted.prefix(2)) + [self.touch(4, self.rightX, 0.7)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testStaggeredLiftAtEndOfHoldDoesNotFire() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.35) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.35, to: 0.4) { _ in [self.touch(1, self.leftX)] }
        end(r, at: 0.4)
        XCTAssertEqual(fired(), [])
    }

    func testLiftedFingerThatDraggedBeforeLiftingDoesNotArm() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { t in
            [self.touch(1, self.leftX), self.touch(2, self.middleX), self.touch(3, self.rightX, 0.5 - t * 0.2)] // right finger slides 0.06
        }
        feed(r, from: 0.3, to: 0.4) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.4, to: 0.6) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX), self.touch(4, self.rightX, 0.44)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testShortZeroTouchBlipWhileFingerIsUpStillResolves() {
        let (r, fired) = recognizer()
        let anchors = [touch(1, leftX), touch(2, middleX)]
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.35) { _ in anchors }
        r.process(.init(touches: [], timestamp: 0.35)) // 10ms blip, inside the end grace period
        feed(r, from: 0.36, to: 0.4) { _ in anchors }
        feed(r, from: 0.4, to: 0.6) { _ in anchors + [self.touch(4, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight])
    }

    func testLongZeroTouchGapWhileFingerIsUpDiscards() {
        let (r, fired) = recognizer()
        let anchors = [touch(1, leftX), touch(2, middleX)]
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.34) { _ in anchors }
        feed(r, from: 0.34, to: 0.38) { _ in [] } // 40ms: the hold really ended
        feed(r, from: 0.38, to: 0.42) { _ in anchors }
        feed(r, from: 0.42, to: 0.6) { _ in anchors + [self.touch(4, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    // MARK: - Interaction with other gestures in the same hold

    func testNoHoldTapAfterASwipeFiredThisHold() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.1) { t in self.three(dx: t * 1.5) } // swipes right
        feed(r, from: 0.1, to: 0.5) { _ in self.three(dx: 0.15) }
        feed(r, from: 0.5, to: 0.6) { _ in Array(self.three(dx: 0.15).prefix(2)) }
        feed(r, from: 0.6, to: 0.8) { _ in Array(self.three(dx: 0.15).prefix(2)) + [self.touch(4, self.rightX + 0.15)] }
        end(r, at: 0.8)
        XCTAssertEqual(fired(), [.threeFingerSwipeRight])
    }

    func testNoSwipeFromFingersDriftingAfterAHoldTap() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.4) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.4, to: 0.6) { t in
            let dx = (t - 0.4) * 1.0 // drifts 0.2 after the tap
            return [self.touch(1, self.leftX + dx), self.touch(2, self.middleX + dx), self.touch(4, self.rightX + dx)]
        }
        end(r, at: 0.6)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight])
    }

    func testNoTwoFingerSplitTapDuringRaggedLiftAfterAHoldTap() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in self.three() }
        feed(r, from: 0.3, to: 0.4) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.4, to: 0.5) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX), self.touch(4, self.rightX)] }
        feed(r, from: 0.5, to: 0.55) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        feed(r, from: 0.55, to: 0.6) { _ in [self.touch(1, self.leftX)] }
        feed(r, from: 0.6, to: 0.65) { _ in [self.touch(1, self.leftX), self.touch(2, self.middleX)] }
        end(r, at: 0.65)
        XCTAssertEqual(fired(), [.threeFingerHoldTapRight])
    }

    // MARK: - Fails closed

    func testDuplicateTouchIDsFailClosedWithoutCrashing() {
        let (r, fired) = recognizer()
        feed(r, from: 0, to: 0.3) { _ in [self.touch(1, self.leftX), self.touch(1, self.middleX), self.touch(3, self.rightX)] }
        feed(r, from: 0.3, to: 0.4) { _ in [self.touch(1, self.leftX), self.touch(1, self.middleX)] }
        feed(r, from: 0.4, to: 0.6) { _ in [self.touch(1, self.leftX), self.touch(1, self.middleX), self.touch(4, self.rightX)] }
        end(r, at: 0.6)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    func testNoSurfaceSizeDisablesHoldTap() {
        let (r, fired) = recognizer(surface: nil)
        rightTap(r)
        XCTAssertEqual(holdTapKinds(fired()), [])
    }

    // MARK: - Model

    func testHoldTapIsItsOwnCategoryAndNeverRepeats() {
        for kind in [Trigger.GestureKind.threeFingerHoldTapLeft, .threeFingerHoldTapRight] {
            XCTAssertEqual(kind.category, .holdTap)
            XCTAssertNil(kind.swipeAngleDegrees)
            XCTAssertFalse(Trigger.trackpadGesture(kind).supportsRepeatWhileHeld)
            XCTAssertFalse(Trigger.trackpadGesture(kind).supportsRepeatByDistance)
        }
        XCTAssertEqual(Trigger.GestureKind.threeFingerHoldTapLeft.holdTapIsLeft, true)
        XCTAssertEqual(Trigger.GestureKind.threeFingerHoldTapRight.holdTapIsLeft, false)
    }

    /// ⌘ may only stay held for a trackpad hold-tap — a gripped Magic
    /// Mouse, or a swipe/tap/pinch, must get a single press instead.
    func testAppSwitcherHoldsCommandOnlyForTrackpadHoldTaps() {
        XCTAssertTrue(TrackpadManager.appSwitcherHoldsCommand(gesture: .threeFingerHoldTapRight, device: .trackpad))
        XCTAssertTrue(TrackpadManager.appSwitcherHoldsCommand(gesture: .threeFingerHoldTapLeft, device: .trackpad))
        XCTAssertFalse(TrackpadManager.appSwitcherHoldsCommand(gesture: .threeFingerHoldTapRight, device: .magicMouse))
        XCTAssertFalse(TrackpadManager.appSwitcherHoldsCommand(gesture: .twoFingerSwipeRight, device: .magicMouse))
        XCTAssertFalse(TrackpadManager.appSwitcherHoldsCommand(gesture: .threeFingerSwipeRight, device: .trackpad))
        XCTAssertFalse(TrackpadManager.appSwitcherHoldsCommand(gesture: .threeFingerTap, device: .trackpad))
        XCTAssertFalse(TrackpadManager.appSwitcherHoldsCommand(gesture: .pinchIn, device: .trackpad))
        XCTAssertFalse(TrackpadManager.appSwitcherHoldsCommand(gesture: nil, device: .trackpad), "repeat-while-held ticks")
    }

    func testAppSwitcherActionRoundTripsThroughCodable() throws {
        for action in [Action.appSwitcher(forward: true), .appSwitcher(forward: false)] {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(Action.self, from: data), action)
        }
    }
}
