import XCTest
@testable import Glint

@MainActor
final class AgentBusyStatusTests: XCTestCase {

    func testThinkingIsBusy() {
        XCTAssertTrue(WorkspaceStore.isBusyStatus(.thinking))
    }

    func testToolIsBusy() {
        XCTAssertTrue(WorkspaceStore.isBusyStatus(.tool))
    }

    func testCompactingIsBusy() {
        XCTAssertTrue(WorkspaceStore.isBusyStatus(.compacting))
    }

    func testNeedsPermissionIsBusy() {
        XCTAssertTrue(WorkspaceStore.isBusyStatus(.needsPermission))
    }

    func testIdleIsNotBusy() {
        XCTAssertFalse(WorkspaceStore.isBusyStatus(.idle))
    }

    func testJustCompletedIsNotBusy() {
        XCTAssertFalse(WorkspaceStore.isBusyStatus(.justCompleted))
    }

    func testFailedIsNotBusy() {
        XCTAssertFalse(WorkspaceStore.isBusyStatus(.failed))
    }
}
