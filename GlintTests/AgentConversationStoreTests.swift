import XCTest
@testable import Glint

final class AgentConversationStoreTests: XCTestCase {
    private func makeStore() throws -> (AgentConversationStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-agent-conversation-store-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (AgentConversationStore(sessionsDirectory: dir), dir)
    }

    private func makeSnapshot(workspaceID: UUID = UUID()) -> AgentSessionSnapshot {
        AgentSessionSnapshot.empty(identity: AgentSessionIdentity(
            workspaceID: workspaceID,
            paneID: PaneID(value: 0),
            provider: .devin
        ))
    }

    func testSnapshotRoundTrip() throws {
        let (store, _) = try makeStore()
        var snapshot = makeSnapshot()
        snapshot.sessionID = "session-123"
        snapshot.messages = [AgentTranscriptItem(role: .user, text: "hello")]

        try store.saveSnapshot(snapshot)
        let restored = try XCTUnwrap(store.loadSnapshot(workspaceID: snapshot.identity.workspaceID))

        XCTAssertEqual(restored.sessionID, "session-123")
        XCTAssertEqual(restored.messages.first?.text, "hello")
    }

    func testJournalReplayAppliesEventsAndSkipsCorruptedLines() throws {
        let (store, _) = try makeStore()
        let workspaceID = UUID()
        let snapshot = makeSnapshot(workspaceID: workspaceID)

        try store.appendEvent(.userPromptQueued(text: "hello"), workspaceID: workspaceID)
        let handle = try FileHandle(forWritingTo: store.journalURL(workspaceID: workspaceID))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try store.appendEvent(.messageChunk(role: .assistant, messageId: "a1", content: .text("hi")), workspaceID: workspaceID)

        let replayed = store.replayJournal(workspaceID: workspaceID, from: snapshot)

        XCTAssertEqual(replayed.messages.map(\.text), ["hello", "hi"])
    }

    func testSavingSnapshotClearsJournalSoReplayDoesNotDuplicateSnapshotEvents() throws {
        let (store, _) = try makeStore()
        let workspaceID = UUID()
        var snapshot = makeSnapshot(workspaceID: workspaceID)

        try store.appendEvent(.userPromptQueued(text: "hello"), workspaceID: workspaceID)
        snapshot = store.replayJournal(workspaceID: workspaceID, from: snapshot)
        try store.saveSnapshot(snapshot)

        let restored = try XCTUnwrap(store.loadSnapshot(workspaceID: workspaceID))
        let replayed = store.replayJournal(workspaceID: workspaceID, from: restored)

        XCTAssertEqual(replayed.messages.map(\.text), ["hello"])
    }

    func testDeleteConversationRemovesSnapshotAndJournal() throws {
        let (store, _) = try makeStore()
        let snapshot = makeSnapshot()

        try store.saveSnapshot(snapshot)
        try store.appendEvent(.userPromptQueued(text: "hello"), workspaceID: snapshot.identity.workspaceID)
        store.deleteConversation(workspaceID: snapshot.identity.workspaceID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.snapshotURL(workspaceID: snapshot.identity.workspaceID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL(workspaceID: snapshot.identity.workspaceID).path))
    }
}
