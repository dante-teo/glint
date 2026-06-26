import XCTest
@testable import Glint

final class SleepAssertionTests: XCTestCase {

    func testStartsNotHolding() {
        let manager = SleepAssertionManager()
        XCTAssertFalse(manager.isHolding)
    }

    func testAcquireSetsHolding() {
        let manager = SleepAssertionManager()
        manager.acquire()
        XCTAssertTrue(manager.isHolding)
        manager.release()
    }

    func testDoubleAcquireIsIdempotent() {
        let manager = SleepAssertionManager()
        manager.acquire()
        manager.acquire()
        XCTAssertTrue(manager.isHolding)
        manager.release()
        XCTAssertFalse(manager.isHolding)
    }

    func testReleaseClearsHolding() {
        let manager = SleepAssertionManager()
        manager.acquire()
        manager.release()
        XCTAssertFalse(manager.isHolding)
    }

    func testDoubleReleaseIsSafe() {
        let manager = SleepAssertionManager()
        manager.acquire()
        manager.release()
        manager.release()
        XCTAssertFalse(manager.isHolding)
    }

    func testReleaseWithoutAcquireIsSafe() {
        let manager = SleepAssertionManager()
        manager.release()
        XCTAssertFalse(manager.isHolding)
    }
}
