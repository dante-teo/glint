import Foundation

@MainActor
final class DevinSessionManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case starting
        case thinking
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .starting, .thinking: return true
            case .idle, .failed: return false
            }
        }
    }

    struct Message: Identifiable, Equatable {
        enum Role: Equatable {
            case user
            case assistant
            case system
        }

        let id = UUID()
        let role: Role
        var text: String
    }

    @Published private(set) var status: Status = .idle {
        didSet { onStatusChange(status) }
    }
    @Published private(set) var messages: [Message] = []
    @Published private(set) var sessionID: String?

    private let onStatusChange: (Status) -> Void
    private let onSessionID: (String?) -> Void
    private var client: ACPClient?
    private var runID = UUID()

    init(workspaceID: UUID,
         paneID: PaneID,
         onStatusChange: @escaping (Status) -> Void,
         onSessionID: @escaping (String?) -> Void) {
        self.onStatusChange = onStatusChange
        self.onSessionID = onSessionID
    }

    func sendFirstPrompt(text: String, projectPath: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !status.isBusy else { return }

        messages.append(Message(role: .user, text: trimmed))
        status = .starting

        let runID = UUID()
        self.runID = runID
        let client = ACPClient()
        self.client = client

        Task.detached { [weak self, client, runID] in
            do {
                try client.start()
                try await client.initialize()
                guard let sessionID = try await client.createSession(cwd: projectPath),
                      !sessionID.isEmpty else {
                    throw ACPClientError.invalidResponse(String(localized: "Devin ACP did not return a session id."))
                }
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.markThinking(sessionID: sessionID)
                try await client.prompt(sessionID: sessionID, text: trimmed)
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.markIdle()
            } catch {
                guard await self?.isCurrentRun(runID) == true else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await self?.markFailed(message)
            }
        }
    }

    func stop() {
        runID = UUID()
        client?.close()
        client = nil
        status = .idle
    }

    private func isCurrentRun(_ id: UUID) -> Bool {
        runID == id
    }

    private func markThinking(sessionID: String?) {
        self.sessionID = sessionID
        onSessionID(sessionID)
        status = .thinking
    }

    private func markIdle() {
        status = .idle
    }

    private func markFailed(_ message: String) {
        messages.append(Message(role: .system, text: message))
        status = .failed(message)
    }
}
