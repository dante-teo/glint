import SwiftUI
import UniformTypeIdentifiers

struct AgentContextUsageFormatter {
    static func percent(for usage: DevinSessionManager.UsageInfo?) -> Double {
        guard let usage, usage.size > 0 else { return 0 }
        return min(1, max(0, Double(usage.used) / Double(usage.size)))
    }

    static func label(for usage: DevinSessionManager.UsageInfo?) -> String {
        guard let usage, usage.size > 0 else {
            return String(localized: "Context unavailable")
        }
        return String(format: "%.0f%% context", percent(for: usage) * 100)
    }

    static func tooltip(for usage: DevinSessionManager.UsageInfo?) -> String {
        guard let usage, usage.size > 0 else {
            return String(localized: "Context usage has not been reported yet.")
        }
        let used = min(usage.used, usage.size)
        let remaining = usage.size - used
        var lines = [
            String(format: String(localized: "%@ of %@ used"), formattedCount(used), formattedCount(usage.size)),
            String(format: String(localized: "%@ remaining"), formattedCount(remaining)),
            String(format: "%.0f%%", percent(for: usage) * 100)
        ]
        if let amount = usage.costAmount, let currency = usage.costCurrency {
            lines.append(String(format: String(localized: "Cost: %.4f %@"), amount, currency))
        }
        return lines.joined(separator: "\n")
    }

    private static func formattedCount(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
}

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

private extension SessionConfigOption {
    var stableID: String {
        id ?? name ?? type ?? value?.prettyPrinted ?? "unknown-config-option"
    }
}

private extension SessionModel {
    var stableID: String {
        id ?? name ?? raw?.prettyPrinted ?? "unknown-model"
    }
}

enum AgentComposerMode: Equatable {
    case agent
    case plan
}

struct AgentComposer: View {
    @EnvironmentObject private var store: WorkspaceStore
    let workspace: Workspace
    let paneID: PaneID
    @ObservedObject var manager: DevinSessionManager
    @Binding var draft: String
    @Binding var attachments: [ComposerAttachment]
    @Binding var mode: AgentComposerMode
    @Binding var pendingModeDirective: String?
    let onSend: () -> Void

    @FocusState private var isFocused: Bool
    @State private var projectError: String?
    @State private var isPickingImages = false
    @State private var showContextUsage = false
    @State private var isModeLabelHovered = false

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

            if projectError != nil || !isSessionActive {
                projectSection
            }

            // Toolbar Row
            HStack(spacing: 8) {
                plusMenu
                approvalMenu
                if mode == .plan {
                    planModeLabel
                }
                contextUsageButton
                Spacer(minLength: 8)
                modelMenu
                sendButton
            }
            .frame(minHeight: 30)
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

    // MARK: - Bottom controls
    private var plusMenu: some View {
        Menu {
            Button {
                pickImages()
            } label: {
                Label("Attach Image", systemImage: "photo")
            }
            Divider()
            Button {
                insertDraftToken("/")
            } label: {
                Label("Insert Slash Command", systemImage: "command")
            }
            Button {
                enablePlanMode()
            } label: {
                Label("Plan Mode", systemImage: "checklist")
            }
            Button {
                insertDraftToken("$")
            } label: {
                Label("Mention Skill", systemImage: "sparkle.magnifyingglass")
            }
        } label: {
            controlIcon("plus")
        }
        .menuStyle(.borderlessButton)
        .help("Add content or commands")
    }

