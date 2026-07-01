import AppKit
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
    @State private var showFullInput = false
    @State private var showFullOutput = false
    @State private var showFullRaw = false

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
                            .lineLimit(1)
                            .truncationMode(.middle)

                        statusBadge

                        if let durationText {
                            Text(durationText)
                                .font(AppFonts.ui(10.5, weight: .medium))
                                .foregroundStyle(Theme.text4)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.text4)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = message.toolAbandonedReason {
                            detailSection(title: "Status", text: reason, color: Theme.orange)
                        }
                        if let kind = message.toolKind {
                            metadataItem(label: "Kind", value: kind.description)
                        }
                        if let id = message.toolCallId {
                            metadataItem(label: "ID", value: id)
                        }
                        if let locations = message.toolLocations, !locations.isEmpty {
                            detailSection(title: "Locations", text: locationsText(locations), color: Theme.text3)
                        }
                        rawJSONSection(title: "Input", value: message.toolRawInput, showFull: $showFullInput)
                        rawJSONSection(title: "Output", value: message.toolRawOutput, showFull: $showFullOutput)
                        if let content = message.toolContent, !content.isEmpty {
                            detailSection(title: "Content", text: contentText(content), color: Theme.text3)
                        }
                        detailSection(title: "Raw Tool JSON", text: rawToolJSON, color: Theme.text3, showFull: $showFullRaw)
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
        if message.toolAbandonedReason != nil {
            return ("Stale", Theme.orange, Theme.orange.opacity(0.12))
        }
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

    private var durationText: String? {
        guard let start = message.toolStartedAt else { return nil }
        let end = message.toolCompletedAt ?? message.toolUpdatedAt ?? Date()
        let seconds = max(0, end.timeIntervalSince(start))
        if seconds < 1 {
            return "<1s"
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded()))s"
        }
        return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
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

    @ViewBuilder
    private func rawJSONSection(title: String, value: ACPJSONValue?, showFull: Binding<Bool>) -> some View {
        if let value {
            detailSection(title: title, text: value.prettyPrinted, color: Theme.text3, showFull: showFull)
        } else {
            detailSection(title: title, text: "No \(title.lowercased()) provided by agent.", color: Theme.text4)
        }
    }

    private func detailSection(title: String,
                               text: String,
                               color: Color,
                               showFull: Binding<Bool>? = nil) -> some View {
        let fullText = text.isEmpty ? "(empty)" : text
        let truncated = fullText.count > 4000 && showFull?.wrappedValue != true
        let displayText = truncated ? String(fullText.prefix(4000)) + "\n..." : fullText

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(AppFonts.ui(10.5, weight: .bold))
                    .foregroundStyle(Theme.text4)
                Spacer()
                Button {
                    copy(fullText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text4)
                .help("Copy \(title)")
                if let showFull, fullText.count > 4000 {
                    Button(showFull.wrappedValue ? "Less" : "Full") {
                        showFull.wrappedValue.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(AppFonts.ui(10.5, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                }
            }
            Text(displayText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .lineLimit(showFull?.wrappedValue == true ? nil : 80)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.overlay(0.04))
                )
        }
        .frame(maxWidth: 680, alignment: .leading)
    }

    private func locationsText(_ locations: [ToolCallLocation]) -> String {
        locations.map { location in
            if let path = location.path, let line = location.line {
                return "\(path):\(line)"
            }
            return location.path ?? String(localized: "Unknown location")
        }
        .joined(separator: "\n")
    }

    private func contentText(_ content: [ToolCallContent]) -> String {
        content.map { item in
            switch item {
            case .content(let block):
                return block.plainText ?? String(describing: block)
            case .diff(let raw):
                return raw.prettyPrinted
            case .unknown(let type, let raw):
                return "Unknown content (\(type))\n\(raw.prettyPrinted)"
            }
        }
        .joined(separator: "\n\n")
    }

    private var rawToolJSON: String {
        var object: [String: ACPJSONValue] = [:]
        if let id = message.toolCallId { object["toolCallId"] = .string(id) }
        object["title"] = .string(message.text)
        if let kind = message.toolKind { object["kind"] = .string(kind.description) }
        if let status = message.toolStatus { object["status"] = .string(String(describing: status)) }
        if let rawInput = message.toolRawInput { object["rawInput"] = rawInput }
        if let rawOutput = message.toolRawOutput { object["rawOutput"] = rawOutput }
        if let reason = message.toolAbandonedReason { object["abandonedReason"] = .string(reason) }
        return ACPJSONValue.object(object).prettyPrinted
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
