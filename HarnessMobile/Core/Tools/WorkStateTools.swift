import Foundation

enum ConversationGoalAction: Sendable, Equatable {
    case create(title: String)
    case edit(title: String)
    case pause
    case resume
    case complete
    case block
    case clear
    case transition(to: ConversationItemStatus)
}

enum ConversationGoalLifecycleError: LocalizedError, Sendable, Equatable {
    case noGoal
    case goalAlreadyExists
    case emptyTitle
    case titleTooLong(maximumUTF8Bytes: Int)
    case invalidTransition(from: ConversationItemStatus, to: ConversationItemStatus)

    var errorDescription: String? {
        switch self {
        case .noGoal:
            "当前会话没有可操作的目标。"
        case .goalAlreadyExists:
            "当前目标尚未完成，请先完成或清空后再创建新目标。"
        case .emptyTitle:
            "目标内容不能为空。"
        case let .titleTooLong(maximumUTF8Bytes):
            "目标内容过长，最多允许 \(maximumUTF8Bytes) 字节。"
        case let .invalidTransition(from, to):
            "目标不能从 \(from.rawValue) 切换到 \(to.rawValue)。"
        }
    }
}

extension ConversationItemStatus {
    var allowedGoalTransitions: [ConversationItemStatus] {
        switch self {
        case .pending:
            [.active, .completed]
        case .active:
            [.paused, .blocked, .completed]
        case .paused:
            [.active, .completed]
        case .blocked:
            [.active, .completed]
        case .completed:
            []
        }
    }
}

actor WorkStateCoordinator {
    private static let maximumGoalUTF8Bytes = 512

    private var state: ConversationWorkState

    init(state: ConversationWorkState = ConversationWorkState()) {
        self.state = state
    }

    func replace(with state: ConversationWorkState) {
        self.state = state
    }

    func snapshot() -> ConversationWorkState {
        state
    }

    func setGoal(title: String, status: ConversationItemStatus) -> ConversationWorkState {
        let replacingCompletedGoal = state.goal?.status == .completed && status != .completed
        if let current = state.goal,
           current.status != .completed || status == .completed {
            // Editing keeps the round accounting; only a fresh goal after a
            // completed one starts a new sequence.
            state.goal = ConversationGoal(
                id: replacingCompletedGoal ? UUID() : current.id,
                title: title,
                status: status,
                isContinuationEnabled: replacingCompletedGoal ? false : current.isContinuationEnabled,
                maximumRounds: replacingCompletedGoal ? nil : current.maximumRounds,
                usedRounds: replacingCompletedGoal ? 0 : current.usedRounds,
                blocker: replacingCompletedGoal ? nil : current.blocker
            )
        } else {
            state.goal = ConversationGoal(title: title, status: status)
        }
        return state
    }

    /// Upstream `dsh-goal-round-driver`: start one goal-sourced round when the
    /// goal is active, continuation is on, and the cap still has room. Spending
    /// the cap records a blocker so the stop is visible, not silent.
    func startGoalRound() -> Bool {
        guard var goal = state.goal, goal.canStartRound else { return false }
        goal.usedRounds += 1
        if goal.usedRounds >= goal.effectiveMaximumRounds {
            goal.blocker = "已达目标轮次上限（\(goal.effectiveMaximumRounds) 轮）。"
        }
        state.goal = goal
        return true
    }

    func setGoalContinuation(enabled: Bool, maximumRounds: Int? = nil) throws -> ConversationWorkState {
        var goal = try currentGoal()
        goal.isContinuationEnabled = enabled
        if let maximumRounds {
            goal.maximumRounds = max(1, maximumRounds)
        }
        if enabled {
            // Re-enabling after a cap-spent block clears the blocker so the
            // driver can run again.
            goal.blocker = nil
        }
        state.goal = goal
        return state
    }

    func applyGoalAction(_ action: ConversationGoalAction) throws -> ConversationWorkState {
        switch action {
        case let .create(title):
            if let goal = state.goal, goal.status != .completed {
                throw ConversationGoalLifecycleError.goalAlreadyExists
            }
            state.goal = ConversationGoal(
                title: try Self.normalizedGoalTitle(title),
                status: .active
            )
        case let .edit(title):
            var goal = try currentGoal()
            goal.title = try Self.normalizedGoalTitle(title)
            state.goal = goal
        case .pause:
            try transitionGoal(to: .paused, allowedFrom: [.active])
        case .resume:
            try transitionGoal(to: .active, allowedFrom: [.paused, .blocked])
        case .complete:
            try transitionGoal(
                to: .completed,
                allowedFrom: [.pending, .active, .paused, .blocked]
            )
        case .block:
            try transitionGoal(to: .blocked, allowedFrom: [.active])
        case .clear:
            _ = try currentGoal()
            state.goal = nil
        case let .transition(status):
            try transitionGoal(to: status)
        }
        return state
    }

    func replacePlan(_ steps: [ConversationPlanStep]) -> ConversationWorkState {
        state.plan = steps
        return state
    }

    func replaceTodos(_ items: [ConversationTodoItem]) -> ConversationWorkState {
        state.todos = items
        return state
    }

    private func currentGoal() throws -> ConversationGoal {
        guard let goal = state.goal else {
            throw ConversationGoalLifecycleError.noGoal
        }
        return goal
    }

    private func transitionGoal(to status: ConversationItemStatus) throws {
        var goal = try currentGoal()
        guard goal.status != status else { return }
        guard goal.status.allowedGoalTransitions.contains(status) else {
            throw ConversationGoalLifecycleError.invalidTransition(
                from: goal.status,
                to: status
            )
        }
        goal.status = status
        state.goal = goal
    }

    private func transitionGoal(
        to status: ConversationItemStatus,
        allowedFrom: [ConversationItemStatus]
    ) throws {
        let goal = try currentGoal()
        guard allowedFrom.contains(goal.status) else {
            throw ConversationGoalLifecycleError.invalidTransition(
                from: goal.status,
                to: status
            )
        }
        try transitionGoal(to: status)
    }

    private static func normalizedGoalTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw ConversationGoalLifecycleError.emptyTitle
        }
        guard normalized.utf8.count <= maximumGoalUTF8Bytes else {
            throw ConversationGoalLifecycleError.titleTooLong(
                maximumUTF8Bytes: maximumGoalUTF8Bytes
            )
        }
        return normalized
    }
}

