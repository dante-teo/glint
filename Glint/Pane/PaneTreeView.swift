import SwiftUI
import AppKit

struct PaneTreeView: View {
    @EnvironmentObject var store: WorkspaceStore
    let node: SplitNode
    /// The workspace this tree belongs to, captured by value at render time.
    /// PaneView must NOT read `store.selectedWorkspaceID` live instead: when
    /// the selection changes, SwiftUI still evaluates the outgoing tree's
    /// PaneViews once before dismantling them, and a live read there pairs
    /// the NEW workspace ID with the OLD tree's pane IDs — minting phantom
    /// surfaces (spawning shells!) and re-parenting the new workspace's
    /// surface into a container that is about to be torn down, leaving the
    /// real pane blank.
    let workspaceID: UUID?
    /// Branch choices from the root to `node` (false = first child, true =
    /// second). Identifies this subtree to `WorkspaceStore.setSplitRatio`.
    var path: [Bool] = []
    /// Captured at the root and passed through recursion so every leaf in a
    /// nested split agrees about whether it belongs in the glass-window mode.
    var usesLiquidGlassSplitWindows: Bool? = nil

    var body: some View {
        let framed = usesLiquidGlassSplitWindows ?? WorkspaceStore.usesLiquidGlassSplitWindows(
            framedSplits: store.framedSplits,
            glassEffect: store.glassEffect,
            root: node
        )
        treeBody(framed: framed)
            .padding(path.isEmpty && framed ? SplitContainer.framedOuterPadding : 0)
            .background {
                if path.isEmpty && framed {
                    paneAreaBacking
                }
            }
    }

    private var paneAreaBacking: Color {
        Theme.bgPane.opacity(store.terminalOpacity)
    }

    @ViewBuilder
    private func treeBody(framed: Bool) -> some View {
        switch node {
        case .leaf(let id):
            if framed {
                PaneFrame(paneID: id) {
                    PaneView(workspaceID: workspaceID, paneID: id)
                }
            } else {
                PaneView(workspaceID: workspaceID, paneID: id)
            }
        case .split(let dir, let ratio, let a, let b):
            SplitContainer(direction: dir, ratio: ratio, path: path,
                           workspaceID: workspaceID, a: a, b: b,
                           usesLiquidGlassSplitWindows: framed)
        }
    }
}

/// Two child trees laid out by the split's stored ratio, separated by a 1px
/// line with an invisible 9pt drag handle floating over it. Dragging writes
/// the ratio back to the store, so it persists with the rest of the tree.
private struct SplitContainer: View {
    @EnvironmentObject var store: WorkspaceStore
    static let framedOuterPadding: CGFloat = 10

    let direction: SplitDirection
    let ratio: CGFloat
    let path: [Bool]
    let workspaceID: UUID?
    let a: SplitNode
    let b: SplitNode
    let usesLiquidGlassSplitWindows: Bool

    /// Ratio at drag start; nil when not dragging. Drag math works off this
    /// base so the divider tracks the cursor instead of compounding deltas.
    @State private var dragBaseRatio: CGFloat?
    @State private var hovering = false

    /// Don't let either side shrink below this. Roughly a minimal readable
    /// terminal strip; the ratio clamp in the store is the second guard.
    private static let defaultMinPaneLength: CGFloat = 100
    private static let framedMinPaneLength: CGFloat = 140
    private static let framedPaneSpacing: CGFloat = 10
    private static let dividerLength: CGFloat = 1

    private var isHorizontal: Bool { direction == .horizontal }
    private var minPaneLength: CGFloat {
        usesLiquidGlassSplitWindows ? Self.framedMinPaneLength : Self.defaultMinPaneLength
    }
    private var paneSpacing: CGFloat {
        usesLiquidGlassSplitWindows ? Self.framedPaneSpacing : 0
    }

