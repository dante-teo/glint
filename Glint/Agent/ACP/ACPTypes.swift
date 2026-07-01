import Foundation

enum ACPJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ACPJSONValue])
    case object([String: ACPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ACPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ACPJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    func decoded<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: JSONEncoder.acp.encode(self))
    }
}

extension JSONEncoder {
    static var acp: JSONEncoder {
        JSONEncoder()
    }
}

extension JSONDecoder {
    static var acp: JSONDecoder {
        JSONDecoder()
    }
}

private enum SessionIDAliasKey: String, CodingKey {
    case sessionId, sessionID
}

private extension Decoder {
    func decodeSessionIdAlias() throws -> String {
        let container = try self.container(keyedBy: SessionIDAliasKey.self)
        if let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) {
            return sessionId
        }
        return try container.decode(String.self, forKey: .sessionID)
    }
}

struct ACPRequest<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: Params
}

struct ACPNotificationEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: Params
}

struct ACPResponse<Result: Decodable>: Decodable {
    let id: Int?
    let result: Result?
    let error: ACPErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case id, result, error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        error = try container.decodeIfPresent(ACPErrorPayload.self, forKey: .error)
        if container.contains(.result) {
            result = try container.decode(Result.self, forKey: .result)
        } else {
            result = nil
        }
    }
}

struct ACPRawResponse: Decodable {
    let id: Int?
    let result: ACPJSONValue?
    let error: ACPErrorPayload?
}

struct ACPNotification: Decodable, Equatable, Sendable {
    let method: String
    let params: ACPJSONValue?
}

struct ACPServerRequest: Decodable, Equatable, Sendable {
    let id: Int
    let method: String
    let params: ACPJSONValue?

    func decodeParams<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = .acp) throws -> T {
        try (params ?? .null).decoded(type, using: decoder)
    }
}

struct ACPIncomingMessage: Decodable {
    let id: Int?
    let method: String?
    let params: ACPJSONValue?
    let result: ACPJSONValue?
    let error: ACPErrorPayload?
}

struct ACPResponseEnvelope<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let result: Result?
    let error: ACPErrorPayload?
}

struct ACPErrorPayload: Codable, Error, Equatable, Sendable {
    let code: Int
    let message: String
    let data: ACPJSONValue?

    init(code: Int = -32000, message: String, data: ACPJSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decodeIfPresent(Int.self, forKey: .code) ?? -32000
        message = try container.decode(String.self, forKey: .message)
        data = try container.decodeIfPresent(ACPJSONValue.self, forKey: .data)
    }
}

struct EmptyACPResult: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        _ = try? container.decode([String: ACPJSONValue].self)
    }
}

struct InitializeRequest: Codable, Equatable, Sendable {
    var protocolVersion: Int = 1
    var clientCapabilities = ClientCapabilities()
    var clientInfo: ImplementationInfo? = ImplementationInfo(name: "glint", title: "Glint")
}

struct InitializeResponse: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var agentCapabilities: AgentCapabilities?
    var agentInfo: ImplementationInfo?
    var authMethods: [AuthMethod]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, agentCapabilities, agentInfo, authMethods
    }

    init(protocolVersion: Int,
         agentCapabilities: AgentCapabilities? = nil,
         agentInfo: ImplementationInfo? = nil,
         authMethods: [AuthMethod] = []) {
        self.protocolVersion = protocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentInfo = agentInfo
        self.authMethods = authMethods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try? container.decode(Int.self, forKey: .protocolVersion) {
            protocolVersion = version
        } else {
            let rawVersion = try container.decode(String.self, forKey: .protocolVersion)
            protocolVersion = Int(rawVersion) ?? -1
        }
        agentCapabilities = try container.decodeIfPresent(AgentCapabilities.self, forKey: .agentCapabilities)
        agentInfo = try container.decodeIfPresent(ImplementationInfo.self, forKey: .agentInfo)
        authMethods = try container.decodeIfPresent([AuthMethod].self, forKey: .authMethods) ?? []
    }
}

struct ImplementationInfo: Codable, Equatable, Sendable {
    var name: String
    var title: String?
    var version: String?
}

struct ClientCapabilities: Codable, Equatable, Sendable {
    var fs = FileSystemCapabilities()
    var terminal = false
}

struct FileSystemCapabilities: Codable, Equatable, Sendable {
    var readTextFile = true
    var writeTextFile = true
}

