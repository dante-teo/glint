import Foundation

enum SidebarMode: String, CaseIterable, Identifiable {
    case workspaces
    case activity

    var id: String { rawValue }
}

struct AgentActivityItem: Identifiable, Equatable {
    let workspaceID: UUID
    let workspaceName: String
    let tabID: TabID
    let tabName: String
    let paneID: PaneID
    let paneNumber: Int
    let kind: PaneAgentKind
    let status: PaneAgentStatus
    let detail: String?
    let since: Date
    let updatedAt: Date
    let sessionID: String?
    let capabilities: Set<AgentCapability>

    var id: String { "\(workspaceID.uuidString):\(paneID.value)" }
}

/// Pure projection from workspace + transient agent state into the global
/// Activity queue. The priority order is part of the product behavior, not a
/// view concern, so every consumer sees the same deterministic ordering.
enum AgentActivityPresentation {
    static func items(
        workspaces: [Workspace],
        states: [WorkspaceStore.WorkspacePaneKey: PaneAgentState]
    ) -> [AgentActivityItem] {
        workspaces.flatMap { workspace in
            workspace.tabs.flatMap { tab in
                tab.root.leaves.enumerated().compactMap { index, paneID in
                    let key = WorkspaceStore.WorkspacePaneKey(
                        workspace: workspace.id,
                        pane: paneID
                    )
                    guard let state = states[key], state.status != .idle else { return nil }
                    return AgentActivityItem(
                        workspaceID: workspace.id,
                        workspaceName: workspace.displayName,
                        tabID: tab.id,
                        tabName: workspace.tabDisplayName(tab),
                        paneID: paneID,
                        paneNumber: index + 1,
                        kind: state.kind,
                        status: state.status,
                        detail: state.detail,
                        since: state.turnStartedAt,
                        updatedAt: state.updatedAt,
                        sessionID: state.sessionID,
                        capabilities: state.capabilities
                    )
                }
            }
        }
        .sorted {
            let lhsRank = $0.status.attentionRank
            let rhsRank = $1.status.attentionRank
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

}

extension WorkspaceStore {
    var agentActivityItems: [AgentActivityItem] {
        AgentActivityPresentation.items(
            workspaces: workspaces,
            states: paneAgentState
        )
    }
}
