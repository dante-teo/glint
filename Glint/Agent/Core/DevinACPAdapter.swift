import Combine
import Foundation

final class DevinACPAdapter: AgentRuntimeAdapter {
    private let client: ACPClient

    init(client: ACPClient = ACPClient()) {
        self.client = client
    }

    var notifications: AnyPublisher<ACPNotification, Never> {
        client.notifications
    }

    var diagnostics: AnyPublisher<ACPDiagnosticEvent, Never> {
        client.diagnostics
    }

    func start() throws {
        try client.start()
    }

    func setRequestHandler(method: String, handler: ACPServerRequestHandler?) {
        client.setRequestHandler(method: method, handler: handler)
    }

    func initialize() async throws -> InitializeResponse {
        try await client.initialize()
    }

    func createSession(cwd: String) async throws -> NewSessionResponse {
        try await client.createSession(cwd: cwd)
    }

    func loadSession(sessionID: String, cwd: String) async throws -> LoadSessionResponse {
        try await client.loadSession(sessionID: sessionID, cwd: cwd)
    }

    func prompt(sessionID: String, content: [ContentBlock]) async throws -> PromptResponse {
        try await client.prompt(sessionID: sessionID, content: content)
    }

    func setMode(sessionID: String, modeId: String) async throws {
        try await client.setMode(sessionID: sessionID, modeId: modeId)
    }

    func closeSession(sessionID: String) async throws {
        try await client.closeSession(sessionID: sessionID)
    }

    func cancelSession(sessionID: String) {
        client.cancelSession(sessionID: sessionID)
    }

    func close() {
        client.close()
    }
}
