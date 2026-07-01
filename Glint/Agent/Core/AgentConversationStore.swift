import Foundation

struct AgentConversationStore: Sendable {
    private let sessionsDirectory: URL

    init(sessionsDirectory: URL? = nil) {
        self.sessionsDirectory = sessionsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".glint", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    func snapshotURL(workspaceID: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    func journalURL(workspaceID: UUID) -> URL {
        sessionsDirectory.appendingPathComponent("\(workspaceID.uuidString).events.ndjson")
    }

    func loadSnapshot(workspaceID: UUID) -> AgentSessionSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(workspaceID: workspaceID)) else { return nil }
        return try? JSONDecoder().decode(AgentSessionSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: AgentSessionSnapshot) throws {
        try FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: snapshotURL(workspaceID: snapshot.identity.workspaceID), options: .atomic)
        try? FileManager.default.removeItem(at: journalURL(workspaceID: snapshot.identity.workspaceID))
    }

    func appendEvent(_ event: AgentRuntimeEvent, workspaceID: UUID) throws {
        try FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(event) + Data([0x0A])
        let url = journalURL(workspaceID: workspaceID)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    func replayJournal(workspaceID: UUID, from snapshot: AgentSessionSnapshot) -> AgentSessionSnapshot {
        guard let data = try? Data(contentsOf: journalURL(workspaceID: workspaceID)),
              let text = String(data: data, encoding: .utf8) else { return snapshot }
        var state = snapshot
        for line in text.split(separator: "\n") {
            guard let eventData = String(line).data(using: .utf8),
                  let event = try? JSONDecoder().decode(AgentRuntimeEvent.self, from: eventData) else {
                continue
            }
            AgentSessionReducer.reduce(&state, event: event)
        }
        return state
    }

    func deleteConversation(workspaceID: UUID) {
        try? FileManager.default.removeItem(at: snapshotURL(workspaceID: workspaceID))
        try? FileManager.default.removeItem(at: journalURL(workspaceID: workspaceID))
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