struct AgentCapabilities: Codable, Equatable, Sendable {
    var loadSession: Bool?
    var promptCapabilities: PromptCapabilities?
    var mcpCapabilities: MCPCapabilities?
    var sessionCapabilities: SessionCapabilities?
    var auth: ACPJSONValue?
}

struct PromptCapabilities: Codable, Equatable, Sendable {
    var image: Bool?
    var audio: Bool?
    var embeddedContext: Bool?
}

struct MCPCapabilities: Codable, Equatable, Sendable {
    var http: Bool?
    var sse: Bool?
}

struct SessionCapabilities: Codable, Equatable, Sendable {
    var close: ACPJSONValue?
    var delete: ACPJSONValue?
    var list: ACPJSONValue?
    var resume: ACPJSONValue?
    var additionalDirectories: ACPJSONValue?
}

struct AuthMethod: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var description: String?
    var raw: ACPJSONValue?
}

struct McpServer: Codable, Equatable, Sendable {
    var name: String
    var command: String
    var args: [String]
    var env: [EnvVariable]

    init(name: String, command: String, args: [String] = [], env: [EnvVariable] = []) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }
}

struct EnvVariable: Codable, Equatable, Sendable {
    var name: String
    var value: String
}

struct NewSessionRequest: Codable, Equatable, Sendable {
    var cwd: String
    var mcpServers: [McpServer] = []
    var additionalDirectories: [String]?
}

struct NewSessionResponse: Codable, Equatable, Sendable {
    var sessionId: String?
    var sessionID: String?
    var modes: SessionModeState?
    var models: [SessionModel]?
    var configOptions: [SessionConfigOption]?

    private enum CodingKeys: String, CodingKey {
        case sessionId, sessionID, modes, models, configOptions
    }

    var resolvedSessionId: String? {
        sessionId ?? sessionID
    }
}

typealias NewSessionResult = NewSessionResponse

struct LoadSessionRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var cwd: String
    var mcpServers: [McpServer] = []
    var additionalDirectories: [String]?
}

struct LoadSessionResponse: Codable, Equatable, Sendable {
    var modes: SessionModeState?
    var configOptions: [SessionConfigOption]?
}

struct CloseSessionRequest: Codable, Equatable, Sendable {
    var sessionId: String
}

struct SetSessionModeRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var modeId: String
}

struct CloseSessionResponse: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        _ = try? container.decode([String: ACPJSONValue].self)
    }
}

struct PromptRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var prompt: [ContentBlock]
}

struct PromptResponse: Codable, Equatable, Sendable {
    var stopReason: StopReason

    private enum CodingKeys: String, CodingKey {
        case stopReason
    }

    init(stopReason: StopReason) {
        self.stopReason = stopReason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            stopReason = .endTurn
            return
        }
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            stopReason = try keyed.decodeIfPresent(StopReason.self, forKey: .stopReason) ?? .endTurn
        } else {
            stopReason = .endTurn
        }
    }
}

enum StopReason: Codable, Equatable, Sendable {
    case endTurn
    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        case "cancelled": self = .cancelled
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .endTurn: try container.encode("end_turn")
        case .maxTokens: try container.encode("max_tokens")
        case .maxTurnRequests: try container.encode("max_turn_requests")
        case .refusal: try container.encode("refusal")
        case .cancelled: try container.encode("cancelled")
        case .unknown(let value): try container.encode(value)
        }
    }
}

enum ContentBlock: Codable, Equatable, Sendable {
    case text(TextContent)
    case image(ImageContent)
    case resourceLink(ResourceLinkContent)
    case resource(ResourceContent)
    case unknown(type: String, raw: ACPJSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let raw = try ACPJSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let data = try JSONEncoder.acp.encode(raw)
        switch type {
        case "text":
            self = .text(try JSONDecoder.acp.decode(TextContent.self, from: data))
        case "image":
            self = .image(try JSONDecoder.acp.decode(ImageContent.self, from: data))
        case "resource_link":
            self = .resourceLink(try JSONDecoder.acp.decode(ResourceLinkContent.self, from: data))
        case "resource":
            self = .resource(try JSONDecoder.acp.decode(ResourceContent.self, from: data))
        default:
            self = .unknown(type: type, raw: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let value):
            try value.encode(to: encoder)
        case .image(let value):
            try value.encode(to: encoder)
        case .resourceLink(let value):
            try value.encode(to: encoder)
        case .resource(let value):
            try value.encode(to: encoder)
        case .unknown(_, let raw):
            try raw.encode(to: encoder)
        }
    }

