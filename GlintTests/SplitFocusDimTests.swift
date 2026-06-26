import XCTest
@testable import Glint

@MainActor
final class SplitFocusDimTests: XCTestCase {

    private func makeStore(cwd: String? = nil) -> (WorkspaceStore, UUID, PaneID) {
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

    // MARK: - Model: focus tracks correctly through split + refocus

    func testSplitMovesFocusToNewPane() {
        let (store, wsID, original) = makeStore()
        store.splitFocused(.horizontal)

        let ws = store.workspaces.first { $0.id == wsID }!
        let focused = ws.selectedTab!.focusedPane
        XCTAssertNotEqual(focused, original,
                          "After split, focus should move to the new pane")
    }

    func testRefocusOriginalPaneAfterSplit() {
        let (store, wsID, original) = makeStore()
        store.splitFocused(.horizontal)
        store.focus(original)

        let ws = store.workspaces.first { $0.id == wsID }!
        XCTAssertEqual(ws.selectedTab!.focusedPane, original,
                       "Focusing the original pane should update focusedPane")
    }

    func testNewPaneIsUnfocusedAfterRefocus() {
        let (store, wsID, original) = makeStore()
        store.splitFocused(.horizontal)

        let ws1 = store.workspaces.first { $0.id == wsID }!
        let newPane = ws1.selectedTab!.focusedPane

        store.focus(original)

        let ws2 = store.workspaces.first { $0.id == wsID }!
        XCTAssertNotEqual(ws2.selectedTab!.focusedPane, newPane,
                          "New pane should be unfocused after switching back to original")
    }

    // MARK: - Focus click notification updates store

    func testFocusClickNotificationUpdatesFocusedPane() {
        let (store, wsID, original) = makeStore()
        store.splitFocused(.horizontal)

        let ws1 = store.workspaces.first { $0.id == wsID }!
        let newPane = ws1.selectedTab!.focusedPane
        XCTAssertNotEqual(newPane, original, "Sanity: split moved focus away")

        // Simulate the notification that GhosttySurfaceView.mouseDown posts
        // when the user clicks an unfocused pane.
        let paneKey = "\(wsID.uuidString):\(original.value)"
        NotificationCenter.default.post(
            name: .glintPaneFocusClicked,
            object: nil,
            userInfo: ["pane": paneKey]
        )

        let ws2 = store.workspaces.first { $0.id == wsID }!
        XCTAssertEqual(ws2.selectedTab!.focusedPane, original,
                       "Focus click notification should update focusedPane to the clicked pane")
    }

    func testFocusClickNotificationSkipsRedundantWrite() {
        let (store, wsID, original) = makeStore()

        // Focus is already on `original`. Posting a notification for the same
        // pane should be a no-op (no objectWillChange churn).
        let paneKey = "\(wsID.uuidString):\(original.value)"
        NotificationCenter.default.post(
            name: .glintPaneFocusClicked,
            object: nil,
            userInfo: ["pane": paneKey]
        )

        let ws = store.workspaces.first { $0.id == wsID }!
        XCTAssertEqual(ws.selectedTab!.focusedPane, original,
                       "Redundant focus notification should leave focusedPane unchanged")
    }

    // MARK: - Dim overlay opacity

    func testDimOpacityUnfocusedOpaque() {
        let opacity = PaneView.dimOverlayOpacity(isFocused: false, isTransparent: false)
        XCTAssertEqual(opacity, 0.28)
    }

    func testDimOpacityUnfocusedTransparent() {
        let opacity = PaneView.dimOverlayOpacity(isFocused: false, isTransparent: true)
        XCTAssertEqual(opacity, 0.18)
    }

    func testDimOpacityFocused() {
        let opaque = PaneView.dimOverlayOpacity(isFocused: false, isTransparent: false)
        let transparent = PaneView.dimOverlayOpacity(isFocused: false, isTransparent: true)
        XCTAssertGreaterThan(opaque, 0, "Unfocused opaque pane must be dimmed")
        XCTAssertGreaterThan(transparent, 0, "Unfocused transparent pane must be dimmed")

        let focusedOpaque = PaneView.dimOverlayOpacity(isFocused: true, isTransparent: false)
        let focusedTransparent = PaneView.dimOverlayOpacity(isFocused: true, isTransparent: true)
        XCTAssertEqual(focusedOpaque, 0, "Focused pane must not be dimmed")
        XCTAssertEqual(focusedTransparent, 0, "Focused pane must not be dimmed")
    }
}
