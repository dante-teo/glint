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

    func testInitializeRequestEncodesACPv1ClientCapabilities() throws {
        let data = try JSONEncoder().encode(ACPRequest(id: 1, method: "initialize", params: InitializeRequest()))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(params["clientCapabilities"] as? [String: Any])
        let fs = try XCTUnwrap(capabilities["fs"] as? [String: Any])

        XCTAssertEqual(params["protocolVersion"] as? Int, 1)
        XCTAssertEqual(fs["readTextFile"] as? Bool, true)
        XCTAssertEqual(fs["writeTextFile"] as? Bool, true)
        XCTAssertEqual(capabilities["terminal"] as? Bool, false)
    }

    func testNewSessionRequestEncodesEmptyMCPServers() throws {
        let request = ACPRequest(id: 2, method: "session/new", params: NewSessionRequest(cwd: "/tmp/project"))
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(json["params"] as? [String: Any])

        XCTAssertEqual(params["cwd"] as? String, "/tmp/project")
        XCTAssertEqual((params["mcpServers"] as? [Any])?.count, 0)
    }

    func testPromptRequestEncodesContentBlocks() throws {
        let request = ACPRequest(
            id: 3,
            method: "session/prompt",
            params: PromptRequest(sessionId: "session-123", prompt: [.text("hello")])
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        let prompt = try XCTUnwrap(params["prompt"] as? [[String: Any]])

        XCTAssertEqual(params["sessionId"] as? String, "session-123")
        XCTAssertEqual(prompt.first?["type"] as? String, "text")
        XCTAssertEqual(prompt.first?["text"] as? String, "hello")
    }

    func testNullResultResponseDecodesAsEmptyResult() throws {
        let data = #"{"jsonrpc":"2.0","id":5,"result":null}"#.data(using: .utf8)!

        let response = try JSONDecoder().decode(ACPResponse<EmptyACPResult>.self, from: data)

        XCTAssertEqual(response.id, 5)
        XCTAssertNotNil(response.result)
    }

    func testPromptResponseDefaultsEmptyResultToEndTurn() throws {
        let empty = try JSONDecoder().decode(PromptResponse.self, from: #"{}"#.data(using: .utf8)!)
        let null = try JSONDecoder().decode(PromptResponse.self, from: #"null"#.data(using: .utf8)!)

        XCTAssertEqual(empty.stopReason, .endTurn)
        XCTAssertEqual(null.stopReason, .endTurn)
    }

    func testSessionUpdateDecodesKnownVariants() throws {
        let cases: [(String, (SessionUpdate) -> Bool)] = [
            (#"{"sessionUpdate":"user_message_chunk","messageId":"u1","content":{"type":"text","text":"hi"}}"#, {
                if case .userMessageChunk(let chunk) = $0 { return chunk.messageId == "u1" }
                return false
            }),
            (#"{"sessionUpdate":"agent_message_chunk","messageId":"a1","content":{"type":"text","text":"hello"}}"#, {
                if case .agentMessageChunk(let chunk) = $0 { return chunk.content.plainText == "hello" }
                return false
            }),
            (#"{"sessionUpdate":"agent_thought_chunk","messageId":"t1","content":{"type":"text","text":"thinking"}}"#, {
                if case .agentThoughtChunk(let chunk) = $0 { return chunk.messageId == "t1" }
                return false
            }),
            (#"{"sessionUpdate":"tool_call","toolCallId":"tool1","title":"Read file","kind":"read","status":"pending"}"#, {
                if case .toolCall(let tool) = $0 { return tool.toolCallId == "tool1" && tool.kind == .read }
                return false
            }),
            (#"{"sessionUpdate":"tool_call_update","toolCallId":"tool1","status":"completed"}"#, {
                if case .toolCallUpdate(let tool) = $0 { return tool.status == .completed }
                return false
            }),
            (#"{"sessionUpdate":"plan","entries":[{"content":"step","status":"pending"}]}"#, {
                if case .plan(let plan) = $0 { return plan.entries.first?.content == "step" }
                return false
            }),
            (#"{"sessionUpdate":"usage_update","used":10,"size":100,"cost":{"amount":0.1,"currency":"USD"}}"#, {
                if case .usageUpdate(let usage) = $0 { return usage.used == 10 && usage.cost?.currency == "USD" }
                return false
            }),
            (#"{"sessionUpdate":"session_info_update","title":"New title"}"#, {
                if case .sessionInfoUpdate(let info) = $0 { return info.title == "New title" }
                return false
            }),
            (#"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#, {
                if case .currentModeUpdate(let mode) = $0 { return mode.currentModeId == "plan" }
                return false
            }),
            (#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"/reset"}]}"#, {
                if case .availableCommandsUpdate(let update) = $0 { return update.availableCommands.first?.name == "/reset" }
                return false
            }),
            (#"{"sessionUpdate":"config_option_update","configOptions":[{"id":"model","value":"fast"}]}"#, {
                if case .configOptionUpdate(let update) = $0 { return update.configOptions.first?.id == "model" }
                return false
            }),
        ]

        for (json, matches) in cases {
            let update = try JSONDecoder().decode(SessionUpdate.self, from: json.data(using: .utf8)!)
            XCTAssertTrue(matches(update), "Failed to match \(json)")
        }
    }

    func testUnknownSessionUpdateIsTolerated() throws {
        let data = #"{"sessionUpdate":"future_update","value":42}"#.data(using: .utf8)!

        let update = try JSONDecoder().decode(SessionUpdate.self, from: data)

        if case .unknown(let name, let raw) = update {
            XCTAssertEqual(name, "future_update")
            XCTAssertEqual(raw, .object(["sessionUpdate": .string("future_update"), "value": .number(42)]))
        } else {
            XCTFail("Expected unknown update")
        }
    }

    func testUnknownEnumValuesAreTolerated() throws {
        let tool = try JSONDecoder().decode(
            ToolCallUpdate.self,
            from: #"{"sessionUpdate":"tool_call","toolCallId":"1","title":"Custom","kind":"custom_kind","status":"custom_status"}"#.data(using: .utf8)!
        )

        XCTAssertEqual(tool.kind, .unknown("custom_kind"))
        XCTAssertEqual(tool.status, .unknown("custom_status"))
    }

    func testContentTypesDecode() throws {
        let text = try JSONDecoder().decode(ContentBlock.self, from: #"{"type":"text","text":"hello"}"#.data(using: .utf8)!)
        let image = try JSONDecoder().decode(ContentBlock.self, from: #"{"type":"image","uri":"file:///tmp/a.png","mimeType":"image/png"}"#.data(using: .utf8)!)
        let resource = try JSONDecoder().decode(ContentBlock.self, from: #"{"type":"resource_link","uri":"file:///tmp/a.swift"}"#.data(using: .utf8)!)

        XCTAssertEqual(text.plainText, "hello")
        if case .image(let content) = image {
            XCTAssertEqual(content.mimeType, "image/png")
        } else {
            XCTFail("Expected image content")
        }
        if case .resourceLink(let content) = resource {
            XCTAssertEqual(content.uri, "file:///tmp/a.swift")
        } else {
            XCTFail("Expected resource link content")
        }
    }

    func testPermissionElicitationFileAndTerminalTypesDecode() throws {
        let permission = try JSONDecoder().decode(
            RequestPermissionRequest.self,
            from: #"{"sessionId":"s","toolCallId":"t","title":"Run command","kind":"execute"}"#.data(using: .utf8)!
        )
        let elicitation = try JSONDecoder().decode(
            ElicitationRequest.self,
            from: #"{"sessionId":"s","message":"Need value","schema":{"type":"object"}}"#.data(using: .utf8)!
        )
        let read = try JSONDecoder().decode(
            ReadTextFileRequest.self,
            from: #"{"sessionId":"s","path":"/tmp/a","line":2,"limit":3}"#.data(using: .utf8)!
        )
        let terminal = try JSONDecoder().decode(
            CreateTerminalRequest.self,
            from: #"{"sessionId":"s","command":"pnpm","args":["test"],"cwd":"/tmp/project"}"#.data(using: .utf8)!
        )

        XCTAssertEqual(permission.kind, .execute)
        XCTAssertEqual(elicitation.schema, .object(["type": .string("object")]))
        XCTAssertEqual(read.line, 2)
        XCTAssertEqual(terminal.args, ["test"])
    }

    func testInboundSessionScopedTypesDecodeLegacySessionIDAlias() throws {
        let notification = try JSONDecoder().decode(
            SessionNotification.self,
            from: #"{"sessionID":"legacy","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}"#.data(using: .utf8)!
        )
        let permission = try JSONDecoder().decode(
            RequestPermissionRequest.self,
            from: #"{"sessionID":"legacy","title":"Run command"}"#.data(using: .utf8)!
        )
        let elicitation = try JSONDecoder().decode(
            ElicitationRequest.self,
            from: #"{"sessionID":"legacy","message":"Need value"}"#.data(using: .utf8)!
        )
        let read = try JSONDecoder().decode(
            ReadTextFileRequest.self,
            from: #"{"sessionID":"legacy","path":"/tmp/a"}"#.data(using: .utf8)!
        )
        let write = try JSONDecoder().decode(
            WriteTextFileRequest.self,
            from: #"{"sessionID":"legacy","path":"/tmp/a","content":"text"}"#.data(using: .utf8)!
        )
        let createTerminal = try JSONDecoder().decode(
            CreateTerminalRequest.self,
            from: #"{"sessionID":"legacy","command":"pnpm"}"#.data(using: .utf8)!
        )
        let terminalOutput = try JSONDecoder().decode(
            TerminalOutputRequest.self,
            from: #"{"sessionID":"legacy","terminalId":"term-1"}"#.data(using: .utf8)!
        )
        let killTerminal = try JSONDecoder().decode(
            KillTerminalRequest.self,
            from: #"{"sessionID":"legacy","terminalId":"term-1"}"#.data(using: .utf8)!
        )

        XCTAssertEqual(notification.sessionId, "legacy")
        XCTAssertEqual(permission.sessionId, "legacy")
        XCTAssertEqual(elicitation.sessionId, "legacy")
        XCTAssertEqual(read.sessionId, "legacy")
        XCTAssertEqual(write.sessionId, "legacy")
        XCTAssertEqual(createTerminal.sessionId, "legacy")
        XCTAssertEqual(terminalOutput.sessionId, "legacy")
        XCTAssertEqual(killTerminal.sessionId, "legacy")
    }
}