    static func text(_ text: String) -> ContentBlock {
        .text(TextContent(text: text))
    }

    var plainText: String? {
        switch self {
        case .text(let value): return value.text
        default: return nil
        }
    }
}

struct TextContent: Codable, Equatable, Sendable {
    var type = "text"
    var text: String
}

struct ImageContent: Codable, Equatable, Sendable {
    var type = "image"
    var data: String?
    var mimeType: String?
    var uri: String?
}

struct ResourceLinkContent: Codable, Equatable, Sendable {
    var type = "resource_link"
    var uri: String
    var name: String?
    var mimeType: String?
}

struct ResourceContent: Codable, Equatable, Sendable {
    var type = "resource"
    var resource: EmbeddedResource
}

struct EmbeddedResource: Codable, Equatable, Sendable {
    var uri: String
    var mimeType: String?
    var text: String?
}

struct SessionNotification: Codable, Equatable, Sendable {
    var sessionId: String
    var update: SessionUpdate

    private enum CodingKeys: String, CodingKey {
        case sessionId, update
    }

    init(sessionId: String, update: SessionUpdate) {
        self.sessionId = sessionId
        self.update = update
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        update = try container.decode(SessionUpdate.self, forKey: .update)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(update, forKey: .update)
    }
}

enum SessionUpdate: Codable, Equatable, Sendable {
    case userMessageChunk(MessageChunkUpdate)
    case agentMessageChunk(MessageChunkUpdate)
    case agentThoughtChunk(MessageChunkUpdate)
    case toolCall(ToolCallUpdate)
    case toolCallUpdate(ToolCallDelta)
    case plan(PlanUpdate)
    case usageUpdate(UsageUpdate)
    case sessionInfoUpdate(SessionInfoUpdate)
    case currentModeUpdate(CurrentModeUpdate)
    case availableCommandsUpdate(AvailableCommandsUpdate)
    case configOptionUpdate(ConfigOptionUpdate)
    case unknown(String, ACPJSONValue)

    private enum CodingKeys: String, CodingKey {
        case sessionUpdate
    }

    init(from decoder: Decoder) throws {
        let raw = try ACPJSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let discriminator = try container.decode(String.self, forKey: .sessionUpdate)
        let data = try JSONEncoder.acp.encode(raw)
        switch discriminator {
        case "user_message_chunk":
            self = .userMessageChunk(try JSONDecoder.acp.decode(MessageChunkUpdate.self, from: data))
        case "agent_message_chunk":
            self = .agentMessageChunk(try JSONDecoder.acp.decode(MessageChunkUpdate.self, from: data))
        case "agent_thought_chunk":
            self = .agentThoughtChunk(try JSONDecoder.acp.decode(MessageChunkUpdate.self, from: data))
        case "tool_call":
            self = .toolCall(try JSONDecoder.acp.decode(ToolCallUpdate.self, from: data))
        case "tool_call_update":
            self = .toolCallUpdate(try JSONDecoder.acp.decode(ToolCallDelta.self, from: data))
        case "plan":
            self = .plan(try JSONDecoder.acp.decode(PlanUpdate.self, from: data))
        case "usage_update":
            self = .usageUpdate(try JSONDecoder.acp.decode(UsageUpdate.self, from: data))
        case "session_info_update":
            self = .sessionInfoUpdate(try JSONDecoder.acp.decode(SessionInfoUpdate.self, from: data))
        case "current_mode_update":
            self = .currentModeUpdate(try JSONDecoder.acp.decode(CurrentModeUpdate.self, from: data))
        case "available_commands_update":
            self = .availableCommandsUpdate(try JSONDecoder.acp.decode(AvailableCommandsUpdate.self, from: data))
        case "config_option_update":
            self = .configOptionUpdate(try JSONDecoder.acp.decode(ConfigOptionUpdate.self, from: data))
        default:
            self = .unknown(discriminator, raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .userMessageChunk(let value): try value.encode(to: encoder)
        case .agentMessageChunk(let value): try value.encode(to: encoder)
        case .agentThoughtChunk(let value): try value.encode(to: encoder)
        case .toolCall(let value): try value.encode(to: encoder)
        case .toolCallUpdate(let value): try value.encode(to: encoder)
        case .plan(let value): try value.encode(to: encoder)
        case .usageUpdate(let value): try value.encode(to: encoder)
        case .sessionInfoUpdate(let value): try value.encode(to: encoder)
        case .currentModeUpdate(let value): try value.encode(to: encoder)
        case .availableCommandsUpdate(let value): try value.encode(to: encoder)
        case .configOptionUpdate(let value): try value.encode(to: encoder)
        case .unknown(_, let raw): try raw.encode(to: encoder)
        }
    }
}

struct MessageChunkUpdate: Codable, Equatable, Sendable {
    var sessionUpdate: String
    var messageId: String?
    var content: ContentBlock
}

struct ToolCallUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "tool_call"
    var toolCallId: String
    var title: String
    var kind: ToolKind?
    var status: ToolCallStatus?
    var content: [ToolCallContent]?
    var locations: [ToolCallLocation]?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
}

