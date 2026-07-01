import Combine
import Foundation

protocol DevinACPClient: AnyObject {
    var notifications: AnyPublisher<ACPNotification, Never> { get }
    func start() throws
    func setRequestHandler(method: String, handler: ACPServerRequestHandler?)
    func initialize() async throws -> InitializeResponse
    func createSession(cwd: String) async throws -> NewSessionResponse
    func loadSession(sessionID: String, cwd: String) async throws -> LoadSessionResponse
    func prompt(sessionID: String, content: [ContentBlock]) async throws -> PromptResponse
    func setMode(sessionID: String, modeId: String) async throws
    func closeSession(sessionID: String) async throws
    func cancelSession(sessionID: String)
    func close()
}

extension DevinACPClient {
    @discardableResult
    func prompt(sessionID: String, text: String) async throws -> PromptResponse {
        try await prompt(sessionID: sessionID, content: [.text(text)])
    }
}

extension ACPClient: DevinACPClient {}

@MainActor
final class DevinSessionManager: ObservableObject {
    enum Status: Equatable, Codable {
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

    struct Message: Identifiable, Equatable, Codable {
        enum Role: String, Codable {
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
        var toolCallId: String?
        var toolStatus: ToolCallStatus?
        var toolKind: ToolKind?
    }

    struct PendingPermission: Identifiable, Equatable {
        var id = UUID()
        var request: RequestPermissionRequest
    }

    struct PendingElicitation: Identifiable, Equatable {
        var id = UUID()
        var request: ElicitationRequest
    }

    struct UsageInfo: Equatable, Codable {
        var used: UInt64
        var size: UInt64
        var costAmount: Double?
        var costCurrency: String?
    }

    /// A single image attached to an outgoing prompt (composer attachments).
    struct ImageAttachment: Equatable {
        var base64Data: String
        var mimeType: String
    }

    @Published private(set) var status: Status = .idle {
        didSet { onStatusChange(status) }
    }
    @Published private(set) var messages: [Message] = []
    @Published private(set) var sessionID: String?
    @Published private(set) var pendingPermission: PendingPermission?
    @Published private(set) var pendingElicitation: PendingElicitation?
    @Published private(set) var sessionTitle: String?
    @Published private(set) var usageInfo: UsageInfo?
    @Published private(set) var models: [SessionModel] = []
    @Published private(set) var currentModel: SessionModel?
    @Published private(set) var modes: [SessionMode] = []
    @Published private(set) var currentMode: String?

    private struct PersistedConversation: Codable {
        var workspaceID: UUID
        var paneID: Int
        var sessionID: String?
        var projectPath: String?
        var sessionTitle: String?
        var usageInfo: UsageInfo?
        var models: [SessionModel]
        var currentModel: SessionModel?
        var modes: [SessionMode]
        var currentMode: String?
        var messages: [Message]
    }

    private let workspaceID: UUID
    private let paneID: PaneID
    private let onStatusChange: (Status) -> Void
    private let onSessionID: (String?) -> Void
    private let clientFactory: () -> DevinACPClient
    private let sessionsDirectory: URL
    private var client: DevinACPClient?
    private var notificationCancellable: AnyCancellable?
    private var runID = UUID()
    /// Whether a turn is currently in flight. Session/update notifications
    /// for a turn the agent process keeps emitting after the user cancels
    /// (or after we've already marked the turn idle/failed) must not be
    /// allowed to flip `status` back to busy — nothing would ever reset it
    /// again, leaving the composer permanently disabled. Message/tool
    /// content from those notifications is still recorded either way.
    private var isTurnActive = false
    private var projectPath: String?
    private var saveTask: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<ACPJSONValue, Never>?
    private var elicitationContinuation: CheckedContinuation<ACPJSONValue, Never>?

