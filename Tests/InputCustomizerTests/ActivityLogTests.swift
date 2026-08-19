import XCTest
@testable import InputCustomizer

final class ActivityLogTests: XCTestCase {
    func testLogAppendsEntriesInOrder() {
        let log = ActivityLog()
        log.log(.detected, "first")
        log.log(.fired, "second")

        XCTAssertEqual(log.entries.map(\.message), ["first", "second"])
        XCTAssertEqual(log.entries.map(\.kind), [.detected, .fired])
    }

    func testLogCapsEntriesAndDropsOldest() {
        let log = ActivityLog()
        for i in 0..<250 {
            log.log(.info, "entry \(i)")
        }

        XCTAssertEqual(log.entries.count, 200)
        // The oldest 50 should have been dropped, keeping the most recent 200.
        XCTAssertEqual(log.entries.first?.message, "entry 50")
        XCTAssertEqual(log.entries.last?.message, "entry 249")
    }

    func testClearRemovesAllEntries() {
        let log = ActivityLog()
        log.log(.executing, "something")
        XCTAssertFalse(log.entries.isEmpty)

        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}
