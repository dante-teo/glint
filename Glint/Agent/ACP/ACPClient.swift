import Combine
import Foundation

enum ACPClientError: LocalizedError, Equatable {
    case devinNotFound
    case processLaunchFailed(String)
    case processExited(String)
    case invalidResponse(String)
    case serverError(String)
    case unsupportedProtocol(String)
    case requestCancelled
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .devinNotFound:
            return String(localized: "Devin CLI was not found. Install Devin or make sure `devin` is on PATH.")
        case .processLaunchFailed(let message):
            return message
        case .processExited(let message):
            return message.isEmpty
                ? String(localized: "Devin ACP exited before it could respond.")
                : message
        case .invalidResponse(let message), .serverError(let message), .unsupportedProtocol(let message):
            return message
        case .requestCancelled:
            return String(localized: "The Devin ACP request was cancelled.")
        case .requestTimedOut:
            return String(localized: "Devin ACP did not respond in time.")
        }
    }
}

typealias ACPServerRequestHandler = @Sendable (ACPServerRequest) async -> Result<ACPJSONValue, ACPErrorPayload>

final class ACPClient: @unchecked Sendable {
    private final class PendingRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let resume: (Result<ACPJSONValue, Error>) -> Void

        init(resume: @escaping (Result<ACPJSONValue, Error>) -> Void) {
            self.resume = resume
        }

