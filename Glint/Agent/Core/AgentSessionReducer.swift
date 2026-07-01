import Foundation

enum AgentSessionReducer {
    private static let maxTranscriptItems = 2_000

    static func reduce(_ state: inout AgentSessionSnapshot, event: AgentRuntimeEvent, now: Date = Date()) {
        switch event {
        case .userPromptQueued(let text):
            appendBounded(&state.messages, AgentTranscriptItem(role: .user, text: text))

        case .sessionStarted(let sessionID, let response):
            state.sessionID = sessionID
            if let models = response.models {
                state.models = models
                state.currentModel = models.first
            }
            if let modes = response.modes {
                state.modes = modes.availableModes ?? []
                state.currentMode = modes.currentModeId
            }
            if let configOptions = response.configOptions {
                state.configOptions = configOptions
            }

        case .sessionLoaded(let sessionID, let response):
            state.sessionID = sessionID
            if let modes = response.modes {
                state.modes = modes.availableModes ?? []
                state.currentMode = modes.currentModeId
            }
            if let configOptions = response.configOptions {
                state.configOptions = configOptions
            }

        case .turnBegan:
            state.isTurnActive = true
            state.status = .thinking

        case .turnCompleted(let reason):
            state.isTurnActive = false
            state.pendingPermission = nil
            state.pendingElicitation = nil
            abandonUnfinishedToolCalls(in: &state, reason: reason, now: now)
            state.status = .idle

        case .turnCancelled(let reason):
            state.isTurnActive = false
            state.pendingPermission = nil
            state.pendingElicitation = nil
            abandonUnfinishedToolCalls(in: &state, reason: reason, now: now)
            state.status = .idle

        case .turnFailed(let message):
            state.isTurnActive = false
            state.pendingPermission = nil
            state.pendingElicitation = nil
            abandonUnfinishedToolCalls(in: &state, reason: message, now: now)
            appendBounded(&state.messages, AgentTranscriptItem(role: .system, text: message))
            state.status = .failed(message)

        case .statusChanged(let status):
            state.status = status

        case .messageChunk(let role, let messageId, let content):
            appendChunk(in: &state, role: role, messageId: messageId, content: content)
            if state.isTurnActive, role == .assistant || role == .thought {
                state.status = .thinking
            }

        case let .toolCallUpsert(id, title, status, kind, content, locations, rawInput, rawOutput):
            mergeToolCall(
                in: &state,
                id: id,
                title: title,
                status: status,
                kind: kind,
                content: content,
                locations: locations,
                rawInput: rawInput,
                rawOutput: rawOutput,
                now: now
            )
            if state.isTurnActive {
                state.status = .tool
            }

        case .plan(let text):
            if !text.isEmpty {
                appendBounded(&state.messages, AgentTranscriptItem(role: .system, text: text))
            }

        case .usage(let usage):
            state.usageInfo = usage

        case .sessionTitle(let title):
            state.sessionTitle = title

        case .currentMode(let mode):
            state.currentMode = mode

        case .configOptions(let options):
            state.configOptions = options

        case .pendingPermission(let permission):
            state.pendingPermission = permission
            if permission != nil {
                state.status = .needsPermission
            } else if state.pendingElicitation != nil {
                state.status = .needsPermission
            } else {
                state.status = state.isTurnActive ? .thinking : .idle
            }

        case .pendingElicitation(let elicitation):
            state.pendingElicitation = elicitation
            if elicitation != nil {
                state.status = .needsPermission
            } else if state.pendingPermission != nil {
                state.status = .needsPermission
            } else {
                state.status = state.isTurnActive ? .thinking : .idle
            }

        case .diagnostic:
            break
        }
    }

    private static func appendChunk(in state: inout AgentSessionSnapshot,
                                    role: AgentTranscriptItem.Role,
                                    messageId: String?,
                                    content: ContentBlock) {
        guard let text = content.plainText, !text.isEmpty else { return }
        if let idx = indexForChunk(in: state.messages, role: role, messageId: messageId) {
            state.messages[idx].text += text
        } else {
            appendBounded(&state.messages, AgentTranscriptItem(role: role, text: text, messageId: messageId))
        }
    }

    /// See the matching comment on `DevinSessionManager.indexForChunk`: a
    /// chunk may only continue the message currently at the tail of the
    /// transcript, never reach back past later messages (e.g. a user prompt
    /// from a subsequent turn) just because it shares a role.
    private static func indexForChunk(in messages: [AgentTranscriptItem],
                                      role: AgentTranscriptItem.Role,
                                      messageId: String?) -> Int? {
        guard let lastIndex = messages.indices.last, messages[lastIndex].role == role else { return nil }
        return messages[lastIndex].messageId == messageId ? lastIndex : nil
    }

    private static func mergeToolCall(in state: inout AgentSessionSnapshot,
                                      id: String,
                                      title: String?,
                                      status: ToolCallStatus?,
                                      kind: ToolKind?,
                                      content: [ToolCallContent]?,
                                      locations: [ToolCallLocation]?,
                                      rawInput: ACPJSONValue?,
                                      rawOutput: ACPJSONValue?,
                                      now: Date) {
        let display = title ?? String(localized: "Tool call")
        if let idx = state.messages.firstIndex(where: { $0.toolCall?.toolCallId == id }) {
            if let title {
                state.messages[idx].text = title
            }
            var tool = state.messages[idx].toolCall ?? AgentToolCall(toolCallId: id, title: display)
            tool.title = title ?? tool.title
            tool.status = status ?? tool.status
            tool.kind = kind ?? tool.kind
            tool.content = content ?? tool.content
            tool.locations = locations ?? tool.locations
            tool.rawInput = rawInput ?? tool.rawInput
            tool.rawOutput = rawOutput ?? tool.rawOutput
            tool.updatedAt = now
            if (status ?? tool.status)?.isTerminal == true {
                tool.completedAt = tool.completedAt ?? now
                tool.abandonedReason = nil
            }
            state.messages[idx].toolCall = tool
        } else {
            appendBounded(&state.messages, AgentTranscriptItem(
                role: .toolCall,
                text: display,
                toolCall: AgentToolCall(
                    toolCallId: id,
                    title: display,
                    status: status,
                    kind: kind,
                    content: content,
                    locations: locations,
                    rawInput: rawInput,
                    rawOutput: rawOutput,
                    startedAt: now,
                    updatedAt: now,
                    completedAt: status?.isTerminal == true ? now : nil
                )
            ))
        }
    }

    private static func abandonUnfinishedToolCalls(in state: inout AgentSessionSnapshot,
                                                   reason: String,
                                                   now: Date) {
        for idx in state.messages.indices {
            guard var tool = state.messages[idx].toolCall, tool.isUnfinished else { continue }
            tool.updatedAt = now
            tool.completedAt = tool.completedAt ?? now
            tool.abandonedReason = reason
            state.messages[idx].toolCall = tool
        }
    }

    private static func appendBounded(_ messages: inout [AgentTranscriptItem], _ message: AgentTranscriptItem) {
        messages.append(message)
        if messages.count > maxTranscriptItems {
            messages.removeFirst(messages.count - maxTranscriptItems)
        }
    }
}
