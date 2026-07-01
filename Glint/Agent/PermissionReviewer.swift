import Foundation

enum PermissionReviewMode: String, Codable, CaseIterable {
    case manual
    case autoReview
    case alwaysAllow

    var title: String {
        switch self {
        case .manual:
            return String(localized: "Always Ask")
        case .autoReview:
            return String(localized: "Auto Review")
        case .alwaysAllow:
            return String(localized: "Always Allow")
        }
    }

    var subtitle: String {
        switch self {
        case .manual:
            return String(localized: "Show every permission card.")
        case .autoReview:
            return String(localized: "Use Devin to review risky actions.")
        case .alwaysAllow:
            return String(localized: "Approve offered allow options.")
        }
    }
}

enum PermissionPolicy: String, Codable {
    case autoApprove
    case alwaysEscalate
    case llmReview

    static func defaultPolicy(for kind: ToolKind?) -> PermissionPolicy {
        guard let kind else { return .alwaysEscalate }
        switch kind {
        case .read, .think, .fetch, .search:
            return .autoApprove
        case .delete:
            return .alwaysEscalate
        case .edit, .execute, .move, .other, .unknown:
            return .llmReview
        }
    }
}

enum ReviewDecision: Equatable {
    case approve(reason: String)
    case deny(reason: String)
    case escalate(reason: String)
}

struct ReviewResponse: Codable {
    let decision: String // "approve" | "deny" | "escalate"
    let reason: String
}

@MainActor
final class PermissionReviewer {
    static let shared = PermissionReviewer()

    private init() {}

    /// Run the LLM reviewer using `devin -p` with a structurally constrained prefix prompt
    func review(
        title: String,
        kind: ToolKind?,
        rawInput: String,
        conversationContext: [DevinSessionManager.Message],
        projectRoot: String
    ) async -> ReviewDecision {
        guard let devinURL = Self.devinExecutableURL() else {
            return .escalate(reason: String(localized: "Devin CLI not found on system path."))
        }

        let prompt = buildReviewPrompt(
            title: title,
            kind: kind,
            rawInput: rawInput,
            conversationContext: conversationContext,
            projectRoot: projectRoot
        )

        do {
            let stdout = try await runDevinCommand(executableURL: devinURL, prompt: prompt)
            return parseResponse(stdout)
        } catch {
            return .escalate(reason: String(format: String(localized: "Review failed: %@"), error.localizedDescription))
        }
    }

    private func buildReviewPrompt(
        title: String,
        kind: ToolKind?,
        rawInput: String,
        conversationContext: [DevinSessionManager.Message],
        projectRoot: String
    ) -> String {
        let lastMessages = conversationContext.suffix(5).map { msg in
            "[\(msg.role.rawValue.uppercased())]: \(msg.text)"
        }.joined(separator: "\n")

        let kindString = kind.map { String(describing: $0) } ?? "unknown"

        return """
You are the security agent inside the Glint App, reviewing a tool execution requested by the coding agent Devin.
Analyze the request below and make a decision:
- "approve": The request is completely safe, aligned with the user's intent, and poses no risk of data loss or security breach.
- "deny": The request is highly dangerous, unauthorized, malicious, or completely unrelated to the project.
- "escalate": You are unsure, there are potential side-effects, or this requires human verification (e.g. destructive edits, running tests/scripts with side-effects).

Context:
Project Root: \(projectRoot)
Last \(conversationContext.count) messages:
\(lastMessages)

Requested Tool:
Title: \(title)
Kind: \(kindString)
Input/Args: \(rawInput.prefix(1500))

Choose exactly one decision: "approve", "deny", or "escalate". Give a short, concise 1-sentence reason.
Complete this JSON (no other output, do not repeat the prefix):
{"decision":
"""
    }

    private func runDevinCommand(executableURL: URL, prompt: String) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-p", "--", prompt]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let lock = NSLock()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000) // 8s timeout
                lock.lock()
                defer { lock.unlock() }
                if !completed {
                    completed = true
                    if process.isRunning {
                        process.terminate()
                    }
                    continuation.resume(throwing: NSError(domain: "PermissionReviewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Review request timed out"]))
                }
            }

            process.terminationHandler = { _ in
                timeoutTask.cancel()
                lock.lock()
                defer { lock.unlock() }
                if !completed {
                    completed = true
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let stdout = String(data: data, encoding: .utf8) ?? ""
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: errData, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: stdout)
                    } else {
                        let errMessage = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: NSError(domain: "PermissionReviewer", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMessage.isEmpty ? "devin -p failed" : errMessage]))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                timeoutTask.cancel()
                lock.lock()
                defer { lock.unlock() }
                if !completed {
                    completed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Parse prefix-json structurally with robust fallback layers
    func parseResponse(_ rawStdout: String) -> ReviewDecision {
        let clean = rawStdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return .escalate(reason: String(localized: "Empty model response."))
        }

        // Layer 1: Prepend prefix and decode
        let jsonCandidates = [
            "{\"decision\":" + clean,
            clean
        ]

        for candidate in jsonCandidates {
            if let decoded = tryDecode(candidate) {
                return mapDecision(decoded)
            }
        }

        // Layer 2: Clean up markdown block fences and try again
        let stripped = clean
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidatesStripped = [
            "{\"decision\":" + stripped,
            stripped
        ]

        for candidate in candidatesStripped {
            if let decoded = tryDecode(candidate) {
                return mapDecision(decoded)
            }
        }

        // Layer 3: Regex match key patterns
        if let decision = extractValue(for: "decision", from: clean) {
            let reason = extractValue(for: "reason", from: clean) ?? "Escalated by regex heuristic"
            let decoded = ReviewResponse(decision: decision, reason: reason)
            return mapDecision(decoded)
        }

        return .escalate(reason: String(localized: "Failed to parse model response structure."))
    }

    private func tryDecode(_ jsonString: String) -> ReviewResponse? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReviewResponse.self, from: data)
    }

    private func mapDecision(_ response: ReviewResponse) -> ReviewDecision {
        let decision = response.decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let reason = response.reason.trimmingCharacters(in: .whitespacesAndNewlines)

        switch decision {
        case "approve":
            return .approve(reason: reason)
        case "deny":
            return .deny(reason: reason)
        default:
            return .escalate(reason: reason)
        }
    }

    private func extractValue(for key: String, from text: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        if let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        return nil
    }

    private static func devinExecutableURL() -> URL? {
        AgentPresence.executableURL("devin")
    }
}