        func complete(_ result: Result<ACPJSONValue, Error>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            resume(result)
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private let notificationSubject = PassthroughSubject<ACPNotification, Never>()
    private let diagnosticSubject = PassthroughSubject<ACPDiagnosticEvent, Never>()
    private var stderrData = Data()
    private var nextID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var requestHandlers: [String: ACPServerRequestHandler] = [:]
    private var readerTask: Task<Void, Never>?
    private var didStart = false
    private var didClose = false

    var notifications: AnyPublisher<ACPNotification, Never> {
        notificationSubject.eraseToAnyPublisher()
    }

    var diagnostics: AnyPublisher<ACPDiagnosticEvent, Never> {
        diagnosticSubject.eraseToAnyPublisher()
    }

    var stderrText: String {
        stateLock.lock()
        let data = stderrData
        stateLock.unlock()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func start() throws {
        guard !didStart else { return }
        guard let devinURL = Self.devinExecutableURL() else {
            throw ACPClientError.devinNotFound
        }

        process.executableURL = devinURL
        process.arguments = ["acp"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStderr(data)
        }

        process.terminationHandler = { [weak self] _ in
            let stderr = self?.stderrText ?? ""
            self?.emitDiagnostic(.init(kind: .lifecycle, title: "ACP process exited", detail: stderr.isEmpty ? nil : stderr))
            self?.failPending(ACPClientError.processExited(stderr))
        }

        do {
            try process.run()
            didStart = true
            emitDiagnostic(.init(kind: .lifecycle, title: "Started Devin ACP process", detail: devinURL.path))
            startReader()
        } catch {
            throw ACPClientError.processLaunchFailed(error.localizedDescription)
        }
    }

    func setRequestHandler(method: String, handler: ACPServerRequestHandler?) {
        stateLock.lock()
        if let handler {
            requestHandlers[method] = handler
        } else {
            requestHandlers.removeValue(forKey: method)
        }
        stateLock.unlock()
    }

    @discardableResult
    func initialize() async throws -> InitializeResponse {
        do {
            let response: InitializeResponse = try await request(
                method: "initialize",
                params: InitializeRequest()
            )
            guard response.protocolVersion == 1 else {
                throw ACPClientError.unsupportedProtocol(
                    String(format: String(localized: "Devin ACP negotiated unsupported protocol version %d. Glint supports ACP v1."), response.protocolVersion)
                )
            }
            return response
        } catch ACPClientError.serverError(let message) {
            throw ACPClientError.unsupportedProtocol(
                String(localized: "Devin ACP rejected ACP v1 initialization: \(message)")
            )
        }
    }

    func createSession(cwd: String) async throws -> NewSessionResponse {
        let result: NewSessionResponse = try await request(
            method: "session/new",
            params: NewSessionRequest(cwd: cwd)
        )
        guard let sessionID = result.resolvedSessionId, !sessionID.isEmpty else {
            throw ACPClientError.invalidResponse(String(localized: "Devin ACP did not return a session id."))
        }
        return result
    }

    func loadSession(sessionID: String, cwd: String) async throws -> LoadSessionResponse {
        try await request(
            method: "session/load",
            params: LoadSessionRequest(sessionId: sessionID, cwd: cwd)
        )
    }

    /// Real Devin turns can legitimately run for a long time (multiple tool
    /// calls, builds, etc.) before returning `end_turn`. A short timeout
    /// here would fail the turn out from under a still-working agent,
    /// leaving the UI in a confusing state even though work continues in
    /// the background. Cancellation (`session/cancel`) is the intended way
    /// to end a turn early, not a timeout.
    private static let promptTimeout: TimeInterval = 60 * 60 * 24

    @discardableResult
    func prompt(sessionID: String, content: [ContentBlock]) async throws -> PromptResponse {
        try await request(
            method: "session/prompt",
            params: PromptRequest(sessionId: sessionID, prompt: content),
            timeout: Self.promptTimeout
        )
    }

    func setMode(sessionID: String, modeId: String) async throws {
        let _: EmptyACPResult = try await request(
            method: "session/set_mode",
            params: SetSessionModeRequest(sessionId: sessionID, modeId: modeId)
        )
    }

    func closeSession(sessionID: String) async throws {
        let _: CloseSessionResponse = try await request(
            method: "session/close",
            params: CloseSessionRequest(sessionId: sessionID),
            timeout: 2
        )
    }

    func notify<Params: Encodable>(method: String, params: Params) throws {
        let envelope = ACPNotificationEnvelope(method: method, params: params)
        try write(JSONEncoder.acp.encode(envelope))
    }

    func cancelSession(sessionID: String) {
        try? notify(method: "session/cancel", params: ["sessionId": sessionID])
    }

    func close() {
        stateLock.lock()
        guard !didClose else {
            stateLock.unlock()
            return
        }
        didClose = true
        stateLock.unlock()

        readerTask?.cancel()
        error.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
        emitDiagnostic(.init(kind: .lifecycle, title: "Closed ACP client"))
        failPending(ACPClientError.requestCancelled)
        notificationSubject.send(completion: .finished)
        diagnosticSubject.send(completion: .finished)
    }

    private func request<Result: Decodable, Params: Encodable>(
        method: String,
        params: Params,
        timeout: TimeInterval = 60
    ) async throws -> Result {
        let id = nextRequestID()
        let envelope = ACPRequest(id: id, method: method, params: params)
        let payload = try JSONEncoder.acp.encode(envelope)
        emitDiagnostic(.init(kind: .request, title: method, detail: "id \(id)"))

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.removePending(id: id)?.complete(.failure(ACPClientError.requestTimedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            do {
                let raw = try await awaitResponse(id: id, payload: payload)
                return try JSONDecoder.acp.decode(Result.self, from: JSONEncoder.acp.encode(raw))
            } catch {
                self.removePending(id: id)?.complete(.failure(error))
                throw error
            }
        } onCancel: {
            self.removePending(id: id)?.complete(.failure(ACPClientError.requestCancelled))
        }
    }

    private func awaitResponse(id: Int, payload: Data) async throws -> ACPJSONValue {
        try await withCheckedThrowingContinuation { continuation in
            let pending = PendingRequest { result in
                continuation.resume(with: result)
            }
            insertPending(id: id, pending)
            do {
                try write(payload)
            } catch {
                removePending(id: id)?.complete(.failure(error))
            }
        }
    }

    private func startReader() {
        readerTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let line = try self.readLine()
                    guard !line.isEmpty else { continue }
                    self.handleIncomingLine(line)
                }
            } catch {
                self.failPending(error)
            }
        }
    }

