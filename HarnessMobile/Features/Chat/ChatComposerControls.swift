import PhotosUI
import SwiftUI
import UIKit

struct ChatInputBar: View {
    @Binding var draft: String
    @Binding var selectedPhoto: PhotosPickerItem?

    let isRunning: Bool
    let isSubmitting: Bool
    let submissionStatus: String?
    let hasStagedImage: Bool
    let hasStagedFile: Bool
    let queuedInputs: [QueuedAgentInput]
    let triggerGroups: [InputTriggerSuggestionGroup]
    let onCamera: () -> Void
    let onPickFile: () -> Void
    let onShowCommands: () -> Void
    let onSelectSuggestion: (InputTriggerSuggestion) -> Void
    let onSend: (QueuedInputDisposition) -> Void
    let onCancel: () -> Void
    let onEditQueuedInput: (QueuedAgentInput) -> Void
    let onRemoveQueuedInput: (UUID) -> Void
    let onSteerQueuedInput: (UUID) -> Void
    let onSteerAll: () -> Void

    private var hasDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        hasDraft || hasStagedImage || hasStagedFile
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

            if !triggerGroups.isEmpty {
                InputTriggerPalette(
                    groups: triggerGroups,
                    onSelect: onSelectSuggestion
                )
            }

            if hasStagedImage {
                HarnessStatusPill(
                    title: "图片已就绪，可供本机 OCR 工具读取",
                    systemImage: "text.viewfinder",
                    tint: .accentColor
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if hasStagedFile {
                HarnessStatusPill(
                    title: "文件已就绪；将只发送类型、名称和大小说明",
                    systemImage: "doc.badge.plus",
                    tint: .orange
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isSubmitting {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(submissionStatus ?? "正在准备请求")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(submissionStatus ?? "正在准备请求")
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08), in: Capsule())
            }

            inputRow
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: -2)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
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

                Button(action: onPickFile) {
                    Label("选择 PDF、音频或视频", systemImage: "doc")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .accessibilityLabel("添加内容")

            // Commands are a high-frequency developer action. Keep the
            // standalone entry visible at large Dynamic Type and in VoiceOver.
            Button(action: onShowCommands) {
                Image(systemName: "slash.circle")
                    .font(.body.weight(.medium))
                    .frame(width: 44, height: 44)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("命令")
            .accessibilityHint("打开开发者命令")

            TextField(
                isRunning ? "输入后加入队列" : "输入任务",
                text: $draft,
                axis: .vertical
            )
            .accessibilityIdentifier("chat-input")
            .accessibilityLabel(isRunning ? "排队消息" : "任务输入")
            .lineLimit(1...6)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 44)
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.quaternary, lineWidth: 0.5)
            }
            .submitLabel(.send)
            .onSubmit {
                guard canSend, !isSubmitting else { return }
                onSend(.queued)
            }

            if isRunning {
                Button {
                    onSend(.steer)
                } label: {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 44, height: 44)
                        .background(Color.orange.opacity(0.12), in: Circle())
                }
                .disabled(!hasDraft || isSubmitting)
                .accessibilityLabel("作为 steer 发送")
                .accessibilityHint("在下一个安全步骤改变当前任务方向")
                .accessibilityIdentifier("chat-steer-button")
            }

            Button {
                onSend(.queued)
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    canSend && !isSubmitting
                        ? Color.accentColor
                        : Color.secondary.opacity(0.28),
                    in: Circle()
                )
            }
            .disabled(!canSend || isSubmitting)
            .accessibilityLabel(isRunning ? "加入队列" : "发送")
            .accessibilityIdentifier("chat-send-button")

            if isRunning {
                Button(action: onCancel) {
                    Image(systemName: "stop.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("停止当前运行")
                .accessibilityIdentifier("chat-stop-button")
            }
        }
    }
}

private struct InputTriggerPalette: View {
    let groups: [InputTriggerSuggestionGroup]
    let onSelect: (InputTriggerSuggestion) -> Void

