import XCTest
@testable import Glint

final class AgentActivityPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testActivitySortsApprovalFailureRunningThenCompleted() {
        let fixtures: [(PaneAgentStatus, PaneAgentKind)] = [
            (.thinking, .codex),
            (.justCompleted, .omp),
            (.needsPermission, .claude),
            (.failed, .opencode),
        ]
        let workspaces = fixtures.enumerated().map { index, _ in
            makeWorkspace(name: "Workspace \(index)", pane: PaneID(value: UInt32(index)))
        }
        let states = Dictionary(uniqueKeysWithValues: zip(workspaces, fixtures).map { workspace, fixture in
            (
                WorkspaceStore.WorkspacePaneKey(
                    workspace: workspace.id,
                    pane: workspace.tabs[0].focusedPane
                ),
                PaneAgentState(
                    kind: fixture.1,
                    status: fixture.0,
                    detail: "detail",
                    updatedAt: now,
                    turnStartedAt: now
                )
            )
        })

        let items = AgentActivityPresentation.items(workspaces: workspaces, states: states)

        XCTAssertEqual(items.map(\.status), [
            .needsPermission, .failed, .thinking, .justCompleted,
        ])
    }

    func testActivityIncludesWorkspaceTabPaneDetailAndCapabilities() {
        var workspace = makeWorkspace(name: "Shipping", pane: PaneID(value: 4))
        workspace.tabs[0].name = "Release"
        let key = WorkspaceStore.WorkspacePaneKey(workspace: workspace.id, pane: PaneID(value: 4))
        let state = PaneAgentState(
            kind: .codex,
            status: .needsPermission,
            detail: "Run deployment?",
            updatedAt: now,
            turnStartedAt: now,
            sessionID: "session-1",
            capabilities: [.focusPane, .interrupt, .resume]
        )

        let item = AgentActivityPresentation.items(
            workspaces: [workspace], states: [key: state]
        ).first

        XCTAssertEqual(item?.workspaceName, "Shipping")
        XCTAssertEqual(item?.tabName, "Release")
        XCTAssertEqual(item?.paneNumber, 1)
        XCTAssertEqual(item?.detail, "Run deployment?")
        XCTAssertEqual(item?.capabilities, [.focusPane, .interrupt, .resume])
    }

    func testIdleAgentsAreExcludedFromActivity() {
        let workspace = makeWorkspace(name: "Idle", pane: PaneID(value: 0))
        let key = WorkspaceStore.WorkspacePaneKey(workspace: workspace.id, pane: PaneID(value: 0))
        let state = PaneAgentState(kind: .claude, status: .idle, updatedAt: now)

        XCTAssertTrue(AgentActivityPresentation.items(
            workspaces: [workspace], states: [key: state]
        ).isEmpty)
    }

    private func makeWorkspace(name: String, pane: PaneID) -> Workspace {
        let tab = WorkspaceTab(
            id: TabID(value: 0), name: nil, root: .leaf(pane), focusedPane: pane
        )
        return Workspace(
            id: UUID(), name: name, userNamed: true,
            accentHex: "5E5CE6", symbol: String(name.prefix(1)),
            tabs: [tab], selectedTabID: tab.id, nextTabSeq: 1,
            panes: [pane: Pane(id: pane, title: "zsh", workingDirectory: "/tmp")],
            nextPaneSeq: pane.value + 1
        )
    }
}

@MainActor
final class AgentActivityRoutingTests: XCTestCase {
    func testShowActivityExpandsSidebarAndSelectsActivityMode() {
        let store = WorkspaceStore()
        store.sidebarCollapsed = true
        store.sidebarMode = .workspaces

        store.showAgentActivity()

        XCTAssertFalse(store.sidebarCollapsed)
        XCTAssertEqual(store.sidebarMode, .activity)
    }

    func testFocusSidebarSearchSwitchesFromActivityMode() {
        let store = WorkspaceStore()
        store.sidebarCollapsed = true
        store.sidebarMode = .activity
        let priorTick = store.sidebarSearchFocusTick

        store.focusSidebarSearch()

        XCTAssertFalse(store.sidebarCollapsed)
        XCTAssertEqual(store.sidebarMode, .workspaces)
        XCTAssertEqual(store.sidebarSearchFocusTick, priorTick + 1)
    }

    func testRouteSelectsWorkspaceTabAndPane() {
        let store = WorkspaceStore()
        let firstPane = PaneID(value: 0)
        let targetPane = PaneID(value: 1)
        let firstTab = WorkspaceTab(
            id: TabID(value: 0), name: "First", root: .leaf(firstPane), focusedPane: firstPane
        )
        let targetTab = WorkspaceTab(
            id: TabID(value: 1), name: "Target", root: .leaf(targetPane), focusedPane: targetPane
        )
        let workspace = Workspace(
            id: UUID(), name: "Routing", userNamed: true,
            accentHex: "5E5CE6", symbol: "R",
            tabs: [firstTab, targetTab], selectedTabID: firstTab.id, nextTabSeq: 2,
            panes: [
                firstPane: Pane(id: firstPane, title: "zsh"),
                targetPane: Pane(id: targetPane, title: "codex"),
            ],
            nextPaneSeq: 2
        )
        store.workspaces = [workspace]
        store.selectedWorkspaceID = nil
        let targetKey = WorkspaceStore.WorkspacePaneKey(
            workspace: workspace.id,
            pane: targetPane
        )
        store.paneAgentState[targetKey] = PaneAgentState(
            kind: .codex,
            status: .justCompleted,
            updatedAt: Date()
        )

        store.routeToAgentPane(workspaceID: workspace.id, paneID: targetPane)

        XCTAssertEqual(store.selectedWorkspaceID, workspace.id)
        XCTAssertEqual(store.selectedWorkspace?.selectedTabID, targetTab.id)
        XCTAssertEqual(store.selectedWorkspace?.selectedTab?.focusedPane, targetPane)
        XCTAssertEqual(store.paneAgentState[targetKey]?.status, .idle)
    }
}
