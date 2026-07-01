import XCTest
@testable import Glint

final class ACPTypesTests: XCTestCase {
    func testEmptyResultResponseDecodes() throws {
        let data = #"{"jsonrpc":"2.0","id":1,"result":{}}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(ACPResponse<EmptyACPResult>.self, from: data)

        XCTAssertEqual(response.id, 1)
        XCTAssertNotNil(response.result)
        XCTAssertNil(response.error)
    }

    func testNewSessionResponseDecodesSessionId() throws {
        let data = #"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-123","models":[]}}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(ACPResponse<NewSessionResult>.self, from: data)

        XCTAssertEqual(response.id, 2)
        XCTAssertEqual(response.result?.sessionId, "session-123")
    }

    func testNewSessionResponseDecodesAlternateSessionID() throws {
        let data = #"{"jsonrpc":"2.0","id":3,"result":{"sessionID":"session-456"}}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(ACPResponse<NewSessionResult>.self, from: data)

        XCTAssertEqual(response.result?.sessionID, "session-456")
    }

    func testErrorResponseDecodes() throws {
        let data = #"{"jsonrpc":"2.0","id":4,"error":{"code":-32000,"message":"auth required"}}"#
            .data(using: .utf8)!

        let response = try JSONDecoder().decode(ACPResponse<EmptyACPResult>.self, from: data)

        XCTAssertEqual(response.id, 4)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.message, "auth required")
    }
}