enum WorkStateToolSupport {
    static let itemSchema = JSONValue.object([
        "type": .string("object"),
        "properties": .object([
            "title": .object([
                "type": .string("string"),
                "description": .string("Short, concrete item text.")
            ]),
            "status": .object([
                "type": .string("string"),
                "enum": .array(ConversationItemStatus.allCases.map { .string($0.rawValue) })
            ])
        ]),
        "required": .array([.string("title"), .string("status")]),
        "additionalProperties": .bool(false)
    ])

    static func status(from value: JSONValue?) throws -> ConversationItemStatus {
        let rawValue = value?.stringValue
        guard let rawValue,
              let status = ConversationItemStatus(rawValue: rawValue) else {
            throw LocalToolError.invalidEnumValue(
                field: "status",
                value: rawValue,
                allowed: ConversationItemStatus.allCases.map(\.rawValue)
            )
        }
        return status
    }

    static func items(from value: JSONValue?) throws -> [(String, ConversationItemStatus)] {
        guard case let .array(values) = value, values.count <= 32 else {
            throw LocalToolError.invalidArguments
        }
        return try values.map { value in
            guard case let .object(item) = value else {
                throw LocalToolError.invalidArguments
            }
            try item.requireOnlyKeys(["title", "status"])
            let title = try item.requiredString("title", maximumUTF8Bytes: 512)
            return (title, try status(from: item["status"]))
        }
    }

