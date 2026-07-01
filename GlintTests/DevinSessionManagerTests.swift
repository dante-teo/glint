import Combine
import XCTest
@testable import Glint

@MainActor
final class DevinSessionManagerTests: XCTestCase {
    private final class FakeClient: DevinACPClient {
        let subject = PassthroughSubject<ACPNotification, Never>()
        var notifications: AnyPublisher<ACPNotification, Never> { subject.eraseToAnyPublisher() }
        let diagnosticSubject = PassthroughSubject<ACPDiagnosticEvent, Never>()
        var diagnostics: AnyPublisher<ACPDiagnosticEvent, Never> { diagnosticSubject.eraseToAnyPublisher() }
        var handlers: [String: ACPServerRequestHandler] = [:]
        var started = false
        var closed = false
        var cancelledSessionID: String?
        var promptCalls: [(sessionID: String, content: [ContentBlock])] = []
        var setModeCalls: [(sessionID: String, modeId: String)] = []
        var setModeError: Error?
        var promptError: Error?
        /// When set, the next `prompt(sessionID:content:)` call suspends
        /// until this continuation is resumed, letting tests interleave a
        /// notification between "prompt sent" and "prompt resolved" to
        /// exercise the ordering-race fix.
        var promptGate: CheckedContinuation<Void, Never>?

        func start() throws {
            started = true
        }

        func setRequestHandler(method: String, handler: ACPServerRequestHandler?) {
            handlers[method] = handler
        }

        func initialize() async throws -> InitializeResponse {
            InitializeResponse(protocolVersion: 1)
        }

        func createSession(cwd: String) async throws -> NewSessionResponse {
            NewSessionResponse(sessionId: "session-123", sessionID: nil, modes: nil, models: nil, configOptions: nil)
        }

        func loadSession(sessionID: String, cwd: String) async throws -> LoadSessionResponse {
            LoadSessionResponse(modes: nil, configOptions: nil)
        }

        private var shouldGateNextPrompt = false

        func armPromptGate() {
            shouldGateNextPrompt = true
        }

        func releasePromptGate() {
            promptGate?.resume()
            promptGate = nil
        }

        func prompt(sessionID: String, content: [ContentBlock]) async throws -> PromptResponse {
            promptCalls.append((sessionID, content))
            if shouldGateNextPrompt {
                shouldGateNextPrompt = false
                await withCheckedContinuation { continuation in
                    promptGate = continuation
                }
            }
            if let promptError { throw promptError }
            return PromptResponse(stopReason: .endTurn)
        }

        func setMode(sessionID: String, modeId: String) async throws {
            setModeCalls.append((sessionID, modeId))
            if let setModeError { throw setModeError }
        }

        func closeSession(sessionID: String) async throws {}

        func cancelSession(sessionID: String) {
            cancelledSessionID = sessionID
        }

        func close() {
            closed = true
        }
    }

    private func makeManager(client: FakeClient = FakeClient(),
                             sessionsDirectory: URL? = nil) -> DevinSessionManager {
        DevinSessionManager(
            workspaceID: UUID(),
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { client },
            sessionsDirectory: sessionsDirectory
        )
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) async {
        for _ in 0..<50 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> ACPJSONValue {
        try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(value))
    }

    func testFirstSendStartsSessionAndSendsPrompt() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.sendFirstPrompt(text: "  hello Devin  ", projectPath: "/tmp")

