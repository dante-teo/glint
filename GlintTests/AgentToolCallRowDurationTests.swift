import XCTest
@testable import Glint

final class AgentToolCallRowDurationTests: XCTestCase {
    func testSubSecondFormatsAsLessThanOneSecond() {
        let start = Date()
        XCTAssertEqual(AgentToolCallRow.formattedDuration(from: start, to: start.addingTimeInterval(0.4)), "<1s")
    }

    func testWholeSecondsUnderAMinute() {
        let start = Date()
        XCTAssertEqual(AgentToolCallRow.formattedDuration(from: start, to: start.addingTimeInterval(12)), "12s")
    }

    func testMinutesAndSecondsOverAMinute() {
        let start = Date()
        XCTAssertEqual(AgentToolCallRow.formattedDuration(from: start, to: start.addingTimeInterval(75)), "1m 15s")
    }

    /// Regression test for a "stuck" tool call misleadingly reporting a
    /// tiny duration forever: a non-terminal tool call's elapsed time must
    /// always be measured against the current moment, not the timestamp of
    /// whatever notification last updated it. Simulates a tool call whose
    /// last update was seconds after it started, but where real wall-clock
    /// time has since moved on much further (no further notifications ever
    /// arrived) — the duration must reflect the true elapsed time, not the
    /// stale last-update gap, so a genuinely hung tool call is visible
    /// (ticking upward) instead of looking like it just started.
    func testElapsedTimeIsMeasuredAgainstNowNotLastUpdate() {
        let start = Date(timeIntervalSince1970: 0)
        let lastUpdate = start.addingTimeInterval(0.5) // what `toolUpdatedAt` used to be compared against
        let muchLater = start.addingTimeInterval(600) // 10 real minutes later, tool never completed

        XCTAssertEqual(AgentToolCallRow.formattedDuration(from: start, to: lastUpdate), "<1s")
        XCTAssertEqual(AgentToolCallRow.formattedDuration(from: start, to: muchLater), "10m 0s")
    }
}