    var body: some View {
        GeometryReader { geo in
            let total = isHorizontal ? geo.size.width : geo.size.height
            let firstLength = firstLength(total: total)
            let dividerPosition = firstLength + (usesLiquidGlassSplitWindows ? paneSpacing : 0)

            ZStack(alignment: .topLeading) {
                if isHorizontal {
                    HStack(spacing: paneSpacing) {
                        PaneTreeView(node: a, workspaceID: workspaceID, path: path + [false],
                                     usesLiquidGlassSplitWindows: usesLiquidGlassSplitWindows)
                            .frame(width: firstLength)
                        divider
                        PaneTreeView(node: b, workspaceID: workspaceID, path: path + [true],
                                     usesLiquidGlassSplitWindows: usesLiquidGlassSplitWindows)
                    }
                } else {
                    VStack(spacing: paneSpacing) {
                        PaneTreeView(node: a, workspaceID: workspaceID, path: path + [false],
                                     usesLiquidGlassSplitWindows: usesLiquidGlassSplitWindows)
                            .frame(height: firstLength)
                        divider
                        PaneTreeView(node: b, workspaceID: workspaceID, path: path + [true],
                                     usesLiquidGlassSplitWindows: usesLiquidGlassSplitWindows)
                    }
                }

                // The visible divider stays 1px so panes butt up against
                // each other like before; the grabbable area is this wider
                // transparent strip floating on top of the seam.
                Color.clear
                    .frame(
                        width: isHorizontal ? 9 : geo.size.width,
                        height: isHorizontal ? geo.size.height : 9
                    )
                    .contentShape(Rectangle())
                    .offset(
                        x: isHorizontal ? dividerPosition - 4 : 0,
                        y: isHorizontal ? 0 : dividerPosition - 4
                    )
                    .onHover { inside in
                        hovering = inside
                        if inside {
                            (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let base = dragBaseRatio ?? ratio
                                if dragBaseRatio == nil { dragBaseRatio = base }
                                guard total > 0 else { return }
                                let available = usesLiquidGlassSplitWindows
                                    ? max(total - (paneSpacing * 2) - Self.dividerLength, 1)
                                    : total
                                let delta = (isHorizontal ? value.translation.width : value.translation.height) / available
                                let minFraction = min(minPaneLength / available, 0.5)
                                let next = min(max(base + delta, minFraction), 1 - minFraction)
                                store.setSplitRatio(path: path, ratio: next)
                            }
                            .onEnded { _ in dragBaseRatio = nil }
                    )
            }
        }
    }

    private func firstLength(total: CGFloat) -> CGFloat {
        guard total > 1 else { return 0 }
        let available = usesLiquidGlassSplitWindows
            ? max(total - (paneSpacing * 2) - Self.dividerLength, 1)
            : total
        let minFraction = min(minPaneLength / available, 0.5)
        let clamped = min(max(ratio, minFraction), 1 - minFraction)
        // Floor to whole points so the ghostty surfaces sit on integral
        // boundaries (fractional frames cause the scroll "fault line" —
        // see NoDragContainerView in PaneSurfaceRepresentable).
        return (available * clamped).rounded(.down)
    }

    private var divider: some View {
        Rectangle()
            .fill(dividerColor)
            .frame(
                width: isHorizontal ? 1 : nil,
                height: isHorizontal ? nil : 1
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var dividerColor: Color {
        guard !usesLiquidGlassSplitWindows else {
            return hovering ? Theme.overlay(0.12) : Color.clear
        }
        return hovering ? Theme.overlay(0.18) : Theme.divider
    }
}

private struct PaneFrame<Content: View>: View {
    @EnvironmentObject var store: WorkspaceStore
    let paneID: PaneID
    @ViewBuilder var content: () -> Content

    private let cornerRadius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            PaneGlassChrome(cornerRadius: cornerRadius)
                .allowsHitTesting(false)
            content()
                .clipShape(shape)
        }
            .clipShape(shape)
            .contentShape(shape)
            .overlay(
                shape.strokeBorder(Theme.overlay(Theme.current.isDark ? 0.14 : 0.18), lineWidth: 0.75)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .top) {
                shape
                    .strokeBorder(Color.white.opacity(Theme.current.isDark ? 0.08 : 0.35), lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                PaneCloseButton {
                    store.closePane(paneID)
                }
                .padding(8)
            }
            .zIndex(1)
            .shadow(color: Color.black.opacity(Theme.current.isDark ? 0.22 : 0.10),
                    radius: 14, x: 0, y: 6)
    }
}

private struct PaneGlassChrome: View {
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .liquidGlass(enabled: true, cornerRadius: cornerRadius, tint: Theme.glassTint)
    }
}

private struct PaneCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.38, blue: 0.34))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 3, x: 0, y: 1)

                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.62))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close Pane")
        .onHover { hovering = $0 }
    }
}
