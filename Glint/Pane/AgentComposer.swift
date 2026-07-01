import SwiftUI
import UniformTypeIdentifiers

/// A single image the user has attached in the composer, pending send.
/// Distinct from `DevinSessionManager.ImageAttachment`: this one keeps an
/// `NSImage` thumbnail for the UI alongside the base64 payload that
/// actually gets sent.
struct ComposerAttachment: Identifiable, Equatable {
    let id = UUID()
    let thumbnail: NSImage
    let base64Data: String
    let mimeType: String
    let filename: String

    static func == (lhs: ComposerAttachment, rhs: ComposerAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

struct AgentComposer: View {
    @EnvironmentObject private var store: WorkspaceStore
    let workspace: Workspace
    let paneID: PaneID
    @ObservedObject var manager: DevinSessionManager
    @Binding var draft: String
    @Binding var attachments: [ComposerAttachment]
    let onSend: () -> Void

    @FocusState private var isFocused: Bool
    @State private var projectError: String?
    @State private var isPickingImages = false

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
        (!trimmedDraft.isEmpty || !attachments.isEmpty) && projectIsValid && !manager.status.isBusy &&
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
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                attachmentsRow
            }

            // Text Editor
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(AppFonts.ui(14))
                    .foregroundStyle(Theme.text1)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: 40, maxHeight: 140)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return, !press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        if canSend {
                            onSend()
                            return .handled
                        }
                        return .ignored
                    }

                if draft.isEmpty {
                    Text("Ask Devin Anything...")
                        .font(AppFonts.ui(14))
                        .foregroundStyle(Theme.text4)
                        // Matches the TextEditor's own padding, plus the ~5pt
                        // leading inset NSTextView's line fragment padding
                        // adds internally (a well-known SwiftUI TextEditor
                        // quirk) so the placeholder lines up with real text.
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            // Toolbar Row
            HStack(spacing: 12) {
                Button {
                    pickImages()
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
                .help("Attach images")

                modelBadge

                modeMenu

                Spacer()

                projectSection

                sendButton
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.overlay(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.overlay(isFocused ? 0.22 : 0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 20, y: 8)
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

    // MARK: - Attachments
    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: attachment.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Theme.overlay(0.15), lineWidth: 1)
                            )

                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white, Color.black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func pickImages() {
        guard !isPickingImages else { return }
        isPickingImages = true
        Task { @MainActor in
            defer { isPickingImages = false }
            let urls = await ImagePicker.pickImages()
            for url in urls {
                if let attachment = Self.loadAttachment(from: url) {
                    attachments.append(attachment)
                }
            }
        }
    }

    private static func loadAttachment(from url: URL) -> ComposerAttachment? {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return ComposerAttachment(
            thumbnail: image,
            base64Data: data.base64EncodedString(),
            mimeType: mimeType,
            filename: url.lastPathComponent
        )
    }

    // MARK: - Model (informational only)
    // There's no confirmed ACP v1 method for the client to request a model
    // change (only inbound notifications telling us the agent's current
    // model), so this is a plain, non-interactive badge rather than a
    // dropdown that would silently do nothing when tapped.
    private var modelBadge: some View {
        Group {
            if let modelName = manager.currentModel?.name ?? manager.currentModel?.id {
                Text(modelName)
                    .font(AppFonts.ui(12, weight: .medium))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.overlay(0.05))
                    )
            }
        }
    }

    private var modeMenu: some View {
        Group {
            if isSessionActive && !manager.modes.isEmpty {
                Menu {
                    ForEach(manager.modes, id: \.id) { mode in
                        Button {
                            manager.selectMode(mode.id)
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
            }
        }
    }

    private var currentModeLabel: String {
        if let currentMode = manager.currentMode,
           let mode = manager.modes.first(where: { $0.id == currentMode }) {
            return mode.name ?? mode.id
        }
        return manager.modes.first?.name ?? String(localized: "Mode")
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
