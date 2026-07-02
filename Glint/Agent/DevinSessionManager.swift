import Combine
import Foundation

protocol AgentRuntimeAdapter: AnyObject {
    var notifications: AnyPublisher<ACPNotification, Never> { get }
    var diagnostics: AnyPublisher<ACPDiagnosticEvent, Never> { get }
    func start() throws
    func setRequestHandler(method: String, handler: ACPServerRequestHandler?)
    func initialize() async throws -> InitializeResponse
    func createSession(cwd: String) async throws -> NewSessionResponse
    func loadSession(sessionID: String, cwd: String) async throws -> LoadSessionResponse
    func prompt(sessionID: String, content: [ContentBlock]) async throws -> PromptResponse
    func setMode(sessionID: String, modeId: String) async throws
    func setConfigOption(sessionID: String, configId: String, value: String) async throws -> [SessionConfigOption]
    func closeSession(sessionID: String) async throws
    func cancelSession(sessionID: String)
    func close()
}

typealias DevinACPClient = AgentRuntimeAdapter

extension AgentRuntimeAdapter {
    @discardableResult
    func prompt(sessionID: String, text: String) async throws -> PromptResponse {
        try await prompt(sessionID: sessionID, content: [.text(text)])
    }
}

extension ACPClient: AgentRuntimeAdapter {}

@MainActor
final class AgentSessionController: ObservableObject {
    typealias Status = AgentSessionStatus

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
        var toolContent: [ToolCallContent]?
        var toolLocations: [ToolCallLocation]?
        var toolRawInput: ACPJSONValue?
        var toolRawOutput: ACPJSONValue?
        var toolStartedAt: Date?
        var toolUpdatedAt: Date?
        var toolCompletedAt: Date?
        var toolAbandonedReason: String?

