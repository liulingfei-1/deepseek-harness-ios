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
    @State private var isFileImporterPresented = false
    @State private var triggerSuggestions: InputTriggerSuggestionSnapshot?
    @State private var editingQueuedInput: QueuedAgentInput?
    @State private var queuedEditText = ""
    @State private var editingUserMessage: AgentMessage?
    @State private var userMessageEditText = ""
    @State private var isSettingsPresented = false
    @State private var isJobsPresented = false
    @State private var isSessionOptionsPresented = false
    @State private var isSchedulePanelPresented = false
    @State private var isExportFormatPresented = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportContentType = UTType.json
    @State private var exportFilename = "Harness-Conversation"
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.visibleSessionPath.count > 1 {
                SessionBreadcrumbBar(
                    path: model.visibleSessionPath,
                    onOpen: { node in
                        Task { await model.openVisibleSessionPathNode(node) }
                    }
                )
            }
        }
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
                            Text("\(model.effectiveConfiguration.model) · \(model.interactionMode.title)")
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
                sessionOptionsButton
            }

        }
        .sheet(isPresented: $isSessionOptionsPresented) {
            NavigationStack {
                sessionOptionsPanel
                    // The session controls are deliberately entered through the
                    // compact top-right ellipsis. Repeating a four-character
                    // title in the sheet made it look like an in-content button
                    // on compact iPhone navigation bars.
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task {
            consumePendingDraft()
            await model.refreshVisibleJobs()
        }
        .onChange(of: model.pendingDraft) {
            consumePendingDraft()
        }
        .onChange(of: model.activeSessionID) {
            consumePendingDraft()
            Task { await model.refreshVisibleJobs() }
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
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.pdf, .audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else {
                    model.presentError(
                        NSError(
                            domain: "HarnessMobile",
                            code: 400,
                            userInfo: [
                                NSLocalizedDescriptionKey: "没有可导入的文件。"
                            ]
                        )
                    )
                    return
                }
                Task { await model.stageFileAttachment(from: url) }
            case let .failure(error):
                model.presentError(error)
            }
        }
        .task(id: draft) {
            let requestedDraft = draft
            let snapshot = await model.inputTriggerSuggestions(
                for: requestedDraft,
                draftRevision: 0
            )
            guard !Task.isCancelled, requestedDraft == draft else { return }
            triggerSuggestions = snapshot
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
        .sheet(isPresented: $isJobsPresented) {
            JobsPanelView()
        }
        .sheet(isPresented: $isSchedulePanelPresented) {
            HarnessSchedulePanel(
                store: model.scheduleStore,
                sessionID: model.activeSessionID?.uuidString ?? ""
            ) {
                isSchedulePanelPresented = false
            }
        }
        .sheet(isPresented: agentPresetPickerPresented) {
            AgentPresetPickerView()
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
        .sheet(item: pendingCommandInteraction) { pending in
            SlashCommandInteractionSheet(pending: pending) { response in
                model.resolveSlashCommandInteraction(response)
            }
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
        .sheet(item: $editingUserMessage) { message in
            EditUserMessageView(
                text: $userMessageEditText,
                onRerun: {
                    model.editAndRerunUserMessage(
                        id: message.id,
                        text: userMessageEditText
                    )
                    editingUserMessage = nil
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
            if model.pendingApproval != nil {
                Button("仅允许这一次") {
                    model.resolveApproval(.allowOnce)
                }
                Button("始终允许此范围") {
                    model.resolveApproval(.trustScope)
                }
                if model.pendingApproval?.risk != .destructive {
                    Button("始终允许本机工具") {
                        model.resolveApproval(.trustDevice)
                    }
                }
            }
        } message: {
            if let approval = model.pendingApproval {
                Text(
                    "\(approval.summary)\n\n当前范围：\(approval.scope.chatResourceSummary)\n\n工具只在本机执行；产生的文字结果将发送给 \(approval.modelHost) 继续推理。\(approval.risk == .destructive ? "危险操作只能永久允许当前精确范围，不能使用整机通配授权。" : "可永久允许当前范围或本机常规工具。")长期 Harness 授权可在设置中撤销，不会跳过 iOS 的照片、联系人、位置等系统权限。"
                )
            }
        }
    }

    @ViewBuilder
    private var sessionOptionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    conversationMode = .chat
                    isSessionOptionsPresented = false
                } label: {
                    optionLabel("对话", systemImage: "bubble.left.and.bubble.right", selected: conversationMode == .chat)
                }
                .accessibilityIdentifier("对话")

                Button {
                    conversationMode = .trajectory
                    isSessionOptionsPresented = false
                } label: {
                    optionLabel("轨迹", systemImage: "point.3.connected.trianglepath.dotted", selected: conversationMode == .trajectory)
                }
                .accessibilityIdentifier("轨迹")

                Divider()

                Button {
                    model.isSessionAgentPresetPickerRequested = true
                    isSessionOptionsPresented = false
                } label: {
                    Label(
                        "Agent 预设：\(model.activeAgentPreset?.displayName ?? model.controlState.agentPresetID)",
                        systemImage: "switch.2"
                    )
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
                    isSessionOptionsPresented = false
                } label: {
                    Label("切换模型", systemImage: "cpu")
                }
                .disabled(model.isRunning)

                Button {
                    isSettingsPresented = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("设置", systemImage: "gearshape")
                }

                Button {
                    isJobsPresented = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("后台任务", systemImage: "list.bullet.rectangle")
                }

                Button {
                    isSessionOptionsPresented = false
                    isSchedulePanelPresented = true
                } label: {
                    Label("定时提醒", systemImage: "clock.badge.checkmark")
                }
                .accessibilityIdentifier("定时提醒")

                Button {
                    isExportFormatPresented = true
                    isSessionOptionsPresented = false
                } label: {
                    Label("导出对话", systemImage: "square.and.arrow.up")
                }
                .disabled(model.messages.isEmpty)
            }
            .padding(16)
            .frame(minWidth: 260, alignment: .leading)
        }
    }

    private var sessionOptionsButton: some View {
        Button {
            isSessionOptionsPresented = true
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("会话选项")
        .accessibilityHint("打开对话、轨迹、模型和工具权限选项")
        .accessibilityIdentifier("会话选项")
    }

    private func optionLabel(_ title: String, systemImage: String, selected: Bool) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 16)
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private var chatSurface: some View {
        ConversationScroller(
            model: model,
            onStartInput: { isInputFocused = true },
            onEditUserMessage: beginEditingUserMessage
        )
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                ConversationWorkStateDock()

                ChatInputBar(
                    draft: $draft,
                    selectedPhoto: $selectedPhoto,
                    isRunning: model.isRunning,
                    isSubmitting: model.isSubmitting,
                    submissionStatus: model.submissionStatus,
                    hasStagedImage: model.hasStagedImage,
                    hasStagedFile: model.hasStagedFile,
                    queuedInputs: model.queuedInputs,
                    triggerGroups: triggerSuggestions?.groups ?? [],
                    onCamera: {
                        isCameraPresented = true
                    },
                    onPickFile: {
                        isFileImporterPresented = true
                    },
                    onShowCommands: showCommands,
                    onSelectSuggestion: selectSuggestion,
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = model.errorMessage {
                ChatErrorBanner(message: errorMessage) {
                    model.errorMessage = nil
                }
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

    private var modelPickerPresented: Binding<Bool> {
        Binding(
            get: { model.isSessionModelPickerRequested },
            set: { model.isSessionModelPickerRequested = $0 }
        )
    }

    private var agentPresetPickerPresented: Binding<Bool> {
        Binding(
            get: { model.isSessionAgentPresetPickerRequested },
            set: { model.isSessionAgentPresetPickerRequested = $0 }
        )
    }

    private var commandOutput: Binding<DirectCommandOutput?> {
        Binding(
            get: { model.directCommandOutput },
            set: { model.directCommandOutput = $0 }
        )
    }

    private var pendingCommandInteraction: Binding<PendingSlashCommandInteraction?> {
        Binding(
            get: { model.pendingSlashCommandInteraction },
            set: { value in
                if value == nil, model.pendingSlashCommandInteraction != nil {
                    model.resolveSlashCommandInteraction(.cancelled)
                }
            }
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
        guard !model.isSubmitting,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { @MainActor in
            let accepted = await model.submit(text, disposition: disposition)
            guard accepted, draft == text else { return }
            draft = ""
        }
    }

    private func beginEditingUserMessage(_ message: AgentMessage) {
        guard !model.isRunning, !model.isSubmitting else { return }
        userMessageEditText = message.content
        editingUserMessage = message
    }

    private func showCommands() {
        if draft.isEmpty {
            draft = "/"
        } else if draft.last?.isWhitespace == true {
            draft.append("/")
        } else {
            draft.append(" /")
        }
        isInputFocused = true
    }

    private func selectSuggestion(_ suggestion: InputTriggerSuggestion) {
        guard let snapshot = triggerSuggestions,
              snapshot.draft == draft,
              let updated = InputTriggerDetector.replacing(
                  draft,
                  span: snapshot.hit.span,
                  with: suggestion.replacementText,
                  currentRevision: snapshot.hit.span.draftRevision
              ) else { return }
        draft = updated
        triggerSuggestions = nil

        if snapshot.hit.position == .leading,
           case let .command(command) = suggestion.kind {
            switch command.name {
            case "model":
                draft = ""
                model.isSessionModelPickerRequested = true
            case "agent":
                draft = ""
                model.isSessionAgentPresetPickerRequested = true
            default:
                break
            }
        }
        isInputFocused = true
    }

    private func beginEditingQueuedInput(_ input: QueuedAgentInput) {
        queuedEditText = input.text
        editingQueuedInput = input
    }

    private var activeSessionTitle: String {
        model.sessions.first(where: { $0.id == model.activeSessionID })?.title ?? "Harness"
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

private struct ChatErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: HarnessTheme.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HarnessTheme.Spacing.xSmall) {
                Text("任务未完成")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.leading, HarnessTheme.Spacing.large)
        .padding(.trailing, HarnessTheme.Spacing.small)
        .padding(.vertical, HarnessTheme.Spacing.small)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-error-banner")
    }
}

private struct SessionBreadcrumbBar: View {
    let path: [HarnessSessionPathNode]
    let onOpen: (HarnessSessionPathNode) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }

                    Button {
                        onOpen(node)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: index == 0 ? "house" : statusIcon(node.status))
                            Text(node.label)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(node.isCurrent ? .semibold : .regular))
                        .foregroundStyle(node.isCurrent ? Color.primary : Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            node.isCurrent ? Color.secondary.opacity(0.12) : Color.clear,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(node.isCurrent)
                    .accessibilityLabel(
                        node.isCurrent
                            ? "当前子 Agent，\(node.label)，地址深度 \(node.depth)"
                            : "返回 \(node.label)，地址深度 \(node.depth)"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-breadcrumb")
    }

    private func statusIcon(_ status: HarnessJobStatus?) -> String {
        switch status {
        case .running: "bolt.horizontal.circle.fill"
        case .stopping: "hourglass.circle"
        case .completed: "checkmark.circle.fill"
        case .killed: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        case nil: "circle"
        }
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

private struct ConversationScroller: View {
    let model: AppModel
    let onStartInput: () -> Void
    let onEditUserMessage: (AgentMessage) -> Void

    @State private var renderedMessageLimit = 80
    @State private var renderedMessages: [AgentMessage] = []
    @State private var hiddenMessageCount = 0
    @State private var availableMessageCount = 0
    @State private var followsConversationTail = true
    @State private var automaticScrollTask: Task<Void, Never>?
    @State private var scrollViewportHeight: CGFloat = 0

    private let bottomID = "conversation-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ConversationTimeline(
                    hasResumableRun: model.hasResumableRun,
                    isRunning: model.isRunning,
                    omittedContextMessages: model.omittedContextMessages,
                    messages: renderedMessages,
                    hiddenMessageCount: hiddenMessageCount,
                    contextInjections: model.activeContextInjections,
                    activeRunID: model.activeRunID,
                    streamingReasoning: model.streamingReasoning,
                    streamingText: model.streamingText,
                    activeToolStatus: model.activeToolStatus,
                    activeToolEvents: model.activeToolEvents,
                    runStartedAt: model.runStartedAt,
                    pendingQuestionCount: model.pendingUserQuestion?.request.questions.count ?? 0,
                    pendingQuestionTitle: model.pendingUserQuestion?.request.questions.first?.question,
                    metrics: model.trajectoryMetrics,
                    bottomID: bottomID,
                    onResume: model.resumePendingRun,
                    onLoadEarlierMessages: loadEarlierMessages,
                    onStartInput: onStartInput,
                    onRetryUserMessage: model.retryFromUserMessage,
                    onEditUserMessage: onEditUserMessage,
                    onToggleFeedback: model.toggleMessageFeedback,
                    onUpdateFeedbackNote: model.updateMessageFeedbackNote
                )
                .padding(.horizontal)
                .padding(.top, 12)
            }
            .coordinateSpace(.named("conversation-scroll"))
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ConversationViewportHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
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
            .task(id: model.activeSessionID) {
                renderedMessageLimit = 80
                followsConversationTail = true
                refreshRenderedMessages()
                scheduleAutomaticScroll(proxy)
            }
            .onChange(of: model.messagesRevision) {
                refreshRenderedMessages()
                scheduleAutomaticScroll(proxy)
            }
            .onChange(of: model.streamingPresentationRevision) {
                scheduleAutomaticScroll(proxy)
            }
            .onDisappear {
                automaticScrollTask?.cancel()
                automaticScrollTask = nil
            }
        }
    }

    private func loadEarlierMessages() {
        renderedMessageLimit = min(availableMessageCount, renderedMessageLimit + 80)
        refreshRenderedMessages()
    }

    private func refreshRenderedMessages() {
        let window = ConversationMessageWindow.project(
            model.messages,
            limit: renderedMessageLimit
        )
        renderedMessages = window.messages
        hiddenMessageCount = window.hiddenCount
        availableMessageCount = window.totalCount
    }

    /// Keep at most one pending scroll. Continuous model deltas then produce a
    /// bounded 8 Hz scroll cadence instead of cancelling and reallocating a task
    /// for every presentation update.
    private func scheduleAutomaticScroll(_ proxy: ScrollViewProxy) {
        guard followsConversationTail, automaticScrollTask == nil else { return }
        automaticScrollTask = Task { @MainActor in
            defer { automaticScrollTask = nil }
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
        }
    }
}

