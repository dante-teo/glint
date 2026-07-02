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
        id ?? name ?? type ?? resolvedCurrentValue?.prettyPrinted ?? "unknown-config-option"
    }
}

private extension SessionConfigOptionValue {
    var stableID: String {
        value?.stringValue ?? name ?? value?.prettyPrinted ?? "unknown-config-option-value"
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
    @State private var isPickingImages = false
    @State private var showContextUsage = false
    @State private var isModeLabelHovered = false
    @State private var editorHeight: CGFloat = AgentComposer.minEditorHeight

    // Two lines at the composer's 14pt font plus its 8pt top/bottom padding,
    // and a generous cap so a long paste doesn't swallow the whole pane.
    // Kept as named constants (rather than inlined into `.frame`) so the
    // clamping math below is unit-testable without a live view hierarchy.
    static let minEditorHeight: CGFloat = 52
    static let maxEditorHeight: CGFloat = 140

    // The floating card's own max width. `AgentPaneView.messageListSection`
    // caps message bubbles to this same width so they never extend past
    // the composer's edges — keep both call sites on this shared constant
    // rather than duplicating the literal, or the two can silently drift
    // apart and reintroduce that overlap.
    static let maxWidth: CGFloat = 760

    /// Clamps a measured text height into the editor's allowed range.
    /// Pure so it can be exercised directly in tests.
    static func clampedEditorHeight(
        for measuredHeight: CGFloat,
        min minHeight: CGFloat = AgentComposer.minEditorHeight,
        max maxHeight: CGFloat = AgentComposer.maxEditorHeight
    ) -> CGFloat {
        Swift.min(Swift.max(measuredHeight, minHeight), maxHeight)
    }

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
            // Height is measured from the actual draft content (via the
            // hidden mirror `Text` below) and clamped to [minEditorHeight,
            // maxEditorHeight], so the card starts at a real two-line
            // minimum and grows only as far as the text needs — rather than
            // sitting at a fixed height regardless of content.
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(AppFonts.ui(14))
                    .foregroundStyle(Theme.text1)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(height: editorHeight)
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

                // Invisible mirror of the draft, laid out with the same
                // font/padding as the TextEditor, used purely to measure how
                // tall the real content wants to be at the current width.
                // `.fixedSize(vertical: true)` makes it report its true,
                // unbounded ideal height, and a ZStack's own size is the
                // union of all its children's sizes — so without the
                // `.frame(maxHeight:)` cap below, a long paste would balloon
                // this hidden sibling (and therefore the whole card) far
                // past `maxEditorHeight`, even though the *visible*
                // TextEditor stays correctly capped via `editorHeight`. The
                // cap is applied after the `GeometryReader` background so
                // the preference still reports the true, uncapped height.
                Text(draft.isEmpty ? " " : draft)
                    .font(AppFonts.ui(14))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: ComposerTextHeightPreferenceKey.self, value: geo.size.height)
                        }
                    )
                    .frame(maxHeight: AgentComposer.maxEditorHeight, alignment: .top)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
            .onPreferenceChange(ComposerTextHeightPreferenceKey.self) { measuredHeight in
                let target = Self.clampedEditorHeight(for: measuredHeight)
                if abs(target - editorHeight) > 0.5 {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editorHeight = target
                    }
                }
            }

            // Toolbar Row: a plain HStack, left to right, each control
            // sized to its own content. The only flexible space is the
            // `Spacer` below, which pushes the context-usage indicator and
            // send button to the trailing edge.
            HStack(spacing: 6) {
                plusMenu
                if !projectIsValid || !isSessionActive {
                    projectSection
                }
                modelMenu
                approvalMenu
                if mode == .plan {
                    planModeLabel
                }
                Spacer(minLength: 8)
                contextUsageButton
                sendButton
            }
            .frame(minHeight: 30)
        }
        .padding(12)
        // A flat, near-transparent fill (previously `Theme.overlay(0.06)` —
        // 6% white/black tint, no real blur) let message text bleed
        // straight through the card on any layout hiccup (e.g. a same-tick
        // resize/scroll settling a frame late), reading as a broken overlap
        // rather than a floating card. Give it a genuine
        // `NSVisualEffectView` blur — via the same `liquidGlass` treatment
        // the command palette and toolbar islands use — so the card is
        // always opaque enough to fully occlude whatever's behind it,
        // whether or not Liquid Glass itself is enabled.
        .liquidGlass(enabled: store.glassEffect, cornerRadius: 16, tint: Theme.glassTint) {
            ZStack {
                VisualEffectBackground(material: .menu)
                Theme.overlay(0.06)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.overlay(isFocused ? 0.22 : 0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 20, y: 8)
        .onAppear {
            isFocused = true
            connectIfNeeded()
        }
        .onChange(of: workspace.agentProjectPath) { _, _ in
            connectIfNeeded()
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
        .fixedSize()
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
            controlPill(icon: approvalIcon, title: store.permissionReviewMode.title)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
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

    /// The live model selector, exposed by Devin (and any other ACP v1
    /// provider following the current spec) as a `SessionConfigOption`
    /// with `category == "model"` — see `agentclientprotocol.com/protocol/
    /// v1/session-config-options`. This supersedes the older unstable
    /// `models`/`currentModel` fields, which Devin's ACP server no longer
    /// populates.
    private var modelConfigOption: SessionConfigOption? {
        manager.configOptions.first { $0.category == "model" }
    }

    private var modelMenu: some View {
        Menu {
            if let option = modelConfigOption, let choices = option.options, !choices.isEmpty {
                Section("Model") {
                    ForEach(choices, id: \.stableID) { choice in
                        Button {
                            select(choice, in: option)
                        } label: {
                            HStack {
                                Text(choice.name ?? choice.value?.stringValue ?? "Model")
                                if isCurrentChoice(choice, in: option) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } else if manager.models.isEmpty {
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
                Divider()
                Text("Devin did not expose model switching for this session.")
            }

            if !reasoningOptions.isEmpty {
                Section("Reasoning Effort") {
                    ForEach(reasoningOptions, id: \.stableID) { option in
                        if let choices = option.options, !choices.isEmpty {
                            ForEach(choices, id: \.stableID) { choice in
                                Button {
                                    select(choice, in: option)
                                } label: {
                                    HStack {
                                        Text(choice.name ?? choice.value?.stringValue ?? "Reasoning")
                                        if isCurrentChoice(choice, in: option) {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } else {
                            Button(reasoningLabel(for: option)) {}
                                .disabled(true)
                        }
                    }
                }
            }
        } label: {
            controlPill(icon: "cpu", title: modelMenuLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(modelConfigOption != nil
            ? String(localized: "Change the model used for this session.")
            : String(localized: "Model and reasoning are read-only until Devin exposes a supported switcher."))
    }

    private var modelMenuLabel: String {
        if let option = modelConfigOption {
            let currentValue = option.resolvedCurrentValue?.stringValue
            if let match = option.options?.first(where: { $0.value?.stringValue == currentValue }) {
                return match.name ?? currentValue ?? String(localized: "Model")
            }
            if let currentValue { return currentValue }
        }
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

    /// Devin's ACP server tags its reasoning-effort selector with
    /// `category == "thought_level"` per the current spec. Older/other
    /// providers that only send a bare `name`/`id` are matched by
    /// substring as a fallback.
    private var reasoningOptions: [SessionConfigOption] {
        let byCategory = manager.configOptions.filter { $0.category == "thought_level" }
        if !byCategory.isEmpty { return byCategory }
        return manager.configOptions.filter { option in
            let key = [option.id, option.name, option.type]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return (key.contains("reasoning") || key.contains("effort")) && !key.contains("speed")
        }
    }

    private func reasoningLabel(for option: SessionConfigOption) -> String {
        let name = option.name ?? option.id ?? String(localized: "Reasoning")
        guard let value = option.resolvedCurrentValue else { return name }
        return "\(name): \(value.stringValue ?? value.prettyPrinted)"
    }

    private func isCurrentModel(_ model: SessionModel) -> Bool {
        guard let current = manager.currentModel else { return false }
        return (model.id ?? model.name) == (current.id ?? current.name)
    }

    private func isCurrentChoice(_ choice: SessionConfigOptionValue, in option: SessionConfigOption) -> Bool {
        choice.value?.stringValue == option.resolvedCurrentValue?.stringValue
    }

    private func select(_ choice: SessionConfigOptionValue, in option: SessionConfigOption) {
        guard let configId = option.id, let value = choice.value?.stringValue else { return }
        manager.selectConfigOption(configId, value: value)
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

    private func controlPill(icon: String, title: String) -> some View {
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
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.overlay(0.05))
        )
    }

    private var projectSection: some View {
        HStack(spacing: 8) {
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
                .fixedSize()
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
        store.setAgentProjectPath(workspaceID: workspace.id, path: path)
    }

    private func chooseFolder() {
        Task { @MainActor in
            guard let folder = await FolderPicker.pickProjectFolder() else { return }
            chooseProject(folder.path)
        }
    }

    /// Establishes the ACP connection as soon as we know where (pane
    /// appears with an already-chosen project, or a project just got
    /// picked) instead of waiting for the user's first message — so the
    /// model/mode/reasoning pickers reflect real session data right away.
    /// `DevinSessionManager.connectIfNeeded` itself is idempotent/no-ops
    /// once connected, so calling this from both `.onAppear` and
    /// `.onChange(of: workspace.agentProjectPath)` is safe.
    private func connectIfNeeded() {
        guard let projectPath, projectIsValid else { return }
        manager.connectIfNeeded(projectPath: projectPath)
    }
}

// MARK: - Helper Preferences
private struct ComposerTextHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = AgentComposer.minEditorHeight
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
