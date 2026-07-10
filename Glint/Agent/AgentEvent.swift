import Foundation

/// Capabilities are declared by the integration that produced an event. UI
/// actions must check these values instead of inferring support from an agent
/// name or from the mere presence of a hook file.
enum AgentCapability: String, Codable, CaseIterable, Hashable {
    case focusPane
    case interrupt
    case resume
    case respondToApproval
}

/// The lifecycle vocabulary shared by every upstream agent adapter.
enum AgentLifecycleEvent: String, Codable, Equatable {
    case sessionStarted
    case sessionEnded
    case turnStarted
    case toolStarted
    case toolCompleted
    case notification
    case permissionRequested
    case compactionStarted
    case turnCompleted
    case turnFailed
    case interrupted
}

/// Versioned, normalized envelope carried from the socket boundary to the
/// pure pane-state reducer. `eventID` is optional only for legacy reporters.
struct AgentEvent: Equatable {
    static let currentVersion = 1

    var version: Int
    var eventID: String?
    var pane: String
    var agent: PaneAgentKind
    var event: AgentLifecycleEvent
    var timestamp: Date
    var sessionID: String?
    var detail: String?
    var capabilities: Set<AgentCapability>

    init(
        version: Int = AgentEvent.currentVersion,
        eventID: String? = nil,
        pane: String,
        agent: PaneAgentKind,
        event: AgentLifecycleEvent,
        timestamp: Date,
        sessionID: String? = nil,
        detail: String? = nil,
        capabilities: Set<AgentCapability> = []
    ) {
        self.version = version
        self.eventID = eventID
        self.pane = pane
        self.agent = agent
        self.event = event
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.detail = detail
        self.capabilities = capabilities
    }
}

enum AgentEventDecodingError: Error, Equatable {
    case malformedPayload
    case missingEventID
    case unsupportedVersion(Int)
    case unknownAgent(String)
    case unknownEvent(String)
}

/// Converts both the original `{pane, hook, agent}` protocol and evolving
/// provider payloads into `AgentEvent`. JSON inspection is intentionally kept
/// at this I/O boundary; all downstream code is strongly typed.
enum AgentEventDecoder {
    static func decodeLegacy(
        pane: String,
        hook: String,
        agent: PaneAgentKind,
        receivedAt: Date = Date()
    ) throws -> AgentEvent {
        guard let event = lifecycleEvent(hook) else {
            throw AgentEventDecodingError.unknownEvent(hook)
        }
        return AgentEvent(
            version: 0,
            pane: pane,
            agent: agent,
            event: event,
            timestamp: receivedAt
        )
    }

    static func decode(_ data: Data, receivedAt: Date = Date()) throws -> AgentEvent {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any],
              let pane = nonemptyString(payload["pane"]) else {
            throw AgentEventDecodingError.malformedPayload
        }

        let isLegacy = nonemptyString(payload["hook"]) != nil
            && nonemptyString(payload["event"]) == nil
        let version = isLegacy ? 0 : (payload["version"] as? NSNumber)?.intValue ?? 1
        guard version == 0 || version == AgentEvent.currentVersion else {
            throw AgentEventDecodingError.unsupportedVersion(version)
        }

        let eventID = nonemptyString(payload["eventID"] ?? payload["event_id"])
        guard isLegacy || eventID != nil else {
            throw AgentEventDecodingError.missingEventID
        }

        let rawAgent = nonemptyString(payload["agent"]) ?? "claude"
        guard let agent = agentKind(rawAgent) else {
            throw AgentEventDecodingError.unknownAgent(rawAgent)
        }
        guard let rawEvent = nonemptyString(payload[isLegacy ? "hook" : "event"]),
              let event = lifecycleEvent(rawEvent) else {
            throw AgentEventDecodingError.unknownEvent(
                nonemptyString(payload[isLegacy ? "hook" : "event"]) ?? ""
            )
        }

        return AgentEvent(
            version: version,
            eventID: eventID,
            pane: pane,
            agent: agent,
            event: event,
            timestamp: timestamp(payload["timestamp"]) ?? receivedAt,
            sessionID: nonemptyString(
                payload["session"] ?? payload["sessionID"] ?? payload["session_id"]
            ),
            detail: detail(payload),
            capabilities: capabilities(payload["capabilities"])
        )
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    private static func agentKind(_ raw: String) -> PaneAgentKind? {
        let value = normalized(raw)
        if value.contains("claude") { return .claude }
        if value.contains("codex") { return .codex }
        if value.contains("opencode") { return .opencode }
        if value == "omp" || value.contains("ohmypi") { return .omp }
        return nil
    }

