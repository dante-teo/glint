import XCTest
@testable import Glint

@MainActor
final class WorkspaceKindTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal store with a single terminal workspace.
    private func makeStore() -> (WorkspaceStore, UUID) {
        let store = WorkspaceStore()
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
        store.workspaces = [ws]
        store.selectedWorkspaceID = ws.id
        return (store, ws.id)
    }

    private func makeTempProject(named name: String = UUID().uuidString) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glint-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url.path
    }

    // MARK: - addAgentWorkspace

    func testAddAgentWorkspaceSetsCorrectFields() throws {
        let (store, _) = makeStore()
        let projectPath = try makeTempProject(named: "my-app")
        store.addAgentWorkspace(provider: .devin, projectPath: projectPath)

        let agent = store.workspaces.first { $0.kind == .agent }
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.kind, .agent)
        XCTAssertEqual(agent?.agentProvider, .devin)
        XCTAssertFalse(agent?.committed ?? true)
        XCTAssertEqual(agent?.agentProjectPath, projectPath)
        XCTAssertNil(agent?.agentSessionID)
        XCTAssertEqual(agent?.name, "my-app")
        // Should be selected.
        XCTAssertEqual(store.selectedWorkspaceID, agent?.id)
    }

    func testAddAgentWorkspaceCanCreatePathlessDraft() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)

        let agent = store.workspaces.first { $0.kind == .agent }
        XCTAssertEqual(agent?.name, "Devin Agent")
        XCTAssertEqual(agent?.panes[PaneID(value: 0)]?.title, "Devin Agent")
        XCTAssertNil(agent?.agentProjectPath)
        XCTAssertFalse(agent?.committed ?? true)
    }

    func testAddAgentWorkspaceCleansUpPriorUncommitted() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let firstID = store.workspaces.first { $0.kind == .agent }!.id

        store.addAgentWorkspace(provider: .devin)

        // The first uncommitted workspace should be gone.
        XCTAssertNil(store.workspaces.first(where: { $0.id == firstID }))
        XCTAssertEqual(store.workspaces.filter { $0.kind == .agent }.count, 1)
        XCTAssertEqual(store.workspaces.first { $0.kind == .agent }?.name, "Devin Agent")
    }

    func testSetAgentProjectPathUpdatesAutoNameAndPaneTitle() throws {
        let (store, _) = makeStore()
        let projectPath = try makeTempProject(named: "selected-project")
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id

        XCTAssertTrue(store.setAgentProjectPath(workspaceID: agentID, path: projectPath))

        let agent = store.workspaces.first { $0.id == agentID }
        XCTAssertEqual(agent?.agentProjectPath, projectPath)
        XCTAssertEqual(agent?.name, "selected-project")
        XCTAssertEqual(agent?.panes[PaneID(value: 0)]?.title, "selected-project")
    }

    func testSetAgentProjectPathDoesNotOverwriteUserRenamedWorkspace() throws {
        let (store, _) = makeStore()
        let projectPath = try makeTempProject(named: "selected-project")
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id
        store.renameWorkspace(agentID, to: "My Custom Agent")

        XCTAssertTrue(store.setAgentProjectPath(workspaceID: agentID, path: projectPath))

        let agent = store.workspaces.first { $0.id == agentID }
        XCTAssertEqual(agent?.name, "My Custom Agent")
        XCTAssertEqual(agent?.panes[PaneID(value: 0)]?.title, "selected-project")
    }

    func testSetAgentProjectPathRejectsMissingFolder() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id

        XCTAssertFalse(store.setAgentProjectPath(workspaceID: agentID, path: "/tmp/glint-missing-\(UUID().uuidString)"))
        XCTAssertNil(store.workspaces.first { $0.id == agentID }?.agentProjectPath)
    }

    func testAddWorkspaceCleansUpSelectedUncommittedAgentWorkspace() {
        let (store, terminalID) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id
        XCTAssertEqual(store.selectedWorkspaceID, agentID)

        store.addWorkspace()

        XCTAssertNil(store.workspaces.first(where: { $0.id == agentID }))
        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertTrue(store.workspaces.contains(where: { $0.id == terminalID }))
        XCTAssertEqual(store.selectedWorkspace?.kind, .terminal)
    }

    // MARK: - activeWorkspaces excludes uncommitted

    func testActiveWorkspacesExcludesUncommitted() {
        let (store, terminalID) = makeStore()
        store.addAgentWorkspace(provider: .devin)

        let active = store.activeWorkspaces
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.id, terminalID)
    }

    // MARK: - commitAgentWorkspace

    func testCommitAgentWorkspaceMakesVisible() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id

        XCTAssertFalse(store.activeWorkspaces.contains(where: { $0.id == agentID }))

        store.commitAgentWorkspace(agentID)

        XCTAssertTrue(store.activeWorkspaces.contains(where: { $0.id == agentID }))
        XCTAssertTrue(store.workspaces.first(where: { $0.id == agentID })!.committed)
    }

    // MARK: - Auto-cleanup on workspace switch

    func testAutoCleanupOnWorkspaceSwitch() {
        let (store, terminalID) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id
        XCTAssertEqual(store.selectedWorkspaceID, agentID)

        // Switch back to the terminal workspace.
        store.selectWorkspace(terminalID)

        // The uncommitted agent workspace should be cleaned up.
        XCTAssertNil(store.workspaces.first(where: { $0.id == agentID }))
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.selectedWorkspaceID, terminalID)
    }

    func testAutoCleanupSkipsCommittedWorkspace() {
        let (store, terminalID) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id
        store.commitAgentWorkspace(agentID)

        // Switch away from the committed agent workspace.
        store.selectWorkspace(terminalID)

        // The committed workspace should survive.
        XCTAssertNotNil(store.workspaces.first(where: { $0.id == agentID }))
        XCTAssertEqual(store.workspaces.count, 2)
    }

    // MARK: - splitFocused no-op for agent workspace

    func testSplitFocusedNoOpForAgentWorkspace() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id

        let paneBefore = store.workspaces.first { $0.id == agentID }!
            .selectedTab!.root.leafCount

        store.splitFocused(.horizontal)

        let paneAfter = store.workspaces.first { $0.id == agentID }!
            .selectedTab!.root.leafCount

        XCTAssertEqual(paneBefore, 1)
        XCTAssertEqual(paneAfter, 1, "Split should be a no-op for agent workspaces")
    }

    // MARK: - newTab no-op for agent workspace

    func testNewTabNoOpForAgentWorkspace() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agentID = store.workspaces.first { $0.kind == .agent }!.id

        let tabsBefore = store.workspaces.first { $0.id == agentID }!.tabs.count

        store.newTab()

        let tabsAfter = store.workspaces.first { $0.id == agentID }!.tabs.count

        XCTAssertEqual(tabsBefore, 1)
        XCTAssertEqual(tabsAfter, 1, "New tab should be a no-op for agent workspaces")
    }

    // MARK: - liveIconKind returns .devin for agent workspace

    func testIconKindReturnsDevinForAgentWorkspace() {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)
        let agent = store.workspaces.first { $0.kind == .agent }!

        let icon = store.iconKind(for: agent)
        XCTAssertEqual(icon.letter, "D", "Agent workspace should show Devin icon")
    }

    // MARK: - persist() strips uncommitted workspaces

    func testPersistStripsUncommittedWorkspaces() throws {
        let (store, _) = makeStore()
        store.addAgentWorkspace(provider: .devin)

        // Verify there are 2 workspaces in memory (1 terminal + 1 uncommitted agent).
        XCTAssertEqual(store.workspaces.count, 2)

        // Build the PersistedState the same way persist() does.
        let committedWorkspaces = store.workspaces.filter { $0.committed }
        XCTAssertEqual(committedWorkspaces.count, 1)
        XCTAssertEqual(committedWorkspaces.first?.kind, .terminal)

        // Round-trip through JSON to verify the stripped state encodes/decodes.
        let state = PersistedState(
            workspaces: committedWorkspaces,
            selectedWorkspaceID: committedWorkspaces.first?.id,
            sidebarCollapsed: false
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.workspaces.count, 1)
        XCTAssertEqual(decoded.workspaces.first?.kind, .terminal)
        XCTAssertTrue(decoded.workspaces.first?.committed ?? false)
    }

    // MARK: - showNewWorkspacePopover

    func testShowNewWorkspacePopoverExpandsSidebar() {
        let (store, _) = makeStore()
        store.sidebarCollapsed = true

        store.showNewWorkspacePopover()

        XCTAssertFalse(store.sidebarCollapsed)
        XCTAssertTrue(store.newWorkspacePopoverOpen)
    }

    func testShowNewWorkspacePopoverSetsFlag() {
        let (store, _) = makeStore()
        store.sidebarCollapsed = false

        store.showNewWorkspacePopover()

        XCTAssertTrue(store.newWorkspacePopoverOpen)
    }
}