    private func readLine() throws -> Data {
        var data = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty {
                throw ACPClientError.processExited(stderrText)
            }
            if byte.first == 0x0A {
                return data
            }
            data.append(byte)
        }
    }

    private func handleIncomingLine(_ line: Data) {
        guard let message = try? JSONDecoder.acp.decode(ACPIncomingMessage.self, from: line) else {
            NSLog("[glint] Devin ACP sent malformed JSON line (\(line.count) bytes)")
            emitDiagnostic(.init(kind: .malformed, title: "Malformed JSON line", detail: String(data: line, encoding: .utf8)))
            return
        }

        if let id = message.id, message.method == nil {
            handleResponse(id: id, result: message.result, error: message.error)
        } else if let id = message.id, let method = message.method {
            emitDiagnostic(.init(kind: .serverRequest, title: method, detail: "id \(id)", payload: message.params))
            handleServerRequest(ACPServerRequest(id: id, method: method, params: message.params))
        } else if let method = message.method {
            emitDiagnostic(.init(kind: .notification, title: method, payload: message.params))
            notificationSubject.send(ACPNotification(method: method, params: message.params))
        }
    }

    private func handleResponse(id: Int, result: ACPJSONValue?, error: ACPErrorPayload?) {
        guard let pending = removePending(id: id) else {
            NSLog("[glint] Devin ACP response for unknown id \(id)")
            emitDiagnostic(.init(kind: .response, title: "Unknown response id", detail: "id \(id)", payload: result))
            return
        }
        if let error {
            emitDiagnostic(.init(kind: .error, title: "Response error", detail: "id \(id): \(error.message)", payload: error.data))
            pending.complete(.failure(ACPClientError.serverError(error.message)))
        } else {
            emitDiagnostic(.init(kind: .response, title: "Response", detail: "id \(id)", payload: result))
            pending.complete(.success(result ?? .null))
        }
    }

    private func handleServerRequest(_ request: ACPServerRequest) {
        let handler = handler(for: request.method)
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let result: Result<ACPJSONValue, ACPErrorPayload>
            if let handler {
                result = await handler(request)
            } else {
                result = .failure(ACPErrorPayload(code: -32601, message: "Method not found: \(request.method)"))
            }
            self.writeResponse(id: request.id, result: result)
        }
    }

    private func writeResponse(id: Int, result: Result<ACPJSONValue, ACPErrorPayload>) {
        let envelope: ACPResponseEnvelope<ACPJSONValue>
        switch result {
        case .success(let value):
            envelope = ACPResponseEnvelope(id: id, result: value, error: nil)
        case .failure(let error):
            envelope = ACPResponseEnvelope(id: id, result: nil, error: error)
        }
        do {
            try write(JSONEncoder.acp.encode(envelope))
        } catch {
            NSLog("[glint] failed to write Devin ACP response: \(error)")
            emitDiagnostic(.init(kind: .error, title: "Failed to write ACP response", detail: error.localizedDescription))
        }
    }

    private func write(_ data: Data) throws {
        guard !didClose else {
            throw ACPClientError.requestCancelled
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func nextRequestID() -> Int {
        stateLock.lock()
        let id = nextID
        nextID += 1
        stateLock.unlock()
        return id
    }

    private func insertPending(id: Int, _ request: PendingRequest) {
        stateLock.lock()
        pending[id]?.complete(.failure(ACPClientError.invalidResponse("Duplicate JSON-RPC request id \(id).")))
        pending[id] = request
        stateLock.unlock()
    }

    private func removePending(id: Int) -> PendingRequest? {
        stateLock.lock()
        let request = pending.removeValue(forKey: id)
        stateLock.unlock()
        return request
    }

    private func failPending(_ error: Error) {
        stateLock.lock()
        let requests = pending.values
        pending.removeAll()
        stateLock.unlock()
        for request in requests {
            request.complete(.failure(error))
        }
    }

    private func handler(for method: String) -> ACPServerRequestHandler? {
        stateLock.lock()
        let handler = requestHandlers[method]
        stateLock.unlock()
        return handler
    }

    private func appendStderr(_ data: Data) {
        stateLock.lock()
        stderrData.append(data)
        stateLock.unlock()
        emitDiagnostic(.init(kind: .stderr, title: "stderr", detail: String(data: data, encoding: .utf8)))
    }

    private func emitDiagnostic(_ event: ACPDiagnosticEvent) {
        diagnosticSubject.send(event)
    }

    private static func devinExecutableURL() -> URL? {
        AgentPresence.executableURL("devin")
    }

    #if DEBUG
    func _ingestLineForTesting(_ line: Data) {
        handleIncomingLine(line)
    }
    #endif
}