struct ToolCallDelta: Codable, Equatable, Sendable {
    var sessionUpdate = "tool_call_update"
    var toolCallId: String
    var title: String?
    var kind: ToolKind?
    var status: ToolCallStatus?
    var content: [ToolCallContent]?
    var locations: [ToolCallLocation]?
    var rawInput: ACPJSONValue?
    var rawOutput: ACPJSONValue?
}

enum ToolKind: Codable, Equatable, Sendable {
    case read
    case edit
    case delete
    case move
    case search
    case execute
    case think
    case fetch
    case other
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "read": self = .read
        case "edit": self = .edit
        case "delete": self = .delete
        case "move": self = .move
        case "search": self = .search
        case "execute": self = .execute
        case "think": self = .think
        case "fetch": self = .fetch
        case "other": self = .other
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .read: try container.encode("read")
        case .edit: try container.encode("edit")
        case .delete: try container.encode("delete")
        case .move: try container.encode("move")
        case .search: try container.encode("search")
        case .execute: try container.encode("execute")
        case .think: try container.encode("think")
        case .fetch: try container.encode("fetch")
        case .other: try container.encode("other")
        case .unknown(let value): try container.encode(value)
        }
    }
}

enum ToolCallStatus: Codable, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("pending")
        case .inProgress: try container.encode("in_progress")
        case .completed: try container.encode("completed")
        case .failed: try container.encode("failed")
        case .unknown(let value): try container.encode(value)
        }
    }
}

enum ToolCallContent: Codable, Equatable, Sendable {
    case content(ContentBlock)
    case diff(ACPJSONValue)
    case unknown(type: String, raw: ACPJSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, content
    }

    init(from decoder: Decoder) throws {
        let raw = try ACPJSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "content":
            self = .content(try container.decode(ContentBlock.self, forKey: .content))
        case "diff":
            self = .diff(raw)
        default:
            self = .unknown(type: type, raw: raw)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .content(let content):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("content", forKey: .type)
            try container.encode(content, forKey: .content)
        case .diff(let raw), .unknown(_, let raw):
            try raw.encode(to: encoder)
        }
    }
}

struct ToolCallLocation: Codable, Equatable, Sendable {
    var path: String?
    var line: Int?
}

struct PlanUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "plan"
    var entries: [PlanEntry]
}

struct PlanEntry: Codable, Equatable, Sendable {
    var content: String
    var status: String?
    var priority: String?
}

struct UsageUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "usage_update"
    var used: UInt64
    var size: UInt64
    var cost: Cost?
}

struct Cost: Codable, Equatable, Sendable {
    var amount: Double
    var currency: String
}

struct SessionInfoUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "session_info_update"
    var title: String?
    var updatedAt: String?
}

struct CurrentModeUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "current_mode_update"
    var modeId: String

    // The ACP spec's `current_mode_update` notification uses a flat
    // `modeId` key (distinct from `SessionModeState.currentModeId`, which
    // is nested under `modes` in session setup responses). Tolerate a
    // `currentModeId` key too in case an agent sends the nested-style name
    // here as well.
    private enum CodingKeys: String, CodingKey {
        case sessionUpdate, modeId, currentModeId
    }

    init(modeId: String) {
        self.modeId = modeId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionUpdate = try container.decodeIfPresent(String.self, forKey: .sessionUpdate) ?? "current_mode_update"
        if let modeId = try container.decodeIfPresent(String.self, forKey: .modeId) {
            self.modeId = modeId
        } else {
            modeId = try container.decode(String.self, forKey: .currentModeId)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionUpdate, forKey: .sessionUpdate)
        try container.encode(modeId, forKey: .modeId)
    }
}

