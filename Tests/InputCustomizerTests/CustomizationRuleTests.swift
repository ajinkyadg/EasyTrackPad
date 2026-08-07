import Cocoa
import XCTest
@testable import InputCustomizer

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

    private func scratchStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        return SettingsStore(fileURL: url)
    }

    func testRulesForDeviceFiltersByDeviceAndEnabled() {
        let store = scratchStore()
        store.rules = [
            CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl),
            CustomizationRule(name: "B", device: .trackpad, trigger: .trackpadGesture(.pinchIn), action: .missionControl),
            CustomizationRule(name: "C", device: .mouse, trigger: .mouseButton(number: 4, modifiers: 0), action: .missionControl, isEnabled: false)
        ]
        XCTAssertEqual(store.rules(for: .mouse).map(\.name), ["A"])
    }

    func testRulesForDeviceReturnsEmptyWhenPaused() {
        let store = scratchStore()
        defer { store.isPaused = false } // isPaused persists via UserDefaults.standard
        store.rules = [
            CustomizationRule(name: "A", device: .mouse, trigger: .mouseButton(number: 3, modifiers: 0), action: .missionControl)
        ]
        store.isPaused = true
        XCTAssertEqual(store.rules(for: .mouse), [])
    }

    func testKeyCodeMapDescribesUnsetAndCombos() {
        XCTAssertEqual(KeyCodeMap.describe(keyCode: KeyCodeMap.unset, modifiers: 0), "Not set")
        // keyCode 0 = "A", with Command + Shift modifiers.
        let modifiers = UInt(NSEvent.ModifierFlags([.command, .shift]).rawValue)
        XCTAssertEqual(KeyCodeMap.describe(keyCode: 0, modifiers: modifiers), "⇧⌘A")
    }
}