    var body: some View {
        ScrollView(.vertical) {
            // Candidates are capped at ~20 rows; LazyVStack mis-estimates
            // height here and lets content spill past the 280pt frame.
            VStack(spacing: 0) {
                ForEach(groups) { group in
                    Text(title(for: group.source))
                        .font(.caption2.weight(.semibold))
                        // UIKit semantic colors render reliably here; SwiftUI
                        // .secondary vibrancy text drops out on this
                        // secondarySystemBackground container in the simulator.
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    ForEach(group.suggestions.prefix(10)) { suggestion in
                        Button {
                            onSelect(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                HarnessIconTile(
                                    systemImage: suggestion.systemImage ?? "terminal",
                                    tint: .accentColor,
                                    size: 28
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayName(for: suggestion))
                                        .font(.body.weight(.medium))
                                    if let description = suggestion.description {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(Color(uiColor: .secondaryLabel))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 14))
        .accessibilityLabel("输入建议")
    }

    private func title(for source: String) -> String {
        switch source {
        case "command": "命令"
        case "skill": "Skills"
        case "file": "文件"
        case "history": "历史会话"
        case "subagent": "子 Agent"
        case "model": "模型"
        case "agent": "Agent"
        case "plugin": "插件"
        case "session": "会话"
        default: source
        }
    }

    private func displayName(for suggestion: InputTriggerSuggestion) -> String {
        if case .completion = suggestion.kind { return suggestion.name }
        return "\(suggestion.trigger.rawValue)\(suggestion.name)"
    }
}

struct SlashCommandInteractionSheet: View {
    let pending: PendingSlashCommandInteraction
    let onResolve: (SlashCommandInteractionResponse) -> Void

    @State private var search = ""
    @State private var gatedOption: SlashCommandSelectOption?
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            Group {
                switch pending.request {
                case let .popupSelect(title, options):
                    popup(title: title, options: options)
                case let .confirmation(confirmation):
                    confirmationView(confirmation)
                }
            }
            .navigationTitle("/\(pending.commandName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onResolve(.cancelled) }
                }
            }
        }
    }

    private func popup(
        title: String,
        options: [SlashCommandSelectOption]
    ) -> some View {
        List {
            Section {
                TextField("搜索", text: $search)
            } header: {
                Text(title)
            }
            if let gatedOption, let confirmation = gatedOption.confirmation {
                Section(confirmation.title) {
                    Text(confirmation.description)
                    Toggle(confirmation.acknowledgeLabel, isOn: $acknowledged)
                    Button(confirmation.confirmLabel) {
                        onResolve(.selected(optionID: gatedOption.id))
                    }
                    .disabled(!acknowledged)
                    Button(confirmation.cancelLabel, role: .cancel) {
                        self.gatedOption = nil
                        acknowledged = false
                    }
                }
            } else {
                Section {
                    ForEach(filtered(options)) { option in
                        Button {
                            if option.confirmation == nil {
                                onResolve(.selected(optionID: option.id))
                            } else {
                                gatedOption = option
                                acknowledged = false
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if option.active {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func confirmationView(
        _ confirmation: SlashCommandConfirmation
    ) -> some View {
        Form {
            Section(confirmation.title) {
                Text(confirmation.description)
                Toggle(confirmation.acknowledgeLabel, isOn: $acknowledged)
            }
            Section {
                Button(confirmation.confirmLabel) { onResolve(.confirmed) }
                    .disabled(!acknowledged)
                Button(confirmation.cancelLabel, role: .destructive) {
                    onResolve(.denied)
                }
            }
        }
    }

    private func filtered(
        _ options: [SlashCommandSelectOption]
    ) -> [SlashCommandSelectOption] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return options }
        return options.filter {
            $0.label.lowercased().contains(needle)
                || ($0.detail?.lowercased().contains(needle) ?? false)
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
            .foregroundStyle(.secondary)

            ForEach(inputs) { input in
                HStack(spacing: 8) {
                    Image(systemName: input.disposition == .steer ? "arrow.triangle.branch" : "clock")
                        .foregroundStyle(input.disposition == .steer ? .orange : .secondary)
                    Text(input.text)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        Button {
                            onEdit(input)
                        } label: {
                            Label("编辑排队消息", systemImage: "pencil")
                        }

                        Button {
                            onSteer(input.id)
                        } label: {
                            Label("将排队消息设为 steer", systemImage: "arrow.triangle.branch")
                        }
                        .disabled(input.disposition == .steer)

                        Button(role: .destructive) {
                            onRemove(input.id)
                        } label: {
                            Label("移除排队消息", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("排队消息操作")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: .rect(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(.quaternary, lineWidth: 0.5)
                }
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.72), in: .rect(cornerRadius: 14))
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