    /// Includes the native spellings currently emitted by Claude Code,
    /// Codex, OpenCode, and Oh My Pi adapters.
    private static func lifecycleEvent(_ raw: String) -> AgentLifecycleEvent? {
        switch normalized(raw) {
        case "sessionstart", "sessionstarted", "sessioncreated": return .sessionStarted
        case "sessionend", "sessionended", "sessionexit", "processexit": return .sessionEnded
        case "userpromptsubmit", "turnstarted", "agentanalysis", "agentstarted": return .turnStarted
        case "pretooluse", "toolstarted", "toolexecutebefore", "toolcall": return .toolStarted
        case "posttooluse", "toolcompleted", "toolexecuteafter", "toolresult": return .toolCompleted
        case "notification": return .notification
        case "permissionrequest", "permissionrequested", "permissionasked": return .permissionRequested
        case "precompact", "postcompaction", "compactionstarted", "contextcompaction": return .compactionStarted
        case "stop", "turncompleted", "turnfinished", "done": return .turnCompleted
        case "stopfailure", "turnfailed", "error", "failed": return .turnFailed
        case "interrupt", "interrupted", "turninterrupted": return .interrupted
        default: return nil
        }
    }

    private static func normalized(_ raw: String) -> String {
        raw.lowercased().filter(\.isLetter)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let string = nonemptyString(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func capabilities(_ value: Any?) -> Set<AgentCapability> {
        Set((value as? [String] ?? []).compactMap(AgentCapability.init(rawValue:)))
    }

    private static func detail(_ payload: [String: Any]) -> String? {
        nonemptyString(payload["detail"])
            ?? nonemptyString(payload["message"])
            ?? nonemptyString(payload["tool"])
            ?? nonemptyString(payload["tool_name"])
    }
}

enum AgentEventDisposition: Equatable {
    case applied
    case duplicate
    case stale
    case protectedPermission
}

struct AgentStateReduction: Equatable {
    var state: PaneAgentState?
    var disposition: AgentEventDisposition
    var replayEventIDs: [String]
}

/// The complete agent lifecycle state machine. It has no dependencies on
/// SwiftUI, AppKit, notifications, clocks, or persistence.
enum AgentStateReducer {
    static func reduce(
        _ existing: PaneAgentState?,
        event: AgentEvent,
        completionIsUnread: Bool = true,
        replayEventIDs: [String] = []
    ) -> AgentStateReduction {
        let replayWindow = Array(
            (replayEventIDs + (existing?.recentEventIDs ?? [])).suffix(32)
        )
        if let eventID = event.eventID,
           replayWindow.contains(eventID) {
            return AgentStateReduction(
                state: existing,
                disposition: .duplicate,
                replayEventIDs: replayWindow
            )
        }
        if let lastEventAt = existing?.lastEventAt, event.timestamp < lastEventAt {
            return AgentStateReduction(
                state: existing,
                disposition: .stale,
                replayEventIDs: replayWindow
            )
        }
        let updatedReplayWindow = event.eventID.map {
            Array((replayWindow + [$0]).suffix(32))
        } ?? replayWindow
        if event.event == .sessionEnded {
            return AgentStateReduction(
                state: nil,
                disposition: .applied,
                replayEventIDs: updatedReplayWindow
            )
        }
        if event.event == .toolCompleted,
           let existing,
           existing.status == .needsPermission,
           event.timestamp.timeIntervalSince(existing.updatedAt) < 2 {
            return AgentStateReduction(
                state: existing,
                disposition: .protectedPermission,
                replayEventIDs: replayWindow
            )
        }

        var state = existing ?? PaneAgentState(
            kind: event.agent,
            status: .idle,
            updatedAt: event.timestamp
        )
        let oldStatus = state.status
        state.kind = event.agent
        state.status = status(
            for: event.event,
            existing: state.status,
            completionIsUnread: completionIsUnread
        )
        if event.event != .notification {
            state.detail = event.detail
        }
        state.sessionID = event.sessionID ?? state.sessionID
        if !event.capabilities.isEmpty {
            state.capabilities = event.capabilities
        }

        let isBusy = state.status.isBusy
        let startsTurn = isBusy && !oldStatus.isBusy
        let resumesAfterApproval = isBusy
            && oldStatus == .needsPermission
            && state.status != .needsPermission
        if startsTurn || resumesAfterApproval {
            state.turnStartedAt = event.timestamp
        }
        state.updatedAt = event.timestamp
        state.lastEventAt = event.timestamp
        state.lastEventHealth = .verified
        state.recentEventIDs = updatedReplayWindow
        return AgentStateReduction(
            state: state,
            disposition: .applied,
            replayEventIDs: updatedReplayWindow
        )
    }

    private static func status(
        for event: AgentLifecycleEvent,
        existing: PaneAgentStatus,
        completionIsUnread: Bool
    ) -> PaneAgentStatus {
        switch event {
        case .sessionStarted, .interrupted: return .idle
        case .sessionEnded: return .idle
        case .turnStarted, .toolCompleted: return .thinking
        case .toolStarted: return .tool
        case .notification: return existing
        case .permissionRequested: return .needsPermission
        case .compactionStarted: return .compacting
        case .turnCompleted: return completionIsUnread ? .justCompleted : .idle
        case .turnFailed: return .failed
        }
    }

}