struct AvailableCommandsUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "available_commands_update"
    var availableCommands: [AvailableCommand]
}

struct AvailableCommand: Codable, Equatable, Sendable {
    var name: String?
    var description: String?
}

struct ConfigOptionUpdate: Codable, Equatable, Sendable {
    var sessionUpdate = "config_option_update"
    var configOptions: [SessionConfigOption]
}

struct SessionModel: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var raw: ACPJSONValue?
}

struct SessionModeState: Codable, Equatable, Sendable {
    var currentModeId: String?
    var availableModes: [SessionMode]?
}

struct SessionMode: Codable, Equatable, Sendable {
    var id: String
    var name: String?
    var description: String?
}

struct SessionConfigOption: Codable, Equatable, Sendable {
    var id: String?
    var name: String?
    var type: String?
    var value: ACPJSONValue?
}

/// The `toolCall` field nested inside a `session/request_permission`
/// request. The ACP v1 spec's own example includes only `toolCallId` (all
/// other fields omitted), so unlike `ToolCallUpdate` (used for the
/// tool_call *creation* notification, where `title` is required), every
/// field here besides the id must tolerate being absent.
struct PermissionToolCallInfo: Codable, Equatable, Sendable {
    var toolCallId: String
    var title: String?
    var kind: ToolKind?
    var status: ToolCallStatus?
    var rawInput: ACPJSONValue?
}

struct PermissionOption: Codable, Equatable, Sendable {
    var optionId: String
    var name: String?
    var kind: PermissionOptionKind?
}

enum PermissionOptionKind: Codable, Equatable, Sendable {
    case allowOnce
    case allowAlways
    case rejectOnce
    case rejectAlways
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "allow_once": self = .allowOnce
        case "allow_always": self = .allowAlways
        case "reject_once": self = .rejectOnce
        case "reject_always": self = .rejectAlways
        default: self = .unknown(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .allowOnce: try container.encode("allow_once")
        case .allowAlways: try container.encode("allow_always")
        case .rejectOnce: try container.encode("reject_once")
        case .rejectAlways: try container.encode("reject_always")
        case .unknown(let value): try container.encode(value)
        }
    }
}

struct RequestPermissionRequest: Codable, Equatable, Sendable {
    var sessionId: String
    /// Per the ACP v1 spec, the tool call details are nested under
    /// `toolCall`, not flat on the request — do not add flattened
    /// `toolCallId`/`title`/`kind`/`rawInput` fields back here; read them
    /// via `toolCall`.
    var toolCall: PermissionToolCallInfo?
    /// The choices the agent is offering (e.g. allow-once/reject-once).
    /// The client's response must echo back one of these `optionId`s, not
    /// an arbitrary approved/denied string.
    var options: [PermissionOption]
    /// Glint-local enrichment set when `PermissionReviewer` escalates a
    /// request to the user. Never part of the ACP wire format (not decoded
    /// from or encoded back to `devin acp`) — keeps the original `rawInput`
    /// intact so the permission card can show both the reviewer's reasoning
    /// and the actual tool arguments.
    var reviewReason: String?

    private enum CodingKeys: String, CodingKey {
        case sessionId, toolCall, options
    }

    init(sessionId: String,
         toolCall: PermissionToolCallInfo? = nil,
         options: [PermissionOption] = [],
         reviewReason: String? = nil) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
        self.reviewReason = reviewReason
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCall = try container.decodeIfPresent(PermissionToolCallInfo.self, forKey: .toolCall)
        options = try container.decodeIfPresent([PermissionOption].self, forKey: .options) ?? []
        reviewReason = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(toolCall, forKey: .toolCall)
        try container.encode(options, forKey: .options)
    }
}

struct RequestPermissionResponse: Codable, Equatable, Sendable {
    var outcome: RequestPermissionOutcome
}

/// Per the ACP v1 spec, the response is `{"outcome": {"outcome": ...}}` —
/// a nested object naming the *selected option* by id, not a bare
/// "approved"/"denied" string. `selected` must reference one of the
/// `optionId`s the agent offered in the request's `options` array;
/// `cancelled` is mandatory when the client abandons the turn (e.g. the
/// user hits stop) rather than actually deciding allow/reject.
enum RequestPermissionOutcome: Codable, Equatable, Sendable {
    case selected(optionId: String)
    case cancelled