    init(workspaceID: UUID,
         paneID: PaneID,
         onStatusChange: @escaping (Status) -> Void,
         onSessionID: @escaping (String?) -> Void,
         clientFactory: @escaping () -> DevinACPClient = { ACPClient() },
         sessionsDirectory: URL? = nil) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.onStatusChange = onStatusChange
        self.onSessionID = onSessionID
        self.clientFactory = clientFactory
        self.sessionsDirectory = sessionsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".glint", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        loadPersistedConversation()
    }

    func sendFirstPrompt(text: String, projectPath: String, images: [ImageAttachment] = []) {
        sendPrompt(text: text, projectPath: projectPath, images: images)
    }

    func sendPrompt(text: String, projectPath: String? = nil, images: [ImageAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, !status.isBusy else { return }
        if let projectPath {
            self.projectPath = projectPath
        }
        guard let projectRoot = self.projectPath else {
            markFailed(String(localized: "Choose a valid project folder before sending."))
            return
        }

        var content: [ContentBlock] = []
        if !trimmed.isEmpty {
            content.append(.text(trimmed))
        }
        content.append(contentsOf: images.map { .image(ImageContent(data: $0.base64Data, mimeType: $0.mimeType)) })

        let displayText = trimmed.isEmpty
            ? (images.count == 1 ? String(localized: "Sent an image") : String(format: String(localized: "Sent %d images"), images.count))
            : trimmed
        messages.append(Message(role: .user, text: displayText))
        scheduleSave()

        let runID = UUID()
        self.runID = runID
        isTurnActive = true

        if sessionID == nil || client == nil {
            startSessionAndPrompt(content: content, projectPath: projectRoot, runID: runID)
        } else {
            promptExistingSession(content: content, runID: runID)
        }
    }

    func cancelTurn() {
        guard let sessionID else {
            stop()
            return
        }
        status = .cancelling
        client?.cancelSession(sessionID: sessionID)
        runID = UUID()
        isTurnActive = false
        status = .idle
    }

    /// Common teardown shared by `closeSession()` and `closeSessionForQuit()`:
    /// deny any pending permission/elicitation, fence off the current run,
    /// and detach the client so nothing else can use it. Returns the client
    /// and session id the caller needs to actually close the ACP session.
    private func prepareForClose() -> (client: DevinACPClient?, sessionID: String?) {
        let currentSessionID = sessionID
        denyPendingInteractions()
        runID = UUID()
        isTurnActive = false
        status = .cancelling
        let client = self.client
        self.client = nil
        notificationCancellable = nil
        return (client, currentSessionID)
    }

    func closeSession() {
        let (client, sessionID) = prepareForClose()
        Task.detached {
            if let sessionID {
                try? await client?.closeSession(sessionID: sessionID)
            }
            client?.close()
        }
        status = .idle
    }

    /// Same teardown as `closeSession()`, but awaits the ACP `session/close`
    /// call (which already self-bounds to ~2s in `ACPClient`) instead of
    /// firing-and-forgetting, then flushes the conversation synchronously.
    /// Used only at app quit, where we need to know shutdown actually
    /// finished before letting the process disappear.
    func closeSessionForQuit() async {
        let (client, sessionID) = prepareForClose()
        if let sessionID {
            try? await client?.closeSession(sessionID: sessionID)
        }
        client?.close()
        status = .idle
        flushSaveSynchronously()
    }

    /// Closes the live session and guarantees the on-disk conversation
    /// reflects the final in-memory state — used when archiving a
    /// workspace, where a later "Resume Session" must be able to reload it.
    func closeSessionPreservingConversation() {
        closeSession()
        flushSaveSynchronously()
    }

    /// Closes the live session and permanently deletes the persisted
    /// conversation, cancelling any pending debounced save first so it
    /// can't resurrect the file after deletion.
    func closeSessionAndDeleteConversation() {
        closeSession()
        saveTask?.cancel()
        saveTask = nil
        try? FileManager.default.removeItem(at: conversationURL)
    }

    func stop() {
        denyPendingInteractions()
        runID = UUID()
        isTurnActive = false
        client?.close()
        client = nil
        notificationCancellable = nil
        status = .idle
    }

    /// The ACP v1 response to a permission request must select one of the
    /// `optionId`s the agent offered (`{"outcome":{"outcome":"selected","optionId":...}}`),
    /// not a bare "approved"/"denied" string — Devin's ACP server has no
    /// way to act on the latter, which looks to the user like the tool
    /// call permanently "stuck" since the agent is left waiting for a
    /// response it can actually parse.
    func respondToPermission(approved: Bool) {
        let options = pendingPermission?.request.options ?? []
        completePermission(with: Self.outcomeJSON(for: Self.selectOption(from: options, approved: approved)))
    }

    /// Picks the offered option matching the desired allow/reject
    /// direction, preferring the "once" variant over "always" — checked in
    /// that priority order regardless of where the agent placed them in
    /// `options`, not by set membership (which would let whichever kind
    /// happens to come first in the array win). Returns nil (→
    /// `cancelled`) if no option of the requested direction exists at
    /// all; it must never fall back to an option of the *opposite*
    /// direction, since that would silently turn a user's Deny into an
    /// Allow (or vice versa).
    nonisolated private static func selectOption(from options: [PermissionOption], approved: Bool) -> PermissionOption? {
        let preferredKinds: [PermissionOptionKind] = approved
            ? [.allowOnce, .allowAlways]
            : [.rejectOnce, .rejectAlways]
        for kind in preferredKinds {
            if let match = options.first(where: { $0.kind == kind }) {
                return match
            }
        }
        return nil
    }

    nonisolated private static func outcomeJSON(for option: PermissionOption?) -> ACPJSONValue {
        guard let option else {
            return (try? RequestPermissionResponse(outcome: .cancelled).jsonValue())
                ?? .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        return (try? RequestPermissionResponse(outcome: .selected(optionId: option.optionId)).jsonValue())
            ?? .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option.optionId)])])
    }

    func submitElicitation(values: ACPJSONValue?) {
        let response = ElicitationResponse(values: values, cancelled: values == nil)
        completeElicitation(with: (try? response.jsonValue()) ?? .object(["cancelled": .bool(values == nil)]))
    }

    static func conversationURL(workspaceID: UUID, sessionsDirectory: URL? = nil) -> URL {
        let base = sessionsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".glint", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        return base.appendingPathComponent("\(workspaceID.uuidString).json")
    }

    static func deleteConversation(workspaceID: UUID, sessionsDirectory: URL? = nil) {
        try? FileManager.default.removeItem(at: conversationURL(workspaceID: workspaceID, sessionsDirectory: sessionsDirectory))
    }

    private func startSessionAndPrompt(content: [ContentBlock], projectPath: String, runID: UUID) {
        status = .starting
        let client = clientFactory()
        installHandlers(on: client, projectRoot: projectPath)
        observeNotifications(from: client)
        self.client = client

        Task.detached { [weak self, client, runID] in
            do {
                try client.start()
                let initialize = try await client.initialize()
                let session = try await client.createSession(cwd: projectPath)
                guard let sessionID = session.resolvedSessionId, !sessionID.isEmpty else {
                    throw ACPClientError.invalidResponse(String(localized: "Devin ACP did not return a session id."))
                }
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.applyInitialize(initialize)
                await self?.applySession(sessionID: sessionID, response: session)
                await self?.markThinking()
                _ = try await client.prompt(sessionID: sessionID, content: content)
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

    private func promptExistingSession(content: [ContentBlock], runID: UUID) {
        guard let client, let sessionID else { return }
        status = .thinking
        Task.detached { [weak self, client, sessionID, runID] in
            do {
                _ = try await client.prompt(sessionID: sessionID, content: content)
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

    /// Switches the session's operating mode via `session/set_mode`
    /// (confirmed ACP v1 method: `{sessionId, modeId}`). The mode can be
    /// changed at any point, whether idle or generating a response.
    func selectMode(_ modeId: String) {
        guard let client, let sessionID, modeId != currentMode else { return }
        let previousMode = currentMode
        currentMode = modeId
        Task.detached { [weak self, client, sessionID, modeId] in
            do {
                try await client.setMode(sessionID: sessionID, modeId: modeId)
            } catch {
                await self?.revertMode(to: previousMode, failedModeId: modeId, error: error)
            }
        }
    }

    private func revertMode(to previousMode: String?, failedModeId: String, error: Error) {
        guard currentMode == failedModeId else { return }
        currentMode = previousMode
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        messages.append(Message(role: .system, text: String(format: String(localized: "Couldn't switch mode: %@"), message)))
        scheduleSave()
    }

    private func installHandlers(on client: DevinACPClient, projectRoot: String) {
        client.setRequestHandler(method: "fs/read_text_file") { [weak self] request in
            await self?.handleReadTextFile(request, projectRoot: projectRoot)
                ?? .failure(ACPErrorPayload(message: "Session is no longer available."))
        }
        client.setRequestHandler(method: "fs/write_text_file") { [weak self] request in
            await self?.handleWriteTextFile(request, projectRoot: projectRoot)
                ?? .failure(ACPErrorPayload(message: "Session is no longer available."))
        }
        for method in ["terminal/create", "terminal/output", "terminal/kill", "terminal/release", "terminal/wait_for_exit"] {
            client.setRequestHandler(method: method) { _ in
                .failure(ACPErrorPayload(code: -32601, message: "Terminal support is not implemented by Glint for Devin ACP yet."))
            }
        }
        client.setRequestHandler(method: "session/request_permission") { [weak self] request in
            await self?.handlePermissionRequest(request)
                ?? .success(Self.outcomeJSON(for: nil))
        }
        client.setRequestHandler(method: "session/elicitation") { [weak self] request in
            await self?.handleElicitationRequest(request)
                ?? .success(.object(["cancelled": .bool(true)]))
        }
        client.setRequestHandler(method: "session/request_elicitation") { [weak self] request in
            await self?.handleElicitationRequest(request)
                ?? .success(.object(["cancelled": .bool(true)]))
        }
    }

    /// Notifications are delivered via `.receive(on: DispatchQueue.main)`, so
    /// by the time this sink runs we're already on the main thread/queue.
    /// Handling it synchronously here (instead of spawning a further
    /// `Task { @MainActor in ... }`) is required for correctness, not just
    /// style: the `session/prompt` response for the same turn resolves its
    /// own MainActor hop via a separate async chain, and an extra
    /// unstructured-Task hop on the notification side isn't guaranteed to
    /// preserve relative ordering against it. Losing that race lets a late
    /// `toolCallUpdate`/thinking notification apply *after* `markIdle()`,
    /// leaving `status` stuck busy forever (composer permanently disabled).
    private func observeNotifications(from client: DevinACPClient) {
        notificationCancellable = client.notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleNotification(notification)
                }
            }
    }

    private func handleNotification(_ notification: ACPNotification) {
        guard notification.method == "session/update",
              let params = notification.params,
              let session = try? params.decoded(SessionNotification.self) else {
            return
        }
        applySessionUpdate(session.update)
    }

    private func applySessionUpdate(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let chunk):
            appendChunk(role: .user, messageId: chunk.messageId, content: chunk.content)
        case .agentMessageChunk(let chunk):
            appendChunk(role: .assistant, messageId: chunk.messageId, content: chunk.content)
            if isTurnActive { status = .thinking }
        case .agentThoughtChunk(let chunk):
            appendChunk(role: .thought, messageId: chunk.messageId, content: chunk.content)
            if isTurnActive { status = .thinking }
        case .toolCall(let tool):
            upsertToolCall(id: tool.toolCallId, title: tool.title, status: tool.status, kind: tool.kind)
            if isTurnActive { status = .tool }
        case .toolCallUpdate(let tool):
            upsertToolCall(id: tool.toolCallId, title: tool.title, status: tool.status, kind: tool.kind)
            if isTurnActive { status = .tool }
        case .plan(let plan):
            let text = plan.entries.map(\.content).joined(separator: "\n")
            if !text.isEmpty {
                messages.append(Message(role: .system, text: text))
            }
        case .usageUpdate(let usage):
            usageInfo = UsageInfo(
                used: usage.used,
                size: usage.size,
                costAmount: usage.cost?.amount,
                costCurrency: usage.cost?.currency
            )
        case .sessionInfoUpdate(let info):
            sessionTitle = info.title
        case .currentModeUpdate(let mode):
            currentMode = mode.modeId
        case .availableCommandsUpdate, .configOptionUpdate:
            break
        case .unknown:
            break
        }
        scheduleSave()
    }

    private func appendChunk(role: Message.Role, messageId: String?, content: ContentBlock) {
        guard let text = content.plainText, !text.isEmpty else { return }
        if let idx = indexForChunk(role: role, messageId: messageId) {
            messages[idx].text += text
        } else {
            messages.append(Message(role: role, text: text, messageId: messageId))
        }
    }

    private func indexForChunk(role: Message.Role, messageId: String?) -> Int? {
        if let messageId {
            return messages.lastIndex { $0.role == role && $0.messageId == messageId }
        }
        return messages.indices.reversed().first { idx in
            messages[idx].role == role && messages[idx].messageId == nil
        }
    }

    private func upsertToolCall(id: String, title: String?, status: ToolCallStatus?, kind: ToolKind?) {
        let display = title ?? String(localized: "Tool call")
        if let idx = messages.firstIndex(where: { $0.toolCallId == id }) {
            messages[idx].text = display
            messages[idx].toolStatus = status ?? messages[idx].toolStatus
            messages[idx].toolKind = kind ?? messages[idx].toolKind
        } else {
            messages.append(Message(role: .toolCall, text: display, toolCallId: id, toolStatus: status, toolKind: kind))
        }
    }

    private func handleReadTextFile(_ request: ACPServerRequest, projectRoot: String) async -> Result<ACPJSONValue, ACPErrorPayload> {
        do {
            let params = try request.decodeParams(ReadTextFileRequest.self)
            let url = try validatedProjectFileURL(path: params.path, projectRoot: projectRoot)
            let content = try String(contentsOf: url, encoding: .utf8)
            let sliced = slice(content: content, line: params.line, limit: params.limit)
            return .success(try ReadTextFileResponse(content: sliced).jsonValue())
        } catch {
            return .failure(ACPErrorPayload(message: error.localizedDescription))
        }
    }

    private func handleWriteTextFile(_ request: ACPServerRequest, projectRoot: String) async -> Result<ACPJSONValue, ACPErrorPayload> {
        do {
            let params = try request.decodeParams(WriteTextFileRequest.self)
            let url = try validatedProjectFileURL(path: params.path, projectRoot: projectRoot, allowMissingLeaf: true)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try params.content.write(to: url, atomically: true, encoding: .utf8)
            return .success(.null)
        } catch {
            return .failure(ACPErrorPayload(message: error.localizedDescription))
        }
    }

    private func handlePermissionRequest(_ request: ACPServerRequest) async -> Result<ACPJSONValue, ACPErrorPayload> {
        // Falls back to a couple of generic allow/reject options (rather
        // than an empty list) so a malformed/unexpected request can still
        // be answered with a real optionId instead of forcing `cancelled`.
        let fallbackOptions = [
            PermissionOption(optionId: "allow", name: "Allow", kind: .allowOnce),
            PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce)
        ]
        let params = (try? request.decodeParams(RequestPermissionRequest.self))
            ?? RequestPermissionRequest(sessionId: sessionID ?? "", options: fallbackOptions)

        // 1. Check user permission review mode
        let mode = WorkspaceStore.current?.permissionReviewMode ?? .manual

        if mode == .autoReview {
            let kind = params.toolCall?.kind
            let policy = PermissionPolicy.defaultPolicy(for: kind)
            let title = params.toolCall?.title ?? "Permission request"

            switch policy {
            case .autoApprove:
                messages.append(Message(role: .system, text: String(format: String(localized: "Auto-approved permission: %@"), title)))
                scheduleSave()
                return .success(Self.outcomeJSON(for: Self.selectOption(from: params.options, approved: true)))

            case .alwaysEscalate:
                break // Fallthrough to UI card

            case .llmReview:
                // Spawn the LLM background review
                let projectRoot = self.projectPath ?? ""
                let decision = await PermissionReviewer.shared.review(
                    title: title,
                    kind: kind,
                    rawInput: params.toolCall?.rawInput.map { String(describing: $0) } ?? "",
                    conversationContext: self.messages,
                    projectRoot: projectRoot
                )

                switch decision {
                case .approve(let reason):
                    let logText = reason.isEmpty 
                        ? String(format: String(localized: "Auto-approved permission (LLM): %@"), title)
                        : String(format: String(localized: "Auto-approved: %@ (%@)"), title, reason)
                    messages.append(Message(role: .system, text: logText))
                    scheduleSave()
                    return .success(Self.outcomeJSON(for: Self.selectOption(from: params.options, approved: true)))

                case .deny(let reason):
                    let logText = reason.isEmpty
                        ? String(format: String(localized: "Auto-denied permission (LLM): %@"), title)
                        : String(format: String(localized: "Auto-denied: %@ (%@)"), title, reason)
                    messages.append(Message(role: .system, text: logText))
                    scheduleSave()
                    return .success(Self.outcomeJSON(for: Self.selectOption(from: params.options, approved: false)))

                case .escalate(let reason):
                    // Attach the reviewer's reasoning via a dedicated field so
                    // the permission card can show it alongside the original
                    // rawInput (the actual tool arguments) instead of losing
                    // them.
                    var enrichedParams = params
                    if !reason.isEmpty {
                        enrichedParams.reviewReason = reason
                    }
                    return .success(await withCheckedContinuation { continuation in
                        permissionContinuation = continuation
                        pendingPermission = PendingPermission(request: enrichedParams)
                        status = .needsPermission
                    })
                }
            }
        }

        // Default manual flow
        return .success(await withCheckedContinuation { continuation in
            permissionContinuation = continuation
            pendingPermission = PendingPermission(request: params)
            status = .needsPermission
        })
    }

    private func handleElicitationRequest(_ request: ACPServerRequest) async -> Result<ACPJSONValue, ACPErrorPayload> {
        let params = (try? request.decodeParams(ElicitationRequest.self))
            ?? ElicitationRequest(sessionId: sessionID ?? "", message: "Input requested")
        return .success(await withCheckedContinuation { continuation in
            elicitationContinuation = continuation
            pendingElicitation = PendingElicitation(request: params)
            status = .needsPermission
        })
    }

    private func completePermission(with value: ACPJSONValue) {
        pendingPermission = nil
        permissionContinuation?.resume(returning: value)
        permissionContinuation = nil
        status = .thinking
    }

    private func completeElicitation(with value: ACPJSONValue) {
        pendingElicitation = nil
        elicitationContinuation?.resume(returning: value)
        elicitationContinuation = nil
        status = .thinking
    }

    private func denyPendingInteractions() {
        // Per the ACP v1 spec: "If the current prompt turn gets cancelled,
        // the Client MUST respond with the cancelled outcome" — not a
        // rejected/denied option selection, since the client is abandoning
        // the turn rather than actually deciding allow/reject.
        if pendingPermission != nil {
            completePermission(with: Self.outcomeJSON(for: nil))
        }
        if pendingElicitation != nil {
            completeElicitation(with: .object(["cancelled": .bool(true)]))
        }
    }

    private func validatedProjectFileURL(path: String, projectRoot: String, allowMissingLeaf: Bool = false) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        let candidateExists = fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        let resolved = (allowMissingLeaf && !candidateExists ? candidate.deletingLastPathComponent() : candidate).resolvingSymlinksInPath()
        let resolvedPath = resolved.path
        guard resolvedPath == root.path || resolvedPath.hasPrefix(root.path + "/") else {
            throw ACPClientError.invalidResponse(String(localized: "File access outside the project folder is not allowed."))
        }
        guard allowMissingLeaf || (candidateExists && !isDirectory.boolValue) else {
            throw ACPClientError.invalidResponse(String(localized: "Requested file does not exist or is not a text file."))
        }
        return candidate
    }

    private func slice(content: String, line: Int?, limit: Int?) -> String {
        guard line != nil || limit != nil else { return content }
        let lines = content.components(separatedBy: .newlines)
        let start = max((line ?? 1) - 1, 0)
        guard start < lines.count else { return "" }
        let end = min(start + (limit ?? (lines.count - start)), lines.count)
        return lines[start..<end].joined(separator: "\n")
    }

    private func isCurrentRun(_ id: UUID) -> Bool {
        runID == id
    }

    private func applyInitialize(_ response: InitializeResponse) {
        // Future UI can expose auth methods and agent metadata from here.
        _ = response
    }

    private func applySession(sessionID: String, response: NewSessionResponse) {
        self.sessionID = sessionID
        onSessionID(sessionID)
        if let models = response.models {
            self.models = models
            currentModel = models.first
        }
        if let modes = response.modes {
            self.modes = modes.availableModes ?? []
            currentMode = modes.currentModeId
        }
        scheduleSave()
    }

    private func markThinking() {
        status = .thinking
    }

    private func markIdle() {
        isTurnActive = false
        status = .idle
        scheduleSave()
    }

    private func markFailed(_ message: String) {
        isTurnActive = false
        messages.append(Message(role: .system, text: message))
        status = .failed(message)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = makePersistedConversation()
        let url = conversationURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            // `Task.sleep` throws on cancellation, but `try?` above swallows
            // that — without this check a cancelled save would still fall
            // through and write its (now stale) snapshot, potentially
            // racing with (and undoing) a synchronous flush or a delete
            // that ran right after the cancel.
            guard !Task.isCancelled else { return }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[glint] failed to save Devin conversation: \(error)")
            }
        }
    }

    private func loadPersistedConversation() {
        guard let data = try? Data(contentsOf: conversationURL),
              let decoded = try? JSONDecoder().decode(PersistedConversation.self, from: data) else {
            return
        }
        sessionID = decoded.sessionID
        projectPath = decoded.projectPath
        sessionTitle = decoded.sessionTitle
        usageInfo = decoded.usageInfo
        models = decoded.models
        currentModel = decoded.currentModel
        modes = decoded.modes
        currentMode = decoded.currentMode
        messages = decoded.messages
    }

    private var conversationURL: URL {
        Self.conversationURL(workspaceID: workspaceID, sessionsDirectory: sessionsDirectory)
    }

    private func makePersistedConversation() -> PersistedConversation {
        PersistedConversation(
            workspaceID: workspaceID,
            paneID: Int(paneID.value),
            sessionID: sessionID,
            projectPath: projectPath,
            sessionTitle: sessionTitle,
            usageInfo: usageInfo,
            models: models,
            currentModel: currentModel,
            modes: modes,
            currentMode: currentMode,
            messages: messages
        )
    }

    /// Cancels any pending debounced save and writes the current snapshot
    /// to disk immediately. `scheduleSave()`'s ~250ms debounce could
    /// otherwise lose the last few chunks (or, worse, resurrect a
    /// just-deleted file) if the manager is torn down right after streaming
    /// ends — archiving, deleting, or quitting all need the on-disk state
    /// to be trustworthy the moment they run, not ~250ms later.
    private func flushSaveSynchronously() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = makePersistedConversation()
        do {
            try FileManager.default.createDirectory(
                at: conversationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: conversationURL, options: .atomic)
        } catch {
            NSLog("[glint] failed to flush Devin conversation: \(error)")
        }
    }
}

private extension Encodable {
    func jsonValue() throws -> ACPJSONValue {
        try JSONDecoder.acp.decode(ACPJSONValue.self, from: JSONEncoder.acp.encode(self))
    }
}
