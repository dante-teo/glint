import XCTest
@testable import Glint

final class AgentPresentationTests: XCTestCase {
    func testContextUsagePercentHandlesMissingAndZeroSize() {
        XCTAssertEqual(AgentContextUsageFormatter.percent(for: nil), 0)
        XCTAssertEqual(AgentContextUsageFormatter.percent(for: .init(used: 10, size: 0, costAmount: nil, costCurrency: nil)), 0)
    }

    func testContextUsagePercentClampsOverfullUsage() {
        let usage = DevinSessionManager.UsageInfo(used: 120, size: 100, costAmount: nil, costCurrency: nil)

        XCTAssertEqual(AgentContextUsageFormatter.percent(for: usage), 1)
        XCTAssertTrue(AgentContextUsageFormatter.tooltip(for: usage).contains("100"))
    }

    func testToolCallDisplayTitleFallsBackForPartialToolUpdate() {
        let message = DevinSessionManager.Message(
            role: .toolCall,
            text: "",
            toolCallId: "tool-123",
            toolStatus: .inProgress
        )

        XCTAssertEqual(AgentToolCallDisplay.title(for: message), "Tool call tool-123")
    }

    func testToolCallDisplayTruncatesHugeTextAndKeepsPrimitiveJSONReadable() {
        let long = String(repeating: "a", count: 20)
        let truncated = AgentToolCallDisplay.truncated(long, limit: 8, expanded: false)

        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.text, "aaaaaaaa\n...")
        XCTAssertEqual(ACPJSONValue.string("done").prettyPrinted, "\"done\"")
    }
}
