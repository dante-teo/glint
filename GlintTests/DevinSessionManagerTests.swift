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
        var setConfigOptionCalls: [(sessionID: String, configId: String, value: String)] = []
        var setConfigOptionError: Error?
        var setConfigOptionResult: [SessionConfigOption]?
        var createSessionCalls: [String] = []
        var loadSessionCalls: [(sessionID: String, cwd: String)] = []
        var loadSessionError: Error?
        var loadSessionResult: LoadSessionResponse?
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
            createSessionCalls.append(cwd)
            return NewSessionResponse(sessionId: "session-123", sessionID: nil, modes: nil, models: nil, configOptions: nil)
        }

        func loadSession(sessionID: String, cwd: String) async throws -> LoadSessionResponse {
            loadSessionCalls.append((sessionID, cwd))
            if let loadSessionError { throw loadSessionError }
            return loadSessionResult ?? LoadSessionResponse(modes: nil, configOptions: nil)
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

        func setConfigOption(sessionID: String, configId: String, value: String) async throws -> [SessionConfigOption] {
            setConfigOptionCalls.append((sessionID, configId, value))
            if let setConfigOptionError { throw setConfigOptionError }
            return setConfigOptionResult ?? []
        }

        func closeSession(sessionID: String) async throws {}

        func cancelSession(sessionID: String) {
            cancelledSessionID = sessionID
        }

        func close() {
            closed = true
        }
    }

    /// Always isolates conversation persistence to a throwaway temp
    /// directory unless a caller explicitly passes its own. Leaving
    /// `sessionsDirectory` as `nil` here would fall through to
    /// `DevinSessionManager`'s real default (`~/.glint/sessions`) — the
    /// user's actual production conversation store — and every one of the
    /// ~30 call sites that used to rely on that default was silently
    /// writing (and never cleaning up) real files there on every test run.
    private func makeManager(client: FakeClient = FakeClient(),
                             sessionsDirectory: URL? = nil) -> DevinSessionManager {
        let directory = sessionsDirectory ?? Self.makeTemporarySessionsDirectory(self)
        return DevinSessionManager(
            workspaceID: UUID(),
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { client },
            sessionsDirectory: directory
        )
    }

    /// Creates a fresh, uniquely-named temp directory for a single test's
    /// conversation persistence and registers a teardown block to remove
    /// it, mirroring the pattern already used by the resume/persistence
    /// tests below.
    private static func makeTemporarySessionsDirectory(_ testCase: XCTestCase) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-manager-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
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

    func testConnectIfNeededCreatesNewSessionWithoutSendingAPrompt() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)

        manager.connectIfNeeded(projectPath: "/tmp")

        await waitUntil { client.createSessionCalls.count == 1 }
        XCTAssertTrue(client.loadSessionCalls.isEmpty)
        XCTAssertTrue(client.promptCalls.isEmpty)
        await waitUntil { manager.sessionID == "session-123" }
        await waitUntil { manager.status == .idle }
    }

    /// Regression test: reopening a workspace (or relaunching the app) with
    /// a persisted conversation must resume the *same* ACP session via
    /// `session/load` — not silently abandon it server-side by calling
    /// `session/new` again just because there's no live process yet.
    func testConnectIfNeededResumesPersistedSessionViaLoadSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-session-store", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let workspaceID = UUID()
        let firstClient = FakeClient()
        let original = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { firstClient },
            sessionsDirectory: dir
        )
        original.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { firstClient.promptCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let resumedClient = FakeClient()
        resumedClient.loadSessionResult = LoadSessionResponse(
            modes: SessionModeState(currentModeId: "code", availableModes: [SessionMode(id: "code", name: "Code")]),
            configOptions: [SessionConfigOption(id: "model", name: "Model", category: "model", type: "select", currentValue: .string("claude-opus-4-6"))]
        )
        let restored = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { resumedClient },
            sessionsDirectory: dir
        )
        XCTAssertEqual(restored.sessionID, "session-123")

        restored.connectIfNeeded(projectPath: "/tmp")

        await waitUntil { !resumedClient.loadSessionCalls.isEmpty }
        XCTAssertEqual(resumedClient.loadSessionCalls.first?.sessionID, "session-123")
        XCTAssertTrue(resumedClient.createSessionCalls.isEmpty)
        XCTAssertTrue(resumedClient.promptCalls.isEmpty)
        await waitUntil { restored.currentMode == "code" }
        await waitUntil { restored.configOptions.contains { $0.id == "model" } }
        await waitUntil { restored.status == .idle }
    }

    /// If the Agent no longer recognizes a previously persisted session
    /// (expired, or the CLI/process restarted), resuming must fall back to
    /// starting a fresh one instead of leaving the pane stuck.
    func testConnectIfNeededFallsBackToCreateSessionWhenResumeFails() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-session-store", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let workspaceID = UUID()
        let firstClient = FakeClient()
        let original = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { firstClient },
            sessionsDirectory: dir
        )
        original.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { firstClient.promptCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let resumedClient = FakeClient()
        resumedClient.loadSessionError = ACPClientError.requestTimedOut
        let restored = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { resumedClient },
            sessionsDirectory: dir
        )

        restored.connectIfNeeded(projectPath: "/tmp")

        await waitUntil { !resumedClient.createSessionCalls.isEmpty }
        XCTAssertEqual(resumedClient.loadSessionCalls.count, 1)
        await waitUntil { restored.status == .idle }
    }

    /// Sending a message on a resumed pane (no live client yet, but a
    /// persisted `sessionID`) must resume via `session/load` too, not just
    /// the dedicated `connectIfNeeded()` path.
    func testSendPromptOnResumedSessionUsesLoadSessionNotCreateSession() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-session-store", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let workspaceID = UUID()
        let firstClient = FakeClient()
        let original = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { firstClient },
            sessionsDirectory: dir
        )
        original.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { firstClient.promptCalls.count == 1 }
        try? await Task.sleep(nanoseconds: 400_000_000)

        let resumedClient = FakeClient()
        let restored = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { resumedClient },
            sessionsDirectory: dir
        )

        restored.sendPrompt(text: "resume me", projectPath: "/tmp")

        await waitUntil { resumedClient.promptCalls.count == 1 }
        XCTAssertEqual(resumedClient.loadSessionCalls.first?.sessionID, "session-123")
        XCTAssertTrue(resumedClient.createSessionCalls.isEmpty)
        XCTAssertEqual(resumedClient.promptCalls.first?.content.compactMap(\.plainText).joined(), "resume me")
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

    /// Regression test for the "answers appear above questions" bug:
    /// `indexForChunk` used to scan the *entire* transcript history for the
    /// last assistant message with no `messageId` (which is what Devin
    /// actually sends), so a second turn's reply chunks kept getting glued
    /// onto the first turn's reply bubble instead of starting a new one —
    /// even though a new user prompt had already been appended in between.
    /// Chunks without a `messageId` must only continue the message that is
    /// currently last in the transcript, never reach back past later
    /// messages.
    func testAgentChunksWithoutMessageIdDoNotMergeAcrossLaterTurns() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .agentMessageChunk(MessageChunkUpdate(sessionUpdate: "agent_message_chunk", messageId: nil, content: .text("answer one")))
        ))))
        await waitUntil { manager.messages.contains { $0.role == .assistant && $0.text == "answer one" } }

        manager.sendPrompt(text: "second")
        await waitUntil { client.promptCalls.count == 2 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .agentMessageChunk(MessageChunkUpdate(sessionUpdate: "agent_message_chunk", messageId: nil, content: .text("answer two")))
        ))))
        await waitUntil { manager.messages.contains { $0.role == .assistant && $0.text == "answer two" } }

        let assistantTexts = manager.messages.filter { $0.role == .assistant }.map(\.text)
        XCTAssertEqual(assistantTexts, ["answer one", "answer two"])

        let idxAnswerOne = try XCTUnwrap(manager.messages.firstIndex { $0.text == "answer one" })
        let idxSecondPrompt = try XCTUnwrap(manager.messages.firstIndex { $0.text == "second" })
        let idxAnswerTwo = try XCTUnwrap(manager.messages.firstIndex { $0.text == "answer two" })
        XCTAssertLessThan(idxAnswerOne, idxSecondPrompt)
        XCTAssertLessThan(idxSecondPrompt, idxAnswerTwo)
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

    /// Regression test: per the ACP spec `toolCallId` is unique within a
    /// session, but a reused id (e.g. a misbehaving/reconnecting agent)
    /// must never resurrect an already-`completed` row back to
    /// "pending"/"in progress" — that would misleadingly read "Working"
    /// forever if the new occurrence's own completion event is ever
    /// dropped. A reused id with a non-terminal status must instead create
    /// a fresh row, leaving the original completed row untouched.
    func testReusedToolCallIdAfterCompletionDoesNotRegressToWorking() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Reading", kind: .read, status: .completed))
        ))))
        await waitUntil { manager.messages.contains { $0.toolCallId == "tool-1" && $0.toolStatus == .completed } }

        // A later, unrelated notification reuses the same id with a fresh
        // non-terminal status.
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "tool-1", title: "Reading again", kind: .read, status: .pending))
        ))))
        await waitUntil {
            manager.messages.filter { $0.toolCallId == "tool-1" }.count == 2
        }

        let toolCalls = manager.messages.filter { $0.toolCallId == "tool-1" }
        XCTAssertEqual(toolCalls[0].toolStatus, .completed, "the original completed row must not regress")
        XCTAssertEqual(toolCalls[1].toolStatus, .pending, "the reused id must land on a new row")

        // The new occurrence can still complete normally on its own row.
        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCallUpdate(ToolCallDelta(toolCallId: "tool-1", status: .completed))
        ))))
        await waitUntil {
            manager.messages.filter { $0.toolCallId == "tool-1" && $0.toolStatus == .completed }.count == 2
        }
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

    /// Regression test for a crash-recovery gap: every *documented* turn-end
    /// path (finishActiveTurn/markFailed/stop/prepareForClose) sweeps
    /// unfinished tool calls to "stale", but a process that dies (crash,
    /// force-quit) without going through any of them can leave a
    /// `pending`/`in_progress`, non-abandoned tool call sitting in the
    /// on-disk conversation. Starting a brand-new turn on the *next*
    /// launch — proof the old one is over — must sweep it immediately, not
    /// leave it reading "Working" until some later, unrelated event
    /// happens to touch it.
    func testSendPromptSweepsLeftoverUnfinishedToolCallFromUncleanShutdown() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-devin-session-store", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let workspaceID = UUID()
        let crashedClient = FakeClient()
        crashedClient.armPromptGate()
        addTeardownBlock { crashedClient.releasePromptGate() }
        let crashedManager = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { crashedClient },
            sessionsDirectory: dir
        )
        crashedManager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { crashedClient.promptCalls.count == 1 }

        crashedClient.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .toolCall(ToolCallUpdate(toolCallId: "leftover-tool", title: "Running", kind: .execute, status: .inProgress))
        ))))
        await waitUntil { crashedManager.messages.contains { $0.toolCallId == "leftover-tool" } }
        // Let the debounced save land — simulating the state on disk right
        // before the process disappears without ever closing the session.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // A fresh launch loads the persisted conversation as-is: the tool
        // call is still non-terminal and not yet abandoned.
        let restoredClient = FakeClient()
        let restoredManager = DevinSessionManager(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            onStatusChange: { _ in },
            onSessionID: { _ in },
            clientFactory: { restoredClient },
            sessionsDirectory: dir
        )
        let leftoverBeforeSend = try XCTUnwrap(restoredManager.messages.first { $0.toolCallId == "leftover-tool" })
        XCTAssertEqual(leftoverBeforeSend.toolStatus, .inProgress)
        XCTAssertNil(leftoverBeforeSend.toolAbandonedReason)

        // Sending the very next message must sweep it immediately, before
        // the new turn does anything else.
        restoredManager.sendFirstPrompt(text: "second", projectPath: "/tmp")
        let leftoverAfterSend = try XCTUnwrap(restoredManager.messages.first { $0.toolCallId == "leftover-tool" })
        XCTAssertNotNil(leftoverAfterSend.toolAbandonedReason)
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

    func testSelectConfigOptionCallsSetConfigOptionAndAdoptsResponse() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .configOptionUpdate(ConfigOptionUpdate(configOptions: [
                SessionConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: .string("claude-sonnet-5-high"),
                    options: [
                        SessionConfigOptionValue(value: .string("claude-sonnet-5-high"), name: "Claude Sonnet 5 High"),
                        SessionConfigOptionValue(value: .string("claude-opus-4-6-thinking"), name: "Claude Opus 4.6 Thinking")
                    ]
                )
            ]))
        ))))
        await waitUntil { manager.configOptions.contains { $0.id == "model" } }

        client.setConfigOptionResult = [
            SessionConfigOption(
                id: "model",
                name: "Model",
                category: "model",
                type: "select",
                currentValue: .string("claude-opus-4-6-thinking"),
                options: [
                    SessionConfigOptionValue(value: .string("claude-sonnet-5-high"), name: "Claude Sonnet 5 High"),
                    SessionConfigOptionValue(value: .string("claude-opus-4-6-thinking"), name: "Claude Opus 4.6 Thinking")
                ]
            )
        ]

        manager.selectConfigOption("model", value: "claude-opus-4-6-thinking")

        await waitUntil { client.setConfigOptionCalls.contains { $0.value == "claude-opus-4-6-thinking" } }
        XCTAssertEqual(client.setConfigOptionCalls.first?.sessionID, "session-123")
        XCTAssertEqual(client.setConfigOptionCalls.first?.configId, "model")
        await waitUntil {
            manager.configOptions.first { $0.id == "model" }?.resolvedCurrentValue?.stringValue == "claude-opus-4-6-thinking"
        }
    }

    func testSelectConfigOptionRevertsOnFailure() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .configOptionUpdate(ConfigOptionUpdate(configOptions: [
                SessionConfigOption(
                    id: "model",
                    name: "Model",
                    category: "model",
                    type: "select",
                    currentValue: .string("claude-sonnet-5-high"),
                    options: [
                        SessionConfigOptionValue(value: .string("claude-sonnet-5-high"), name: "Claude Sonnet 5 High"),
                        SessionConfigOptionValue(value: .string("claude-opus-4-6-thinking"), name: "Claude Opus 4.6 Thinking")
                    ]
                )
            ]))
        ))))
        await waitUntil { manager.configOptions.contains { $0.id == "model" } }

        client.setConfigOptionError = ACPClientError.requestTimedOut

        manager.selectConfigOption("model", value: "claude-opus-4-6-thinking")

        await waitUntil {
            manager.configOptions.first { $0.id == "model" }?.resolvedCurrentValue?.stringValue == "claude-sonnet-5-high"
        }
        XCTAssertTrue(manager.messages.contains { $0.role == .system && $0.text.contains("Couldn't change model") })
    }

    func testConfigOptionUpdateStoresOptions() async throws {
        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.promptCalls.count == 1 }

        client.subject.send(ACPNotification(method: "session/update", params: try jsonValue(SessionNotification(
            sessionId: "session-123",
            update: .configOptionUpdate(ConfigOptionUpdate(configOptions: [
                SessionConfigOption(id: "reasoning_effort", name: "Reasoning", type: "enum", value: .string("high"))
            ]))
        ))))

        await waitUntil { manager.configOptions.contains { $0.id == "reasoning_effort" } }
        XCTAssertEqual(manager.configOptions.first?.value, .string("high"))
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

    func testAlwaysAllowPermissionModeApprovesAllowOptionWithoutPublishingCard() async throws {
        let previous = UserDefaults.standard.string(forKey: "glint.permissionReviewMode")
        let store = WorkspaceStore()
        store.permissionReviewMode = .alwaysAllow
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "glint.permissionReviewMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "glint.permissionReviewMode")
            }
            _ = store
        }

        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let result = await handler(ACPServerRequest(
            id: 13,
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

        XCTAssertNil(manager.pendingPermission)
        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow-once")])]))
        } else {
            XCTFail("Expected permission success")
        }
    }

    func testAlwaysAllowPermissionModeCancelsWhenNoAllowOptionExists() async throws {
        let previous = UserDefaults.standard.string(forKey: "glint.permissionReviewMode")
        let store = WorkspaceStore()
        store.permissionReviewMode = .alwaysAllow
        addTeardownBlock {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "glint.permissionReviewMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "glint.permissionReviewMode")
            }
            _ = store
        }

        let client = FakeClient()
        let manager = makeManager(client: client)
        manager.sendFirstPrompt(text: "first", projectPath: "/tmp")
        await waitUntil { client.handlers["session/request_permission"] != nil }
        let handler = try XCTUnwrap(client.handlers["session/request_permission"])

        let result = await handler(ACPServerRequest(
            id: 14,
            method: "session/request_permission",
            params: try jsonValue(RequestPermissionRequest(
                sessionId: "session-123",
                toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
                options: [PermissionOption(optionId: "reject-once", name: "Reject", kind: .rejectOnce)]
            ))
        ))

        XCTAssertNil(manager.pendingPermission)
        if case .success(let value) = result {
            XCTAssertEqual(value, .object(["outcome": .object(["outcome": .string("cancelled")])]))
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
