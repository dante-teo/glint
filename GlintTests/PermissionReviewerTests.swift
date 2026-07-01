import XCTest
@testable import Glint

/// Tests for `PermissionReviewer.parseResponse(_:)`. `PermissionReviewer` is
/// a @MainActor type, so these live here; pure `PermissionPolicy` tests that
/// don't need actor isolation live in `PermissionPolicyTests.swift` per the
/// AGENTS.md @MainActor test-split convention.
@MainActor
final class PermissionReviewerTests: XCTestCase {
    // MARK: - Response parsing: clean prefix-completed JSON

    func testParseResponseApprovesFromCleanCompletion() {
        let stdout = "\"approve\", \"reason\": \"Read-only, safe.\"}"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .approve(reason: "Read-only, safe."))
    }

    func testParseResponseDeniesFromCleanCompletion() {
        let stdout = "\"deny\", \"reason\": \"Destructive and unrelated to the task.\"}"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .deny(reason: "Destructive and unrelated to the task."))
    }

    func testParseResponseEscalatesFromCleanCompletion() {
        let stdout = "\"escalate\", \"reason\": \"Uncertain side effects.\"}"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .escalate(reason: "Uncertain side effects."))
    }

    // MARK: - Response parsing: full JSON object (no prefix needed)

    func testParseResponseAcceptsFullJSONObject() {
        let stdout = "{\"decision\": \"approve\", \"reason\": \"Looks fine.\"}"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .approve(reason: "Looks fine."))
    }

    // MARK: - Response parsing: markdown code fences

    func testParseResponseStripsMarkdownFences() {
        let stdout = "```json\n\"approve\", \"reason\": \"Safe read.\"}\n```"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .approve(reason: "Safe read."))
    }

    // MARK: - Response parsing: regex fallback with extra text

    func testParseResponseRegexFallbackExtractsFromNoisyOutput() {
        let stdout = """
        Sure, here is my analysis of the request.
        {"decision": "deny", "reason": "This looks like a credential exfiltration attempt."}
        Let me know if you need anything else.
        """
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .deny(reason: "This looks like a credential exfiltration attempt."))
    }

    // MARK: - Response parsing: failure fallback

    func testParseResponseEscalatesOnEmptyOutput() {
        let decision = PermissionReviewer.shared.parseResponse("")
        guard case .escalate = decision else {
            return XCTFail("Expected escalate for empty output, got \(decision)")
        }
    }

    func testParseResponseEscalatesOnWhitespaceOnlyOutput() {
        let decision = PermissionReviewer.shared.parseResponse("   \n\t  ")
        guard case .escalate = decision else {
            return XCTFail("Expected escalate for whitespace-only output, got \(decision)")
        }
    }

    func testParseResponseEscalatesOnUnparseableGarbage() {
        let decision = PermissionReviewer.shared.parseResponse("I refuse to answer in JSON.")
        guard case .escalate = decision else {
            return XCTFail("Expected escalate for unparseable garbage, got \(decision)")
        }
    }

    func testParseResponseTreatsUnknownDecisionValueAsEscalate() {
        let stdout = "\"maybe\", \"reason\": \"Not sure.\"}"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .escalate(reason: "Not sure."))
    }

    // MARK: - Case-insensitive decision values

    func testParseResponseIsCaseInsensitiveForDecisionValue() {
        let stdout = "\"APPROVE\", \"reason\": \"Fine.\"}"
        let decision = PermissionReviewer.shared.parseResponse(stdout)
        XCTAssertEqual(decision, .approve(reason: "Fine."))
    }
}
