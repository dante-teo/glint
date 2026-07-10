import Foundation

/// Which CLI agent the pane is running.
enum PaneAgentKind: String, Codable {
    case claude
    case codex
    case opencode
    case omp

    /// Human-facing label for the per-pane summary popover.
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .codex:    return "Codex"
        case .opencode: return "OpenCode"
        case .omp:      return "Oh My Pi"
        }
    }
}

enum PaneAgentStatus: String, Codable {
    case idle              // session live, no active turn
    case thinking          // user prompted, agent working
    case tool              // a tool just fired
    case needsPermission   // agent is asking for user approval
    case compacting        // auto-compacting context window
    case justCompleted     // turn just finished — transient, fades to idle
    case failed            // turn ended in an API/transport error (StopFailure)

    var isBusy: Bool {
        switch self {
        case .thinking, .tool, .needsPermission, .compacting: return true
        case .idle, .justCompleted, .failed: return false
        }
    }

    /// Cross-surface attention priority: approvals, failures, active work,
    /// completions, then idle sessions.
    var attentionRank: Int {
        switch self {
        case .needsPermission: return 5
        case .failed: return 4
        case .thinking, .tool, .compacting: return 3
        case .justCompleted: return 2
        case .idle: return 1
        }
    }
}

enum AgentEventHealth: String, Codable, Equatable {
    case verified
    case degraded
}

struct PaneAgentState: Codable, Equatable {
    var kind: PaneAgentKind
    var status: PaneAgentStatus
    var detail: String?       // tool name, notification text, …
    var updatedAt: Date       // last status change — bumped on every hook event
    /// When the CURRENT turn began (user sent the request). Unlike `updatedAt`,
    /// this is NOT reset on intermediate tool/thinking transitions, so the
    /// sidebar can show total turn elapsed time rather than per-step time.
    var turnStartedAt: Date
    var sessionID: String?
    var capabilities: Set<AgentCapability>
    var lastEventAt: Date?
    var lastEventHealth: AgentEventHealth?
    /// A bounded transient replay window. This state is never persisted with
    /// workspaces, but keeping it beside the pane state makes reduction pure.
    var recentEventIDs: [String]

    init(kind: PaneAgentKind, status: PaneAgentStatus, detail: String? = nil,
         updatedAt: Date, turnStartedAt: Date? = nil,
         sessionID: String? = nil,
         capabilities: Set<AgentCapability> = [],
         lastEventAt: Date? = nil,
         lastEventHealth: AgentEventHealth? = nil,
         recentEventIDs: [String] = []) {
        self.kind = kind
        self.status = status
        self.detail = detail
        self.updatedAt = updatedAt
        self.turnStartedAt = turnStartedAt ?? updatedAt
        self.sessionID = sessionID
        self.capabilities = capabilities
        self.lastEventAt = lastEventAt
        self.lastEventHealth = lastEventHealth
        self.recentEventIDs = recentEventIDs
    }

    private enum CodingKeys: String, CodingKey {
        case kind, status, detail, updatedAt, turnStartedAt, sessionID
        case capabilities, lastEventAt, lastEventHealth, recentEventIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(PaneAgentKind.self, forKey: .kind)
        status = try values.decode(PaneAgentStatus.self, forKey: .status)
        detail = try values.decodeIfPresent(String.self, forKey: .detail)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        turnStartedAt = try values.decodeIfPresent(Date.self, forKey: .turnStartedAt) ?? updatedAt
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        capabilities = try values.decodeIfPresent(Set<AgentCapability>.self, forKey: .capabilities) ?? []
        lastEventAt = try values.decodeIfPresent(Date.self, forKey: .lastEventAt)
        lastEventHealth = try values.decodeIfPresent(AgentEventHealth.self, forKey: .lastEventHealth)
        recentEventIDs = try values.decodeIfPresent([String].self, forKey: .recentEventIDs) ?? []
    }
}
