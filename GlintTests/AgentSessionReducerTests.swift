import XCTest
@testable import Glint

final class AgentSessionReducerTests: XCTestCase {
    private func makeState() -> AgentSessionSnapshot {
        AgentSessionSnapshot.empty(identity: AgentSessionIdentity(
            workspaceID: UUID(),
            paneID: PaneID(value: 0),
            provider: .devin
        ))
    }

    func testChunksWithSameMessageIDAppendToOneMessage() {
        var state = makeState()

        AgentSessionReducer.reduce(&state, event: .messageChunk(role: .assistant, messageId: "m1", content: .text("hel")))
        AgentSessionReducer.reduce(&state, event: .messageChunk(role: .assistant, messageId: "m1", content: .text("lo")))

        XCTAssertEqual(state.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(state.messages.first?.text, "hello")
    }

    /// Regression test mirroring `DevinSessionManagerTests
    /// .testAgentChunksWithoutMessageIdDoNotMergeAcrossLaterTurns`: chunks
    /// without a `messageId` must only continue the message currently at
    /// the tail of the transcript, never reach back past a later message
    /// (e.g. a user prompt from a subsequent turn) just because it shares a
    /// role. Otherwise a second turn's reply keeps getting glued onto the
    /// first turn's bubble instead of starting a new one.
    func testChunksWithoutMessageIdDoNotMergeAcrossLaterTurns() {
        var state = makeState()

        AgentSessionReducer.reduce(&state, event: .messageChunk(role: .assistant, messageId: nil, content: .text("answer one")))
        AgentSessionReducer.reduce(&state, event: .userPromptQueued(text: "second"))
        AgentSessionReducer.reduce(&state, event: .messageChunk(role: .assistant, messageId: nil, content: .text("answer two")))

        let assistantTexts = state.messages.filter { $0.role == .assistant }.map(\.text)
        XCTAssertEqual(assistantTexts, ["answer one", "answer two"])

        let idxAnswerOne = try! XCTUnwrap(state.messages.firstIndex { $0.text == "answer one" })
        let idxSecondPrompt = try! XCTUnwrap(state.messages.firstIndex { $0.text == "second" })
        let idxAnswerTwo = try! XCTUnwrap(state.messages.firstIndex { $0.text == "answer two" })
        XCTAssertLessThan(idxAnswerOne, idxSecondPrompt)
        XCTAssertLessThan(idxSecondPrompt, idxAnswerTwo)
    }

    func testToolUpdatePreservesExistingFields() {
        var state = makeState()
        let started = Date(timeIntervalSince1970: 10)
        let finished = Date(timeIntervalSince1970: 20)

        AgentSessionReducer.reduce(&state, event: .toolCallUpsert(
            id: "tool-1",
            title: "Reading",
            status: .pending,
            kind: .read,
            content: [.content(.text("reading"))],
            locations: [ToolCallLocation(path: "/tmp/a.swift", line: 3)],
            rawInput: .object(["path": .string("/tmp/a.swift")]),
            rawOutput: nil
        ), now: started)
        AgentSessionReducer.reduce(&state, event: .toolCallUpsert(
            id: "tool-1",
            title: nil,
            status: .completed,
            kind: nil,
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: .object(["ok": .bool(true)])
        ), now: finished)

        let item = try! XCTUnwrap(state.messages.first)
        let tool = try! XCTUnwrap(item.toolCall)
        XCTAssertEqual(item.text, "Reading")
        XCTAssertEqual(tool.kind, .read)
        XCTAssertEqual(tool.content, [.content(.text("reading"))])
        XCTAssertEqual(tool.locations, [ToolCallLocation(path: "/tmp/a.swift", line: 3)])
        XCTAssertEqual(tool.rawInput, .object(["path": .string("/tmp/a.swift")]))
        XCTAssertEqual(tool.rawOutput, .object(["ok": .bool(true)]))
        XCTAssertEqual(tool.completedAt, finished)
    }

    func testLateNotificationAfterCancelDoesNotSetBusy() {
        var state = makeState()

        AgentSessionReducer.reduce(&state, event: .turnBegan)
        AgentSessionReducer.reduce(&state, event: .turnCancelled(staleReason: "Cancelled"))
        AgentSessionReducer.reduce(&state, event: .toolCallUpsert(
            id: "late",
            title: "Late update",
            status: .completed,
            kind: .execute,
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil
        ))

        XCTAssertEqual(state.status, .idle)
        XCTAssertFalse(state.isTurnActive)
        XCTAssertTrue(state.messages.contains { $0.toolCall?.toolCallId == "late" })
    }

    func testTurnCompletionMarksUnfinishedToolStale() {
        var state = makeState()

        AgentSessionReducer.reduce(&state, event: .turnBegan)
        AgentSessionReducer.reduce(&state, event: .toolCallUpsert(
            id: "tool-1",
            title: "Running",
            status: .inProgress,
            kind: .execute,
            content: nil,
            locations: nil,
            rawInput: nil,
            rawOutput: nil
        ))
        AgentSessionReducer.reduce(&state, event: .turnCompleted(staleReason: "Ended"))

        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.messages.first?.toolCall?.abandonedReason, "Ended")
    }

    func testPendingPermissionIsStoredAndClearsToThinkingWhileTurnActive() {
        var state = makeState()
        let permission = AgentPendingPermission(request: RequestPermissionRequest(
            sessionId: "session-123",
            toolCall: PermissionToolCallInfo(toolCallId: "tool-1", title: "Run", kind: .execute),
            options: [PermissionOption(optionId: "allow-once", name: "Allow once", kind: .allowOnce)]
        ))

        AgentSessionReducer.reduce(&state, event: .turnBegan)
        AgentSessionReducer.reduce(&state, event: .pendingPermission(permission))

        XCTAssertEqual(state.status, .needsPermission)
        XCTAssertEqual(state.pendingPermission?.request.toolCall?.toolCallId, "tool-1")

        AgentSessionReducer.reduce(&state, event: .pendingPermission(nil))

        XCTAssertEqual(state.status, .thinking)
        XCTAssertNil(state.pendingPermission)
    }

    func testCancelClearsPendingInteractionsAndStaysIdle() {
        var state = makeState()
        let elicitation = AgentPendingElicitation(request: ElicitationRequest(sessionId: "session-123", message: "Need input"))

        AgentSessionReducer.reduce(&state, event: .turnBegan)
        AgentSessionReducer.reduce(&state, event: .pendingElicitation(elicitation))
        AgentSessionReducer.reduce(&state, event: .turnCancelled(staleReason: "Cancelled"))

        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.pendingElicitation)
        XCTAssertFalse(state.isTurnActive)
    }
}
