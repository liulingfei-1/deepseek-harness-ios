import SwiftUI
import UIKit

struct MessageBubble: View, Equatable {
    nonisolated let message: AgentMessage
    let canRerunUserMessage: Bool
    let onRetryUserMessage: (UUID) -> Void
    let onEditUserMessage: (AgentMessage) -> Void
    let onToggleFeedback: (UUID, MessageFeedbackRating) -> Void
    let onUpdateFeedbackNote: (UUID, String) -> Void

    @State private var feedbackNoteEditor: FeedbackNoteEditor?
    @State private var showsFullContent = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                if message.role == .assistant {
                    Label("DeepSeek Harness", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(reasoning: reasoning, isStreaming: false)
                }

                if message.role == .assistant, !message.toolEvents.isEmpty {
                    ToolEventTreeView(events: message.toolEvents, isLive: false)
                } else if message.role == .assistant, !message.toolCalls.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(message.toolCalls) { call in
                            DisclosureGroup {
                                Text(call.arguments)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            } label: {
                                Label(call.name, systemImage: "wrench.and.screwdriver")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                    }
                }

                if !message.content.isEmpty, message.role != .tool {
                    VStack(alignment: .leading, spacing: 6) {
                        NativeMarkdownText(source: presentedContent)
                        if message.content.count > Self.collapsedContentCharacters {
                            Button(showsFullContent ? "收起长回复" : "展开完整回复") {
                                showsFullContent.toggle()
                            }
                            .font(.caption.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                if message.isIncomplete {
                    Label("回复因模型输出长度限制而截断", systemImage: "text.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if message.role == .tool {
                    ToolEventCard(event: legacyToolEvent, isLive: false) {}
                }

                if message.role == .assistant {
                    assistantActions
                }
            }
            .padding(message.role == .user ? 12 : 0)
            .background {
                if message.role == .user {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(background)
                }
            }
            .frame(
                maxWidth: message.role == .user ? 320 : 620,
                alignment: .leading
            )

            if message.role != .user {
                Spacer(minLength: 12)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("message-\(message.role.rawValue)")
        .contextMenu {
            if message.role == .user {
                Button {
                    onRetryUserMessage(message.id)
                } label: {
                    Label("重试此消息", systemImage: "arrow.clockwise")
                }
                .disabled(!canRerunUserMessage)

                Button {
                    onEditUserMessage(message)
                } label: {
                    Label("编辑并重新运行", systemImage: "pencil")
                }
                .disabled(!canRerunUserMessage)
            }
        }
        .sheet(item: $feedbackNoteEditor) { editor in
            MessageFeedbackNoteSheet(
                editor: editor,
                onSave: { note in
                    onUpdateFeedbackNote(message.id, note)
                }
            )
        }
    }

    private var assistantActions: some View {
        HStack(spacing: 2) {
            feedbackButton(
                rating: .positive,
                systemImage: "hand.thumbsup",
                label: "有帮助"
            )
            feedbackButton(
                rating: .negative,
                systemImage: "hand.thumbsdown",
                label: "需要改进"
            )

            if let feedback = message.feedback {
                Button {
                    feedbackNoteEditor = FeedbackNoteEditor(note: feedback.note ?? "")
                } label: {
                    Image(systemName: feedback.note == nil ? "note.text.badge.plus" : "note.text")
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(feedback.note == nil ? "添加反馈备注" : "编辑反馈备注")
                .help(feedback.note == nil ? "添加反馈备注" : "编辑反馈备注")
            }

            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(message.content.isEmpty)
            .accessibilityLabel("复制回答")
            .help("复制回答")
        }
        .font(.caption.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func feedbackButton(
        rating: MessageFeedbackRating,
        systemImage: String,
        label: String
    ) -> some View {
        let isSelected = message.feedback?.rating == rating
        return Button {
            onToggleFeedback(message.id, rating)
        } label: {
            Image(systemName: isSelected ? "\(systemImage).fill" : systemImage)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(label)
    }

    private var legacyToolEvent: AgentToolEvent {
        let call = AgentToolCall(
            id: message.toolCallID ?? message.id.uuidString,
            name: message.toolName ?? "local_tool",
            arguments: "{}"
        )
        let status: AgentToolEventStatus = message.isToolError == true ? .failed : .succeeded
        return AgentToolEvent(
            id: message.id,
            call: call,
            summary: firstResultLine,
            status: status,
            result: message.content,
            errorMessage: message.isToolError == true ? message.content : nil,
            createdAt: message.createdAt,
            startedAt: message.createdAt,
            finishedAt: message.createdAt
        )
    }

    private var firstResultLine: String {
        message.content
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? ""
    }

    private var background: Color {
        switch message.role {
        case .user:
            return Color(uiColor: .secondarySystemBackground)
        case .assistant:
            return .clear
        case .tool:
            return Color(uiColor: .tertiarySystemBackground)
        }
    }

    private static let collapsedContentCharacters = 2_400
    private static let expandedContentCharacters = 16_000

    private var presentedContent: String {
        let limit = showsFullContent
            ? Self.expandedContentCharacters
            : Self.collapsedContentCharacters
        guard message.content.count > limit else { return message.content }
        return String(message.content.prefix(limit))
            + (showsFullContent
                ? "\n\n…（界面显示已达上限，完整结果仍保存在本地会话）"
                : "\n\n…")
    }

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.canRerunUserMessage == rhs.canRerunUserMessage
    }
}

struct EditUserMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    let onRerun: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal, 12)
                .navigationTitle("编辑消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("重新运行") {
                            onRerun()
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FeedbackNoteEditor: Identifiable {
    let id = UUID()
    let note: String
}

private struct MessageFeedbackNoteSheet: View {
    let editor: FeedbackNoteEditor
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var note: String

    init(editor: FeedbackNoteEditor, onSave: @escaping (String) -> Void) {
        self.editor = editor
        self.onSave = onSave
        _note = State(initialValue: editor.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 120)
                        .accessibilityLabel("反馈备注")

                    Text("\(note.utf8.count) / \(MessageFeedback.maximumNoteUTF8Bytes) bytes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            note.utf8.count > MessageFeedback.maximumNoteUTF8Bytes
                                ? Color.red
                                : Color.secondary
                        )
                }
            }
            .navigationTitle("反馈备注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(note)
                        dismiss()
                    }
                    .disabled(note.utf8.count > MessageFeedback.maximumNoteUTF8Bytes)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct StreamingMessageBubble: View {
    let reasoning: String
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Label("DeepSeek Harness", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !reasoning.isEmpty {
                    ReasoningDisclosure(reasoning: reasoning, isStreaming: true)
                }
                if !text.isEmpty {
                    Text(text)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 12)
        }
    }
}

private struct ReasoningDisclosure: View {
    let reasoning: String
    let isStreaming: Bool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.secondary)
                    Text("Think")
                        .fontWeight(.semibold)
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isStreaming ? "正在思考" : "思考过程")
            .accessibilityValue(summary)
            .accessibilityHint(isExpanded ? "折叠完整思考过程" : "展开完整思考过程")

            if isExpanded {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 23)
            }
        }
    }

    private var summary: String {
        let sample = isStreaming
            ? String(reasoning.suffix(800))
            : String(reasoning.prefix(1_600))
        let lines = sample
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return isStreaming ? "正在推理" : "已完成" }
        let value: String
        if isStreaming {
            value = lines.last ?? "正在推理"
        } else {
            value = lines.first(where: { !$0.hasPrefix("[") }) ?? lines[0]
        }
        guard value.count > 160 else { return value }
        return String(value.prefix(160)) + "…"
    }
}