        await waitUntil { client.promptCalls.count == 1 }
        XCTAssertTrue(client.started)
        XCTAssertEqual(manager.sessionID, "session-123")
        XCTAssertEqual(client.promptCalls.first?.sessionID, "session-123")
        XCTAssertEqual(client.promptCalls.first?.content.compactMap(\.plainText).joined(), "hello Devin")
        XCTAssertEqual(manager.status, .idle)
    }

    func testSubsequentPromptReusesSession() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }
        manager.sendPrompt(text: "second")
        await waitUntil { client.promptCalls.count == 2 }

        XCTAssertEqual(client.promptCalls.map { $0.content.compactMap(\.plainText).joined() }, ["first", "second"])
    }

    /// Regression test for `sendPrompt`'s content-array construction: a
    /// non-empty text draft plus attached images must produce a text
    /// block followed by one image block per attachment, in that order.
    func testSendPromptWithTextAndImagesBuildsTextThenImageBlocks() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.sendFirstPrompt(
            text: "check this screenshot",
            projectPath: "/tmp",
            images: [DevinSessionManager.ImageAttachment(base64Data: "AAAA", mimeType: "image/png")]
        )

        await waitUntil { client.promptCalls.count == 1 }
        let content = client.promptCalls.first?.content ?? []
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content.first?.plainText, "check this screenshot")
        if case .image(let image) = content.last {
            XCTAssertEqual(image.data, "AAAA")
            XCTAssertEqual(image.mimeType, "image/png")
        } else {
            XCTFail("Expected an image content block")
        }
    }

    /// Regression test for the "images-only send" guard: sending with an
    /// empty draft but at least one attachment must still go through
    /// (only text AND images both empty should be rejected), and the
    /// displayed user message should fall back to a descriptive string
    /// since there's no literal text to show.
    func testSendPromptWithOnlyImagesSendsImageOnlyContentAndDisplayText() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.sendFirstPrompt(
            text: "   ",
            projectPath: "/tmp",
            images: [DevinSessionManager.ImageAttachment(base64Data: "AAAA", mimeType: "image/png")]
        )

        await waitUntil { client.promptCalls.count == 1 }
        let content = client.promptCalls.first?.content ?? []
        XCTAssertEqual(content.count, 1)
        if case .image = content.first {
            // expected
        } else {
            XCTFail("Expected the only content block to be an image")
        }
        XCTAssertTrue(manager.messages.contains { $0.role == .user && $0.text == "Sent an image" })
    }

    /// A draft that's empty (after trimming) with no images at all must
    /// not send anything.
    func testSendPromptWithEmptyTextAndNoImagesDoesNothing() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.sendFirstPrompt(text: "   ", projectPath: "/tmp")

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.promptCalls.count, 0)
        XCTAssertTrue(manager.messages.isEmpty)
    }

    func testAgentChunksWithSameMessageIDAppendToOneMessage() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .agentMessageChunk(MessageChunkUpdate(sessionUpdate: "agent_message_chunk", messageId: "m1", content: .text("hel")))
        ))))
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .agentMessageChunk(MessageChunkUpdate(sessionUpdate: "agent_message_chunk", messageId: "m1", content: .text("lo")))
        ))))

        await waitUntil { manager.messages.contains { $0.role == .assistant && $0.text == "hello" } }
        XCTAssertEqual(manager.messages.filter { $0.role == .assistant }.count, 1)
    }

    func testToolCallUpdateReplacesExistingToolCall() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(
                toolCallId: "tool-1",
                title: "Reading",
                kind: .read,
                status: .pending,
                content: [.content(.text("reading file"))],
                locations: [ToolCallLocation(path: "/tmp/file.swift", line: 12)],
                rawInput: .object(["path": .string("/tmp/file.swift")]),
                rawOutput: nil
            ))
        ))))
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCallUpdate(ToolCallDelta(
                toolCallId: "tool-1",
                title: "Read file",
                kind: nil,
                status: .completed,
                content: nil,
                locations: nil,
                rawInput: nil,
                rawOutput: .object(["ok": .bool(true)])
            ))
        ))))

        await waitUntil { manager.messages.contains { $0.toolCallId == "tool-1" && $0.toolStatus == .completed } }
        let message = try XCTUnwrap(manager.messages.first { $0.toolCallId == "tool-1" })
        XCTAssertEqual(manager.messages.filter { $0.toolCallId == "tool-1" }.count, 1)
        XCTAssertEqual(message.toolKind, .read)
        XCTAssertEqual(message.toolContent, [.content(.text("reading file"))])
        XCTAssertEqual(message.toolLocations, [ToolCallLocation(path: "/tmp/file.swift", line: 12)])
        XCTAssertEqual(message.toolRawInput, .object(["path": .string("/tmp/file.swift")]))
        XCTAssertEqual(message.toolRawOutput, .object(["ok": .bool(true)]))
        XCTAssertNotNil(message.toolStartedAt)
        XCTAssertNotNil(message.toolCompletedAt)
    }

    func testToolCallUpdateBeforeCreateBuildsInspectablePlaceholder() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCallUpdate(ToolCallDelta(
                toolCallId: "late-tool",
                title: nil,
                kind: .execute,
                status: .inProgress,
                content: nil,
                locations: nil,
                rawInput: .object(["command": .string("swift test")]),
                rawOutput: nil
            ))
        ))))

        await waitUntil { manager.messages.contains { $0.toolCallId == "late-tool" } }
        let message = try XCTUnwrap(manager.messages.first { $0.toolCallId == "late-tool" })
        XCTAssertEqual(message.text, "Tool call")
        XCTAssertEqual(message.toolKind, .execute)
        XCTAssertEqual(message.toolStatus, .inProgress)
        XCTAssertEqual(message.toolRawInput, .object(["command": .string("swift test")]))
    }

    func testToolCallUpdateWithoutTitlePreservesExistingTitle() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Read file", kind: .read, status: .pending))
        ))))
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCallUpdate(ToolCallDelta(toolCallId: "tool-1", title: nil, status: .completed))
        ))))

        await waitUntil { manager.messages.contains { $0.toolCallId == "tool-1" && $0.toolStatus == .completed } }
        XCTAssertEqual(manager.messages.first { $0.toolCallId == "tool-1" }?.text, "Read file")
    }

    func testPromptCompletionMarksUnfinishedToolCallStale() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        client.armPromptGate()
        addTeardownBlock { client.releasePromptGate() }

        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Running", kind: .execute, status: .inProgress))
        ))))
        await waitUntil { manager.status == .tool }

        client.releasePromptGate()

        await waitUntil {
            manager.messages.contains { $0.toolCallId == "tool-1" && $0.toolAbandonedReason != nil }
        }
        XCTAssertEqual(manager.status, .idle)
    }

    func testPromptFailureMarksActiveToolCallStaleAndFailed() async throws {
        let client = FakeClient()
        client.promptError = ACPClientError.processExited("boom")
        let manager = makeManager(client: client)
        client.armPromptGate()
        addTeardownBlock { client.releasePromptGate() }

        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Running", kind: .execute, status: .inProgress))
        ))))
        await waitUntil { manager.status == .tool }

        client.releasePromptGate()

        await waitUntil {
            if case .failed = manager.status { return true }
            return false
        }
        XCTAssertTrue(manager.messages.contains { $0.toolCallId == "tool-1" && $0.toolAbandonedReason?.contains("boom") == true })
    }

    /// Regression test for the "stuck tool call" bug: cancelling a turn
    /// must suppress `status` changes from notifications the agent process
    /// keeps emitting for that now-abandoned turn. Without the turn-active
    /// guard, this late `toolCallUpdate` would flip `status` back to
    /// `.tool` with nothing left to ever reset it.
    func testCancelSuppressesStaleNotificationStatus() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        client.armPromptGate()
        addTeardownBlock { client.releasePromptGate() }

        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        manager.cancelTurn()
        XCTAssertEqual(manager.status, .idle)

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCallUpdate(ToolCallDelta(toolCallId: "tool-1", title: "Still running", status: .completed))
        ))))

        await waitUntil { manager.messages.contains { $0.toolCallId == "tool-1" } }
        XCTAssertEqual(manager.status, .idle)
    }

    /// Regression test guarding the removal of the extra `Task { @MainActor
    /// in ... }` hop in `observeNotifications`: a notification delivered
    /// while a prompt is in flight must still land as `.tool`/`.thinking`
    /// (i.e. notification handling itself keeps working) and the turn must
    /// still resolve to `.idle` once the response arrives.
    func testNotificationDuringInFlightPromptThenResolvesIdle() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        client.armPromptGate()
        addTeardownBlock { client.releasePromptGate() }

        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Reading", kind: .read, status: .inProgress))
        ))))
        await waitUntil { manager.status == .tool }

        client.releasePromptGate()
        await waitUntil { manager.status == .idle }
    }

    func testSelectModeCallsSetModeAndUpdatesCurrentMode() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        manager.selectMode("architect")

        await waitUntil { client.setModeCalls.contains { $0.modeId == "architect" } }
        XCTAssertEqual(client.setModeCalls.first?.sessionID, "session-123")
        XCTAssertEqual(manager.currentMode, "architect")
    }

    func testSelectModeRevertsOnFailure() async throws {
        let client = FakeClient()
        client.setModeError = ACPClientError.requestTimedOut
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        manager.selectMode("architect")

        await waitUntil { manager.currentMode == nil }
        XCTAssertTrue(manager.messages.contains { $0.role == .system && $0.text.contains("Couldn't switch mode") })
    }

    func testPermissionRequestPublishesAndResolves() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let task = Task {
            await handler(ACPServerRequest(
                id: 7,
                method: "session/request_permission",
                params: try jsonValue(RequestPermissionRequest(
                    sessionId: "session-123",
                    toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                    options: [
                        PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce),
                        PermissionOption(optionId: "reject-once", name: "Reject", kind: .rejectOnce)
                    ]
                ))
            ))
        }
        await waitUntil { manager.pendingPermission != nil }
        manager.respondToPermission(approved: true)
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow-once")])]))
        } else {
            XCTFail("Expected permission success")
        }
    }

    func testCancelTurnRespondsToPendingPermissionWithCancelledOutcome() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let task = Task {
            await handler(ACPServerRequest(
                id: 12,
                method: "session/request_permission",
                params: try jsonValue(RequestPermissionRequest(
                    sessionId: "session-123",
                    toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                    options: [PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce)]
                ))
            ))
        }

        await waitUntil { manager.pendingPermission != nil }
        manager.cancelTurn()
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("cancelled")])]))
        } else {
            XCTFail("Expected permission success")
        }
        XCTAssertNil(manager.pendingPermission)
        XCTAssertEqual(manager.status, .idle)
    }

    /// Regression test: denying must select a `reject_*` option by its
    /// real `optionId`, not send back a bare "denied" string the ACP
    /// server can't act on.
    func testPermissionRequestDenyingSelectsRejectOption() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let task = Task {
            await handler(ACPServerRequest(
                id: 8,
                method: "session/request_permission",
                params: try jsonValue(RequestPermissionRequest(
                    sessionId: "session-123",
                    toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                    options: [
                        PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce),
                        PermissionOption(optionId: "reject-once", name: "Reject", kind: .rejectOnce)
                    ]
                ))
            ))
        }
        await waitUntil { manager.pendingPermission != nil }
        manager.respondToPermission(approved: false)
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("reject-once")])]))
        } else {
            XCTFail("Expected permission success")
        }
    }

    /// Regression test: the "once" variant must be preferred over
    /// "always" by kind, not by array position — an agent is free to
    /// list `allow_always` before `allow_once`.
    func testPermissionRequestApprovingPrefersOnceEvenWhenListedSecond() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let task = Task {
            await handler(ACPServerRequest(
                id: 10,
                method: "session/request_permission",
                params: try jsonValue(RequestPermissionRequest(
                    sessionId: "session-123",
                    toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                    options: [
                        PermissionOption(optionId: "allow-always", name: "Allow always", kind: .allowAlways),
                        PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce)
                    ]
                ))
            ))
        }
        await waitUntil { manager.pendingPermission != nil }
        manager.respondToPermission(approved: true)
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow-once")])]))
        } else {
            XCTFail("Expected permission success")
        }
    }

    /// Regression test: if the agent only offers options of the opposite
    /// polarity (e.g. only allow-kind options), denying must respond
    /// `cancelled` — it must never silently select an allow option just
    /// because it's the only one available, which would turn a user's
    /// Deny into an Allow.
    func testPermissionRequestDenyingWithOnlyAllowOptionsRespondsCancelled() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let task = Task {
            await handler(ACPServerRequest(
                id: 11,
                method: "session/request_permission",
                params: try jsonValue(RequestPermissionRequest(
                    sessionId: "session-123",
                    toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                    options: [PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce)]
                ))
            ))
        }
        await waitUntil { manager.pendingPermission != nil }
        manager.respondToPermission(approved: false)
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("cancelled")])]))
        } else {
            XCTFail("Expected permission success")
        }
    }

    /// Regression test for the ACP v1 spec requirement: cancelling a turn
    /// with a pending permission request must respond with the
    /// `cancelled` outcome, not a `selected` option — the client is
    /// abandoning the turn, not actually deciding allow/reject.
    func testStopRespondsToPendingPermissionWithCancelledOutcome() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let task = Task {
            await handler(ACPServerRequest(
                id: 9,
                method: "session/request_permission",
                params: try jsonValue(RequestPermissionRequest(
                    sessionId: "session-123",
                    toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                    options: [PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce)]
                ))
            ))
        }
        await waitUntil { manager.pendingPermission != nil }
        manager.stop()
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("cancelled")])]))
        } else {
            XCTFail("Expected permission success")
        }
    }

    func testFileHandlerRejectsPathOutsideProjectRoot() async throws {
        let client = FakeClient()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-manager-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: root.path)
        await waitUntil { client.handlers["fs/read_text_file"] != nil }
        let handler = try XCTUnwrap(client.handlers["fs/read_text_file"])

        let result = await handler(ACPServerRequest(
            id: 8,
            method: "fs/read_text_file",
            params: try jsonValue(ReadTextFileRequest(sessionId: "session-123", path: "/etc/passwd", line: nil, limit: nil))
        ))

        if case .failure(let error) = result {
            XCTAssertTrue(error.message.contains("outside the project folder"))
        } else {
            XCTFail("Expected outside-root read to fail")
        }
    }

    func testWriteFileHandlerRejectsSymlinkTargetOutsideProjectRoot() async throws {
        let client = FakeClient()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-manager-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside.txt")
        let link = root.appendingPathComponent("linked-outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "original".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: root.path)
        await waitUntil { client.handlers["fs/write_text_file"] != nil }
        let handler = try XCTUnwrap(client.handlers["fs/write_text_file"])

        let result = await handler(ACPServerRequest(
            id: 9,
            method: "fs/write_text_file",
            params: try jsonValue(WriteTextFileRequest(sessionId: "session-123", path: link.path, content: "changed"))
        ))

        if case .failure(let error) = result {
            XCTAssertTrue(error.message.contains("outside the project folder"))
        } else {
            XCTFail("Expected outside-root symlink write to fail")
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
    }

    func testConversationPersistenceRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-session-store", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        let workspaceID = UUID()
        let client = FakeClient()
        let manager = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { client },
            sessionsDirectory: dir
        )
        manager.sendFirstPrompt(text: "persist me", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(
                toolCallId: "persisted-tool",
                title: "Persisted read",
                kind: .read,
                status: .completed,
                content: [.content(.text("persisted content"))],
                locations: [ToolCallLocation(path: "/tmp/persisted.txt", line: 1)],
                rawInput: .object(["path": .string("/tmp/persisted.txt")]),
                rawOutput: .object(["content": .string("hello")])
            ))
        ))))
        await waitUntil { manager.messages.contains { $0.toolCallId == "persisted-tool" } }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let restored = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { FakeClient() },
            sessionsDirectory: dir
        )

        XCTAssertEqual(restored.sessionID, "session-123")
        XCTAssertTrue(restored.messages.contains { $0.role == .user && $0.text == "persist me" })
        let tool = try XCTUnwrap(restored.messages.first { $0.toolCallId == "persisted-tool" })
        XCTAssertEqual(tool.toolKind, .read)
        XCTAssertEqual(tool.toolContent, [.content(.text("persisted content"))])
        XCTAssertEqual(tool.toolLocations, [ToolCallLocation(path: "/tmp/persisted.txt", line: 1)])
        XCTAssertEqual(tool.toolRawInput, .object(["path": .string("/tmp/persisted.txt")]))
        XCTAssertEqual(tool.toolRawOutput, .object(["content": .string("hello")]))
    }

    // MARK: - Phase 5: archive/delete/quit teardown

    private func makeTempSessionsDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-session-store", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    func testCloseSessionAndDeleteConversationRemovesFile() async throws {
        let dir = makeTempSessionsDirectory()
        let workspaceID = UUID()
        let client = FakeClient()
        let manager = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { client },
            sessionsDirectory: dir
        )
        manager.sendFirstPrompt(text: "delete me", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }
        // Let the debounced save actually land once, so there's a real
        // file on disk to delete.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let url = DevinSessionManager.conversationURL(workspaceID: workspaceID, sessionsDirectory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        manager.closeSessionAndDeleteConversation()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Regression test for the `scheduleSave()` cancellation race: a save
    /// that's in-flight (mid-debounce) when the conversation is deleted
    /// must not resurrect the file once its sleep elapses.
    func testCancelledDebouncedSaveDoesNotResurrectDeletedFile() async throws {
        let dir = makeTempSessionsDirectory()
        let workspaceID = UUID()
        let client = FakeClient()
        let manager = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { client },
            sessionsDirectory: dir
        )
        manager.sendFirstPrompt(text: "in flight", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        // Delete immediately — the debounced save scheduled by sendFirstPrompt
        // hasn't fired yet (its ~250ms sleep hasn't elapsed).
        manager.closeSessionAndDeleteConversation()

        // Wait well past the original debounce window; if cancellation
        // didn't actually stop the write, the file would reappear here.
        try? await Task.sleep(nanoseconds: 400_000_000)

        let url = DevinSessionManager.conversationURL(workspaceID: workspaceID, sessionsDirectory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCloseSessionPreservingConversationFlushesPendingSaveImmediately() async throws {
        let dir = makeTempSessionsDirectory()
        let workspaceID = UUID()
        let client = FakeClient()
        let manager = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { client },
            sessionsDirectory: dir
        )
        manager.sendFirstPrompt(text: "flush me", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        // Preserve immediately — before the ~250ms debounce would have
        // fired on its own.
        manager.closeSessionPreservingConversation()

        let restored = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { FakeClient() },
            sessionsDirectory: dir
        )
        XCTAssertEqual(restored.sessionID, "session-123")
        XCTAssertTrue(restored.messages.contains { $0.role == .user && $0.text == "flush me" })
    }

    func testCloseSessionForQuitClosesClientAndEndsIdle() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "quitting", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        await manager.closeSessionForQuit()

        XCTAssertTrue(client.closed)
        XCTAssertEqual(manager.status, .idle)
    }
}
