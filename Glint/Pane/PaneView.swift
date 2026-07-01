import SwiftUI

struct PaneView: View {
    @EnvironmentObject var store: WorkspaceStore
    /// Captured by value when the tree was rendered — never read live from
    /// the store here. See the comment on `PaneTreeView.workspaceID` for why
    /// (stale evaluation of the outgoing tree during a workspace switch).
    let workspaceID: UUID?
    let paneID: PaneID

    /// When the terminal is translucent every SwiftUI fill behind the surface
    /// must be clear — an opaque `Theme.bgPane` here sits *between* the alpha
    /// IOSurface and the clear window and re-opacifies the pane (the original
    /// "terminal isn't transparent" bug). At full opacity we keep bgPane as a
    /// flash guard.
    private var paneBacking: Color {
        store.isTerminalTransparent ? Color.clear : Theme.bgPane
    }

    var body: some View {
        // Resolve a surface only for a (workspace, pane) pair that exists in
        // the model. A miss means we're either mid-teardown (workspace
        // deleted, pane closed) or a stale evaluation — rendering a plain
        // background for one frame is correct there; minting a surface for a
        // synthetic key would spawn a shell that nothing ever shows again.
        if let wsID = workspaceID,
           let ws = store.workspaces.first(where: { $0.id == wsID }),
           let pane = ws.panes[paneID] {
            if ws.kind == .agent {
                AgentPlaceholderPaneView(workspace: ws)
            } else {
                paneBody(workspaceID: wsID,
                         focusedPane: ws.selectedTab?.focusedPane ?? paneID,
                         cwd: pane.workingDirectory)
            }
        } else {
            paneBacking
        }
    }

    /// Opacity for the black dim wash drawn over unfocused split panes.
    /// Extracted so unit tests can verify focused panes stay undimmed and
    /// unfocused panes receive the correct wash in both opaque and
    /// translucent modes.
    static func dimOverlayOpacity(isFocused: Bool, isTransparent: Bool) -> Double {
        isFocused ? 0 : (isTransparent ? 0.18 : 0.28)
    }

    private func paneBody(workspaceID: UUID,
                          focusedPane: PaneID,
                          cwd: String?) -> some View {
        if ProcessInfo.processInfo.environment["GLINT_LOG_VISIBLE"] != nil {
            NSLog("[glint.visible] PaneView.body pane=\(paneID.value) ws=\(workspaceID.uuidString.prefix(8))")
        }
        let isFocused = focusedPane == paneID
        return ZStack {
            paneBacking
            PaneSurfaceRepresentable(
                surfaceView: store.surfaceView(workspaceID: workspaceID, paneID: paneID, cwd: cwd),
                focused: isFocused
            )
            // Dim unfocused panes with a black wash in BOTH modes. The
            // overlay is always present (opacity 0 when focused) so its
            // Core Animation layer is part of the initial render and sits
            // above the IOSurface-backed Metal layer. A conditional `if`
            // would insert the layer AFTER the surface is composited,
            // causing it to land behind the IOSurface — leaving freshly
            // split panes undimmed even after losing focus.
            Color.black
                .opacity(Self.dimOverlayOpacity(isFocused: isFocused,
                                               isTransparent: store.isTerminalTransparent))
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // Fallback: only fires for clicks on SwiftUI-rendered areas (the
        // background fill visible during a resize). Clicks on the terminal
        // surface go through mouseDown → glintPaneFocusClicked instead.
        .onTapGesture { store.focus(paneID) }
    }
}
