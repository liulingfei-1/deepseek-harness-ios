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
            Form {
                ForEach(pending.request.questions) { question in
                    questionSection(question)
                        .accessibilityIdentifier("ask-user-question-\(question.id)")
                }
            }
            .accessibilityIdentifier("ask-user-question-sheet")
            .navigationTitle("需要你的选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        model.cancelPendingUserQuestion()
                    }
                    .accessibilityIdentifier("ask-user-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交", action: submit)
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("ask-user-submit")
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var canSubmit: Bool {
        pending.request.questions.allSatisfy { question in
            let draft = drafts[question.id] ?? Draft()
            return draft.skipped || isAnswered(draft)
        }
    }

    private func questionSection(_ question: AskUserQuestionItem) -> some View {
        Section {
            if let detail = question.detail {
                ScrollView(.vertical) {
                    NativeMarkdownText(source: detail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
            }

            if let options = question.options {
                ForEach(options, id: \.label) { option in
                    Button {
                        toggle(option.label, for: question)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(
                                systemName: isSelected(option.label, for: question)
                                    ? selectedIcon(for: question)
                                    : unselectedIcon(for: question)
                            )
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                    .foregroundStyle(.primary)
                                if let description = option.description {
                                    Text(description)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                        }
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
            .accessibilityIdentifier("ask-user-custom-\(question.id)")

            Button {
                skip(question)
            } label: {
                Label(
                    isSkipped(question) ? "已跳过" : "跳过本题",
                    systemImage: isSkipped(question) ? "checkmark" : "forward.end"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSkipped(question))
            .accessibilityIdentifier("ask-user-skip-\(question.id)")
        } header: {
            Text(question.header ?? question.question)
        } footer: {
            if question.header != nil {
                Text(question.question)
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

    private func selectedIcon(for question: AskUserQuestionItem) -> String {
        question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle"
    }

    private func unselectedIcon(for question: AskUserQuestionItem) -> String {
        question.multiSelect ? "square" : "circle"
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
    }

    private func skip(_ question: AskUserQuestionItem) {
        drafts[question.id] = Draft(skipped: true)
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
            }
        )
    }

    private func submit() {
        guard canSubmit else { return }
        let answers = pending.request.questions.map { question in
            let draft = drafts[question.id] ?? Draft()
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

private struct NativeMarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Text(inlineMarkdown(text))
                        .font(headingFont(level: level))
                        .fontWeight(.semibold)
                case let .paragraph(text):
                    Text(inlineMarkdown(text))
                        .font(.body)
                case let .ordered(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(inlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .unordered(text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .quote(text):
                    HStack(alignment: .top, spacing: 10) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3)
                        Text(inlineMarkdown(text))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .code(text):
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(.rect(cornerRadius: 6))
                }
            }
        }
    }

    private var blocks: [NativeMarkdownBlock] {
        NativeMarkdownBlock.parse(source)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private enum NativeMarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case ordered(marker: String, text: String)
    case unordered(String)
    case quote(String)
    case code(String)

    static func parse(_ source: String) -> [Self] {
        var blocks: [Self] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInCodeFence {
                    flushCode()
                } else {
                    flushParagraph()
                }
                isInCodeFence.toggle()
                continue
            }

            if isInCodeFence {
                codeLines.append(line)
                continue
            }

            guard !trimmed.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if let ordered = orderedItem(in: trimmed) {
                flushParagraph()
                blocks.append(.ordered(marker: ordered.marker, text: ordered.text))
            } else if let text = unorderedItem(in: trimmed) {
                flushParagraph()
                blocks.append(.unordered(text))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraphLines.append(trimmed)
            }
        }

        flushParagraph()
        if isInCodeFence || !codeLines.isEmpty {
            flushCode()
        }
        return blocks
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let markers = line.prefix { $0 == "#" }
        guard !markers.isEmpty,
              markers.count <= 6,
              line.dropFirst(markers.count).first == " " else { return nil }
        return (
            markers.count,
            String(line.dropFirst(markers.count + 1))
        )
    }

    private static func orderedItem(in line: String) -> (marker: String, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let suffix = line.dropFirst(digits.count)
        guard suffix.hasPrefix(". ") else { return nil }
        return (String(digits) + ".", String(suffix.dropFirst(2)))
    }

    private static func unorderedItem(in line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }
}
