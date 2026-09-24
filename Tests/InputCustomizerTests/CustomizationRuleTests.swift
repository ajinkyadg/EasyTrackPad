import Cocoa
import XCTest
@testable import InputCustomizer
import GestureEngine
import InputModels

final class CustomizationRuleTests: XCTestCase {
    func testRuleRoundTripsThroughJSON() throws {
        let rule = CustomizationRule(
            name: "Test swipe",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .missionControl
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(CustomizationRule.self, from: data)
        XCTAssertEqual(rule, decoded)
    }

    func testMouseCornerClickTriggerRoundTripsThroughJSON() throws {
        let rule = CustomizationRule(
            name: "Close tab",
            device: .mouse,
            trigger: .mouseCornerClick(corner: .topRight, number: 0, modifiers: 0),
            action: .remapToKey(keyCode: 13, modifiers: 1_048_576)
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(CustomizationRule.self, from: data)
        XCTAssertEqual(rule, decoded)
    }

    /// `RulePreset.id == name` (see its doc comment) — a duplicate name
    /// would mean two presets silently collide as the same `Identifiable`
    /// item in the "Add from Preset" list. Guards against exactly the
    /// kind of collision that was almost introduced when the Magic Mouse
    /// preset list grew to 26 entries (e.g. "Mission Control" already
    /// existed as a plain trackpad preset).
    func testGesturePresetsHaveUniqueNames() {
        let names = GesturePresets.all.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "duplicate preset name(s): \(duplicates)")
    }

    /// Locks in the numeric value of `GesturePresets`'s private
    /// Control+Command modifier constant indirectly, the same way the
    /// existing modifier constants are only ever exercised through a
    /// preset's actual encoded action — a typo'd raw value here would
    /// silently post the wrong modifier keys.
    func testControlCommandModifierPresetsEncodeTheExpectedModifierValue() {
        let controlCommand: UInt = 1_310_720
        for name in ["Full Screen Toggle (3-Finger Swipe Up)", "Lock Screen (3-Finger Tap)"] {
            guard let preset = GesturePresets.all.first(where: { $0.name == name }) else {
                XCTFail("expected preset \(name) to exist")
                continue
            }
            guard case let .remapToKey(_, modifiers) = preset.action else {
                XCTFail("expected \(name) to be a remapToKey action")
                continue
            }
            XCTAssertEqual(modifiers, controlCommand, "\(name) should use Control+Command")
        }
    }

    func testAppliesWhileFrontmostAppIsRespectsRestrictedToApps() {
        var rule = CustomizationRule(
            name: "Test",
            device: .trackpad,
            trigger: .trackpadGesture(.threeFingerSwipeLeft),
            action: .missionControl
        )
        // Empty (default): applies everywhere, regardless of frontmost app.
        XCTAssertTrue(rule.applies(whileFrontmostAppIs: "com.apple.Safari"))
        XCTAssertTrue(rule.applies(whileFrontmostAppIs: nil))

        rule.restrictedToApps = [
            AppReference(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome"),
            AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        ]
        XCTAssertTrue(rule.applies(whileFrontmostAppIs: "com.apple.Safari"))
        XCTAssertTrue(rule.applies(whileFrontmostAppIs: "com.google.Chrome"))
        XCTAssertFalse(rule.applies(whileFrontmostAppIs: "com.apple.Finder"))
        // Fail open: an unknown frontmost app shouldn't silently disable
        // every app-scoped rule.
        XCTAssertTrue(rule.applies(whileFrontmostAppIs: nil))
    }

    private func scratchStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        return SettingsStore(fileURL: url)
    }

    func testRulesForDeviceFiltersByDeviceAndEnabled() {
        let store = scratchStore()
        store.addRule(CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl))
        store.addRule(CustomizationRule(name: "B", device: .trackpad, trigger: .trackpadGesture(.pinchIn), action: .missionControl))
        store.addRule(CustomizationRule(name: "C", device: .mouse, trigger: .mouseButton(number: 4, modifiers: 0), action: .missionControl, isEnabled: false))
        XCTAssertEqual(store.rules(for: .mouse).map(\.name), ["A"])
    }

