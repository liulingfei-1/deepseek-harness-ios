import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model

    @State private var conversationMode = ConversationMode.chat
    @State private var trajectoryState = TrajectoryViewState()
    @State private var draft = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var slashSuggestions: [SlashCommandDescriptor] = []
    @State private var editingQueuedInput: QueuedAgentInput?
    @State private var queuedEditText = ""
    @State private var isSettingsPresented = false
    @State private var isExportFormatPresented = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportContentType = UTType.json
    @State private var exportFilename = "Harness-Conversation"
    @State private var renderedMessageLimit = 80
    @State private var followsConversationTail = true
    @State private var automaticScrollTask: Task<Void, Never>?
    @State private var scrollViewportHeight: CGFloat = 0
    @FocusState private var isInputFocused: Bool

    private let bottomID = "conversation-bottom"

    var body: some View {
        Group {
            switch conversationMode {
            case .chat:
                chatSurface
            case .trajectory:
                TrajectoryView(
                    navigationTitle: activeSessionTitle,
                    state: trajectoryState
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    model.isSessionModelPickerRequested = true
                } label: {
                    VStack(spacing: 1) {
                            Text(activeSessionTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.45))
                                .frame(width: 5, height: 5)
                            Text("\(model.effectiveConfiguration.model) · \(model.activeAgentPreset?.displayName ?? model.controlState.agentPresetID) · \(model.interactionMode.title)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 220)
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
                .accessibilityLabel("选择模型，当前 \(model.effectiveConfiguration.model)")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("会话视图", selection: $conversationMode) {
                        Label("对话", systemImage: "bubble.left.and.bubble.right")
                            .tag(ConversationMode.chat)
                        Label("轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                            .tag(ConversationMode.trajectory)
                    }

                    Divider()

                    Picker("Agent 预设", selection: agentPresetBinding) {
                        ForEach(model.agentPresets.filter(\.isMountable), id: \.id) { preset in
                            Label(preset.displayName, systemImage: preset.id == "cordis" ? "wand.and.stars" : "cpu")
                                .tag(preset.id)
                        }
                    }
                    .disabled(model.isRunning)

                    Divider()

                    Picker("运行模式", selection: modeBinding) {
                        ForEach(ConversationInteractionMode.allCases) { mode in
                            Label(mode.title, systemImage: mode == .agent ? "sparkles" : "list.bullet.clipboard")
                            .tag(mode)
                        }
                    }
                    .disabled(model.isRunning)

                    Picker("工具权限", selection: permissionModeBinding) {
                        ForEach(ToolPermissionMode.allCases) { permission in
                            Label(permission.title, systemImage: permission.systemImage)
                            .tag(permission)
                        }
                    }
                    .disabled(model.isRunning)

                    Divider()

                    Button {
                        model.isSessionModelPickerRequested = true
                    } label: {
                        Label("切换模型", systemImage: "cpu")
                    }
                    .disabled(model.isRunning)

                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }

                    Button {
                        isExportFormatPresented = true
                    } label: {
                        Label("导出对话", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.messages.isEmpty)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "ellipsis.circle")
                        if model.isRunning {
                            Circle()
                                .fill(.green)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1))
                                .offset(x: 1, y: 1)
                        }
                    }
                }
                .accessibilityLabel("会话选项")
            }
        }
        .task {
            consumePendingDraft()
        }
        .onChange(of: model.pendingDraft) {
            consumePendingDraft()
        }
        .onChange(of: model.activeSessionID) {
            renderedMessageLimit = 80
            followsConversationTail = true
            automaticScrollTask?.cancel()
            automaticScrollTask = nil
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                    throw CameraPickerError.noImageData
                }
                await model.stageImage(data)
            } catch is CancellationError {
                return
            } catch {
                model.presentError(error)
            }
        }
        .task(id: draft) {
            slashSuggestions = await model.slashCommandSuggestions(for: draft)
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraPicker { data in
                isCameraPresented = false
                guard let data else { return }
                Task {
                    await model.stageImage(data)
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsView()
            }
        }
        .sheet(isPresented: modelPickerPresented) {
            SessionModelPickerView()
        }
        .sheet(item: pendingUserQuestion) { pending in
            UserQuestionSheet(pending: pending)
        }
        .sheet(item: commandOutput) { output in
            DirectCommandOutputView(output: output)
        }
        .sheet(item: $editingQueuedInput) { input in
            EditQueuedInputView(
                text: $queuedEditText,
                disposition: input.disposition,
                onSave: {
                    model.updateQueuedInput(id: input.id, text: queuedEditText)
                    editingQueuedInput = nil
                }
            )
        }
        .confirmationDialog(
            "脱敏导出对话",
            isPresented: $isExportFormatPresented,
            titleVisibility: .visible
        ) {
            Button("JSON") { prepareExport(.json) }
            Button("Markdown") { prepareExport(.markdown) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("导出会移除工具原始参数并遮盖常见 API Token；文件只在你选择的位置生成。")
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                model.presentError(error)
            }
        }
        .confirmationDialog(
            "允许本地工具？",
            isPresented: approvalPresented,
            titleVisibility: .visible
        ) {
            Button("拒绝", role: .cancel) {
                model.resolveApproval(.deny)
            }
            if let approval = model.pendingApproval {
                if approval.risk == .destructive {
                    Button("允许并永久记住", role: .destructive) {
                        model.resolveApproval(.trustScope)
                    }
                } else {
                    Button("允许并记住本机工具") {
                        model.resolveApproval(.trustDevice)
                    }
                    Button("允许并记住此范围") {
                        model.resolveApproval(.trustScope)
                    }
                }
            }
        } message: {
            if let approval = model.pendingApproval {
                Text(
                    "\(approval.summary)\n\n授权范围：\(approval.scope.chatResourceSummary)\n\n工具在本机执行；产生的文字结果将发送给 \(approval.modelHost) 继续推理。设备级本机授权会覆盖所有风险级别，可随时在设置中撤销。"
                )
            }
        }
        .alert("发生错误", isPresented: errorPresented) {
            Button("好") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var chatSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ConversationTimeline(
                    hasResumableRun: model.hasResumableRun,
                    isRunning: model.isRunning,
                    omittedContextMessages: model.omittedContextMessages,
                    messages: renderedMessages,
                    hiddenMessageCount: hiddenMessageCount,
                    streamingReasoning: model.streamingReasoning,
                    streamingText: model.streamingText,
                    activeToolStatus: model.activeToolStatus,
                    activeToolEvents: model.activeToolEvents,
                    bottomID: bottomID,
                    onResume: model.resumePendingRun,
                    onLoadEarlierMessages: loadEarlierMessages,
                    onStartInput: { isInputFocused = true },
                    onToggleFeedback: model.toggleMessageFeedback,
                    onUpdateFeedbackNote: model.updateMessageFeedbackNote
                )
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .coordinateSpace(name: "conversation-scroll")
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ConversationViewportHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    ConversationWorkStateDock()

                    ChatInputBar(
                        draft: $draft,
                        selectedPhoto: $selectedPhoto,
                        isRunning: model.isRunning,
                        hasStagedImage: model.hasStagedImage,
                        queuedInputs: model.queuedInputs,
                        slashSuggestions: slashSuggestions,
                        onCamera: {
                            isCameraPresented = true
                        },
                        onShowCommands: showCommands,
                        onSelectCommand: selectCommand,
                        onSend: send,
                        onCancel: model.cancelRun,
                        onEditQueuedInput: beginEditingQueuedInput,
                        onRemoveQueuedInput: model.removeQueuedInput,
                        onSteerQueuedInput: model.steerQueuedInput,
                        onSteerAll: model.steerAllQueuedInputs
                    )
                    .focused($isInputFocused)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        followsConversationTail = false
                        automaticScrollTask?.cancel()
                        automaticScrollTask = nil
                    }
            )
            .onPreferenceChange(ConversationViewportHeightPreferenceKey.self) {
                scrollViewportHeight = $0
            }
            .onPreferenceChange(ConversationBottomPreferenceKey.self) { bottom in
                guard !followsConversationTail,
                      scrollViewportHeight > 0,
                      bottom <= scrollViewportHeight + 72 else {
                    return
                }
                followsConversationTail = true
            }
            .onChange(of: model.messages.count) {
                scheduleAutomaticScroll(proxy)
            }
            .onChange(of: model.streamingText.count) {
                scheduleAutomaticScroll(proxy)
            }
            .onChange(of: model.streamingReasoning.count) {
                scheduleAutomaticScroll(proxy)
            }
            .onDisappear {
                automaticScrollTask?.cancel()
                automaticScrollTask = nil
            }
        }
    }

    private var approvalPresented: Binding<Bool> {
        Binding(
            get: { model.pendingApproval != nil },
            set: { presented in
                if !presented, model.pendingApproval != nil {
                    model.resolveApproval(approved: false)
                }
            }
        )
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { presented in
                if !presented {
                    model.errorMessage = nil
                }
            }
        )
    }

    private var modeBinding: Binding<ConversationInteractionMode> {
        Binding(
            get: { model.interactionMode },
            set: { model.setInteractionMode($0) }
        )
    }

    private var permissionModeBinding: Binding<ToolPermissionMode> {
        Binding(
            get: { model.permissionMode },
            set: { model.setPermissionMode($0) }
        )
    }

    private var agentPresetBinding: Binding<String> {
        Binding(
            get: { model.activeAgentPreset?.id ?? model.controlState.agentPresetID },
            set: { model.selectAgentPresetFromUI(id: $0) }
        )
    }

    private var modelPickerPresented: Binding<Bool> {
        Binding(
            get: { model.isSessionModelPickerRequested },
            set: { model.isSessionModelPickerRequested = $0 }
        )
    }

    private var commandOutput: Binding<DirectCommandOutput?> {
        Binding(
            get: { model.directCommandOutput },
            set: { model.directCommandOutput = $0 }
        )
    }

    private var pendingUserQuestion: Binding<ContinuationUserQuestionProvider.Pending?> {
        Binding(
            get: { model.pendingUserQuestion },
            set: { value in
                if value == nil, model.pendingUserQuestion != nil {
                    model.cancelPendingUserQuestion()
                }
            }
        )
    }

    private func send(disposition: QueuedInputDisposition) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task {
            await model.submit(text, disposition: disposition)
        }
    }

    private func showCommands() {
        if draft.isEmpty {
            draft = "/"
        } else if !draft.hasPrefix("/") {
            draft = "/ " + draft
        }
        isInputFocused = true
    }

    private func selectCommand(_ command: SlashCommandDescriptor) {
        let suffix = command.input == nil ? "" : " "
        draft = "/\(command.name)\(suffix)"
        isInputFocused = true
    }

    private func beginEditingQueuedInput(_ input: QueuedAgentInput) {
        queuedEditText = input.text
        editingQueuedInput = input
    }

    private var activeSessionTitle: String {
        model.sessions.first(where: { $0.id == model.activeSessionID })?.title ?? "Harness"
    }

    private var renderedMessages: [AgentMessage] {
        Array(model.messages.suffix(renderedMessageLimit))
    }

    private var hiddenMessageCount: Int {
        max(0, model.messages.count - renderedMessages.count)
    }

    private func loadEarlierMessages() {
        renderedMessageLimit = min(model.messages.count, renderedMessageLimit + 80)
    }

    /// Stream presentation is already coalesced in AppModel. Scroll less
    /// often than the displayed text changes, and leave the user alone once
    /// they browse earlier context.
    private func scheduleAutomaticScroll(_ proxy: ScrollViewProxy) {
        guard followsConversationTail else { return }
        automaticScrollTask?.cancel()
        automaticScrollTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(125))
            } catch {
                return
            }
            guard !Task.isCancelled, followsConversationTail else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            automaticScrollTask = nil
        }
    }

    private func prepareExport(_ format: ConversationExportFormat) {
        guard let sessionID = model.activeSessionID else {
            model.errorMessage = "当前没有可导出的会话。"
            return
        }
        do {
            let configuration = model.effectiveConfiguration
            let data = try ConversationExportBuilder.makeData(
                input: ConversationExportInput(
                    sessionID: sessionID,
                    title: activeSessionTitle,
                    providerID: configuration.providerID.rawValue,
                    model: configuration.model,
                    messages: model.messages
                ),
                format: format
            )
            exportDocument = ConversationExportFileDocument(data: data)
            exportContentType = format == .json
                ? .json
                : ConversationExportFileDocument.markdownContentType
            exportFilename = sanitizedExportFilename(
                "\(activeSessionTitle)-\(sessionID.uuidString.prefix(8))"
            )
            isFileExporterPresented = true
        } catch {
            model.presentError(error)
        }
    }

    private func sanitizedExportFilename(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-")
        return String(cleaned.prefix(120))
    }

    private func consumePendingDraft() {
        guard let pendingDraft = model.pendingDraft else { return }
        draft = pendingDraft
        model.pendingDraft = nil
        isInputFocused = true
    }
}