        var isUnfinishedToolCall: Bool {
            guard role == .toolCall else { return false }
            if toolAbandonedReason != nil { return false }
            return !(toolStatus?.isTerminal ?? false)
        }
    }

    typealias PendingPermission = AgentPendingPermission
    typealias PendingElicitation = AgentPendingElicitation

    typealias UsageInfo = AgentUsage

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
    @Published private(set) var configOptions: [SessionConfigOption] = []
    @Published private(set) var diagnostics: [ACPDiagnosticEvent] = []

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
        var configOptions: [SessionConfigOption]?
        var messages: [Message]
    }

    private let workspaceID: UUID
    private let paneID: PaneID
    private let onStatusChange: (Status) -> Void
    private let onSessionID: (String?) -> Void
    private let clientFactory: () -> AgentRuntimeAdapter
    private let sessionsDirectory: URL
    private var client: AgentRuntimeAdapter?
    private let projectFileService = AgentProjectFileService()
    private var notificationCancellable: AnyCancellable?
    private var diagnosticCancellable: AnyCancellable?
    private var runID = UUID()
    /// Whether a turn is currently in flight. Session/update notifications
    /// for a turn the agent process keeps emitting after the user cancels
    /// (or after we've already marked the turn idle/failed) must not be
    /// allowed to flip `status` back to busy — nothing would ever reset it
    /// again, leaving the composer permanently disabled. Message/tool
    /// content from those notifications is still recorded either way.
    private var isTurnActive = false
    private var projectPath: String?
    /// Set while `connectIfNeeded()`'s background connect is in flight, so
    /// a second call (e.g. from both `.onAppear` and a `.onChange` firing
    /// in quick succession) doesn't spin up a second ACP process.
    private var isConnecting = false
    private var saveTask: Task<Void, Never>?
    private var permissionContinuation: CheckedContinuation<ACPJSONValue, Never>?
    private var elicitationContinuation: CheckedContinuation<ACPJSONValue, Never>?
    private static let maxDiagnostics = 200

    init(workspaceID: UUID,
         paneID: PaneID,
         onStatusChange: @escaping (Status) -> Void,
         onSessionID: @escaping (String?) -> Void,
         clientFactory: @escaping () -> AgentRuntimeAdapter = { DevinACPAdapter() },
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
        // Defense in depth: every documented exit from a turn (finishActiveTurn,
        // markFailed, stop(), prepareForClose()) already sweeps unfinished tool
        // calls to "stale" on its own way out, so this should normally be a
        // no-op. But starting a brand-new turn is itself unambiguous proof the
        // previous one is over, so re-sweep here too — it costs nothing when
        // there's nothing to abandon, and it guarantees no tool call row can
        // ride into a new turn still reading "Working" if some not-yet-covered
        // path ever let one slip through the earlier sweeps.
        abandonUnfinishedToolCalls(reason: String(localized: "A new message was sent before this tool reported completion."))

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
        denyPendingInteractions()
        finishActiveTurn(reason: String(localized: "Cancelled by user."))
    }

    /// Common teardown shared by `closeSession()` and `closeSessionForQuit()`:
    /// deny any pending permission/elicitation, fence off the current run,
    /// and detach the client so nothing else can use it. Returns the client
    /// and session id the caller needs to actually close the ACP session.
    private func prepareForClose() -> (client: AgentRuntimeAdapter?, sessionID: String?) {
        let currentSessionID = sessionID
        denyPendingInteractions()
        runID = UUID()
        isTurnActive = false
        // See `stop()`'s matching comment: bumping `runID` fences off any
        // in-flight `connectIfNeeded()` task before it reaches
        // `finishConnecting()`, so reset the flag here too.
        isConnecting = false
        status = .cancelling
        let client = self.client
        self.client = nil
        notificationCancellable = nil
        diagnosticCancellable = nil
        abandonUnfinishedToolCalls(reason: String(localized: "Session closed before the tool finished."))
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
        // Bumping `runID` above fences off any in-flight `connectIfNeeded()`
        // task: its `isCurrentRun(runID)` guard will now fail, so it returns
        // early *without* reaching `finishConnecting()`. Reset the flag here
        // instead of relying on that task to do it, or `isConnecting` stays
        // stuck `true` forever and `connectIfNeeded()` never runs again for
        // this pane (see `finishConnecting()`).
        isConnecting = false
        client?.close()
        client = nil
        notificationCancellable = nil
        diagnosticCancellable = nil
        finishActiveTurn(reason: String(localized: "Session stopped before the tool finished."))
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
        AgentPermissionDecider.selectOption(from: options, approved: approved)
    }

    nonisolated private static func outcomeJSON(for option: PermissionOption?) -> ACPJSONValue {
        AgentPermissionDecider.outcomeJSON(for: option)
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
        observeDiagnostics(from: client)
        self.client = client
        let existingSessionID = sessionID

        Task.detached { [weak self, client, runID, projectPath, existingSessionID] in
            do {
                let resolved = try await Self.establishSession(
                    client: client,
                    projectPath: projectPath,
                    existingSessionID: existingSessionID
                )
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.applyInitialize(resolved.initialize)
                await self?.applyResolvedSession(resolved)
                await self?.markThinking()
                _ = try await client.prompt(sessionID: resolved.sessionID, content: content)
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.finishActiveTurn(reason: String(localized: "Turn ended before the tool reported completion."))
            } catch {
                guard await self?.isCurrentRun(runID) == true else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await self?.markFailed(message)
            }
        }
    }

    /// Establishes the ACP connection for this pane — starting the process
    /// and resuming or creating a session — without sending a prompt, so
    /// the composer's model/mode/reasoning pickers have real data as soon
    /// as the pane is shown rather than only after the user's first
    /// message. Safe to call repeatedly: no-ops while already
    /// connected/connecting or mid-turn.
    func connectIfNeeded(projectPath: String) {
        guard client == nil, !isConnecting, !status.isBusy else { return }
        self.projectPath = projectPath
        isConnecting = true
        status = .starting
        let client = clientFactory()
        installHandlers(on: client, projectRoot: projectPath)
        observeNotifications(from: client)
        observeDiagnostics(from: client)
        self.client = client
        let runID = UUID()
        self.runID = runID
        let existingSessionID = sessionID

        Task.detached { [weak self, client, runID, projectPath, existingSessionID] in
            do {
                let resolved = try await Self.establishSession(
                    client: client,
                    projectPath: projectPath,
                    existingSessionID: existingSessionID
                )
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.applyInitialize(resolved.initialize)
                await self?.applyResolvedSession(resolved)
                await self?.finishConnecting()
            } catch {
                guard await self?.isCurrentRun(runID) == true else { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                await self?.markFailed(message)
                await self?.finishConnecting()
            }
        }
    }

    private func finishConnecting() {
        isConnecting = false
        if status == .starting { status = .idle }
    }

    private struct ResolvedSession {
        var sessionID: String
        var initialize: InitializeResponse
        var created: NewSessionResponse?
        var loaded: LoadSessionResponse?
    }

    /// Starts `client` and resolves an active session: resumes
    /// `existingSessionID` via `session/load` when we already have one
    /// (e.g. restored from a persisted conversation across app restarts),
    /// falling back to `session/new` if the Agent no longer recognizes it
    /// (expired, or the process was restarted). Always creates fresh when
    /// there's no existing session id. Runs off the main actor; callers
    /// hop back via `self?.apply...` for state mutation. Must stay
    /// `nonisolated`: `AgentSessionController` is `@MainActor`, and static
    /// members of a `@MainActor` type are themselves MainActor-isolated by
    /// default (see the `selectOption`/`outcomeJSON` statics above) —
    /// without this, `await Self.establishSession(...)` would hop back onto
    /// the main actor to run `client.start()`/`initialize()`/`loadSession`/
    /// `createSession` synchronously, defeating the whole point of calling
    /// it from `Task.detached`.
    nonisolated private static func establishSession(
        client: AgentRuntimeAdapter,
        projectPath: String,
        existingSessionID: String?
    ) async throws -> ResolvedSession {
        try client.start()
        let initialize = try await client.initialize()
        if let existingSessionID, !existingSessionID.isEmpty,
           let loaded = try? await client.loadSession(sessionID: existingSessionID, cwd: projectPath) {
            return ResolvedSession(sessionID: existingSessionID, initialize: initialize, created: nil, loaded: loaded)
        }
        let session = try await client.createSession(cwd: projectPath)
        guard let newSessionID = session.resolvedSessionId, !newSessionID.isEmpty else {
            throw ACPClientError.invalidResponse(String(localized: "Devin ACP did not return a session id."))
        }
        return ResolvedSession(sessionID: newSessionID, initialize: initialize, created: session, loaded: nil)
    }

    private func applyResolvedSession(_ resolved: ResolvedSession) {
        if let loaded = resolved.loaded {
            applyLoadedSession(sessionID: resolved.sessionID, response: loaded)
        } else if let created = resolved.created {
            applySession(sessionID: resolved.sessionID, response: created)
        }
    }

    private func promptExistingSession(content: [ContentBlock], runID: UUID) {
        guard let client, let sessionID else { return }
        status = .thinking
        Task.detached { [weak self, client, sessionID, runID] in
            do {
                _ = try await client.prompt(sessionID: sessionID, content: content)
                guard await self?.isCurrentRun(runID) == true else { return }
                await self?.finishActiveTurn(reason: String(localized: "Turn ended before the tool reported completion."))
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

    /// Changes a session config option (model, mode, reasoning level, ...)
    /// via `session/set_config_option` — the current stable ACP mechanism
    /// (see `SessionConfigOption`) that Devin uses to expose model
    /// switching. Can be called at any point, whether idle or generating a
    /// response. The Agent always responds with the complete, updated
    /// configuration state (it may adjust dependent options, e.g. available
    /// reasoning levels changing with the model), so on success we adopt
    /// that response wholesale rather than patching a single field.
    func selectConfigOption(_ configId: String, value: String) {
        guard let client, let sessionID else { return }
        guard let option = configOptions.first(where: { $0.id == configId }),
              option.resolvedCurrentValue?.stringValue != value else { return }
        let previousOptions = configOptions
        if let idx = configOptions.firstIndex(where: { $0.id == configId }) {
            configOptions[idx].currentValue = .string(value)
        }
        Task.detached { [weak self, client, sessionID, configId, value] in
            do {
                let updated = try await client.setConfigOption(sessionID: sessionID, configId: configId, value: value)
                await self?.applyConfigOptions(updated)
            } catch {
                await self?.revertConfigOption(to: previousOptions, failedConfigId: configId, attemptedValue: value, error: error)
            }
        }
    }

    private func applyConfigOptions(_ options: [SessionConfigOption]) {
        configOptions = options
        scheduleSave()
    }

    private func revertConfigOption(to previousOptions: [SessionConfigOption],
                                    failedConfigId: String,
                                    attemptedValue: String,
                                    error: Error) {
        // Revert only the option that actually failed, not the whole
        // array: `configOptions` holds independent selectors (model, mode,
        // reasoning level, ...), so if the user changed a *different*
        // option while this one's request was still in flight,
        // wholesale-restoring `previousOptions` would silently discard
        // that other, possibly-already-applied change too.
        guard let idx = configOptions.firstIndex(where: { $0.id == failedConfigId }),
              configOptions[idx].resolvedCurrentValue?.stringValue == attemptedValue,
              let previous = previousOptions.first(where: { $0.id == failedConfigId }) else { return }
        configOptions[idx] = previous
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        messages.append(Message(role: .system, text: String(format: String(localized: "Couldn't change %@: %@"), failedConfigId, message)))
        scheduleSave()
    }

    private func installHandlers(on client: AgentRuntimeAdapter, projectRoot: String) {
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
    private func observeNotifications(from client: AgentRuntimeAdapter) {
        notificationCancellable = client.notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.handleNotification(notification)
                }
            }
    }

    private func observeDiagnostics(from client: AgentRuntimeAdapter) {
        diagnosticCancellable = client.diagnostics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.appendDiagnostic(event)
                }
            }
    }

    private func handleNotification(_ notification: ACPNotification) {
        guard notification.method == "session/update",
              let params = notification.params,
              let session = try? params.decoded(SessionNotification.self) else {
            appendDiagnostic(.init(kind: .notification, title: notification.method, payload: notification.params))
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
            mergeToolCall(
                id: tool.toolCallId,
                title: tool.title,
                status: tool.status,
                kind: tool.kind,
                content: tool.content,
                locations: tool.locations,
                rawInput: tool.rawInput,
                rawOutput: tool.rawOutput
            )
            if isTurnActive { status = .tool }
        case .toolCallUpdate(let tool):
            mergeToolCall(
                id: tool.toolCallId,
                title: tool.title,
                status: tool.status,
                kind: tool.kind,
                content: tool.content,
                locations: tool.locations,
                rawInput: tool.rawInput,
                rawOutput: tool.rawOutput
            )
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
        case .configOptionUpdate(let update):
            configOptions = update.configOptions
        case .availableCommandsUpdate:
            break
        case .unknown:
            appendDiagnostic(.init(kind: .notification, title: "Unknown session update", detail: String(describing: update)))
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

    /// Chunks only ever continue the message currently at the *tail* of the
    /// transcript, never one further back. Devin commonly streams chunks
    /// with no `messageId`, and scanning the whole history for "the last
    /// message with a matching role" would happily glue a brand-new turn's
    /// reply onto an old bubble from several turns ago as long as nothing
    /// else of that same role happened to sit between them — even though a
    /// new user prompt (and possibly tool calls) had already been appended
    /// after it. That produced merged bubbles rendered above later user
    /// messages instead of a fresh bubble below them.
    private func indexForChunk(role: Message.Role, messageId: String?) -> Int? {
        guard let lastIndex = messages.indices.last, messages[lastIndex].role == role else { return nil }
        return messages[lastIndex].messageId == messageId ? lastIndex : nil
    }

    /// Per the ACP spec, `toolCallId` is unique within a session, but a
    /// misbehaving/reconnecting agent could still resend one. Matches the
    /// *last* (most recent) row with this id, not the first — mirroring
    /// `indexForChunk`'s tail-only philosophy — and, if that row is already
    /// terminal (`completed`/`failed`) while the incoming status is
    /// explicitly non-terminal, treats the update as describing a brand-new
    /// occurrence instead of resurrecting the finished row back to
    /// "pending"/"in progress". Without this, a reused id could permanently
    /// flip an already-completed tool call's badge back to "Working" while
    /// silently overwriting its real output with whatever the new,
    /// unrelated occurrence reports — and if that new occurrence's own
    /// completion event is ever dropped, the row would misleadingly read
    /// "Working" forever instead of "Completed" or "Stale".
    private func toolCallMergeIndex(for id: String, incomingStatus: ToolCallStatus?) -> Int? {
        guard let idx = messages.lastIndex(where: { $0.toolCallId == id }) else { return nil }
        if messages[idx].toolStatus?.isTerminal == true, incomingStatus?.isTerminal == false {
            return nil
        }
        return idx
    }

    private func mergeToolCall(id: String,
                               title: String?,
                               status: ToolCallStatus?,
                               kind: ToolKind?,
                               content: [ToolCallContent]?,
                               locations: [ToolCallLocation]?,
                               rawInput: ACPJSONValue?,
                               rawOutput: ACPJSONValue?) {
        let display = title ?? String(localized: "Tool call")
        let now = Date()
        if let idx = toolCallMergeIndex(for: id, incomingStatus: status) {
            if let title {
                messages[idx].text = title
            }
            messages[idx].toolStatus = status ?? messages[idx].toolStatus
            messages[idx].toolKind = kind ?? messages[idx].toolKind
            messages[idx].toolContent = content ?? messages[idx].toolContent
            messages[idx].toolLocations = locations ?? messages[idx].toolLocations
            messages[idx].toolRawInput = rawInput ?? messages[idx].toolRawInput
            messages[idx].toolRawOutput = rawOutput ?? messages[idx].toolRawOutput
            messages[idx].toolUpdatedAt = now
            if (status ?? messages[idx].toolStatus)?.isTerminal == true {
                messages[idx].toolCompletedAt = messages[idx].toolCompletedAt ?? now
                messages[idx].toolAbandonedReason = nil
            }
        } else {
            messages.append(Message(
                role: .toolCall,
                text: display,
                toolCallId: id,
                toolStatus: status,
                toolKind: kind,
                toolContent: content,
                toolLocations: locations,
                toolRawInput: rawInput,
                toolRawOutput: rawOutput,
                toolStartedAt: now,
                toolUpdatedAt: now,
                toolCompletedAt: status?.isTerminal == true ? now : nil
            ))
        }
    }

    private func handleReadTextFile(_ request: ACPServerRequest, projectRoot: String) async -> Result<ACPJSONValue, ACPErrorPayload> {
        do {
            let params = try request.decodeParams(ReadTextFileRequest.self)
            return .success(try projectFileService.readTextFile(params, projectRoot: projectRoot).jsonValue())
        } catch {
            return .failure(ACPErrorPayload(message: error.localizedDescription))
        }
    }

    private func handleWriteTextFile(_ request: ACPServerRequest, projectRoot: String) async -> Result<ACPJSONValue, ACPErrorPayload> {
        do {
            let params = try request.decodeParams(WriteTextFileRequest.self)
            try projectFileService.writeTextFile(params, projectRoot: projectRoot)
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
        attachPermissionDetails(params)

        // 1. Check user permission review mode
        let mode = WorkspaceStore.current?.permissionReviewMode ?? .manual
        let title = params.toolCall?.title ?? String(localized: "Permission request")

        if mode == .alwaysAllow {
            let option = Self.selectOption(from: params.options, approved: true)
            if option == nil {
                messages.append(Message(role: .system, text: String(format: String(localized: "No allow option was offered for permission: %@"), title)))
            } else {
                messages.append(Message(role: .system, text: String(format: String(localized: "Always allowed permission: %@"), title)))
            }
            scheduleSave()
            return .success(Self.outcomeJSON(for: option))
        }

        if mode == .autoReview {
            let kind = params.toolCall?.kind
            let policy = PermissionPolicy.defaultPolicy(for: kind)

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

    private func attachPermissionDetails(_ request: RequestPermissionRequest) {
        guard let toolCall = request.toolCall else { return }
        mergeToolCall(
            id: toolCall.toolCallId,
            title: toolCall.title ?? String(localized: "Permission request"),
            status: toolCall.status ?? .pending,
            kind: toolCall.kind,
            content: nil,
            locations: nil,
            rawInput: toolCall.rawInput,
            rawOutput: nil
        )
        scheduleSave()
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
        if let configOptions = response.configOptions {
            self.configOptions = configOptions
        }
        scheduleSave()
    }

    /// Mirrors `applySession(sessionID:response:)` for `session/load`'s
    /// response, which (per the ACP spec) carries `modes`/`configOptions`
    /// but no `models`/`sessionId` of its own — the id is already known
    /// since we're the one who asked to resume it.
    private func applyLoadedSession(sessionID: String, response: LoadSessionResponse) {
        self.sessionID = sessionID
        onSessionID(sessionID)
        if let modes = response.modes {
            self.modes = modes.availableModes ?? []
            currentMode = modes.currentModeId
        }
        if let configOptions = response.configOptions {
            self.configOptions = configOptions
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

    private func finishActiveTurn(reason: String) {
        isTurnActive = false
        abandonUnfinishedToolCalls(reason: reason)
        status = pendingPermission != nil || pendingElicitation != nil ? .needsPermission : .idle
        scheduleSave()
    }

    private func markFailed(_ message: String) {
        isTurnActive = false
        abandonUnfinishedToolCalls(reason: message)
        messages.append(Message(role: .system, text: message))
        status = .failed(message)
        scheduleSave()
    }

    private func abandonUnfinishedToolCalls(reason: String) {
        let now = Date()
        var changed = false
        for idx in messages.indices where messages[idx].isUnfinishedToolCall {
            messages[idx].toolUpdatedAt = now
            messages[idx].toolCompletedAt = messages[idx].toolCompletedAt ?? now
            messages[idx].toolAbandonedReason = reason
            changed = true
        }
        if changed {
            appendDiagnostic(.init(kind: .lifecycle, title: "Marked unfinished tools stale", detail: reason))
        }
    }

    private func appendDiagnostic(_ event: ACPDiagnosticEvent) {
        diagnostics.append(event)
        if diagnostics.count > Self.maxDiagnostics {
            diagnostics.removeFirst(diagnostics.count - Self.maxDiagnostics)
        }
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
        configOptions = decoded.configOptions ?? []
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
            configOptions: configOptions,
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

typealias DevinSessionManager = AgentSessionController
