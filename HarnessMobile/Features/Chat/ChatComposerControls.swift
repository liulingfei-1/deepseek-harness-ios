import PhotosUI
import SwiftUI
import UIKit

struct ChatInputBar: View {
    @Binding var draft: String
    @Binding var selectedPhoto: PhotosPickerItem?

    let isRunning: Bool
    let hasStagedImage: Bool
    let queuedInputs: [QueuedAgentInput]
    let slashSuggestions: [SlashCommandDescriptor]
    let onCamera: () -> Void
    let onShowCommands: () -> Void
    let onSelectCommand: (SlashCommandDescriptor) -> Void
    let onSend: (QueuedInputDisposition) -> Void
    let onCancel: () -> Void
    let onEditQueuedInput: (QueuedAgentInput) -> Void
    let onRemoveQueuedInput: (UUID) -> Void
    let onSteerQueuedInput: (UUID) -> Void
    let onSteerAll: () -> Void

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if !queuedInputs.isEmpty {
                QueuedInputList(
                    inputs: queuedInputs,
                    onEdit: onEditQueuedInput,
                    onRemove: onRemoveQueuedInput,
                    onSteer: onSteerQueuedInput,
                    onSteerAll: onSteerAll
                )
            }

            if !slashSuggestions.isEmpty, draft.hasPrefix("/") {
                SlashCommandPalette(
                    commands: slashSuggestions,
                    onSelect: onSelectCommand
                )
            }

            if hasStagedImage {
                Label("图片已就绪，可供本机 OCR 工具读取", systemImage: "text.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Menu {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("选择图片", systemImage: "photo")
                }

                Button(action: onCamera) {
                    Label("拍照", systemImage: "camera")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 40)
            }
            .accessibilityLabel("添加内容")

            Button(action: onShowCommands) {
                Text("/")
                    .font(.title3.weight(.medium))
                    .frame(width: 30, height: 40)
            }
            .accessibilityLabel("命令")

            TextField(
                isRunning ? "输入后加入队列" : "输入任务",
                text: $draft,
                axis: .vertical
            )
            .accessibilityIdentifier("chat-input")
            .lineLimit(1...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
            .submitLabel(.send)
            .onSubmit {
                guard hasDraft else { return }
                onSend(.queued)
            }

            if isRunning {
                Button {
                    onSend(.steer)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 34, height: 40)
                }
                .disabled(!hasDraft)
                .accessibilityLabel("作为 steer 发送")
                .accessibilityHint("在下一个安全步骤改变当前任务方向")
                .accessibilityIdentifier("chat-steer-button")
            }

            Button {
                onSend(.queued)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        hasDraft ? Color.accentColor : Color.secondary.opacity(0.28),
                        in: Circle()
                    )
            }
            .disabled(!hasDraft)
            .accessibilityLabel(isRunning ? "加入队列" : "发送")
            .accessibilityIdentifier("chat-send-button")

            if isRunning {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("停止当前运行")
                .accessibilityIdentifier("chat-stop-button")
            }
        }
    }
}

private struct SlashCommandPalette: View {
    let commands: [SlashCommandDescriptor]
    let onSelect: (SlashCommandDescriptor) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(commands.prefix(8)) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: command.name))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("/\(command.name)")
                                    .font(.body.monospaced())
                                Text(command.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if command.id != commands.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
        }
        .frame(maxHeight: 230)
        .accessibilityLabel("命令列表")
    }

    private func icon(for name: String) -> String {
        switch name {
        case "new": "plus.square"
        case "clear": "trash"
        case "plan": "list.bullet.clipboard"
        case "model": "cpu"
        case "compact": "arrow.down.right.and.arrow.up.left"
        case "status": "gauge"
        case "agent": "person.crop.circle.badge.checkmark"
        default: "questionmark.circle"
        }
    }
}

private struct QueuedInputList: View {
    let inputs: [QueuedAgentInput]
    let onEdit: (QueuedAgentInput) -> Void
    let onRemove: (UUID) -> Void
    let onSteer: (UUID) -> Void
    let onSteerAll: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("排队 \(inputs.count)", systemImage: "text.line.last.and.arrowtriangle.forward")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(action: onSteerAll) {
                    Image(systemName: "arrow.triangle.branch")
                }
                .disabled(inputs.allSatisfy { $0.disposition == .steer })
                .accessibilityLabel("将全部排队消息设为 steer")
            }

            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    Image(systemName: input.disposition == .steer ? "arrow.triangle.branch" : "clock")
                        .foregroundStyle(input.disposition == .steer ? .orange : .secondary)
                    Text(input.text)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onEdit(input)
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("编辑排队消息")

                    Button {
                        onSteer(input.id)
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                            .frame(width: 28, height: 28)
                    }
                    .disabled(input.disposition == .steer)
                    .accessibilityLabel("将排队消息设为 steer")

                    Button(role: .destructive) {
                        onRemove(input.id)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("移除排队消息")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
    }
}

struct EditQueuedInputView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String

    let disposition: QueuedInputDisposition
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(disposition == .steer ? "Steer" : "排队消息") {
                    TextField("内容", text: $text, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .navigationTitle("编辑消息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onSave)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct DirectCommandOutputView: View {
    @Environment(\.dismiss) private var dismiss
    let output: DirectCommandOutput

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output.text)
                    .font(.body.monospaced())
                    .foregroundStyle(output.isError ? .red : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(output.title)
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
