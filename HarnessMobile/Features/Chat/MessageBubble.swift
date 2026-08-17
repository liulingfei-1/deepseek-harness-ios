import SwiftUI
import UIKit

struct MessageBubble: View, Equatable {
    nonisolated let message: AgentMessage
    let onToggleFeedback: (UUID, MessageFeedbackRating) -> Void
    let onUpdateFeedbackNote: (UUID, String) -> Void

    @State private var feedbackNoteEditor: FeedbackNoteEditor?
    @State private var isToolResultPresented = false

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: .leading, spacing: 8) {
                if message.role == .assistant {
                    Label("Harness", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    DisclosureGroup("思考过程") {
                        Text(reasoning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    }
                    .font(.caption)
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
                    Text(limited(message.content))
                        .font(.body)
                        .textSelection(.enabled)
                }

                if message.isIncomplete {
                    Label("回复因模型输出长度限制而截断", systemImage: "text.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if message.role == .tool {
                    Button {
                        isToolResultPresented = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(
                                systemName: message.isToolError == true
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill"
                            )
                            .foregroundStyle(message.isToolError == true ? .red : .green)

                            Text(toolResultLabel)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if message.isToolError == true,
                               let summary = compactToolResultSummary {
                                Text(summary)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer(minLength: 6)

                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(toolResultLabel)，查看完整返回值")
                }

                if message.role == .assistant {
                    assistantActions
                }
            }
            .padding(message.role == .assistant ? 0 : 12)
            .background {
                if message.role != .assistant {
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
        .sheet(item: $feedbackNoteEditor) { editor in
            MessageFeedbackNoteSheet(
                editor: editor,
                onSave: { note in
                    onUpdateFeedbackNote(message.id, note)
                }
            )
        }
        .sheet(isPresented: $isToolResultPresented) {
            ToolResultInspectorView(
                title: toolResultLabel,
                content: message.content,
                isError: message.isToolError == true
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

    private var toolResultLabel: String {
        let name = message.toolName.map { ToolEventPresentation.title(for: $0) } ?? "本地工具"
        return message.isToolError == true ? "\(name) 执行失败" : "\(name) 已完成"
    }

    private var compactToolResultSummary: String? {
        let firstLine = message.content
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let firstLine, !firstLine.isEmpty else { return nil }
        return firstLine
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

    private func limited(_ text: String) -> String {
        guard text.count > 8_000 else { return text }
        return String(text.prefix(8_000)) + "\n\n…（界面已截断，完整结果仍保存在本地会话）"
    }

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
    }
}

private struct ToolResultInspectorView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let content: String
    let isError: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content.isEmpty ? "工具没有返回文本。" : content)
                    .font(.footnote.monospaced())
                    .foregroundStyle(isError ? .red : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
                Label("Harness", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if !reasoning.isEmpty {
                    DisclosureGroup("正在思考…") {
                        Text(reasoning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                if text.isEmpty {
                    ProgressView()
                } else {
                    Text(text)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            Spacer(minLength: 12)
        }
    }
}
