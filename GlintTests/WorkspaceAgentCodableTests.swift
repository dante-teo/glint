import XCTest
@testable import Glint

/// Pure Codable round-trip tests for the agent workspace fields on
/// `Workspace`. These don't touch `WorkspaceStore` (a @MainActor type),
/// so they live in their own unannotated file per AGENTS.md convention.
final class WorkspaceAgentCodableTests: XCTestCase {

    // MARK: - Backward-compatible decoding

    func testOldStateJsonDecodesAsTerminalCommitted() throws {
        // Simulate a pre-agent state.json: no kind, committed, agentProvider,
        // agentProjectPath, or agentSessionID keys.
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy",
            "userNamed": true,
            "accentHex": "5E5CE6",
            "symbol": "L",
            "panes": [
                { "value": 0 },
                { "id": { "value": 0 }, "title": "zsh" }
            ],
            "nextPaneSeq": 1,
            "tabs": [
                {
                    "id": { "value": 0 },
                    "root": { "kind": "leaf", "id": { "value": 0 } },
                    "focusedPane": { "value": 0 }
                }
            ],
            "selectedTabID": { "value": 0 },
            "nextTabSeq": 1
        }
        """
        let data = Data(json.utf8)
        let ws = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(ws.kind, .terminal)
        XCTAssertTrue(ws.committed)
        XCTAssertNil(ws.agentProvider)
        XCTAssertNil(ws.agentProjectPath)
        XCTAssertNil(ws.agentSessionID)
    }

    // MARK: - Encoding omits defaults for terminal workspaces

    func testTerminalWorkspaceEncodingOmitsAgentFields() throws {
        let pane = PaneID(value: 0)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        let ws = Workspace(
            id: UUID(), name: "Terminal", userNamed: false,
            accentHex: "5E5CE6", symbol: "T",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [pane: Pane(id: pane, title: "zsh")],
            nextPaneSeq: 1
        )
        let data = try JSONEncoder().encode(ws)
        let topLevel = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Terminal defaults should NOT be present at the top level.
        // (Note: nested SplitNode has its own "kind" key — we only check the
        // Workspace-level keys here.)
        XCTAssertNil(topLevel["kind"], "kind should be omitted for terminal")
        XCTAssertNil(topLevel["committed"], "committed should be omitted when true")
        XCTAssertNil(topLevel["agentProvider"], "agentProvider should be omitted when nil")
        XCTAssertNil(topLevel["agentProjectPath"], "agentProjectPath should be omitted when nil")
        XCTAssertNil(topLevel["agentSessionID"], "agentSessionID should be omitted when nil")
    }

    func testAgentWorkspaceEncodingIncludesAgentFields() throws {
        let pane = PaneID(value: 0)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        let ws = Workspace(
            id: UUID(), name: "my-app", userNamed: false,
            accentHex: "5E5CE6", symbol: "T",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [pane: Pane(id: pane, title: "my-app")],
            nextPaneSeq: 1,
            kind: .agent,
            agentProvider: .devin,
            committed: false,
            agentProjectPath: "/tmp/my-app"
        )
        let data = try JSONEncoder().encode(ws)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"kind\""))
        XCTAssertTrue(json.contains("\"agent\""))
        XCTAssertTrue(json.contains("\"agentProvider\""))
        XCTAssertTrue(json.contains("\"devin\""))
        XCTAssertTrue(json.contains("\"committed\""))
        XCTAssertTrue(json.contains("\"agentProjectPath\""))
    }

    // MARK: - Agent workspace round-trip encode/decode

    func testAgentWorkspaceRoundTrip() throws {
        let pane = PaneID(value: 0)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        let original = Workspace(
            id: UUID(), name: "my-app", userNamed: false,
            accentHex: "5E5CE6", symbol: "T",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [pane: Pane(id: pane, title: "my-app")],
            nextPaneSeq: 1,
            kind: .agent,
            agentProvider: .devin,
            committed: false,
            agentProjectPath: "/tmp/my-app",
            agentSessionID: "session-42"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.kind, .agent)
        XCTAssertEqual(decoded.agentProvider, .devin)
        XCTAssertFalse(decoded.committed)
        XCTAssertEqual(decoded.agentProjectPath, "/tmp/my-app")
        XCTAssertEqual(decoded.agentSessionID, "session-42")
    }
}
