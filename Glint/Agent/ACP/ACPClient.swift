import Foundation

enum ACPClientError: LocalizedError {
    case devinNotFound
    case processLaunchFailed(String)
    case processExited(String)
    case invalidResponse(String)
    case serverError(String)

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
        case .invalidResponse(let message), .serverError(let message):
            return message
        }
    }
}

final class ACPClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private var stderrData = Data()
    private var nextID = 1

    var stderrText: String {
        String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func start() throws {
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
            self?.stderrData.append(data)
        }

        do {
            try process.run()
        } catch {
            throw ACPClientError.processLaunchFailed(error.localizedDescription)
        }
    }

    func initialize() async throws {
        let _: EmptyACPResult = try await request(
            method: "initialize",
            params: ["protocolVersion": "0.11.3"]
        )
    }

    func createSession(cwd: String) async throws -> String? {
        let result: NewSessionResult = try await request(
            method: "session/new",
            params: ["cwd": cwd]
        )
        return result.sessionId ?? result.sessionID
    }

    func prompt(sessionID: String?, text: String) async throws {
        var params: [String: Any] = ["prompt": text]
        if let sessionID, !sessionID.isEmpty {
            params["sessionId"] = sessionID
        }
        let _: EmptyACPResult = try await request(method: "session/prompt", params: params)
    }

    func close() {
        error.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func request<Result: Decodable>(method: String, params: [String: Any]) async throws -> Result {
        let id = nextID
        nextID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))

        while true {
            guard process.isRunning else {
                throw ACPClientError.processExited(stderrText)
            }
            let line = try await readLine()
            guard let response = try? JSONDecoder().decode(ACPResponse<Result>.self, from: line) else {
                continue
            }
            guard response.id == id else { continue }
            if let error = response.error {
                throw ACPClientError.serverError(error.message)
            }
            guard let result = response.result else {
                throw ACPClientError.invalidResponse(String(localized: "Devin ACP returned an empty response."))
            }
            return result
        }
    }

    private func readLine() async throws -> Data {
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

    private static func devinExecutableURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/bin",
            "\(home)/.bun/bin", "\(home)/.deno/bin",
            "\(home)/.npm-global/bin",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs {
            let path = "\(dir)/devin"
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}

struct ACPResponse<Result: Decodable>: Decodable {
    let id: Int?
    let result: Result?
    let error: ACPErrorPayload?
}

struct ACPErrorPayload: Decodable {
    let message: String
}

struct EmptyACPResult: Decodable {}

struct NewSessionResult: Decodable {
    let sessionId: String?
    let sessionID: String?
}
