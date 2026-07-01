import SwiftUI

struct AgentComposer: View {
    @EnvironmentObject private var store: WorkspaceStore
    let workspace: Workspace
    let paneID: PaneID
    @ObservedObject var manager: DevinSessionManager
    @Binding var draft: String
    let onSend: () -> Void

    @FocusState private var isFocused: Bool
    @State private var projectError: String?

    private var projectPath: String? {
        workspace.agentProjectPath
    }

    private var projectIsValid: Bool {
        store.isValidAgentProjectPath(projectPath)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSessionActive: Bool {
        manager.sessionID != nil
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty && projectIsValid && !manager.status.isBusy &&
        manager.pendingPermission == nil && manager.pendingElicitation == nil
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
        VStack(alignment: .leading, spacing: 8) {
            // Text Editor Container
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.overlay(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Theme.overlay(isFocused ? 0.22 : 0.10), lineWidth: 1)
                    )

                TextEditor(text: $draft)
                    .font(AppFonts.ui(14))
                    .foregroundStyle(Theme.text1)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44, maxHeight: 120)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return, press.modifiers.contains(.command) else {
                            return .ignored
                        }
                        if canSend {
                            onSend()
                            return .handled
                        }
                        return .ignored
                    }

                if draft.isEmpty {
                    Text("Ask Codex Anything...")
                        .font(AppFonts.ui(14))
                        .foregroundStyle(Theme.text4)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }

            // Toolbar Row
            HStack(spacing: 12) {
                // Attach button icon placeholder
                Button {
                    // Placeholder for future attachment logic
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(Theme.overlay(0.05))
                        )
                }
                .buttonStyle(.plain)

                // Model dropdown selector
                modelMenu

                // Mode pill selector
                modeMenu

                Spacer()

                // Project display / selection dropdown
                projectSection

                // Send or Stop Button
                sendButton
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 2)
        .onAppear {
            isFocused = true
            validateProject()
        }
        .onChange(of: workspace.agentProjectPath) { _, _ in
            validateProject()
        }
        .onChange(of: manager.status) { _, status in
            if !status.isBusy && manager.pendingPermission == nil && manager.pendingElicitation == nil {
                // Regain focus when idle and overlays clear
                isFocused = true
            }
        }
    }

    private var modelMenu: some View {
        Group {
            if isSessionActive && !manager.models.isEmpty {
                Menu {
                    ForEach(manager.models, id: \.id) { model in
                        Button {
                            // Selected model (future ACP endpoint for model select can go here)
                        } label: {
                            HStack {
                                Text(model.name ?? model.id ?? "Unknown model")
                                if manager.currentModel?.id == model.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(manager.currentModel?.name ?? manager.currentModel?.id ?? "GPT-5.3-Codex")
                            .font(AppFonts.ui(12, weight: .medium))
                            .foregroundStyle(Theme.text3)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.text4)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.overlay(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 130, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    Text("GPT-5.3-Codex")
                        .font(AppFonts.ui(12, weight: .medium))
                        .foregroundStyle(Theme.text3)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text4)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.overlay(0.05))
                )
                .opacity(0.6)
            }
        }
    }

    private var modeMenu: some View {
        Group {
            if isSessionActive && !manager.modes.isEmpty {
                Menu {
                    ForEach(manager.modes, id: \.id) { mode in
                        Button {
                            // Mode switch placeholder
                        } label: {
                            HStack {
                                Text(mode.name ?? mode.id)
                                if manager.currentMode == mode.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentModeLabel)
                            .font(AppFonts.ui(12, weight: .medium))
                            .foregroundStyle(Theme.text3)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.text4)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.overlay(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    Text("Extra high")
                        .font(AppFonts.ui(12, weight: .medium))
                        .foregroundStyle(Theme.text3)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text4)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.overlay(0.05))
                )
                .opacity(0.6)
            }
        }
    }

    private var currentModeLabel: String {
        if let currentMode = manager.currentMode,
           let mode = manager.modes.first(where: { $0.id == currentMode }) {
            return mode.name ?? mode.id
        }
        return "Extra high"
    }

    private var projectSection: some View {
        HStack(spacing: 8) {
            if let projectError {
                Text(projectError)
                    .font(AppFonts.ui(11))
                    .foregroundStyle(Theme.orange)
                    .lineLimit(1)
            }

            if isSessionActive {
                // Project is locked once session is running
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.text3)
                    Text(projectLabel(for: projectPath ?? ""))
                        .font(AppFonts.ui(11.5, weight: .medium))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Dimmed indicator that we are locked
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.text4)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            } else {
                // Selection dropdown
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
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                        Text(projectPath.map(projectLabel(for:)) ?? String(localized: "Choose folder"))
                            .font(AppFonts.ui(11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.text4)
                    }
                    .foregroundStyle(projectIsValid ? Theme.text2 : Theme.text3)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.overlay(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 180, alignment: .trailing)
            }
        }
    }

    private var sendButton: some View {
        Button {
            manager.status.isBusy ? manager.stop() : onSend()
        } label: {
            Image(systemName: manager.status.isBusy ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(manager.status.isBusy || canSend ? Theme.bgPane : Theme.text4)
        .background(
            Circle()
                .fill(manager.status.isBusy || canSend ? Theme.text1 : Theme.overlay(0.08))
        )
        .disabled(!manager.status.isBusy && !canSend)
        .help(manager.status.isBusy ? "Stop Devin" : "Send")
    }

    private func projectLabel(for path: String) -> String {
        WorkspaceStore.agentProjectDisplayName(for: path) ?? String(localized: "Devin Agent")
    }

    private func chooseProject(_ path: String) {
        if store.setAgentProjectPath(workspaceID: workspace.id, path: path) {
            projectError = nil
        } else {
            projectError = String(localized: "Folder is missing.")
        }
    }

    private func chooseFolder() {
        Task { @MainActor in
            guard let folder = await FolderPicker.pickProjectFolder() else { return }
            chooseProject(folder.path)
        }
    }

    private func validateProject() {
        if projectPath == nil {
            projectError = String(localized: "Choose a folder.")
        } else if !projectIsValid {
            projectError = String(localized: "Folder is unavailable.")
        } else {
            projectError = nil
        }
    }
}
