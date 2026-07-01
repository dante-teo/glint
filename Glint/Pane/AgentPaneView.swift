import SwiftUI

struct AgentPaneView: View {
    @EnvironmentObject private var store: WorkspaceStore
    let workspace: Workspace
    let paneID: PaneID

    var body: some View {
        AgentPaneContent(
            workspace: workspace,
            paneID: paneID,
            manager: store.agentSession(workspaceID: workspace.id, paneID: paneID)
        )
        .environmentObject(store)
    }
}

private struct AgentPaneContent: View {
    @EnvironmentObject private var store: WorkspaceStore
    let workspace: Workspace
    let paneID: PaneID
    @ObservedObject var manager: DevinSessionManager
    @State private var draft = ""
    @State private var projectError: String?
    @FocusState private var composerFocused: Bool

    private var projectPath: String? {
        workspace.agentProjectPath
    }

    private var projectIsValid: Bool {
        store.isValidAgentProjectPath(projectPath)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && projectIsValid && !manager.status.isBusy
    }

    private var projectOptions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        if let projectPath,
           let standardized = WorkspaceStore.standardizedAgentProjectPath(projectPath) {
            seen.insert(standardized)
            out.append(standardized)
        }
        for path in store.recentAgentProjectPaths(excluding: workspace.id) where !seen.contains(path) {
            seen.insert(path)
            out.append(path)
        }
        return out
    }

    var body: some View {
        ZStack {
            Theme.bgPane
            VStack(spacing: 0) {
                header
                messageList
                composer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .onAppear {
            if projectPath == nil {
                projectError = String(localized: "Choose a project folder before sending.")
            } else if !projectIsValid {
                projectError = String(localized: "Project folder is missing or unavailable.")
            }
        }
        .onChange(of: workspace.agentProjectPath) { _, _ in
            projectError = projectIsValid ? nil : String(localized: "Project folder is missing or unavailable.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("DevinMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .shadow(color: Color(red: 0.16, green: 0.43, blue: 0.81).opacity(0.45),
                        radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.displayName)
                    .font(AppFonts.ui(15, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText)
                    .font(AppFonts.ui(11))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.bottom, 18)
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if manager.messages.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.messages) { message in
                        AgentMessageRow(message: message)
                    }
                }
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Start a Devin session")
                .font(AppFonts.ui(20, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text("Pick the project below, then send your first message.")
                .font(AppFonts.ui(13))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.overlay(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.overlay(composerFocused ? 0.22 : 0.12), lineWidth: 1)
                    )
                TextEditor(text: $draft)
                    .font(AppFonts.ui(14))
                    .foregroundStyle(Theme.text1)
                    .scrollContentBackground(.hidden)
                    .focused($composerFocused)
                    .padding(8)
                    .frame(minHeight: 86, maxHeight: 130)
                    .onSubmit { send() }
                if draft.isEmpty {
                    Text("Message Devin...")
                        .font(AppFonts.ui(14))
                        .foregroundStyle(Theme.text4)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 10) {
                projectMenu
                if let projectError {
                    Text(projectError)
                        .font(AppFonts.ui(11))
                        .foregroundStyle(Color(red: 1.0, green: 0.63, blue: 0.36))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    manager.status.isBusy ? manager.stop() : send()
                } label: {
                    Image(systemName: manager.status.isBusy ? "stop.fill" : "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(manager.status.isBusy || canSend ? Theme.bgPane : Theme.text4)
                .background(
                    Circle()
                        .fill(manager.status.isBusy || canSend ? Theme.text1 : Theme.overlay(0.14))
                )
                .disabled(!manager.status.isBusy && !canSend)
                .help(manager.status.isBusy ? "Stop Devin" : "Send")
            }
        }
        .frame(maxWidth: 780)
        .padding(.top, 12)
    }

    private var projectMenu: some View {
        Menu {
            ForEach(projectOptions, id: \.self) { path in
                Button {
                    chooseProject(path)
                } label: {
                    Text(projectLabel(for: path))
                }
            }
            if !projectOptions.isEmpty {
                Divider()
            }
            Button("Choose Folder...") {
                chooseFolder()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .semibold))
                Text(projectPath.map(projectLabel(for:)) ?? String(localized: "Choose project"))
                    .font(AppFonts.ui(12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.text4)
            }
            .foregroundStyle(projectIsValid ? Theme.text2 : Theme.text3)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.overlay(0.08))
            )
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 260, alignment: .leading)
    }

    private var statusText: String {
        switch manager.status {
        case .idle:
            return projectPath ?? String(localized: "Choose a project to begin")
        case .starting:
            return String(localized: "Starting Devin...")
        case .thinking:
            return String(localized: "Devin is working...")
        case .tool:
            return String(localized: "Devin is using a tool...")
        case .needsPermission:
            return String(localized: "Devin needs permission")
        case .cancelling:
            return String(localized: "Cancelling Devin...")
        case .failed:
            return String(localized: "Session error")
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .failed:
            return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .starting, .thinking, .tool, .needsPermission, .cancelling:
            return store.accent
        case .idle:
            return Theme.text3
        }
    }

    private func projectLabel(for path: String) -> String {
        WorkspaceStore.agentProjectDisplayName(for: path) ?? String(localized: "Devin Agent")
    }

    private func chooseProject(_ path: String) {
        if store.setAgentProjectPath(workspaceID: workspace.id, path: path) {
            projectError = nil
        } else {
            projectError = String(localized: "Project folder is missing or unavailable.")
        }
    }

    private func chooseFolder() {
        Task { @MainActor in
            guard let folder = await FolderPicker.pickProjectFolder() else { return }
            chooseProject(folder.path)
        }
    }

    private func send() {
        guard !trimmedDraft.isEmpty else { return }
        guard let projectPath,
              store.setAgentProjectPath(workspaceID: workspace.id, path: projectPath),
              let standardized = WorkspaceStore.standardizedAgentProjectPath(projectPath) else {
            projectError = String(localized: "Choose a valid project folder before sending.")
            return
        }
        projectError = nil
        store.commitAgentWorkspace(workspace.id)
        manager.sendFirstPrompt(text: trimmedDraft, projectPath: standardized)
        draft = ""
    }
}

private struct AgentMessageRow: View {
    let message: DevinSessionManager.Message

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }
            Text(message.text)
                .font(AppFonts.ui(13))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(background)
                )
            if message.role != .user { Spacer(minLength: 80) }
        }
    }

    private var background: Color {
        switch message.role {
        case .user:
            return Theme.overlay(0.18)
        case .assistant, .thought:
            return Theme.overlay(0.10)
        case .toolCall:
            return Theme.overlay(0.12)
        case .system:
            return Color(red: 1.0, green: 0.45, blue: 0.45).opacity(0.14)
        }
    }
}