    func testRulesForDeviceReturnsEmptyWhenPaused() {
        let store = scratchStore()
        defer { store.isPaused = false } // isPaused persists via UserDefaults.standard
        store.addRule(CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl))
        store.isPaused = true
        XCTAssertEqual(store.rules(for: .mouse), [])
    }

    func testKeyCodeMapDescribesUnsetAndCombos() {
        XCTAssertEqual(KeyCodeMap.describe(keyCode: KeyCodeMap.unset, modifiers: 0), "Not set")
        // keyCode 0 = "A", with Command + Shift modifiers.
        let modifiers = UInt(NSEvent.ModifierFlags([.command, .shift]).rawValue)
        XCTAssertEqual(KeyCodeMap.describe(keyCode: 0, modifiers: modifiers), "⇧⌘A")
    }

    func testGestureKindDisplayNameAndIconCoverage() {
        // Every case must produce a non-empty, non-raw-fallback display
        // name and a real-looking icon symbol — guards the camelCase-word
        // derivation against silently falling through to `rawValue` /
        // "questionmark" for any case, especially the ones that broke a
        // naive positional-parsing approach during design (DoubleTap,
        // diagonal swipes).
        for kind in Trigger.GestureKind.allCases {
            XCTAssertNotEqual(kind.displayName, kind.rawValue, "displayName fell through to raw value for \(kind)")
            XCTAssertNotEqual(kind.iconSymbolName, "questionmark", "iconSymbolName fell through for \(kind)")
        }

        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeUpLeft.displayName, "3-Finger Swipe Up-Left")
        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeUpLeft.iconSymbolName, "arrow.up.left")
        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeUpLeft.fingerCount, 3)
        XCTAssertFalse(Trigger.GestureKind.threeFingerSwipeUpLeft.isDoubleTap)

        XCTAssertEqual(Trigger.GestureKind.fiveFingerDoubleTap.displayName, "5-Finger Double Tap")
        XCTAssertEqual(Trigger.GestureKind.fiveFingerDoubleTap.iconSymbolName, "hand.tap.fill")
        XCTAssertEqual(Trigger.GestureKind.fiveFingerDoubleTap.fingerCount, 5)
        XCTAssertTrue(Trigger.GestureKind.fiveFingerDoubleTap.isDoubleTap)

        XCTAssertEqual(Trigger.GestureKind.fourFingerTap.displayName, "4-Finger Tap")
        XCTAssertEqual(Trigger.GestureKind.fourFingerTap.iconSymbolName, "hand.tap.fill")
        XCTAssertFalse(Trigger.GestureKind.fourFingerTap.isDoubleTap)

        XCTAssertEqual(Trigger.GestureKind.pinchIn.displayName, "Pinch In")
        XCTAssertEqual(Trigger.GestureKind.pinchIn.iconSymbolName, "minus.magnifyingglass")
        XCTAssertNil(Trigger.GestureKind.pinchIn.fingerCount)

        XCTAssertEqual(Trigger.GestureKind.rotateClockwise.iconSymbolName, "arrow.clockwise")
    }

    func testGestureKindCategoryAndSwipeAngle() {
        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeRight.category, .swipe)
        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeRight.swipeAngleDegrees, 0)
        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeUp.swipeAngleDegrees, 90)
        XCTAssertEqual(Trigger.GestureKind.threeFingerSwipeUpLeft.swipeAngleDegrees, 135)
        XCTAssertEqual(Trigger.GestureKind.fourFingerSwipeDownRight.swipeAngleDegrees, 315)

        XCTAssertEqual(Trigger.GestureKind.fourFingerTap.category, .tap)
        XCTAssertNil(Trigger.GestureKind.fourFingerTap.swipeAngleDegrees)

        XCTAssertEqual(Trigger.GestureKind.threeFingerDoubleTap.category, .doubleTap)
        XCTAssertNil(Trigger.GestureKind.threeFingerDoubleTap.swipeAngleDegrees)

        XCTAssertEqual(Trigger.GestureKind.pinchIn.category, .pinchIn)
        XCTAssertEqual(Trigger.GestureKind.pinchOut.category, .pinchOut)
        XCTAssertEqual(Trigger.GestureKind.rotateClockwise.category, .rotateClockwise)
        XCTAssertEqual(Trigger.GestureKind.rotateCounterClockwise.category, .rotateCounterClockwise)

        // Every swipe case must resolve to a real angle — a gap here would
        // mean GestureGlyphView silently draws no arrow for that case.
        for kind in Trigger.GestureKind.allCases where kind.category == .swipe {
            XCTAssertNotNil(kind.swipeAngleDegrees, "no angle for \(kind)")
        }
    }

    func testSplitSwipeKindsHaveCorrectDerivedProperties() {
        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftSwipeUp.category, .splitSwipe)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightSwipeDown.category, .splitSwipe)

        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftSwipeUp.fingerCount, 2)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightSwipeDown.fingerCount, 2)

        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftSwipeUp.swipeAngleDegrees, 90)
        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftSwipeDown.swipeAngleDegrees, 270)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightSwipeUp.swipeAngleDegrees, 90)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightSwipeDown.swipeAngleDegrees, 270)

        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftSwipeUp.splitActiveFingerIsLeft, true)
        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftSwipeDown.splitActiveFingerIsLeft, true)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightSwipeUp.splitActiveFingerIsLeft, false)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightSwipeDown.splitActiveFingerIsLeft, false)
        XCTAssertNil(Trigger.GestureKind.twoFingerSwipeUp.splitActiveFingerIsLeft)

        XCTAssertFalse(Trigger.GestureKind.twoFingerLeftSwipeUp.isDoubleTap)
        XCTAssertNotEqual(Trigger.GestureKind.twoFingerLeftSwipeUp.displayName, Trigger.GestureKind.twoFingerRightSwipeUp.displayName)

        XCTAssertTrue(Trigger.trackpadGesture(.twoFingerLeftSwipeUp).supportsRepeatWhileHeld)
        XCTAssertTrue(Trigger.trackpadGesture(.twoFingerRightSwipeDown).supportsRepeatWhileHeld)
    }

    func testSplitTapKindsHaveCorrectDerivedProperties() {
        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftTap.category, .splitTap)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightTap.category, .splitTap)

        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftTap.fingerCount, 2)
        XCTAssertNil(Trigger.GestureKind.twoFingerLeftTap.swipeAngleDegrees, "a tap has no travel direction")

        XCTAssertEqual(Trigger.GestureKind.twoFingerLeftTap.splitActiveFingerIsLeft, true)
        XCTAssertEqual(Trigger.GestureKind.twoFingerRightTap.splitActiveFingerIsLeft, false)

        XCTAssertFalse(Trigger.GestureKind.twoFingerLeftTap.isDoubleTap)
        XCTAssertNotEqual(Trigger.GestureKind.twoFingerLeftTap.displayName, Trigger.GestureKind.twoFingerRightTap.displayName)

        // Unlike split-swipe, a split-tap isn't a "hold" gesture — nothing
        // to repeat while held, and it doesn't measure travel at all.
        XCTAssertFalse(Trigger.trackpadGesture(.twoFingerLeftTap).supportsRepeatWhileHeld)
        XCTAssertFalse(Trigger.trackpadGesture(.twoFingerRightTap).supportsRepeatByDistance)
    }

    func testSupportsRepeatWhileHeldOnlyForSwipeTriggers() {
        XCTAssertTrue(Trigger.trackpadGesture(.threeFingerSwipeLeft).supportsRepeatWhileHeld)
        XCTAssertTrue(Trigger.trackpadGesture(.fiveFingerSwipeUpRight).supportsRepeatWhileHeld)

        XCTAssertFalse(Trigger.trackpadGesture(.threeFingerTap).supportsRepeatWhileHeld)
        XCTAssertFalse(Trigger.trackpadGesture(.threeFingerDoubleTap).supportsRepeatWhileHeld)
        XCTAssertFalse(Trigger.trackpadGesture(.pinchIn).supportsRepeatWhileHeld)
        XCTAssertFalse(Trigger.trackpadGesture(.rotateClockwise).supportsRepeatWhileHeld)

        XCTAssertFalse(Trigger.keyCombo(keyCode: 0, modifiers: 0).supportsRepeatWhileHeld)
        XCTAssertFalse(Trigger.mouseButton(number: 3, modifiers: 0).supportsRepeatWhileHeld)
    }

    func testSupportsRepeatByDistanceOnlyForOrdinarySwipeTriggers() {
        XCTAssertTrue(Trigger.trackpadGesture(.threeFingerSwipeLeft).supportsRepeatByDistance)
        XCTAssertTrue(Trigger.trackpadGesture(.fiveFingerSwipeUpRight).supportsRepeatByDistance)

        // Unlike supportsRepeatWhileHeld, .splitSwipe is NOT included —
        // distance-repeat only tracks travel via the shared centroid,
        // which .splitSwipe doesn't use.
        XCTAssertFalse(Trigger.trackpadGesture(.twoFingerLeftSwipeUp).supportsRepeatByDistance)
        XCTAssertFalse(Trigger.trackpadGesture(.twoFingerRightSwipeDown).supportsRepeatByDistance)

        XCTAssertFalse(Trigger.trackpadGesture(.threeFingerTap).supportsRepeatByDistance)
        XCTAssertFalse(Trigger.trackpadGesture(.threeFingerDoubleTap).supportsRepeatByDistance)
        XCTAssertFalse(Trigger.trackpadGesture(.pinchIn).supportsRepeatByDistance)
        XCTAssertFalse(Trigger.trackpadGesture(.rotateClockwise).supportsRepeatByDistance)

        XCTAssertFalse(Trigger.keyCombo(keyCode: 0, modifiers: 0).supportsRepeatByDistance)
        XCTAssertFalse(Trigger.mouseButton(number: 3, modifiers: 0).supportsRepeatByDistance)
    }

    func testUpdateRuleReplacesInPlacePreservingOtherRules() {
        let store = scratchStore()
        let target = CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)
        let other = CustomizationRule(name: "B", device: .trackpad, trigger: .trackpadGesture(.pinchIn), action: .missionControl)
        store.addRule(target)
        store.addRule(other)

        var updated = target
        updated.name = "A renamed"
        updated.isEnabled = false
        store.updateRule(updated)

        let rules = store.selectedProfile?.rules ?? []
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].name, "A renamed")
        XCTAssertEqual(rules[0].id, target.id)
        XCTAssertFalse(rules[0].isEnabled)
        XCTAssertEqual(rules[1], other)
    }

    func testUpdateRuleIsNoOpWhenIdNotFound() {
        let store = scratchStore()
        let existing = CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)
        store.addRule(existing)

        let stranger = CustomizationRule(name: "Not in store", device: .mouse, trigger: .mouseButton(number: 5, modifiers: 0), action: .missionControl)
        store.updateRule(stranger)

        XCTAssertEqual(store.selectedProfile?.rules, [existing])
    }

    func testLoadBacksUpUndecodableFileInsteadOfDiscardingIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        try Data("not valid json".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        }

        let store = SettingsStore(fileURL: url)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Default")
        XCTAssertEqual(store.profiles[0].rules, [])
        let backupData = try Data(contentsOf: url.appendingPathExtension("bak"))
        XCTAssertEqual(String(data: backupData, encoding: .utf8), "not valid json")
    }
}
