import SwiftUI

@MainActor
struct ConversationWorkStateDock: View {
    @Environment(AppModel.self) private var model
    @State private var isTodoExpanded = false

    private var visibleGoal: ConversationGoal? {
        guard let goal = model.workState.goal, goal.status != .completed else {
            return nil
        }
        return goal
    }

    private var hasContent: Bool {
        visibleGoal != nil || !model.workState.todos.isEmpty
    }

    var body: some View {
        if hasContent {
            VStack(spacing: 6) {
                if !model.workState.todos.isEmpty {
                    ConversationTodoPanel(
                        todos: model.workState.todos,
                        isExpanded: $isTodoExpanded
                    )
                }

                if let visibleGoal {
                    ConversationGoalBar(
                        goal: visibleGoal,
                        onAction: model.applyGoalAction
                    )
                    .id(visibleGoal.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .background(.bar)
            .overlay(alignment: .top) {
                Divider()
            }
            .accessibilityIdentifier("conversation-work-state-dock")
        }
    }
}

@MainActor
private struct ConversationGoalBar: View {
    let goal: ConversationGoal
    let onAction: (ConversationGoalAction) async -> Bool

    @State private var isEditing = false
    @State private var draft = ""
    @State private var isPending = false
    @State private var isClearConfirmationPresented = false
    @FocusState private var isEditFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                editRow
            } else {
                summaryRow
            }
        }
        .frame(minHeight: 36)
        .padding(.horizontal, 8)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .confirmationDialog(
            "清空当前目标？",
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清空目标", role: .destructive) {
                perform(.clear)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目标会从当前会话移除，聊天记录、计划和待办不会被删除。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-goal-bar")
    }

    private var summaryRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(goal.status.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(goal.status.tint)
                .fixedSize()

            Text(goal.title)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                primaryLifecycleButton

                Button {
                    draft = goal.title
                    isEditing = true
                    isEditFocused = true
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑目标")
                .accessibilityIdentifier("goal-edit-button")

                lifecycleMenu
            }
        }
    }

    @ViewBuilder
    private var primaryLifecycleButton: some View {
        switch goal.status {
        case .active:
            Button {
                perform(.pause)
            } label: {
                Image(systemName: "pause")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("暂停目标")
            .accessibilityIdentifier("goal-pause-button")
        case .paused, .blocked:
            Button {
                perform(.resume)
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("恢复目标")
            .accessibilityIdentifier("goal-resume-button")
        case .pending:
            Button {
                perform(.transition(to: .active))
            } label: {
                Image(systemName: "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("开始目标")
            .accessibilityIdentifier("goal-start-button")
        case .completed:
            EmptyView()
        }
    }

    private var lifecycleMenu: some View {
        Menu {
            ForEach(secondaryTransitions, id: \.rawValue) { status in
                Button {
                    perform(.transition(to: status))
                } label: {
                    Label(status.actionTitle, systemImage: status.systemImage)
                }
            }

            if !secondaryTransitions.isEmpty {
                Divider()
            }

            Button(role: .destructive) {
                isClearConfirmationPresented = true
            } label: {
                Label("清空目标", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多目标操作")
        .accessibilityIdentifier("goal-more-menu")
    }

    private var editRow: some View {
        HStack(spacing: 6) {
            TextField("目标", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($isEditFocused)
                .submitLabel(.done)
                .onSubmit(saveEdit)
                .disabled(isPending)
                .accessibilityIdentifier("goal-edit-field")

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                Button(action: saveEdit) {
                    Image(systemName: "checkmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("保存目标")
                .accessibilityIdentifier("goal-save-button")

                Button {
                    isEditing = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("取消编辑目标")
            }
        }
    }

    private var secondaryTransitions: [ConversationItemStatus] {
        goal.status.allowedGoalTransitions.filter { status in
            switch (goal.status, status) {
            case (.active, .paused), (.paused, .active), (.blocked, .active), (.pending, .active):
                false
            default:
                true
            }
        }
    }

    private func saveEdit() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        perform(.edit(title: title), exitsEditMode: true)
    }

    private func perform(
        _ action: ConversationGoalAction,
        exitsEditMode: Bool = false
    ) {
        guard !isPending else { return }
        isPending = true
        Task { @MainActor in
            let succeeded = await onAction(action)
            if succeeded, exitsEditMode {
                isEditing = false
            }
            isPending = false
        }
    }
}

private struct ConversationTodoPanel: View {
    let todos: [ConversationTodoItem]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: isExpanded ? 6 : 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("待办")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(progressSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("待办，\(progressSummary)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .accessibilityIdentifier("todo-panel-toggle")

            if isExpanded {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(todos) { todo in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: todo.status.systemImage)
                                    .font(.caption)
                                    .foregroundStyle(todo.status.tint)
                                    .frame(width: 16)
                                    .accessibilityHidden(true)

                                Text(todo.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(todo.title)
                            .accessibilityValue(todo.status.title)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: listMaximumHeight)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation-todo-panel")
    }

    private var listMaximumHeight: CGFloat {
        min(CGFloat(todos.count) * 31, 170)
    }

    private var progressSummary: String {
        let completed = todos.count { $0.status == .completed }
        let active = todos.count { $0.status == .active }
        let blocked = todos.count { $0.status == .blocked }
        let paused = todos.count { $0.status == .paused }
        let pending = todos.count - completed - active - blocked - paused

        return [
            completed > 0 ? "\(completed) 完成" : nil,
            active > 0 ? "\(active) 进行" : nil,
            blocked > 0 ? "\(blocked) 受阻" : nil,
            paused > 0 ? "\(paused) 暂停" : nil,
            pending > 0 ? "\(pending) 待处理" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
