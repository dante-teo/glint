import XCTest
@testable import Glint

@MainActor
final class CwdInheritanceTests: XCTestCase {

    /// Build a minimal WorkspaceStore whose single workspace has one pane
    /// with the given `workingDirectory`. Returns `(store, workspaceID, paneID)`.
    private func makeStore(cwd: String?) -> (WorkspaceStore, UUID, PaneID) {
        let store = WorkspaceStore()
        let pane = PaneID(value: 0)
        let tab = WorkspaceTab(id: TabID(value: 0), name: nil,
                               root: .leaf(pane), focusedPane: pane)
        let ws = Workspace(
            id: UUID(), name: "Test", userNamed: false,
            accentHex: "5E5CE6", symbol: "T",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [pane: Pane(id: pane, title: "zsh", workingDirectory: cwd)],
            nextPaneSeq: 1
        )
        store.workspaces = [ws]
        store.selectedWorkspaceID = ws.id
        return (store, ws.id, pane)
    }

    // MARK: splitFocused

    func testSplitInheritsCwd() {
        let (store, wsID, _) = makeStore(cwd: "/Users/test/Projects/foo")
        store.splitFocused(.horizontal)

        let ws = store.workspaces.first { $0.id == wsID }!
        let newPaneID = ws.selectedTab!.focusedPane          // split moves focus
        let newPane = ws.panes[newPaneID]!
        XCTAssertEqual(newPane.workingDirectory, "/Users/test/Projects/foo")
    }

    func testSplitWithNilCwd() {
        let (store, wsID, _) = makeStore(cwd: nil)
        store.splitFocused(.vertical)

        let ws = store.workspaces.first { $0.id == wsID }!
        let newPaneID = ws.selectedTab!.focusedPane
        let newPane = ws.panes[newPaneID]!
        XCTAssertNil(newPane.workingDirectory)
    }

    // MARK: newTab

    func testNewTabInheritsCwd() {
        let (store, wsID, _) = makeStore(cwd: "/Users/test/Projects/bar")
        store.newTab()

        let ws = store.workspaces.first { $0.id == wsID }!
        let newTab = ws.selectedTab!
        let newPane = ws.panes[newTab.focusedPane]!
        XCTAssertEqual(newPane.workingDirectory, "/Users/test/Projects/bar")
    }

    func testNewTabWithNilCwd() {
        let (store, wsID, _) = makeStore(cwd: nil)
        store.newTab()

        let ws = store.workspaces.first { $0.id == wsID }!
        let newTab = ws.selectedTab!
        let newPane = ws.panes[newTab.focusedPane]!
        XCTAssertNil(newPane.workingDirectory)
    }
}
