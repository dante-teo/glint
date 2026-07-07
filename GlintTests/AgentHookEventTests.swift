import XCTest
@testable import Glint

@MainActor
final class AgentHookEventTests: XCTestCase {
    private func makeStore() -> (WorkspaceStore, WorkspaceStore.WorkspacePaneKey) {
        let store = WorkspaceStore()
        let pane = PaneID(value: 0)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        let ws = Workspace(
            id: UUID(), name: "Test", userNamed: false,
            accentHex: "5E5CE6", symbol: "T",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [pane: Pane(id: pane, title: "zsh")],
            nextPaneSeq: 1
        )
        store.workspaces = [ws]
        store.selectedWorkspaceID = ws.id
        return (store, WorkspaceStore.WorkspacePaneKey(workspace: ws.id, pane: pane))
    }

    func testExplicitUnknownAgentHookIsIgnored() {
        let (store, key) = makeStore()

        store.handleAgentEvent([
            "pane": "\(key.workspace.uuidString):\(key.pane.value)",
            "hook": "UserPromptSubmit",
            "agent": "devin",
        ])

        XCTAssertNil(store.paneAgentState[key])
    }

    func testMissingAgentHookStillFallsBackToClaude() {
        let (store, key) = makeStore()

        store.handleAgentEvent([
            "pane": "\(key.workspace.uuidString):\(key.pane.value)",
            "hook": "UserPromptSubmit",
        ])

        XCTAssertEqual(store.paneAgentState[key]?.kind, .claude)
        XCTAssertEqual(store.paneAgentState[key]?.status, .thinking)
    }
}
