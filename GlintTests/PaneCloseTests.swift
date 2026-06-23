import XCTest
@testable import Glint

@MainActor
final class PaneCloseTests: XCTestCase {
    private func makeSplitStore(focusedPane: PaneID) -> (WorkspaceStore, UUID, PaneID, PaneID) {
        let store = WorkspaceStore()
        let a = PaneID(value: 0)
        let b = PaneID(value: 1)
        let tab = WorkspaceTab(
            id: TabID(value: 0),
            name: nil,
            root: .split(direction: .horizontal, ratio: 0.5, a: .leaf(a), b: .leaf(b)),
            focusedPane: focusedPane
        )
        let ws = Workspace(
            id: UUID(), name: "Test", userNamed: false,
            accentHex: "5E5CE6", symbol: "T",
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [
                a: Pane(id: a, title: "left", workingDirectory: nil),
                b: Pane(id: b, title: "right", workingDirectory: nil),
            ],
            nextPaneSeq: 2
        )
        store.workspaces = [ws]
        store.selectedWorkspaceID = ws.id
        return (store, ws.id, a, b)
    }

    func testClosePaneCanCloseNonFocusedPane() {
        let (store, wsID, focused, nonFocused) = makeSplitStore(focusedPane: PaneID(value: 0))

        store.closePane(nonFocused)

        let ws = store.workspaces.first { $0.id == wsID }!
        XCTAssertEqual(ws.selectedTab?.root.leaves, [focused])
        XCTAssertNil(ws.panes[nonFocused])
        XCTAssertEqual(ws.selectedTab?.focusedPane, focused)
    }

    func testClosePaneFallsBackToCloseTabForLastPane() {
        let (store, wsID, onlyPane, _) = makeSplitStore(focusedPane: PaneID(value: 0))
        store.closePane(PaneID(value: 1))

        store.closePane(onlyPane)

        let ws = store.workspaces.first { $0.id == wsID }!
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.selectedTab?.root.leaves.count, 1)
    }
}
