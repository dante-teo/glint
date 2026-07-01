import Combine
import XCTest
@testable import Glint

@MainActor
final class DevinSessionManagerTests: XCTestCase {
    private final class FakeClient: DevinACPClient {
        let subject = PassthroughSubject<ACPNotification, Never>()
        var notifications: AnyPublisher<ACPNotification, Never> { subject.eraseToAnyPublisher() }
        var handlers: [String: ACPServerRequestHandler] = [:]
        var started = false
        var closed = false
        var cancelledSessionID: String?
        var promptCalls: [(sessionID: String, text: String)] = []

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

        func prompt(sessionID: String, text: String) async throws -> PromptResponse {
            promptCalls.append((sessionID, text))
            return PromptResponse(stopReason: .endTurn)
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
        XCTAssertEqual(client.promptCalls.first?.text, "hello Devin")
        XCTAssertEqual(manager.status, .idle)
    }

    func testSubsequentPromptReusesSession() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }
        manager.sendPrompt(text: "second")
        await waitUntil { client.promptCalls.count == 2 }

        XCTAssertEqual(client.promptCalls.map(\.text), ["first", "second"])
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
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Reading", kind: .read, status: .pending))
        ))))
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCallUpdate(ToolCallDelta(toolCallId: "tool-1", title: "Read file", status: .completed))
        ))))

        await waitUntil { manager.messages.contains { $0.toolCallId == "tool-1" && $0.toolStatus == .completed } }
        XCTAssertEqual(manager.messages.filter { $0.toolCallId == "tool-1" }.count, 1)
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
                params: try jsonValue(RequestPermissionRequest(sessionId: "session-123", toolCallId: "tool-1", title: "Run", kind: .execute))
            ))
        }
        await waitUntil { manager.pendingPermission != nil }
        manager.respondToPermission(approved: true)
        let result = try await task.value

        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .string("approved")]))
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
