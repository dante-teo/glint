import Foundation

/// Shared deterministic subsequence matcher for command and workspace search.
/// Inputs are expected to be lowercased by the caller.
enum FuzzyMatcher {
    static func score(needle: String, haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let needle = Array(needle)
        let haystack = Array(haystack)
        var score = 0
        var needleIndex = 0
        var lastMatch = -2
        for (index, character) in haystack.enumerated() {
            guard needleIndex < needle.count, character == needle[needleIndex] else { continue }
            if index == 0 { score += 20 }
            else if index == lastMatch + 1 { score += 10 }
            else if !haystack[index - 1].isLetter && !haystack[index - 1].isNumber { score += 15 }
            else { score += 1 }
            lastMatch = index
            needleIndex += 1
        }
        guard needleIndex == needle.count else { return nil }
        if String(haystack).hasPrefix(String(needle)) { score += 100 }
        return score
    }
}

enum AppCommandID: String, CaseIterable, Hashable {
    case newWorkspace
    case nextWorkspace
    case previousWorkspace
    case newTab
    case closeTab
    case nextTab
    case previousTab
    case splitRight
    case splitDown
    case closePane
    case focusNextPane
    case focusPreviousPane
    case toggleSidebar
    case showActivity
    case findInSidebar
    case settings
}

/// Immutable presentation and search metadata shared by menus and palettes.
struct AppCommand: Equatable, Identifiable {
    var id: AppCommandID
    var title: String
    var subtitle: String
    var symbol: String
    var shortcut: String
    var aliases: [String]
}

enum AppCommandRegistry {
    static let commands: [AppCommand] = [
        command(.newWorkspace, "New Workspace", "Create a fresh workspace", "plus.square", "⌘N", ["project"]),
        command(.nextWorkspace, "Next Workspace", "Select the next workspace", "chevron.down", "⌘⇧]", ["switch workspace"]),
        command(.previousWorkspace, "Previous Workspace", "Select the previous workspace", "chevron.up", "⌘⇧[", ["switch workspace"]),
        command(.newTab, "New Tab", "Open a tab in this workspace", "plus.rectangle.on.rectangle", "⌘T", ["create tab"]),
        command(.closeTab, "Close Tab", "Close the current tab", "xmark.rectangle", "⌘⇧W", ["remove tab"]),
        command(.nextTab, "Next Tab", "Select the next tab", "arrow.right.to.line", "⌃Tab", ["switch tab"]),
        command(.previousTab, "Previous Tab", "Select the previous tab", "arrow.left.to.line", "⌃⇧Tab", ["switch tab"]),
        command(.splitRight, "Split Right", "Open a new pane on the right", "rectangle.split.2x1", "⌘D", ["horizontal split"]),
        command(.splitDown, "Split Down", "Stack a new pane below", "rectangle.split.1x2", "⌘⇧D", ["vertical split"]),
        command(.closePane, "Close Pane", "Close the focused pane", "xmark.square", "⌘W", ["remove split"]),
        command(.focusNextPane, "Focus Next Pane", "Cycle pane focus forward", "arrow.triangle.2.circlepath", "⌘]", ["next split"]),
        command(.focusPreviousPane, "Focus Previous Pane", "Cycle pane focus backward", "arrow.triangle.2.circlepath", "⌘[", ["previous split"]),
        command(.toggleSidebar, "Toggle Sidebar", "Show or hide the workspace sidebar", "sidebar.left", "⌘/", ["navigation"]),
        command(.showActivity, "Show Agent Activity", "Open the cross-workspace activity queue", "waveform.path.ecg", "", ["agents", "approvals", "running"]),
        command(.findInSidebar, "Find in Sidebar", "Search workspaces", "magnifyingglass", "⌘⌥F", ["search workspace"]),
        command(.settings, "Settings", "Open Glint settings", "gearshape", "⌘,", ["preferences", "configuration"]),
    ]

    static func command(_ id: AppCommandID) -> AppCommand {
        commands.first { $0.id == id }!
    }

    static func ranked(query: String) -> [AppCommand] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return commands }
        return commands.enumerated()
            .compactMap { index, command in
                relevance(command, query: needle).map { (index, command, $0) }
            }
            .sorted {
                if $0.2 != $1.2 { return $0.2 > $1.2 }
                return $0.0 < $1.0
            }
            .map(\.1)
    }

    @MainActor
    static func execute(_ id: AppCommandID, in store: WorkspaceStore) {
        switch id {
        case .newWorkspace: store.addWorkspace()
        case .nextWorkspace: store.selectNextWorkspace()
        case .previousWorkspace: store.selectPreviousWorkspace()
        case .newTab: store.newTab()
        case .closeTab:
            if let workspace = store.selectedWorkspace {
                store.closeTab(workspace.selectedTabID)
            }
        case .nextTab: store.nextTab()
        case .previousTab: store.previousTab()
        case .splitRight: store.splitFocused(.horizontal)
        case .splitDown: store.splitFocused(.vertical)
        case .closePane: store.closeFocused()
        case .focusNextPane: store.focusNext()
        case .focusPreviousPane: store.focusPrevious()
        case .toggleSidebar: store.sidebarCollapsed.toggle()
        case .showActivity: store.showAgentActivity()
        case .findInSidebar: store.focusSidebarSearch()
        case .settings: store.settingsOpen = true
        }
    }

    private static func command(
        _ id: AppCommandID,
        _ title: String,
        _ subtitle: String,
        _ symbol: String,
        _ shortcut: String,
        _ aliases: [String]
    ) -> AppCommand {
        AppCommand(
            id: id,
            title: title,
            subtitle: subtitle,
            symbol: symbol,
            shortcut: shortcut,
            aliases: aliases
        )
    }

    private static func relevance(_ command: AppCommand, query: String) -> Int? {
        if let title = FuzzyMatcher.score(needle: query, haystack: command.title.lowercased()) {
            return title + 2_000
        }
        if let subtitle = FuzzyMatcher.score(needle: query, haystack: command.subtitle.lowercased()) {
            return subtitle + 1_000
        }
        return command.aliases.compactMap {
            FuzzyMatcher.score(needle: query, haystack: $0.lowercased())
        }.max()
    }
}