private extension ToolApprovalScope {
    var chatResourceSummary: String {
        resources.map { resource in
            switch resource {
            case "tool":
                "整个 \(toolName) 工具"
            case "workspace:root":
                "App 工作区"
            case "ish-sandbox:/workspace":
                "iSH /workspace 沙箱"
            default:
                resource.replacingOccurrences(of: "workspace:file:", with: "工作区文件：")
            }
        }
        .joined(separator: "，")
    }
}

private enum ConversationMode: String, CaseIterable, Identifiable {
    case chat
    case trajectory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .trajectory: "Trajectory"
        }
    }
}

private struct ConversationViewportHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationTimeline: View {
    let hasResumableRun: Bool
    let isRunning: Bool
    let omittedContextMessages: Int
    let messages: [AgentMessage]
    let hiddenMessageCount: Int
    let streamingReasoning: String
    let streamingText: String
    let activeToolStatus: String?
    let activeToolEvents: [AgentToolEvent]
    let bottomID: String
    let onResume: () -> Void
    let onLoadEarlierMessages: () -> Void
    let onStartInput: () -> Void
    let onToggleFeedback: (UUID, MessageFeedbackRating) -> Void
    let onUpdateFeedbackNote: (UUID, String) -> Void

    var body: some View {
        LazyVStack(spacing: 14) {
            if hiddenMessageCount > 0 {
                Button(action: onLoadEarlierMessages) {
                    Label(
                        "显示更早的 \(min(hiddenMessageCount, 80)) 条消息",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if hasResumableRun, !isRunning {
                Button(action: onResume) {
                    Label("继续上次未完成的任务", systemImage: "arrow.clockwise.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("resume-agent-run")
            }

            if omittedContextMessages > 0 {
                Label(
                    "已在本机压缩较早上下文（省略 \(omittedContextMessages) 条）",
                    systemImage: "archivebox"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if messages.isEmpty, streamingText.isEmpty {
                Button(action: onStartInput) {
                    VStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("有什么要处理？")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 104)
            }

            ForEach(messages) { message in
                MessageBubble(
                    message: message,
                    onToggleFeedback: onToggleFeedback,
                    onUpdateFeedbackNote: onUpdateFeedbackNote
                )
                .equatable()
            }

            if !streamingReasoning.isEmpty || !streamingText.isEmpty {
                StreamingMessageBubble(
                    reasoning: streamingReasoning,
                    text: streamingText
                )
            }

            if !activeToolEvents.isEmpty {
                ToolEventTreeView(events: activeToolEvents, isLive: isRunning)
            } else if let activeToolStatus {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(activeToolStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Color.clear
                .frame(height: 1)
                .id(bottomID)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ConversationBottomPreferenceKey.self,
                            value: proxy.frame(in: .named("conversation-scroll")).minY
                        )
                    }
                }
        }
    }
}
