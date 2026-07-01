import SwiftUI

struct AgentMessageView: View {
    let message: DevinSessionManager.Message
    let isLast: Bool
    let status: DevinSessionManager.Status

    var body: some View {
        switch message.role {
        case .user:
            AgentUserMessageRow(message: message)
        case .assistant:
            AgentAssistantMessageRow(message: message, isLast: isLast, status: status)
        case .thought:
            AgentThoughtRow(message: message)
        case .toolCall:
            AgentToolCallRow(message: message)
        case .system:
            AgentSystemMessageRow(message: message)
        }
    }
}

// MARK: - User Message Row
struct AgentUserMessageRow: View {
    let message: DevinSessionManager.Message
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 64)
            Text(message.text)
                .font(AppFonts.ui(13.5, weight: .regular))
                .foregroundStyle(Theme.text1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(store.accent.opacity(0.14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(store.accent.opacity(0.24), lineWidth: 1)
                        )
                )
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Assistant Message Row
struct AgentAssistantMessageRow: View {
    let message: DevinSessionManager.Message
    let isLast: Bool
    let status: DevinSessionManager.Status

    @State private var isBlinking = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Devin Icon Gutter
            Image("DevinMark")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .shadow(color: Color(red: 0.16, green: 0.43, blue: 0.81).opacity(0.4), radius: 4)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Devin")
                        .font(AppFonts.ui(12, weight: .semibold))
                        .foregroundStyle(Theme.text1)
                    Text("AI")
                        .font(AppFonts.ui(9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color(red: 0.16, green: 0.43, blue: 0.81))
                        )
                }

                HStack(alignment: .bottom, spacing: 2) {
                    Text(attributedString)
                        .font(AppFonts.ui(13.5))
                        .foregroundStyle(Theme.text1)
                        .lineSpacing(4)
                        .textSelection(.enabled)

                    if isLast && status == .thinking {
                        Circle()
                            .fill(Theme.text2)
                            .frame(width: 6, height: 6)
                            .opacity(isBlinking ? 0.2 : 1.0)
                            .offset(y: -2)
                            .onAppear {
                                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                    isBlinking = true
                                }
                            }
                    }
                }
            }
            Spacer(minLength: 32)
        }
        .padding(.vertical, 6)
    }

    private var attributedString: AttributedString {
        do {
            return try AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(message.text)
        }
    }
}

// MARK: - Thought Row
struct AgentThoughtRow: View {
    let message: DevinSessionManager.Message
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.orange)
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Thought")
                            .font(AppFonts.ui(12, weight: .bold))
                            .foregroundStyle(Theme.text3)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.text4)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(message.text)
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(Theme.text3)
                        .italic()
                        .lineSpacing(3)
                        .padding(.top, 2)
                        .textSelection(.enabled)
                } else {
                    Text(previewText)
                        .font(AppFonts.ui(12.5))
                        .foregroundStyle(Theme.text4)
                        .italic()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 32)
        }
        .padding(.vertical, 4)
    }

    private var previewText: String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 80 {
            return String(text.prefix(80)) + "..."
        }
        return text
    }
}

// MARK: - Tool Call Row
struct AgentToolCallRow: View {
    let message: DevinSessionManager.Message
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            toolIcon
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(message.text)
                            .font(AppFonts.ui(13, weight: .semibold))
                            .foregroundStyle(Theme.text1)

                        statusBadge

                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.text4)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if let kind = message.toolKind {
                            metadataItem(label: "Kind", value: String(describing: kind))
                        }
                        if let id = message.toolCallId {
                            metadataItem(label: "ID", value: id)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }

    private var toolIconSpec: (systemName: String, color: Color) {
        switch message.toolKind {
        case .read:
            return ("doc.text", Theme.cyan)
        case .edit:
            return ("pencil", Theme.accentBright)
        case .delete:
            return ("trash", Theme.pink)
        case .move:
            return ("arrow.right", Theme.accentBright)
        case .search:
            return ("magnifyingglass", Theme.orange)
        case .execute:
            return ("terminal", Theme.green)
        case .think:
            return ("brain.head.profile", Theme.orange)
        case .fetch:
            return ("arrow.down.circle", Theme.cyan)
        default:
            return ("gearshape", Theme.text3)
        }
    }

    private var toolIcon: some View {
        let spec = toolIconSpec
        return Image(systemName: spec.systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(spec.color)
    }

    private var statusBadgeSpec: (label: String, color: Color, bgColor: Color) {
        switch message.toolStatus {
        case .pending:
            return ("Pending", Theme.text3, Theme.overlay(0.08))
        case .inProgress:
            return ("Working", Theme.accentBright, Theme.accentBright.opacity(0.12))
        case .completed:
            return ("Completed", Theme.green, Theme.green.opacity(0.12))
        case .failed:
            return ("Failed", Theme.pink, Theme.pink.opacity(0.12))
        default:
            return ("Pending", Theme.text3, Theme.overlay(0.08))
        }
    }

    private var statusBadge: some View {
        let spec = statusBadgeSpec
        return Text(spec.label)
            .font(AppFonts.ui(9, weight: .semibold))
            .foregroundStyle(spec.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill(spec.bgColor)
            )
            .overlay(
                Capsule().stroke(spec.color.opacity(0.2), lineWidth: 1)
            )
    }

    private func metadataItem(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text("\(label):")
                .font(AppFonts.ui(10.5, weight: .bold))
                .foregroundStyle(Theme.text4)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.text2)
                .textSelection(.enabled)
        }
    }
}

// MARK: - System Message Row
struct AgentSystemMessageRow: View {
    let message: DevinSessionManager.Message

    var body: some View {
        HStack {
            Spacer()
            Text(message.text)
                .font(AppFonts.ui(11, weight: .medium))
                .foregroundStyle(Theme.text4)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.overlay(0.04))
                )
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