private struct ConversationTimeline: View {
    let hasResumableRun: Bool
    let isRunning: Bool
    let omittedContextMessages: Int
    let messages: [AgentMessage]
    let hiddenMessageCount: Int
    let contextInjections: [AgentContextInjection]
    let activeRunID: UUID?
    let streamingReasoning: String
    let streamingText: String
    let activeToolStatus: String?
    let activeToolEvents: [AgentToolEvent]
    let runStartedAt: Date?
    let pendingQuestionCount: Int
    let pendingQuestionTitle: String?
    let metrics: SessionTrajectoryMetrics?
    let bottomID: String
    let onResume: () -> Void
    let onLoadEarlierMessages: () -> Void
    let onStartInput: () -> Void
    let onRetryUserMessage: (UUID) -> Void
    let onEditUserMessage: (AgentMessage) -> Void
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
                .accessibilityIdentifier("load-earlier-messages")
                .accessibilityValue("尚有 \(hiddenMessageCount) 条较早消息")
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

            if messages.isEmpty, streamingText.isEmpty, !isRunning {
                Button(action: onStartInput) {
                    VStack(spacing: 12) {
                        HarnessIconTile(systemImage: "sparkles", tint: .secondary, size: 40)
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
                VStack(alignment: .leading, spacing: 14) {
                    MessageBubble(
                        message: message,
                        canRerunUserMessage: !isRunning,
                        retryUserMessageID: messageActionTargets[message.id],
                        onRetryUserMessage: onRetryUserMessage,
                        onEditUserMessage: onEditUserMessage,
                        onToggleFeedback: onToggleFeedback,
                        onUpdateFeedbackNote: onUpdateFeedbackNote
                    )
                    .equatable()

                    if message.id == latestUserMessageID, !contextInjections.isEmpty {
                        ContextInjectionList(injections: contextInjections)
                    }
                }
                .id(ConversationPresentationItem.message(message).id)
            }

            if !streamingReasoning.isEmpty || !streamingText.isEmpty {
                StreamingMessageBubble(
                    runID: activeRunID?.uuidString ?? "session-stream",
                    reasoning: streamingReasoning,
                    text: streamingText
                )
                .id(
                    ConversationPresentationItemID.streaming(
                        runID: activeRunID?.uuidString ?? "session-stream",
                        kind: "assistant"
                    )
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

            if pendingQuestionCount > 0 {
                PendingQuestionStatus(
                    count: pendingQuestionCount,
                    title: pendingQuestionTitle
                )
            }

            if isRunning {
                HarnessRunStatus(startedAt: runStartedAt)
            }

            if let metrics, metrics.steps > 0 || metrics.calls > 0 || metrics.outputTokens > 0 {
                ConversationMetricsStrip(metrics: metrics)
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

    private var latestUserMessageID: UUID? {
        messages.last(where: { $0.role == .user })?.id
    }

    private var messageActionTargets: [UUID: UUID] {
        ConversationMessageActionTargets.resolve(messages).retryUserMessageIDByMessageID
    }

}

private struct ContextInjectionList: View {
    let injections: [AgentContextInjection]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(injections) { injection in
                ContextInjectionRow(injection: injection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已注入上下文")
    }
}

private struct ContextInjectionRow: View {
    let injection: AgentContextInjection

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    HarnessIconTile(
                        systemImage: injection.form == "catalog" ? "books.vertical" : "arrow.turn.down.right",
                        tint: .secondary,
                        size: 24
                    )
                    Text(injection.sourceLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let formLabel {
                        Text(formLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(injection.sourceLabel) 上下文")
            .accessibilityHint(isExpanded ? "折叠注入内容" : "展开注入内容")

            if isExpanded {
                ScrollView {
                    Text(injection.content)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(.leading, 23)
            }
        }
    }

    private var formLabel: String? {
        switch injection.form {
        case "catalog": "catalog"
        case "instructions": "instructions"
        case "opaque": nil
        case let value?: value
        case nil: nil
        }
    }
}

private struct PendingQuestionStatus: View {
    let count: Int
    let title: String?

    var body: some View {
        HStack(spacing: 9) {
            HarnessIconTile(systemImage: "questionmark.bubble.fill", tint: .orange, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("等待你的回答")
                    .font(.caption.weight(.semibold))
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(count) 题")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("等待你的回答，共 \(count) 个问题")
    }
}

private struct HarnessRunStatus: View {
    let startedAt: Date?

    @State private var mountedAt = Date.now

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt ?? mountedAt))
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在深入处理…")
                    .font(.caption.weight(.medium))
                if elapsed >= 15 {
                    Text(Self.duration(elapsed))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("正在深入处理，已运行 \(Self.duration(elapsed))")
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct ConversationMetricsStrip: View {
    let metrics: SessionTrajectoryMetrics

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                metric("Turns", String(metrics.turns))
                metric("Steps", String(metrics.steps))
                metric("Calls", String(metrics.calls))
                metric("LLM", duration(metrics.modelDurationMilliseconds))
                metric("Tools", duration(metrics.toolDurationMilliseconds))
                metric("TTFT", metrics.averageTTFTMilliseconds.map(duration) ?? "-")
                metric("Tok/s", tokensPerSecond)
                metric("Cache", CacheHitRateFormat.percent(metrics.cacheHitRate))
                metric("Input", count(metrics.uncachedInputTokens + metrics.cacheReadTokens))
                metric("Output", count(metrics.outputTokens))
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .frame(height: 38)
        .background(HarnessTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("对话运行统计")
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var tokensPerSecond: String {
        guard metrics.decodeDurationMilliseconds > 0 else { return "-" }
        let rate = Double(metrics.decodeTokens) / (metrics.decodeDurationMilliseconds / 1_000)
        return String(format: "%.1f", rate)
    }

    private func duration(_ milliseconds: Double) -> String {
        if milliseconds < 1_000 { return "\(Int(milliseconds.rounded()))ms" }
        return String(format: "%.1fs", milliseconds / 1_000)
    }

    private func count(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
}

private struct AgentPresetPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.agentPresets) { preset in
                    Button {
                        model.selectAgentPresetFromUI(id: preset.id)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            HarnessIconTile(
                                systemImage: systemImage(for: preset),
                                tint: preset.isMountable ? .accentColor : .secondary,
                                size: 32
                            )
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(preset.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if preset.trust == .user {
                                        Text("用户")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let description = preset.description {
                                    Text(description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if let broken = preset.broken {
                                    Label(broken, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            if selectedPresetID == preset.id {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            } else if !preset.isMountable {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!preset.isMountable || model.isRunning)
                    .accessibilityLabel(preset.displayName)
                    .accessibilityValue(preset.broken ?? (selectedPresetID == preset.id ? "已选择" : "可选择"))
                }
            }
            .navigationTitle("Agent 预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // All four presets must be reachable without a drag gesture; a medium
        // detent hides the lower half of the lazy list from the accessibility
        // tree as well as from the user.
        .presentationDetents([.large])
    }

    private var selectedPresetID: String {
        model.activeAgentPreset?.id ?? model.controlState.agentPresetID
    }

    private func systemImage(for preset: AgentPresetDefinition) -> String {
        switch preset.id {
        case "cordis": "wand.and.stars"
        case "minimal": "leaf"
        case "code": "chevron.left.forwardslash.chevron.right"
        default: "cpu"
        }
    }
}

private struct JobsPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedJobID: String?
    @State private var isOutputPresented = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            Group {
                if model.visibleJobs.isEmpty {
                    ContentUnavailableView(
                        "暂无后台任务",
                        systemImage: "checkmark.circle",
                        description: Text("后台工具和子 Agent 完成后会保留在这里。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HarnessTheme.pageBackground)
                } else {
                    List {
                        ForEach(model.visibleJobs, id: \.id) { job in
                            JobPanelRow(
                                job: job,
                                onOutput: {
                                    selectedJobID = job.id
                                    isOutputPresented = true
                                },
                                onStop: {
                                    Task {
                                        do {
                                            try await model.stopVisibleJob(job.id)
                                        } catch {
                                            model.presentError(error)
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.defaultMinListRowHeight, 44)
                    .scrollContentBackground(.hidden)
                    .background(HarnessTheme.pageBackground)
                }
            }
            .safeAreaInset(edge: .top) {
                if !model.visibleSubagents.isEmpty {
                    SubagentTreeSection(
                        subagents: model.visibleSubagents,
                        onOpen: { subagent in
                            Task {
                                await model.openVisibleSubagent(subagent)
                                dismiss()
                            }
                        },
                        onStop: { subagent in
                            Task {
                                do {
                                    try await model.stopVisibleSubagent(subagent)
                                } catch {
                                    model.presentError(error)
                                }
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .navigationTitle("后台任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: isRefreshing ? "progress.indicator" : "arrow.clockwise")
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("刷新后台任务")
                }
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $isOutputPresented) {
            if let selectedJobID {
                JobOutputPanelView(jobID: selectedJobID)
            }
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await model.refreshVisibleJobs()
        isRefreshing = false
    }
}

private struct SubagentTreeSection: View {
    let subagents: [HarnessSubagentSnapshot]
    let onOpen: (HarnessSubagentSnapshot) -> Void
    let onStop: (HarnessSubagentSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("子 Agent", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.subheadline.weight(.semibold))
            ForEach(subagents, id: \.id) { subagent in
                SubagentTreeRow(
                    subagent: subagent,
                    onOpen: { onOpen(subagent) },
                    onStop: { onStop(subagent) }
                )
            }
        }
    }
}

private struct SubagentTreeRow: View {
    let subagent: HarnessSubagentSnapshot
    let onOpen: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HarnessIconTile(systemImage: statusIcon, tint: statusColor, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(subagent.label)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("深度 \(subagent.delegationDepth) · \(statusTitle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.app")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("打开子 Agent")
            if !subagent.status.isTerminal {
                Button(role: .destructive, action: onStop) {
                    Image(systemName: "stop.circle")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("停止子 Agent")
            }
        }
        .padding(.leading, CGFloat(max(0, subagent.delegationDepth - 1)) * 16)
    }

    private var statusTitle: String {
        switch subagent.status {
        case .running: "运行中"
        case .stopping: "停止中"
        case .completed: "已完成"
        case .killed: "已停止"
        case .failed: "失败"
        }
    }

    private var statusIcon: String {
        switch subagent.status {
        case .running: "bolt.horizontal.circle"
        case .stopping: "hourglass"
        case .completed: "checkmark.circle"
        case .killed: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch subagent.status {
        case .running: .green
        case .stopping: .orange
        case .completed: .blue
        case .killed: .secondary
        case .failed: .red
        }
    }
}

private struct JobPanelRow: View {
    let job: HarnessJobSnapshot
    let onOutput: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HarnessIconTile(systemImage: statusIcon, tint: statusColor, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.label)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    Text("\(job.kind) · \(job.id.prefix(12))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            if let detail = job.detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 12) {
                Button(action: onOutput) {
                    Label("查看输出", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                if !job.status.isTerminal {
                    Button(role: .destructive, action: onStop) {
                        Label("停止", systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .font(.footnote.weight(.medium))
        }
        .padding(.vertical, 4)
    }

    private var statusTitle: String {
        switch job.status {
        case .running: "运行中"
        case .stopping: "停止中"
        case .completed: "已完成"
        case .killed: "已停止"
        case .failed: "失败"
        }
    }

    private var statusIcon: String {
        switch job.status {
        case .running: "bolt.horizontal.circle"
        case .stopping: "hourglass"
        case .completed: "checkmark.circle"
        case .killed: "stop.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .running: .green
        case .stopping: .orange
        case .completed: .blue
        case .killed: .secondary
        case .failed: .red
        }
    }
}

private struct JobOutputPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    @State private var read: HarnessJobRead?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let read {
                    ScrollView {
                        Text(read.text)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(16)
                    }
                } else if let errorMessage {
                    ContentUnavailableView("无法读取输出", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    ProgressView("正在读取")
                }
            }
            .navigationTitle("任务输出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task {
            do {
                read = try await model.readVisibleJob(jobID)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