    static func encode(_ state: ConversationWorkState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    /// Model-visible continuation prompt, mirroring upstream
    /// `goal-round-driver/src/prompt.ts`. It is retained in session history so
    /// the transcript explains why the next turn started.
    static func goalRoundPrompt(objective: String, round: Int, maximum: Int) -> String {
        """
        <goal_round>
        Objective: \(objective)
        Round: \(round)/\(maximum)

        继续在同一会话中朝该目标推进。以当前工作区、工具结果与持久会话状态为准，先检查再判断，不要假定先前的叙述仍然有效。取得具体进展并验证结果。在宣告完成前，收集整个目标已达成的证据、读取当前目标并标记完成。若仍有剩余工作，保持目标 active 以进入下一轮。
        </goal_round>
        """
    }
}

struct WorkStateSetGoalTool: LocalAgentTool {
    let coordinator: WorkStateCoordinator
    let definition = ModelToolDefinition(
        name: "work_state_set_goal",
        description: "Set the current local conversation goal. This only updates on-device Agent state.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("One concise outcome for the current conversation.")
                ]),
                "status": .object([
                    "type": .string("string"),
                    "enum": .array(ConversationItemStatus.allCases.map { .string($0.rawValue) })
                ])
            ]),
            "required": .array([.string("title"), .string("status")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["title", "status"])
        _ = try arguments.requiredString("title", maximumUTF8Bytes: 512)
        _ = try WorkStateToolSupport.status(from: arguments["status"])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "更新本机会话目标：\(arguments["title"]?.stringValue ?? "未命名")"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let state = await coordinator.setGoal(
            title: try arguments.requiredString("title", maximumUTF8Bytes: 512),
            status: try WorkStateToolSupport.status(from: arguments["status"])
        )
        return try WorkStateToolSupport.encode(state)
    }
}

/// Read-only counterpart of the state writers. Upstream exposes `get_goal`
/// for the same reason: a model resuming a long task needs to see the durable
/// goal/plan/todo state instead of guessing from earlier turns.
struct WorkStateGetTool: LocalAgentTool {
    let coordinator: WorkStateCoordinator
    let definition = ModelToolDefinition(
        name: "work_state_get",
        description: "Read the current local goal, plan steps and todos for this conversation. Use it before changing work state, or when resuming after a long break. This only reads on-device Agent state.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "读取本机会话目标与待办"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        return try WorkStateToolSupport.encode(await coordinator.snapshot())
    }
}

struct WorkStateReplacePlanTool: LocalAgentTool {
    let coordinator: WorkStateCoordinator
    let definition = ModelToolDefinition(
        name: "work_state_replace_plan",
        description: "Replace the ordered local execution plan with at most 32 concrete steps.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "steps": .object([
                    "type": .string("array"),
                    "maxItems": .number(32),
                    "items": WorkStateToolSupport.itemSchema
                ])
            ]),
            "required": .array([.string("steps")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["steps"])
        _ = try WorkStateToolSupport.items(from: arguments["steps"])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let count: Int
        if case let .array(values) = arguments["steps"] {
            count = values.count
        } else {
            count = 0
        }
        return "更新本地执行计划（\(count) 步）"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let steps = try WorkStateToolSupport.items(from: arguments["steps"]).map {
            ConversationPlanStep(title: $0.0, status: $0.1)
        }
        return try await WorkStateToolSupport.encode(coordinator.replacePlan(steps))
    }
}

struct WorkStateReplaceTodosTool: LocalAgentTool {
    let coordinator: WorkStateCoordinator
    let definition = ModelToolDefinition(
        name: "work_state_replace_todos",
        description: "Replace the local conversation todo list with at most 32 items.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "items": .object([
                    "type": .string("array"),
                    "maxItems": .number(32),
                    "items": WorkStateToolSupport.itemSchema
                ])
            ]),
            "required": .array([.string("items")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["items"])
        _ = try WorkStateToolSupport.items(from: arguments["items"])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let count: Int
        if case let .array(values) = arguments["items"] {
            count = values.count
        } else {
            count = 0
        }
        return "更新本地待办（\(count) 项）"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let items = try WorkStateToolSupport.items(from: arguments["items"]).map {
            ConversationTodoItem(title: $0.0, status: $0.1)
        }
        return try await WorkStateToolSupport.encode(coordinator.replaceTodos(items))
    }
}
