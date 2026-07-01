import Foundation

struct AgentProjectFileService: Sendable {
    func readTextFile(_ request: ReadTextFileRequest, projectRoot: String) throws -> ReadTextFileResponse {
        let url = try validatedProjectFileURL(path: request.path, projectRoot: projectRoot)
        let content = try String(contentsOf: url, encoding: .utf8)
        return ReadTextFileResponse(content: slice(content: content, line: request.line, limit: request.limit))
    }

    func writeTextFile(_ request: WriteTextFileRequest, projectRoot: String) throws {
        let url = try validatedProjectFileURL(path: request.path, projectRoot: projectRoot, allowMissingLeaf: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try request.content.write(to: url, atomically: true, encoding: .utf8)
    }

    func validatedProjectFileURL(path: String, projectRoot: String, allowMissingLeaf: Bool = false) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        let candidateExists = fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
        let resolvedTarget = (allowMissingLeaf && !candidateExists ? candidate.deletingLastPathComponent() : candidate)
            .resolvingSymlinksInPath()
        let resolvedPath = resolvedTarget.path
        guard resolvedPath == root.path || resolvedPath.hasPrefix(root.path + "/") else {
            throw ACPClientError.invalidResponse(String(localized: "File access outside the project folder is not allowed."))
        }
        guard allowMissingLeaf || (candidateExists && !isDirectory.boolValue) else {
            throw ACPClientError.invalidResponse(String(localized: "Requested file does not exist or is not a text file."))
        }
        return candidate
    }

    func slice(content: String, line: Int?, limit: Int?) -> String {
        guard line != nil || limit != nil else { return content }
        let lines = content.components(separatedBy: .newlines)
        let start = max((line ?? 1) - 1, 0)
        guard start < lines.count else { return "" }
        let end = min(start + max(limit ?? (lines.count - start), 0), lines.count)
        return lines[start..<end].joined(separator: "\n")
    }
}
