import SwiftUI

struct UserQuestionSheet: View {
    let pending: ContinuationUserQuestionProvider.Pending

    var body: some View {
        if let review = PlanReviewPresentation(request: pending.request) {
            PlanReviewSheet(review: review)
        } else {
            GenericUserQuestionSheet(pending: pending)
        }
    }
}

private struct GenericUserQuestionSheet: View {
    private struct Draft: Equatable {
        var selected: Set<String> = []
        var custom = ""
        var skipped = false
    }

    @Environment(AppModel.self) private var model
    let pending: ContinuationUserQuestionProvider.Pending

    @State private var drafts: [String: Draft]
    @State private var index = 0
    @State private var validationMessage: String?

    init(pending: ContinuationUserQuestionProvider.Pending) {
        self.pending = pending
        _drafts = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: pending.request.questions.map { ($0.id, Draft()) }
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let header = question.header {
                            Text(header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(question.question)
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let detail = question.detail {
                            NativeMarkdownText(source: detail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                        optionList(for: question)

                        if let validationMessage {
                            Label(validationMessage, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                    .accessibilityIdentifier("ask-user-question-\(question.id)")
                }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        move(to: index - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(index == 0)
                    .accessibilityLabel("上一题")

                    Text("\(index + 1) / \(pending.request.questions.count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        move(to: index + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.bordered)
                    .disabled(index == pending.request.questions.count - 1)
                    .accessibilityLabel("下一题")

                    Spacer(minLength: 0)

                    Button("跳过", action: skipCurrent)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ask-user-skip-\(question.id)")

                    Button(primaryActionTitle, action: continueFlow)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ask-user-submit")
                }
                .padding(16)
            }
            .accessibilityIdentifier("ask-user-question-sheet")
            .navigationTitle("需要你的选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.cancelPendingUserQuestion()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("取消提问")
                    .accessibilityIdentifier("ask-user-cancel")
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var question: AskUserQuestionItem {
        pending.request.questions[index]
    }

    private var primaryActionTitle: String {
        index == pending.request.questions.count - 1 ? "提交" : "下一题"
    }

    @ViewBuilder
    private func optionList(for question: AskUserQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let options = question.options {
                ForEach(Array(options.enumerated()), id: \.element.label) { optionIndex, option in
                    let display = recommendedDisplay(for: option.label)
                    Button {
                        toggle(option.label, for: question)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            if question.multiSelect {
                                Image(
                                    systemName: isSelected(option.label, for: question)
                                        ? "checkmark.square.fill"
                                        : "square"
                                )
                                .foregroundStyle(isSelected(option.label, for: question) ? Color.accentColor : Color.secondary)
                            } else {
                                Text(String(optionIndex + 1))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(isSelected(option.label, for: question) ? Color.white : Color.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(
                                        isSelected(option.label, for: question)
                                            ? Color.accentColor
                                            : Color(uiColor: .tertiarySystemFill)
                                    )
                                    .clipShape(Circle())
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(display.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if display.recommended {
                                        Text("推荐")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                }
                                if let description = option.description {
                                    Text(description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(
                            isSelected(option.label, for: question)
                                ? Color.accentColor.opacity(0.10)
                                : Color(uiColor: .secondarySystemBackground)
                        )
                        .clipShape(.rect(cornerRadius: 8))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        isSelected(option.label, for: question) ? .isSelected : []
                    )
                }
            }

            TextField(
                question.options == nil ? "输入回答" : "补充或自定义回答",
                text: customBinding(for: question),
                axis: .vertical
            )
            .lineLimit(2...8)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("ask-user-custom-\(question.id)")

            if isSkipped(question) {
                Label("本题已跳过", systemImage: "forward.end.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func isAnswered(_ draft: Draft) -> Bool {
        !draft.selected.isEmpty
            || !draft.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSelected(_ label: String, for question: AskUserQuestionItem) -> Bool {
        drafts[question.id]?.selected.contains(label) == true
    }

    private func isSkipped(_ question: AskUserQuestionItem) -> Bool {
        drafts[question.id]?.skipped == true
    }

    private func toggle(_ label: String, for question: AskUserQuestionItem) {
        var draft = drafts[question.id] ?? Draft()
        draft.skipped = false
        if question.multiSelect {
            if draft.selected.contains(label) {
                draft.selected.remove(label)
            } else {
                draft.selected.insert(label)
            }
        } else if draft.selected.contains(label) {
            draft.selected.removeAll()
        } else {
            draft.selected = [label]
            draft.custom = ""
        }
        drafts[question.id] = draft
        validationMessage = nil
        if !question.multiSelect,
           draft.selected.contains(label),
           index < pending.request.questions.count - 1 {
            index += 1
        }
    }

    private func customBinding(for question: AskUserQuestionItem) -> Binding<String> {
        Binding(
            get: { drafts[question.id]?.custom ?? "" },
            set: { value in
                var draft = drafts[question.id] ?? Draft()
                draft.custom = value
                draft.skipped = false
                if !question.multiSelect {
                    draft.selected.removeAll()
                }
                drafts[question.id] = draft
                validationMessage = nil
            }
        )
    }

    private func move(to target: Int) {
        index = min(max(0, target), pending.request.questions.count - 1)
        validationMessage = nil
    }

    private func continueFlow() {
        let draft = drafts[question.id] ?? Draft()
        guard draft.skipped || isAnswered(draft) else {
            validationMessage = "请回答或跳过本题。"
            return
        }
        if index < pending.request.questions.count - 1 {
            move(to: index + 1)
        } else {
            submit()
        }
    }

    private func skipCurrent() {
        var updated = drafts
        updated[question.id] = Draft(skipped: true)
        drafts = updated
        validationMessage = nil
        if index < pending.request.questions.count - 1 {
            index += 1
        } else {
            submit(updated)
        }
    }

    private func submit(_ values: [String: Draft]? = nil) {
        let values = values ?? drafts
        if let missingIndex = pending.request.questions.firstIndex(where: { question in
            let draft = values[question.id] ?? Draft()
            return !draft.skipped && !isAnswered(draft)
        }) {
            index = missingIndex
            validationMessage = "还有问题未回答；可以回答或逐题跳过。"
            return
        }
        let answers = pending.request.questions.map { question in
            let draft = values[question.id] ?? Draft()
            if draft.skipped {
                return AskUserQuestionAnswerItem(id: question.id)
            }

            let normalizedCustom = draft.custom.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return AskUserQuestionAnswerItem(
                id: question.id,
                selected: draft.selected.sorted(),
                custom: normalizedCustom.isEmpty ? nil : normalizedCustom
            )
        }
        model.answerPendingUserQuestion(AskUserQuestionAnswer(answers: answers))
    }

    private func recommendedDisplay(for label: String) -> (label: String, recommended: Bool) {
        let suffixes = [" (Recommended)", "（Recommended）", " (推荐)", "（推荐）"]
        for suffix in suffixes where label.lowercased().hasSuffix(suffix.lowercased()) {
            return (String(label.dropLast(suffix.count)), true)
        }
        return (label, false)
    }
}

private struct PlanReviewSheet: View {
    @Environment(AppModel.self) private var model
    let review: PlanReviewPresentation

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.tint)
                    Text("Plan review")
                        .font(.headline)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 48)
                .background(Color.accentColor.opacity(0.12))

                ScrollView {
                    NativeMarkdownText(source: review.plan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        chatButton(fullWidth: false)
                        if let decline = review.decline {
                            refuseButton(decline, fullWidth: false)
                        }
                        approveButton(fullWidth: false)
                    }

                    VStack(spacing: 10) {
                        chatButton(fullWidth: true)
                        if let decline = review.decline {
                            refuseButton(decline, fullWidth: true)
                        }
                        approveButton(fullWidth: true)
                    }
                }
                .padding(16)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(review.question)
            .accessibilityIdentifier("plan-review-sheet")
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
    }

    private func chatButton(fullWidth: Bool) -> some View {
        Button {
            model.cancelPendingUserQuestion()
        } label: {
            Label("Chat about it", systemImage: "square.and.pencil")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .controlSize(.large)
        .foregroundStyle(.secondary)
        .accessibilityHint("关闭计划审核并返回聊天输入")
        .accessibilityIdentifier("plan-review-chat")
    }

    private func refuseButton(
        _ decline: AskUserQuestionOption,
        fullWidth: Bool
    ) -> some View {
        Button {
            answer(with: decline.label)
        } label: {
            Label("Refuse", systemImage: "xmark")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint(decline.description ?? "保持 Plan 模式并继续修改计划")
        .accessibilityIdentifier("plan-review-refuse")
    }

    private func approveButton(fullWidth: Bool) -> some View {
        Button {
            answer(with: review.approve.label)
        } label: {
            Label("Approve", systemImage: "checkmark")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint(review.approve.description ?? "批准计划并在下一步退出 Plan 模式")
        .accessibilityIdentifier("plan-review-approve")
    }

    private func answer(with label: String) {
        model.answerPendingUserQuestion(
            AskUserQuestionAnswer(
                answers: [
                    AskUserQuestionAnswerItem(id: review.id, selected: [label])
                ]
            )
        )
    }
}
