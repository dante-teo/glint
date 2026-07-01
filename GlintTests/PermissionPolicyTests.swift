import XCTest
@testable import Glint

/// Pure tests for `PermissionPolicy.defaultPolicy(for:)`, a plain
/// non-actor-isolated static function. These don't touch `PermissionReviewer`
/// (a @MainActor type), so they live in their own unannotated file per
/// AGENTS.md convention (see `WorkspaceAgentCodableTests.swift` for the
/// canonical precedent).
final class PermissionPolicyTests: XCTestCase {
    func testDefaultPolicyAutoApprovesReadThinkFetchSearch() {
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .read), .autoApprove)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .think), .autoApprove)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .fetch), .autoApprove)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .search), .autoApprove)
    }

    func testDefaultPolicyAlwaysEscalatesDelete() {
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .delete), .alwaysEscalate)
    }

    func testDefaultPolicyAlwaysEscalatesNilKind() {
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: nil), .alwaysEscalate)
    }

    func testDefaultPolicyUsesLLMReviewForEditExecuteMoveOther() {
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .edit), .llmReview)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .execute), .llmReview)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .move), .llmReview)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .other), .llmReview)
        XCTAssertEqual(PermissionPolicy.defaultPolicy(for: .unknown("custom")), .llmReview)
    }
}
