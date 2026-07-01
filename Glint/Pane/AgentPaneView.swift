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
    @State private var attachments: [ComposerAttachment] = []
    @State private var projectError: String?
    @State private var isNearBottom = true
    @State private var elicitationInput = ""
    @State private var showDiagnostics = false

    private var projectPath: String? {
        workspace.agentProjectPath
    }

    private var projectIsValid: Bool {
        store.isValidAgentProjectPath(projectPath)
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var devinInstalled: Bool {
        DevinHookInstaller.isAgentPresent()
    }

    var body: some View {
        ZStack {
            Theme.bgPane

            VStack(spacing: 0) {
                // Header
                header
                    .padding(.horizontal, 28)
                    // In floating-toolbar mode (`store.glassEffect`) the
                    // global `ToolbarHeader` overlays the pane area instead
                    // of pushing it down (see `ContentView.floatingHeader`).
                    // Terminal panes are kept clear of it via the padded
                    // shell launcher, but this is plain SwiftUI content with
                    // no equivalent trick, so it needs the toolbar's height
                    // added explicitly or its own header renders underneath
                    // the glass islands.
                    .padding(.top, 22 + (store.glassEffect ? ToolbarHeader.height : 0))
                    .padding(.bottom, 12)

                Divider()
                    .overlay(Theme.divider)

                if showDiagnostics {
                    diagnosticsPanel
                    Divider()
                        .overlay(Theme.divider)
                }

                if !devinInstalled {
                    notInstalledCard
                        .padding(28)
                        .frame(maxHeight: .infinity)
                } else if case .starting = manager.status {
                    loadingView
                        .frame(maxHeight: .infinity)
                } else if case .failed(let message) = manager.status, isAuthError(message) {
                    authNeededCard(message: message)
                        .padding(28)
                        .frame(maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        // Error bar if failed
                        if case .failed(let message) = manager.status {
                            errorBanner(message: message)
                        }

                        // Message Scroll List with Smart Auto-Scroll
                        messageListSection
                    }
                    // The composer floats above the message list as a
                    // centered, max-width card (not a full-width bar docked
                    // to the pane edge) — `safeAreaInset` keeps the scroll
                    // content from being obscured by it without needing a
                    // manual bottom-padding calculation.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        HStack {
                            Spacer(minLength: 0)
                            AgentComposer(
                                workspace: workspace,
                                paneID: paneID,
                                manager: manager,
                                draft: $draft,
                                attachments: $attachments,
                                onSend: send
                            )
                            .frame(maxWidth: 760)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                    }
                }
            }

            // Overlays: Permissions and Elicitations
            overlays
        }
        .onAppear {
            validateProject()
        }
        .onChange(of: workspace.agentProjectPath) { _, _ in
            validateProject()
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 12) {
            Image("DevinMark")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .shadow(color: Color(red: 0.16, green: 0.43, blue: 0.81).opacity(0.45), radius: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(workspace.displayName)
                        .font(AppFonts.ui(14, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Status Dot
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                }

                HStack(spacing: 6) {
                    Text(statusText)
                        .font(AppFonts.ui(11))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)

                    if let currentModel = manager.currentModel?.name {
                        Text("•")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.text4)
                        Text(currentModel)
                            .font(AppFonts.ui(11))
                            .foregroundStyle(Theme.text4)
                    }
                }
            }

            Spacer()

            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(showDiagnostics ? store.accent : Theme.text3)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(Theme.overlay(showDiagnostics ? 0.10 : 0.05))
                    )
            }
            .buttonStyle(.plain)
            .help("Session diagnostics")

            // Quick mode toggle if any
            if let currentMode = manager.currentMode {
                Text(currentMode.uppercased())
                    .font(AppFonts.ui(10, weight: .bold))
                    .foregroundStyle(store.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(store.accent.opacity(0.12))
                    )
            }
        }
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session diagnostics")
                    .font(AppFonts.ui(11.5, weight: .bold))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("\(manager.diagnostics.count) events")
                    .font(AppFonts.ui(10.5, weight: .medium))
                    .foregroundStyle(Theme.text4)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if manager.diagnostics.isEmpty {
                        Text("No ACP events recorded yet.")
                            .font(AppFonts.ui(11.5))
                            .foregroundStyle(Theme.text4)
                    } else {
                        ForEach(manager.diagnostics.suffix(40)) { event in
                            diagnosticRow(event)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(Theme.overlay(0.035))
    }

    private func diagnosticRow(_ event: ACPDiagnosticEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(event.kind.rawValue)
                    .font(AppFonts.ui(9.5, weight: .bold))
                    .foregroundStyle(diagnosticColor(event.kind))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(diagnosticColor(event.kind).opacity(0.12)))
                Text(event.title)
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
                Spacer()
            }
            if let detail = event.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if let payload = event.payload {
                Text(payload.prettyPrinted)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text4)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func diagnosticColor(_ kind: ACPDiagnosticEvent.Kind) -> Color {
        switch kind {
        case .error, .malformed:
            return Theme.pink
        case .stderr:
            return Theme.orange
        case .request, .serverRequest:
            return Theme.cyan
        case .response:
            return Theme.green
        case .notification:
            return store.accent
        case .lifecycle:
            return Theme.text3
        }
    }

    // MARK: - Message List Section
    private var messageListSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if manager.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(manager.messages) { message in
                            AgentMessageView(
                                message: message,
                                isLast: message.id == manager.messages.last?.id,
                                status: manager.status
                            )
                        }
                    }

                    // Bottom Anchor
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self, value: geo.frame(in: .global).minY)
                            }
                        )
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                // Detect if user is near bottom
                // Value is coordinate of bottom, if it goes too high (small value), user has scrolled up
                isNearBottom = value < 950 // Threshold for near-bottom
            }
            .onChange(of: manager.messages.count) { _, _ in
                if isNearBottom {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image("DevinMark")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .shadow(color: Color(red: 0.16, green: 0.43, blue: 0.81).opacity(0.3), radius: 10)

            Text("Start a Devin session")
                .font(AppFonts.ui(18, weight: .semibold))
                .foregroundStyle(Theme.text1)

            Text("Pick a project folder below, then describe your task to begin.")
                .font(AppFonts.ui(12.5))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    // MARK: - Overlays
    @ViewBuilder
    private var overlays: some View {
        if let permission = manager.pendingPermission {
            ZStack {
                // Dim/Blur Backdrop
                VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
                    .opacity(0.7)
                    .ignoresSafeArea()

                permissionCard(permission)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if let elicitation = manager.pendingElicitation {
            ZStack {
                VisualEffectBackground(material: .menu, blendingMode: .withinWindow)
                    .opacity(0.7)
                    .ignoresSafeArea()

                elicitationCard(elicitation)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }

    // MARK: - Permission Card
    private func permissionCard(_ permission: DevinSessionManager.PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "shield.righthalf.filled")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.orange)
                Text("Permission Required")
                    .font(AppFonts.ui(14, weight: .bold))
                    .foregroundStyle(Theme.text1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(permission.request.toolCall?.title ?? "Devin is asking to run a tool")
                    .font(AppFonts.ui(13, weight: .semibold))
                    .foregroundStyle(Theme.text1)

                if let kind = permission.request.toolCall?.kind {
                    Text("Tool Kind: \(String(describing: kind).uppercased())")
                        .font(AppFonts.ui(11, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
            }

            // LLM reasoning feedback if auto-reviewed and escalated. Shown
            // alongside (not instead of) the real arguments below, so the
            // human reviewer never loses sight of what they're approving.
            if let reason = permission.request.reviewReason {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-Review Analysis:")
                        .font(AppFonts.ui(11, weight: .bold))
                        .foregroundStyle(Theme.text3)
                    Text(reason)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(Theme.text3)
                        .italic()
                        .padding(8)
                        .background(Theme.overlay(0.04))
                        .cornerRadius(6)
                }
            }

            if let rawInput = permission.request.toolCall?.rawInput {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Arguments:")
                        .font(AppFonts.ui(11, weight: .bold))
                        .foregroundStyle(Theme.text3)
                    ScrollView {
                        Text(String(describing: rawInput))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.text3)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    .background(Theme.overlay(0.04))
                    .cornerRadius(6)
                }
            }

            HStack(spacing: 12) {
                Button {
                    manager.respondToPermission(approved: false)
                } label: {
                    Text("Deny")
                        .font(AppFonts.ui(12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.overlay(0.2), lineWidth: 1)
                )
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    manager.respondToPermission(approved: true)
                } label: {
                    Text("Approve")
                        .font(AppFonts.ui(12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(store.accent)
                )
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.bgPane)
                .shadow(color: Color.black.opacity(0.3), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.overlay(0.12), lineWidth: 1)
        )
    }

    // MARK: - Elicitation Card
    private func elicitationCard(_ elicitation: DevinSessionManager.PendingElicitation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(store.accent)
                Text("Input Required")
                    .font(AppFonts.ui(14, weight: .bold))
                    .foregroundStyle(Theme.text1)
            }

            Text(elicitation.request.message ?? "Devin needs additional input to continue.")
                .font(AppFonts.ui(12.5))
                .foregroundStyle(Theme.text2)

            TextField("Type your answer...", text: $elicitationInput)
                .font(AppFonts.ui(13))
                .textFieldStyle(.plain)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.overlay(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.overlay(0.12), lineWidth: 1)
                        )
                )

            HStack(spacing: 12) {
                Button("Cancel") {
                    manager.submitElicitation(values: nil)
                    elicitationInput = ""
                }
                .buttonStyle(.plain)
                .font(AppFonts.ui(12, weight: .semibold))
                .frame(width: 80, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.overlay(0.2), lineWidth: 1)
                )

                Spacer()

                Button("Submit") {
                    manager.submitElicitation(values: .string(elicitationInput))
                    elicitationInput = ""
                }
                .buttonStyle(.plain)
                .font(AppFonts.ui(12, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 100, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(store.accent)
                )
                .disabled(elicitationInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.bgPane)
                .shadow(color: Color.black.opacity(0.3), radius: 24, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.overlay(0.12), lineWidth: 1)
        )
    }

    // MARK: - Error Banner
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.pink)

            VStack(alignment: .leading, spacing: 2) {
                Text("Session Error")
                    .font(AppFonts.ui(12, weight: .bold))
                    .foregroundStyle(Theme.text1)
                Text(message)
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(2)
            }

            Spacer()

            Button("Restart Session") {
                manager.stop()
            }
            .buttonStyle(.plain)
            .font(AppFonts.ui(11, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(store.accent)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.pink.opacity(0.08))
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("Connecting to Devin...")
                .font(AppFonts.ui(13))
                .foregroundStyle(Theme.text3)
        }
    }

    // MARK: - Not Installed Card
    private var notInstalledCard: some View {
        VStack(spacing: 16) {
            Image("DevinMark")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .opacity(0.6)

            VStack(spacing: 4) {
                Text("Devin CLI Not Installed")
                    .font(AppFonts.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text("Please install the devin CLI to run coding agents.")
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Run this command in your terminal:")
                    .font(AppFonts.ui(11, weight: .bold))
                    .foregroundStyle(Theme.text4)
                Text("brew install devin")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.overlay(0.05))
                    .cornerRadius(6)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Auth Needed Card
    private func authNeededCard(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Theme.orange)

            VStack(spacing: 4) {
                Text("Devin Authentication Required")
                    .font(AppFonts.ui(16, weight: .semibold))
                    .foregroundStyle(Theme.text1)
                Text(message)
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(Theme.text3)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Run this command in your terminal, then try again:")
                    .font(AppFonts.ui(11, weight: .bold))
                    .foregroundStyle(Theme.text4)
                Text("devin auth login")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.overlay(0.05))
                    .cornerRadius(6)
            }
            .padding(.top, 4)

            Button("Restart Session") {
                manager.stop()
            }
            .buttonStyle(.plain)
            .font(AppFonts.ui(12, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(store.accent)
            )
        }
    }

    /// Heuristic check for auth-related failures (no ACP metadata for this
    /// yet; full auth-method surfacing is Phase 5). Looks for common
    /// keywords Devin's ACP error messages use for credential problems.
    private func isAuthError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return ["auth", "credential", "login", "unauthorized", "token expired"]
            .contains { lowered.contains($0) }
    }

    // MARK: - Status Mapping Helpers
    private var statusText: String {
        switch manager.status {
        case .idle:
            return projectPath ?? String(localized: "Choose folder to begin")
        case .starting:
            return String(localized: "Starting...")
        case .thinking:
            return String(localized: "Working...")
        case .tool:
            return String(localized: "Using tool...")
        case .needsPermission:
            return String(localized: "Awaiting permission")
        case .cancelling:
            return String(localized: "Cancelling...")
        case .failed:
            return String(localized: "Session error")
        }
    }

    private var statusColor: Color {
        switch manager.status {
        case .failed:
            return Theme.pink
        case .starting, .thinking, .tool, .cancelling:
            return store.accent
        case .needsPermission:
            return Theme.orange
        case .idle:
            return Theme.green
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

    private func send() {
        guard !trimmedDraft.isEmpty || !attachments.isEmpty else { return }
        guard let projectPath,
              store.setAgentProjectPath(workspaceID: workspace.id, path: projectPath),
              let standardized = WorkspaceStore.standardizedAgentProjectPath(projectPath) else {
            projectError = String(localized: "Choose a folder.")
            return
        }
        projectError = nil
        store.commitAgentWorkspace(workspace.id)
        let images = attachments.map { DevinSessionManager.ImageAttachment(base64Data: $0.base64Data, mimeType: $0.mimeType) }
        manager.sendPrompt(text: trimmedDraft, projectPath: standardized, images: images)
        draft = ""
        attachments = []
    }
}

// MARK: - Helper Preferences
private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
