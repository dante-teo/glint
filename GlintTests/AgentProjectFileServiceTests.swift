import XCTest
@testable import Glint

final class AgentProjectFileServiceTests: XCTestCase {
    private let service = AgentProjectFileService()

    private func makeProject() throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-agent-file-service-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (base, root)
    }

    func testReadRejectsOutsideRoot() throws {
        let (_, root) = try makeProject()

        XCTAssertThrowsError(
            try service.readTextFile(ReadTextFileRequest(sessionId: "s", path: "/etc/passwd", line: nil, limit: nil), projectRoot: root.path)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the project folder"))
        }
    }

    func testWriteRejectsSymlinkTargetOutsideRoot() throws {
        let (base, root) = try makeProject()
        let outside = base.appendingPathComponent("outside.txt")
        let link = root.appendingPathComponent("outside-link.txt")
        try "original".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try service.writeTextFile(WriteTextFileRequest(sessionId: "s", path: link.path, content: "changed"), projectRoot: root.path)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("outside the project folder"))
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
    }

    func testWriteAllowsMissingLeafInsideRoot() throws {
        let (_, root) = try makeProject()
        let target = root.appendingPathComponent("nested/new.txt")

        try service.writeTextFile(WriteTextFileRequest(sessionId: "s", path: target.path, content: "hello"), projectRoot: root.path)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hello")
    }

    func testLineSliceIsDeterministic() throws {
        let (_, root) = try makeProject()
        let file = root.appendingPathComponent("a.txt")
        try "one\ntwo\nthree\nfour".write(to: file, atomically: true, encoding: .utf8)

        let response = try service.readTextFile(ReadTextFileRequest(sessionId: "s", path: file.path, line: 2, limit: 2), projectRoot: root.path)

        XCTAssertEqual(response.content, "two\nthree")
    }
}
