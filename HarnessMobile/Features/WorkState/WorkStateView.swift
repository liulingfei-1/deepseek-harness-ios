import SwiftUI

struct WorkStateView: View {
    @Environment(AppModel.self) private var model
    @State private var goalEditor: GoalEditorRequest?
    @State private var isClearGoalConfirmationPresented = false

    var body: some View {
        List {
            if let errorMessage = model.errorMessage {
                WorkStateErrorSection(message: errorMessage)
            }

            if model.hasResumableRun {
                ResumeRunSection()
            }

            if model.isRunning {
                CurrentRunSection(
                    step: model.currentStep,
                    activeToolStatus: model.activeToolStatus
                )
            }

            if let goal = model.workState.goal {
                Section {
                    WorkStateGoalRow(
                        goal: goal,
                        onEdit: {
                            goalEditor = GoalEditorRequest(
                                mode: .edit,
                                initialTitle: goal.title
                            )
                        },
                        onCreateReplacement: {
                            goalEditor = GoalEditorRequest(mode: .create)
                        },
                        onTransition: { status in
                            Task {
                                await model.applyGoalAction(.transition(to: status))
                            }
                        },
                        onClear: {
                            isClearGoalConfirmationPresented = true
                        }
                    )
                } header: { Label("目标", systemImage: "scope") }
            } else {
                Section {
                    Button {
                        goalEditor = GoalEditorRequest(mode: .create)
                    } label: {
                        Label("创建会话目标", systemImage: "scope")
                    }
                } header: { Label("目标", systemImage: "scope") }
            }

            if !model.workState.plan.isEmpty {
                Section {
                    ForEach(model.workState.plan) { step in
                        WorkStateItemRow(title: step.title, status: step.status)
                    }
                } header: { Label("计划", systemImage: "list.bullet.clipboard") }
            }

            if !model.workState.todos.isEmpty {
                Section {
                    ForEach(model.workState.todos) { item in
                        WorkStateItemRow(title: item.title, status: item.status)
                    }
                } header: { Label("待办", systemImage: "checklist") }
            }

            if model.omittedContextMessages > 0 {
                Section {
                    Label {
                        Text(
                            "发送模型前已省略 \(model.omittedContextMessages) 条较早消息，并保留本地任务状态摘要。"
                        )
                    } icon: {
                        Image(systemName: "internaldrive")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: { Label("上下文治理", systemImage: "internaldrive") }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollContentBackground(.hidden)
        .background(HarnessTheme.pageBackground)
        .navigationTitle("任务状态")
        .sheet(item: $goalEditor) { request in
            GoalEditorSheet(request: request)
        }
        .confirmationDialog(
            "清空当前目标？",
            isPresented: $isClearGoalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清空目标", role: .destructive) {
                Task {
                    await model.applyGoalAction(.clear)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目标会从当前会话移除，聊天记录、计划和待办不会被删除。")
        }
    }

}

private struct WorkStateGoalRow: View {
    let goal: ConversationGoal
    let onEdit: () -> Void
    let onCreateReplacement: () -> Void
    let onTransition: (ConversationItemStatus) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HarnessIconTile(systemImage: goal.status.systemImage, tint: goal.status.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(goal.title)
                    .fixedSize(horizontal: false, vertical: true)
                HarnessStatusPill(
                    title: goal.status.title,
                    systemImage: goal.status.systemImage,
                    tint: goal.status.tint
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                Button(action: onEdit) {
                    Label("编辑目标", systemImage: "pencil")
                }

                ForEach(goal.status.allowedGoalTransitions, id: \.rawValue) { status in
                    Button {
                        onTransition(status)
                    } label: {
                        Label(status.actionTitle, systemImage: status.systemImage)
                    }
                }

                if goal.status == .completed {
                    Button(action: onCreateReplacement) {
                        Label("创建新目标", systemImage: "plus")
                    }
                }

                Divider()

                Button(role: .destructive, action: onClear) {
                    Label("清空目标", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("目标操作")
            .accessibilityIdentifier("work-state-goal-menu")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct GoalEditorRequest: Identifiable {
    enum Mode {
        case create
        case edit
    }

    let id = UUID()
    let mode: Mode
    let initialTitle: String

    init(mode: Mode, initialTitle: String = "") {
        self.mode = mode
        self.initialTitle = initialTitle
    }
}

@MainActor
private struct GoalEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isSaving = false

    let request: GoalEditorRequest

    init(request: GoalEditorRequest) {
        self.request = request
        _title = State(initialValue: request.initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("希望完成的结果", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("goal-editor-field")
                } header: {
                    Label("目标", systemImage: "scope")
                }
            }
            .navigationTitle(request.mode == .create ? "创建目标" : "编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(
                        isSaving
                            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.medium])
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        let action: ConversationGoalAction = switch request.mode {
        case .create:
            .create(title: title)
        case .edit:
            .edit(title: title)
        }
        Task { @MainActor in
            if await model.applyGoalAction(action) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}

private struct ResumeRunSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Button {
                model.errorMessage = nil
                model.resumePendingRun()
            } label: {
                Label("从本机检查点继续", systemImage: "arrow.clockwise.circle.fill")
                    .font(.headline)
            }
            .disabled(model.isRunning)
        } header: {
            Text("可恢复任务")
        } footer: {
            Text("继续当前会话最后一个未完成回合。恢复与 Agent Loop 均在手机执行，不会启动服务器任务。")
        }
    }
}

private struct CurrentRunSection: View {
    let step: Int
    let activeToolStatus: String?

    var body: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent 步骤")
                    Text("第 \(step) 步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                HarnessStatusPill(title: "运行中", systemImage: "bolt.fill", tint: .green)
            }

            if let activeToolStatus {
                Label(activeToolStatus, systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: { Label("当前执行", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") }
    }
}

private struct WorkStateItemRow: View {
    let title: String
    let status: ConversationItemStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HarnessIconTile(systemImage: status.systemImage, tint: status.tint, size: 28)

            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HarnessStatusPill(
                title: status.title,
                systemImage: status.systemImage,
                tint: status.tint
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(status.title)
    }
}

private struct WorkStateErrorSection: View {
    @Environment(AppModel.self) private var model

    let message: String

    var body: some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            Button("关闭") {
                model.errorMessage = nil
            }
        } header: {
            Label("执行失败", systemImage: "exclamationmark.triangle")
        }
    }
}

extension ConversationItemStatus {
    var title: String {
        switch self {
        case .pending:
            "待处理"
        case .active:
            "进行中"
        case .paused:
            "已暂停"
        case .completed:
            "已完成"
        case .blocked:
            "受阻"
        }
    }

    var actionTitle: String {
        switch self {
        case .pending:
            "标记为待处理"
        case .active:
            "开始或恢复"
        case .paused:
            "暂停目标"
        case .completed:
            "标记为已完成"
        case .blocked:
            "标记为受阻"
        }
    }

    var systemImage: String {
        switch self {
        case .pending:
            "circle"
        case .active:
            "play.circle.fill"
        case .paused:
            "pause.circle.fill"
        case .completed:
            "checkmark.circle.fill"
        case .blocked:
            "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pending:
            .secondary
        case .active:
            .blue
        case .paused:
            .orange
        case .completed:
            .green
        case .blocked:
            .red
        }
    }
}