    private var approvalMenu: some View {
        Menu {
            ForEach(PermissionReviewMode.allCases, id: \.self) { mode in
                Button {
                    store.permissionReviewMode = mode
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(mode.title)
                            Text(mode.subtitle)
                                .font(.caption)
                        }
                        if store.permissionReviewMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            controlPill(icon: approvalIcon, title: store.permissionReviewMode.title, maxWidth: 116)
        }
        .menuStyle(.borderlessButton)
        .help(store.permissionReviewMode.subtitle)
    }

    private var planModeLabel: some View {
        HStack(spacing: 6) {
            Divider()
                .frame(height: 22)
                .overlay(Theme.overlay(0.12))
                .padding(.trailing, 2)

            Image(systemName: "checklist")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text4)
            Text("Plan")
                .font(AppFonts.ui(12, weight: .medium))
                .foregroundStyle(Theme.text3)

            Button {
                exitPlanMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text4)
            .opacity(isModeLabelHovered ? 1 : 0)
            .help("Exit plan mode")
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .onHover { isModeLabelHovered = $0 }
        .help("Plan mode will be sent with your next message.")
    }

    private var approvalIcon: String {
        switch store.permissionReviewMode {
        case .manual:
            return "hand.raised"
        case .autoReview:
            return "checkmark.shield"
        case .alwaysAllow:
            return "checkmark.seal"
        }
    }

    private var contextUsageButton: some View {
        Button {} label: {
            ZStack {
                Circle()
                    .stroke(Theme.overlay(0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: AgentContextUsageFormatter.percent(for: manager.usageInfo))
                    .stroke(Theme.accentBright, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "circle.dashed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            showContextUsage = hovering
        }
        .popover(isPresented: $showContextUsage, arrowEdge: .bottom) {
            contextUsagePopover
        }
        .help(AgentContextUsageFormatter.tooltip(for: manager.usageInfo))
        .accessibilityLabel(AgentContextUsageFormatter.label(for: manager.usageInfo))
    }

    private var contextUsagePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Context Window")
                .font(AppFonts.ui(12, weight: .semibold))
                .foregroundStyle(Theme.text1)
            Text(AgentContextUsageFormatter.tooltip(for: manager.usageInfo))
                .font(AppFonts.ui(11.5))
                .foregroundStyle(Theme.text3)
                .lineSpacing(3)
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
    }

    private var modelMenu: some View {
        Menu {
            if manager.models.isEmpty {
                Text("No models reported")
            } else {
                Section("Model") {
                    ForEach(modelMenuModels, id: \.stableID) { model in
                        Button {} label: {
                            HStack {
                                Text(model.name ?? model.id ?? "Model")
                                if isCurrentModel(model) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(true)
                    }
                }
            }

            if !reasoningOptions.isEmpty {
                Section("Reasoning Effort") {
                    ForEach(reasoningOptions, id: \.stableID) { option in
                        Button(reasoningLabel(for: option)) {}
                            .disabled(true)
                    }
                }
            }

            Divider()
            Text("Devin did not expose model switching for this session.")
        } label: {
            controlPill(icon: "cpu", title: modelMenuLabel, maxWidth: 150)
        }
        .menuStyle(.borderlessButton)
        .help("Model and reasoning are read-only until Devin exposes a supported switcher.")
    }

    private var modelMenuLabel: String {
        if let modelName = manager.currentModel?.name ?? manager.currentModel?.id {
            return modelName
        }
        return manager.models.first?.name ?? manager.models.first?.id ?? String(localized: "Model")
    }

    private var modelMenuModels: [SessionModel] {
        if let current = manager.currentModel,
           !manager.models.contains(where: { ($0.id ?? $0.name) == (current.id ?? current.name) }) {
            return [current] + manager.models
        }
        return manager.models
    }

    private var reasoningOptions: [SessionConfigOption] {
        manager.configOptions.filter { option in
            let key = [option.id, option.name, option.type]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return (key.contains("reasoning") || key.contains("effort")) && !key.contains("speed")
        }
    }

    private func reasoningLabel(for option: SessionConfigOption) -> String {
        let name = option.name ?? option.id ?? String(localized: "Reasoning")
        guard let value = option.value else { return name }
        return "\(name): \(value.stringValue ?? value.prettyPrinted)"
    }

    private func isCurrentModel(_ model: SessionModel) -> Bool {
        guard let current = manager.currentModel else { return false }
        return (model.id ?? model.name) == (current.id ?? current.name)
    }

    private func insertDraftToken(_ token: String) {
        if draft.isEmpty || draft.last?.isWhitespace == true {
            draft += token
        } else {
            draft += " \(token)"
        }
        isFocused = true
    }

    private func enablePlanMode() {
        mode = .plan
        pendingModeDirective = "/plan"
        isFocused = true
    }

    private func exitPlanMode() {
        mode = .agent
        pendingModeDirective = pendingModeDirective == "/plan" ? nil : "/agent"
        isModeLabelHovered = false
        isFocused = true
    }

    private func controlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.text3)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.overlay(0.05)))
    }

    private func controlPill(icon: String, title: String, maxWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
            Text(title)
                .font(AppFonts.ui(11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.text4)
        }
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 9)
        .frame(maxWidth: maxWidth, minHeight: 28, maxHeight: 28, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.overlay(0.05))
        )
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
            manager.status.isBusy ? manager.cancelTurn() : onSend()
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
