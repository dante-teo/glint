import XCTest
@testable import Glint

final class AgentComposerEditorHeightTests: XCTestCase {

    func testBelowMinimumClampsToMinimum() {
        XCTAssertEqual(AgentComposer.clampedEditorHeight(for: 10), AgentComposer.minEditorHeight)
    }

    func testEmptyMeasurementClampsToMinimum() {
        XCTAssertEqual(AgentComposer.clampedEditorHeight(for: 0), AgentComposer.minEditorHeight)
    }

    func testWithinRangePassesThrough() {
        let mid = (AgentComposer.minEditorHeight + AgentComposer.maxEditorHeight) / 2
        XCTAssertEqual(AgentComposer.clampedEditorHeight(for: mid), mid)
    }

    func testAboveMaximumClampsToMaximum() {
        XCTAssertEqual(AgentComposer.clampedEditorHeight(for: 1000), AgentComposer.maxEditorHeight)
    }

    func testMinimumFitsAtLeastTwoLinesOfTheComposerFont() {
        // The composer uses a 14pt font with 8pt top/bottom padding; two
        // lines at a ~1.2x line-height ratio need at least ~34pt of text,
        // plus 16pt of padding. The minimum must be no smaller than that.
        let twoLineFloor: CGFloat = 14 * 1.2 * 2 + 16
        XCTAssertGreaterThanOrEqual(AgentComposer.minEditorHeight, twoLineFloor)
    }

    func testMinimumIsNotLargerThanMaximum() {
        XCTAssertLessThanOrEqual(AgentComposer.minEditorHeight, AgentComposer.maxEditorHeight)
    }
}