    private enum CodingKeys: String, CodingKey {
        case outcome, optionId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(String.self, forKey: .outcome)
        if outcome == "cancelled" {
            self = .cancelled
        } else {
            self = .selected(optionId: try container.decode(String.self, forKey: .optionId))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .selected(let optionId):
            try container.encode("selected", forKey: .outcome)
            try container.encode(optionId, forKey: .optionId)
        case .cancelled:
            try container.encode("cancelled", forKey: .outcome)
        }
    }
}

struct ElicitationRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var message: String?
    var schema: ACPJSONValue?

    private enum CodingKeys: String, CodingKey {
        case sessionId, message, schema
    }

    init(sessionId: String, message: String? = nil, schema: ACPJSONValue? = nil) {
        self.sessionId = sessionId
        self.message = message
        self.schema = schema
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        schema = try container.decodeIfPresent(ACPJSONValue.self, forKey: .schema)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(schema, forKey: .schema)
    }
}

struct ElicitationResponse: Codable, Equatable, Sendable {
    var values: ACPJSONValue?
    var cancelled: Bool?
}

struct ReadTextFileRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var path: String
    var line: Int?
    var limit: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionId, path, line, limit
    }

    init(sessionId: String, path: String, line: Int? = nil, limit: Int? = nil) {
        self.sessionId = sessionId
        self.path = path
        self.line = line
        self.limit = limit
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(path, forKey: .path)
        try container.encodeIfPresent(line, forKey: .line)
        try container.encodeIfPresent(limit, forKey: .limit)
    }
}

struct ReadTextFileResponse: Codable, Equatable, Sendable {
    var content: String
}

struct WriteTextFileRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var path: String
    var content: String

    private enum CodingKeys: String, CodingKey {
        case sessionId, path, content
    }

    init(sessionId: String, path: String, content: String) {
        self.sessionId = sessionId
        self.path = path
        self.content = content
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        content = try container.decode(String.self, forKey: .content)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(path, forKey: .path)
        try container.encode(content, forKey: .content)
    }
}

struct WriteTextFileResponse: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        _ = try? container.decode([String: ACPJSONValue].self)
    }
}

struct CreateTerminalRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var command: String
    var args: [String]?
    var env: [EnvVariable]?
    var cwd: String?
    var outputByteLimit: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionId, command, args, env, cwd, outputByteLimit
    }

    init(sessionId: String,
         command: String,
         args: [String]? = nil,
         env: [EnvVariable]? = nil,
         cwd: String? = nil,
         outputByteLimit: Int? = nil) {
        self.sessionId = sessionId
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
        self.outputByteLimit = outputByteLimit
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        env = try container.decodeIfPresent([EnvVariable].self, forKey: .env)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        outputByteLimit = try container.decodeIfPresent(Int.self, forKey: .outputByteLimit)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(args, forKey: .args)
        try container.encodeIfPresent(env, forKey: .env)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(outputByteLimit, forKey: .outputByteLimit)
    }
}

struct CreateTerminalResponse: Codable, Equatable, Sendable {
    var terminalId: String
}

struct TerminalOutputRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var terminalId: String

    private enum CodingKeys: String, CodingKey {
        case sessionId, terminalId
    }

    init(sessionId: String, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try container.decode(String.self, forKey: .terminalId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(terminalId, forKey: .terminalId)
    }
}

struct TerminalOutputResponse: Codable, Equatable, Sendable {
    var output: String
    var truncated: Bool
    var exitStatus: ACPJSONValue?
}

struct KillTerminalRequest: Codable, Equatable, Sendable {
    var sessionId: String
    var terminalId: String

    private enum CodingKeys: String, CodingKey {
        case sessionId, terminalId
    }

    init(sessionId: String, terminalId: String) {
        self.sessionId = sessionId
        self.terminalId = terminalId
    }

    init(from decoder: Decoder) throws {
        sessionId = try decoder.decodeSessionIdAlias()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try container.decode(String.self, forKey: .terminalId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(terminalId, forKey: .terminalId)
    }
}

struct KillTerminalResponse: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        _ = try? container.decode([String: ACPJSONValue].self)
    }
}

struct AuthenticateRequest: Codable, Equatable, Sendable {
    var methodId: String
}

struct AuthenticateResponse: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { return }
        _ = try? container.decode([String: ACPJSONValue].self)
    }
}
