import Foundation

enum AgentProviderID: String, Codable, Equatable, Sendable {
    case devin
}

struct AgentSessionIdentity: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var paneID: PaneID
    var provider: AgentProviderID
}

struct AgentTurnID: Hashable, Codable, Sendable {
    var rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum AgentSessionStatus: Equatable, Codable, Sendable {
    case idle
    case starting
    case thinking
    case tool
    case needsPermission
    case cancelling
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .thinking, .tool, .needsPermission, .cancelling:
            return true
        case .idle, .failed:
            return false
        }
    }
}

struct AgentToolCall: Equatable, Codable, Sendable {
    var toolCallId: String
    var title: String
    var status: ToolCallStatus?
    var kind: ToolKind?
    var content: [ToolCallContent]?
    var locations: [ToolCallLocation]?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
    var startedAt: Date?
    var updatedAt: Date?
    var completedAt: Date?
    var abandonedReason: String?

    var isUnfinished: Bool {
        if abandonedReason != nil { return false }
        return !(status?.isTerminal ?? false)
    }
}

struct AgentTranscriptItem: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
        case thought
        case toolCall
    }

    var id = UUID()
    var role: Role
    var text: String
    var messageId: String?
    var toolCall: AgentToolCall?
}

struct AgentPendingPermission: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var request: RequestPermissionRequest
}

struct AgentPendingElicitation: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var request: ElicitationRequest
}

enum AgentPendingInteraction: Equatable, Sendable {
    case permission(AgentPendingPermission)
    case elicitation(AgentPendingElicitation)
}

struct AgentUsage: Equatable, Codable, Sendable {
    var used: UInt64
    var size: UInt64
    var costAmount: Double?
    var costCurrency: String?
}

struct AgentSessionSnapshot: Codable, Equatable, Sendable {
    var identity: AgentSessionIdentity
    var sessionID: String?
    var projectPath: String?
    var sessionTitle: String?
    var usageInfo: AgentUsage?
    var models: [SessionModel]
    var currentModel: SessionModel?
    var modes: [SessionMode]
    var currentMode: String?
    var configOptions: [SessionConfigOption]
    var messages: [AgentTranscriptItem]
    var status: AgentSessionStatus
    var isTurnActive: Bool
    var pendingPermission: AgentPendingPermission?
    var pendingElicitation: AgentPendingElicitation?

    static func empty(identity: AgentSessionIdentity) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            identity: identity,
            sessionID: nil,
            projectPath: nil,
            sessionTitle: nil,
            usageInfo: nil,
            models: [],
            currentModel: nil,
            modes: [],
            currentMode: nil,
            configOptions: [],
            messages: [],
            status: .idle,
            isTurnActive: false,
            pendingPermission: nil,
            pendingElicitation: nil
        )
    }
}

enum AgentRuntimeEvent: Codable, Equatable, Sendable {
    case userPromptQueued(text: String)
    case sessionStarted(sessionID: String, response: NewSessionResponse)
    case sessionLoaded(sessionID: String, response: LoadSessionResponse)
    case turnBegan
    case turnCompleted(staleReason: String)
    case turnCancelled(staleReason: String)
    case turnFailed(message: String)
    case statusChanged(AgentSessionStatus)
    case messageChunk(role: AgentTranscriptItem.Role, messageId: String?, content: ContentBlock)
    case toolCallUpsert(id: String,
                        title: String?,
                        status: ToolCallStatus?,
                        kind: ToolKind?,
                        content: [ToolCallContent]?,
                        locations: [ToolCallLocation]?,
                        rawInput: ACPJSONValue?,
                        rawOutput: ACPJSONValue?)
    case plan(String)
    case usage(AgentUsage)
    case sessionTitle(String?)
    case currentMode(String?)
    case configOptions([SessionConfigOption])
    case pendingPermission(AgentPendingPermission?)
    case pendingElicitation(AgentPendingElicitation?)
    case diagnostic(ACPDiagnosticEvent)
}
