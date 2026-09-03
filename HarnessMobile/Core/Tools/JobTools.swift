import Foundation

enum JobToolSuite {
    static let names: Set<String> = ["job_output", "job_list", "job_kill"]
    static let promptSection = CordisPromptSection(
        name: "tool:jobs",
        order: 106,
        text: "Track every background job id you start. Do not busy-poll or sleep on a job; continue independent work. Before answering, collect every still-relevant job with job_output, using wait only when genuinely blocked, and stop obsolete work with job_kill."
    )

    static func makeTools(
        registry: any HarnessJobManaging,
        ownerSession: String
    ) -> [any LocalAgentTool] {
        [
            JobOutputTool(registry: registry, ownerSession: ownerSession),
            JobListTool(registry: registry, ownerSession: ownerSession),
            JobKillTool(registry: registry, ownerSession: ownerSession)
        ]
    }

    /// Host adapter for upstream completionDelivery. AppModel can call this
    /// after an owner becomes resident (including cold restore) and at job
    /// settlement boundaries. The registry atomically suppresses duplicates;
    /// the handler owns inject-versus-wake scheduling.
    static func deliverPendingCompletions(
        registry: any HarnessJobManaging,
        ownerSession: String,
        delivery: LocalSubagentReportDelivery = .wakeup,
        handler: @escaping @Sendable (
            _ notice: HarnessJobCompletionNotice,
            _ delivery: LocalSubagentReportDelivery
        ) async throws -> Void
    ) async {
        let notices = await registry.claimCompletionNotices(ownerSession: ownerSession)
        for notice in notices {
            do {
                try await handler(notice, delivery)
                await registry.acknowledgeCompletionNotice(
                    id: notice.id,
                    ownerSession: ownerSession
                )
            } catch {
                await registry.requeueCompletionNotice(
                    id: notice.id,
                    ownerSession: ownerSession
                )
            }
        }
    }
}

/// The mobile projection of DSH's continuable subagent contract. A runner is
/// supplied by AppModel so the tool layer stays independent from the model
/// client and can be reused by Cordis/native plugin compositions.
struct LocalSubagentRequest: Sendable, Equatable {
    static let defaultMaximumDepth = 3

    let childAddress: String
    let prompt: String
    let label: String
    let model: String?
    let reasoningEffort: ReasoningMode?
    let providerBundleID: AgentProviderBundleID?
    /// Whether the child starts fresh or receives the parent's completed
    /// conversation prefix. The runner owns the actual seed operation.
    let contextMode: LocalSubagentContextMode
    /// Absolute delegation depth. A top-level Agent is zero and its direct
    /// child is one. The registry computes and persists this value.
    let delegationDepth: Int
    /// The durable depth ceiling inherited by this child. Nested activations
    /// use it when registering their own child records.
    let maximumDepth: Int
    /// Child-scoped composition restored for every continuation.
    let persona: String?
    let toolFilter: LocalSubagentToolFilter?
    /// Per-activation structured result contract. Unlike persona/toolFilter,
    /// this is deliberately not inherited by later follow-ups.
    let outputSchema: JSONValue?
    /// Deployment-owned scheduling for child reports.
    let reportDelivery: LocalSubagentReportDelivery
    let runInBackground: Bool
    let isContinuation: Bool

    init(
        childAddress: String,
        prompt: String,
        label: String,
        model: String?,
        reasoningEffort: ReasoningMode? = nil,
        providerBundleID: AgentProviderBundleID? = nil,
        contextMode: LocalSubagentContextMode = .fresh,
        delegationDepth: Int = 1,
        maximumDepth: Int = Self.defaultMaximumDepth,
        persona: String? = nil,
        toolFilter: LocalSubagentToolFilter? = nil,
        outputSchema: JSONValue? = nil,
        reportDelivery: LocalSubagentReportDelivery = .wakeup,
        runInBackground: Bool,
        isContinuation: Bool
    ) {
        self.childAddress = childAddress
        self.prompt = prompt
        self.label = label
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.providerBundleID = providerBundleID
        self.contextMode = contextMode
        self.delegationDepth = delegationDepth
        self.maximumDepth = maximumDepth
        self.persona = persona
        self.toolFilter = toolFilter
        self.outputSchema = outputSchema
        self.reportDelivery = reportDelivery
        self.runInBackground = runInBackground
        self.isContinuation = isContinuation
    }

    func withDelegationDepth(_ depth: Int) -> Self {
        Self(
            childAddress: childAddress,
            prompt: prompt,
            label: label,
            model: model,
            reasoningEffort: reasoningEffort,
            providerBundleID: providerBundleID,
            contextMode: contextMode,
            delegationDepth: depth,
            maximumDepth: maximumDepth,
            persona: persona,
            toolFilter: toolFilter,
            outputSchema: outputSchema,
            reportDelivery: reportDelivery,
            runInBackground: runInBackground,
            isContinuation: isContinuation
        )
    }
}

extension LocalSubagentRequest {
    /// Project only the request facts a process-isolated Provider Bundle can
    /// inspect at launch. The default depth is provider-managed; a different
    /// ceiling is an explicit request for Harness-side depth enforcement.
    var providerBundleRequestFeatures: AgentProviderBundleRequestFeatures {
        AgentProviderBundleRequestFeatures(
            usesParentContext: contextMode == .forkCompletedParent,
            hasOutputSchema: outputSchema != nil,
            hasDepthLimitOverride: maximumDepth != Self.defaultMaximumDepth,
            hasToolFilter: toolFilter != nil,
            hasPersona: persona != nil,
            hasModelOverride: model != nil,
            isContinuation: isContinuation
        )
    }
}

typealias LocalSubagentOutputEmitter = @Sendable (AgentToolOutputChunk) async -> Void
typealias LocalSubagentRunner = @Sendable (
    LocalSubagentRequest,
    @escaping LocalSubagentOutputEmitter
) async throws -> String

/// RC.8 deployment-owned parent scheduling. The model-facing `report` tool
/// deliberately does not expose this as an argument.
enum LocalSubagentReportDelivery: String, Codable, Sendable, Equatable {
    case quiet
    case wakeup
}

enum LocalSubagentContextMode: String, Codable, Sendable, Equatable {
    case fresh
    case forkCompletedParent = "fork-completed-parent"
}

struct LocalSubagentToolFilter: Codable, Sendable, Equatable {
    let allow: [String]?
    let deny: [String]?

    init(allow: [String]? = nil, deny: [String]? = nil) {
        self.allow = allow
        self.deny = deny
    }

    func validated() throws -> Self {
        guard allow != nil || deny != nil else {
            throw LocalToolError.invalidArguments
        }
        let allowed = try normalized(allow)
        let denied = try normalized(deny)
        guard Set(allowed ?? []).isDisjoint(with: Set(denied ?? [])) else {
            throw LocalToolError.invalidArguments
        }
        return Self(allow: allowed, deny: denied)
    }

    private func normalized(_ names: [String]?) throws -> [String]? {
        guard let names else { return nil }
        let normalized = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              Set(normalized).count == normalized.count else {
            throw LocalToolError.invalidArguments
        }
        return normalized
    }
}

/// Deployment configuration for one model-facing subagent provider. These are
/// fixed capabilities, not model-selectable arguments, matching upstream DSH.
struct LocalSubagentPolicy: Sendable, Equatable {
    let contextMode: LocalSubagentContextMode
    let persona: String?
    let toolFilter: LocalSubagentToolFilter?
    let outputSchema: JSONValue?
    let reportDelivery: LocalSubagentReportDelivery
    let maximumDepth: Int

    init(
        contextMode: LocalSubagentContextMode = .fresh,
        persona: String? = nil,
        toolFilter: LocalSubagentToolFilter? = nil,
        outputSchema: JSONValue? = nil,
        reportDelivery: LocalSubagentReportDelivery = .wakeup,
        maximumDepth: Int = 3
    ) {
        self.contextMode = contextMode
        self.persona = persona
        self.toolFilter = toolFilter
        self.outputSchema = outputSchema
        self.reportDelivery = reportDelivery
        self.maximumDepth = maximumDepth
    }

    func validated() throws -> Self {
        guard (0...64).contains(maximumDepth),
              persona?.utf8.count ?? 0 <= 48 * 1_024 else {
            throw LocalToolError.invalidArguments
        }
        if let outputSchema {
            try LocalSubagentStructuredOutput.validateSchema(outputSchema)
        }
        return Self(
            contextMode: contextMode,
            persona: persona,
            toolFilter: try toolFilter?.validated(),
            outputSchema: outputSchema,
            reportDelivery: reportDelivery,
            maximumDepth: maximumDepth
        )
    }
}

/// Low-conflict runner adapter for the AppModel boundary. It centralizes the
/// upstream inheritance semantics without teaching the Jobs actor about model
/// history or tool registry implementation details.
extension LocalSubagentRequest {
    /// Rehydrate a durable child address for a follow-up activation. Keeping
    /// this projection in one place prevents native composer routing and the
    /// model-facing `send_message` tool from silently dropping persisted
    /// composition fields such as the depth ceiling.
    static func continuation(
        child: HarnessSubagentSnapshot,
        prompt: String
    ) -> Self {
        Self(
            childAddress: child.id,
            prompt: prompt,
            label: child.label,
            model: child.model,
            providerBundleID: child.providerBundleID,
            contextMode: child.contextMode,
            delegationDepth: child.delegationDepth,
            maximumDepth: child.maximumDepth,
            persona: child.persona,
            toolFilter: child.toolFilter,
            // Structured output is an activation contract. A later follow-up
            // is ordinary conversation unless its caller establishes a new
            // schema-aware activation surface.
            outputSchema: nil,
            reportDelivery: child.reportDelivery,
            runInBackground: true,
            isContinuation: true
        )
    }

    func seedHistory(from completedParentHistory: [AgentMessage]) -> [AgentMessage] {
        contextMode == .forkCompletedParent ? completedParentHistory : []
    }

    func scopedTools(from available: [any LocalAgentTool]) throws -> [any LocalAgentTool] {
        guard let filter = try toolFilter?.validated() else { return available }
        let known = Set(available.map(\.definition.name))
        let requested = Set((filter.allow ?? []) + (filter.deny ?? []))
        guard requested.isSubset(of: known) else {
            throw LocalToolError.pluginDenied(
                "子 Agent 工具过滤器包含未知工具：\(requested.subtracting(known).sorted().joined(separator: ", "))"
            )
        }
        let allowed = filter.allow.map(Set.init)
        let denied = Set(filter.deny ?? [])
        return available.filter { tool in
            let name = tool.definition.name
            // Upstream keeps the child-scoped report return channel outside
            // the global restriction layer.
            if name == "report" { return true }
            return (allowed?.contains(name) ?? true) && !denied.contains(name)
        }
    }
}

enum LocalSubagentStructuredOutput {
    private static let supportedTypes: Set<String> = [
        "object", "array", "string", "integer", "number", "boolean", "null"
    ]

    static func validateSchema(_ schema: JSONValue) throws {
        try validateSchemaNode(schema, depth: 0, requireObjectRoot: true)
    }

    static func validate(text: String, schema: JSONValue?) throws {
        guard let schema else { return }
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw LocalToolError.pluginFailed(
                "子 Agent 没有返回 output schema 要求的合法 JSON。"
            )
        }
        do {
            try NativeAgentJSONSchemaValidator.validate(value: value, schema: schema)
        } catch {
            throw LocalToolError.pluginFailed(
                "子 Agent 的结构化输出不符合声明的 output schema。"
            )
        }
    }

    private static func validateSchemaNode(
        _ schema: JSONValue,
        depth: Int,
        requireObjectRoot: Bool
    ) throws {
        guard depth <= 32,
              case let .object(object) = schema,
              let type = object["type"]?.stringValue,
              supportedTypes.contains(type),
              !requireObjectRoot || type == "object" else {
            throw LocalToolError.invalidArguments
        }
        if case let .array(required)? = object["required"] {
            guard required.allSatisfy({ $0.stringValue != nil }) else {
                throw LocalToolError.invalidArguments
            }
        }
        if let properties = object["properties"]?.objectValue {
            for child in properties.values {
                try validateSchemaNode(child, depth: depth + 1, requireObjectRoot: false)
            }
        }
        if let items = object["items"] {
            try validateSchemaNode(items, depth: depth + 1, requireObjectRoot: false)
        }
    }
}

typealias LocalSubagentReportDeliveryHandler = @Sendable (
    _ childAddress: String,
    _ parentSession: String,
    _ output: String,
    _ delivery: LocalSubagentReportDelivery
) async throws -> String

enum SubagentToolSuite {
    static let names: Set<String> = ["subagent", "subagent_fork", "send_message", "subagent_list", "subagent_control"]

    static let promptSection = CordisPromptSection(
        name: "tool:subagent",
        order: 105,
        text: "Use subagent for a focused task when independent context will reduce pressure on this conversation. The returned subagent_id is a stable local conversation address. Use send_message with that id to continue the same direct child after it finishes, subagent_list for the durable child tree, and subagent_control to wait or interrupt any descendant. Background activations also return a job_id for incremental output. Children and every continuation run locally on this iPhone; any nested delegation is bounded by the durable depth policy."
    )

    static func makeTools(
        runner: LocalSubagentRunner?,
        registry: any HarnessJobManaging,
        ownerSession: String,
        policy: LocalSubagentPolicy = LocalSubagentPolicy()
    ) -> [any LocalAgentTool] {
        [
            SubagentTool(
                runner: runner,
                registry: registry,
                ownerSession: ownerSession,
                policy: policy
            ),
            SubagentTool(
                runner: runner,
                registry: registry,
                ownerSession: ownerSession,
                policy: LocalSubagentPolicy(
                    contextMode: .forkCompletedParent,
                    persona: policy.persona,
                    toolFilter: policy.toolFilter,
                    outputSchema: policy.outputSchema,
                    reportDelivery: policy.reportDelivery,
                    maximumDepth: policy.maximumDepth
                ),
                toolName: "subagent_fork"
            ),
            SendMessageTool(runner: runner, registry: registry, ownerSession: ownerSession),
            SubagentListTool(registry: registry, ownerSession: ownerSession),
            SubagentControlTool(registry: registry, ownerSession: ownerSession)
        ]
    }

    /// Installs the child-scoped RC.8 `report` tool. It is intentionally not
    /// part of the root catalog: only a continuable child knows its exact
    /// parent address and can authenticate a report.
    static func makeReportTool(
        childAddress: String,
        parentSession: String,
        reportDelivery: LocalSubagentReportDelivery = .wakeup,
        delivery: @escaping LocalSubagentReportDeliveryHandler
    ) -> any LocalAgentTool {
        SubagentReportTool(
            childAddress: childAddress,
            parentSession: parentSession,
            reportDelivery: reportDelivery,
            delivery: delivery
        )
    }

    /// Preferred runner-bound overload: restores the child's durable
    /// report-delivery policy without asking AppModel to duplicate it.
    static func makeReportTool(
        request: LocalSubagentRequest,
        parentSession: String,
        delivery: @escaping LocalSubagentReportDeliveryHandler
    ) -> any LocalAgentTool {
        makeReportTool(
            childAddress: request.childAddress,
            parentSession: parentSession,
            reportDelivery: request.reportDelivery,
            delivery: delivery
        )
    }
}

private struct SubagentReportTool: LocalAgentTool {
    private static let maximumOutputBytes = 48 * 1_024

    let childAddress: String
    let parentSession: String
    let reportDelivery: LocalSubagentReportDelivery
    let delivery: LocalSubagentReportDeliveryHandler
    let definition = ModelToolDefinition(
        name: "report",
        description: "向启动你的父 Agent 报告一个自包含的进展或结论。报告不会结束当前轮次；完成前至少报告一次，关键中间发现也可以提前报告。报告内容只会送达该父 Agent。",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "output": .object([
                    "type": .string("string"),
                    "description": .string("给父 Agent 的自包含报告。")
                ])
            ]),
            "required": .array([.string("output")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["output"])
        let output = try arguments.requiredString("output", maximumUTF8Bytes: Self.maximumOutputBytes)
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "报告给父 Agent"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["subagent-report:\(parentSession)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let output = try arguments.requiredString("output", maximumUTF8Bytes: Self.maximumOutputBytes)
        let messageID = try await delivery(
            childAddress,
            parentSession,
            output,
            reportDelivery
        )
        return JSONValue.object([
            "status": .string("accepted"),
            "message_id": .string(messageID)
        ]).displayText
    }
}

private struct SubagentTool: LocalAgentTool {
    private static let maximumPromptBytes = 48 * 1_024
    private static let maximumLabelBytes = 256
    private static let maximumModelBytes = 256

    let runner: LocalSubagentRunner?
    let registry: any HarnessJobManaging
    let ownerSession: String
    let policy: LocalSubagentPolicy
    let toolName: String

    init(
        runner: LocalSubagentRunner?,
        registry: any HarnessJobManaging,
        ownerSession: String,
        policy: LocalSubagentPolicy,
        toolName: String = "subagent"
    ) {
        self.runner = runner
        self.registry = registry
        self.ownerSession = ownerSession
        self.policy = policy
        self.toolName = toolName
    }

    var definition: ModelToolDefinition {
        let fork = toolName == "subagent_fork"
        return ModelToolDefinition(
            name: toolName,
            description: fork
                ? "从父 Agent 最近一个已完成回合的只读前缀 fork 一个独立的一次性本机 Agent；不会继承未完成的工具调用。"
                : "Delegate a focused task to another local Harness Agent under the configured context, persona, tool, schema, and depth policy. Set run_in_background=true to return a job id immediately.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object([
                        "type": .string("string"),
                        "description": .string("Complete, standalone instructions for the child Agent.")
                    ]),
                    "label": .object([
                        "type": .string("string"),
                        "description": .string("Short label shown in the trajectory and Jobs view.")
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("Optional model id override from the active provider profile.")
                    ]),
                    "reasoning_effort": .object([
                        "type": .string("string"),
                        "enum": .array([.string("providerDefault"), .string("off"), .string("low"), .string("high"), .string("max")]),
                        "description": .string("Optional reasoning effort override for the child model.")
                    ]),
                    "provider_bundle": .object([
                        "type": .string("string"),
                        "enum": .array(AgentProviderBundleID.allCases.map { .string($0.rawValue) }),
                        "description": .string("RC.8 coding-agent bundle: codex or claude-code.")
                    ]),
                    "run_in_background": .object([
                        "type": .string("boolean"),
                        "description": .string(fork
                            ? "Run in background instead of waiting. Defaults to false for one-shot forks."
                            : "Return a job id immediately instead of waiting. Defaults to false.")
                    ])
                ]),
                "required": .array([.string("prompt")]),
                "additionalProperties": .bool(false)
            ])
        )
    }
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        _ = try policy.validated()
        try arguments.requireOnlyKeys(["prompt", "label", "model", "reasoning_effort", "provider_bundle", "run_in_background"])
        _ = try arguments.requiredString("prompt", maximumUTF8Bytes: Self.maximumPromptBytes)
        if let label = arguments["label"] {
            _ = try string(label, key: "label", maximumBytes: Self.maximumLabelBytes)
        }
        if let model = arguments["model"] {
            _ = try string(model, key: "model", maximumBytes: Self.maximumModelBytes)
        }
        if let value = arguments["reasoning_effort"],
           ReasoningMode(rawValue: value.stringValue ?? "") == nil {
            throw LocalToolError.invalidArguments
        }
        if let bundle = arguments["provider_bundle"],
           AgentProviderBundleID(rawValue: bundle.stringValue ?? "") == nil {
            throw LocalToolError.invalidArguments
        }
        if let value = arguments["run_in_background"], Self.bool(value) == nil {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let label = arguments["label"]?.stringValue ?? "子 Agent"
        return "启动\(String(label.prefix(80)))"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["subagent:\(ownerSession)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        guard let runner else {
            throw LocalToolError.pluginDenied("手机子 Agent 运行器尚未就绪。")
        }
        let resolvedPolicy = try policy.validated()
        let childAddress = UUID().uuidString.lowercased()
        let request = LocalSubagentRequest(
            childAddress: childAddress,
            prompt: try arguments.requiredString("prompt", maximumUTF8Bytes: Self.maximumPromptBytes),
            label: arguments["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? arguments["label"]?.stringValue ?? "子 Agent"
                : "子 Agent",
            model: arguments["model"]?.stringValue,
            reasoningEffort: arguments["reasoning_effort"].flatMap {
                ReasoningMode(rawValue: $0.stringValue ?? "")
            },
            providerBundleID: arguments["provider_bundle"].flatMap {
                AgentProviderBundleID(rawValue: $0.stringValue ?? "")
            },
            contextMode: resolvedPolicy.contextMode,
            delegationDepth: 0,
            maximumDepth: resolvedPolicy.maximumDepth,
            persona: resolvedPolicy.persona,
            toolFilter: resolvedPolicy.toolFilter,
            outputSchema: resolvedPolicy.outputSchema,
            reportDelivery: resolvedPolicy.reportDelivery,
            runInBackground: arguments["run_in_background"].flatMap(Self.bool) ?? false,
            isContinuation: false
        )
        let registered = try await registry.registerSubagent(
            id: childAddress,
            parentSession: ownerSession,
            label: request.label,
            model: request.model,
            providerBundleID: request.providerBundleID,
            contextMode: request.contextMode,
            persona: request.persona,
            toolFilter: request.toolFilter,
            reportDelivery: request.reportDelivery,
            maximumDepth: resolvedPolicy.maximumDepth
        )
        let activationRequest = request.withDelegationDepth(registered.delegationDepth)
        let jobID = try await registry.startSubagentActivation(id: childAddress) { emit in
            let result = try await runner(activationRequest) { chunk in
                await emit(chunk.text)
            }
            try LocalSubagentStructuredOutput.validate(
                text: result,
                schema: activationRequest.outputSchema
            )
            return HarnessJobOutcome(
                status: .completed,
                detail: "child settled",
                output: result
            )
        }
        if activationRequest.runInBackground {
            return JSONValue.object([
                "kind": .string("background_subagent"),
                "subagent_id": .string(childAddress),
                "job_id": .string(jobID),
                "label": .string(request.label),
                "depth": .number(Double(registered.delegationDepth)),
                "status": .string("running")
            ]).displayText
        }
        _ = try await registry.wait(
            id: jobID,
            timeoutMilliseconds: 600_000,
            ownerSession: ownerSession
        )
        let read = try await registry.read(id: jobID, ownerSession: ownerSession)
        guard read.snapshot.status == .completed else {
            throw LocalToolError.pluginFailed(read.snapshot.detail ?? "子 Agent 未完成。")
        }
        return JSONValue.object([
            "subagent_id": .string(childAddress),
            "status": .string("completed"),
            "output": .string(read.text)
        ]).displayText
    }

    private func string(_ value: JSONValue, key: String, maximumBytes: Int) throws -> String {
        guard let result = value.stringValue,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.utf8.count <= maximumBytes else {
            throw LocalToolError.invalidArguments
        }
        return result
    }

    private static func bool(_ value: JSONValue) -> Bool? {
        guard case let .bool(result) = value else { return nil }
        return result
    }
}

private struct SendMessageTool: LocalAgentTool {
    private static let maximumMessageBytes = 48 * 1_024
    let runner: LocalSubagentRunner?
    let registry: any HarnessJobManaging
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "send_message",
        description: "Send a follow-up to a continuable local child Agent by stable subagent_id. The child keeps its prior conversation and wakes in the background even if its previous turn completed or the app was relaunched.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "subagent_id": .object(["type": .string("string")]),
                "message": .object(["type": .string("string")])
            ]),
            "required": .array([.string("subagent_id"), .string("message")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["subagent_id", "message"])
        _ = try arguments.requiredString("subagent_id", maximumUTF8Bytes: 256)
        _ = try arguments.requiredString("message", maximumUTF8Bytes: Self.maximumMessageBytes)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "继续子 Agent \(arguments["subagent_id"]?.stringValue ?? "")"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["subagent:\(try arguments.requiredString("subagent_id", maximumUTF8Bytes: 256))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        guard let runner else { throw LocalToolError.pluginDenied("手机子 Agent 运行器尚未就绪。") }
        let id = try arguments.requiredString("subagent_id", maximumUTF8Bytes: 256).lowercased()
        let child = try await registry.subagent(id: id, requesterSession: ownerSession)
        guard child.parentSession == ownerSession.lowercased() else {
            throw LocalToolError.pluginDenied(
                "send_message 只能继续直接子 Agent；更深层后代应由它的直接父 Agent 继续。"
            )
        }
        let request = LocalSubagentRequest.continuation(
            child: child,
            prompt: try arguments.requiredString("message", maximumUTF8Bytes: Self.maximumMessageBytes)
        )
        let jobID = try await registry.startSubagentActivation(id: id) { emit in
            let result = try await runner(request) { chunk in await emit(chunk.text) }
            return HarnessJobOutcome(status: .completed, detail: "child settled", output: result)
        }
        return JSONValue.object([
            "subagent_id": .string(id),
            "job_id": .string(jobID),
            "status": .string("accepted")
        ]).displayText
    }
}

private struct SubagentListTool: LocalAgentTool {
    let registry: any HarnessJobManaging
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "subagent_list",
        description: "List durable continuable local child Agents. scope=children lists direct children; scope=descendants walks the complete subtree in stable parent-first order and includes parent/depth.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array([.string("children"), .string("descendants")]),
                    "description": .string("children (default) or descendants.")
                ]),
                "descendants": .object(["type": .string("boolean")])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["scope", "descendants"])
        if arguments["scope"] != nil, arguments["descendants"] != nil {
            throw LocalToolError.invalidArguments
        }
        if let scope = arguments["scope"]?.stringValue,
           !["children", "descendants"].contains(scope) {
            throw LocalToolError.invalidEnumValue(
                field: "scope",
                value: scope,
                allowed: ["children", "descendants"]
            )
        }
        if let value = arguments["descendants"], Self.bool(value) == nil {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String { "列出子 Agent" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let includeDescendants = arguments["scope"]?.stringValue == "descendants"
            || arguments["descendants"].flatMap(Self.bool) == true
        let ownerDepth = await registry.delegationDepth(sessionID: ownerSession)
        let children = await registry.listSubagents(
            rootSession: ownerSession,
            descendants: includeDescendants
        )
        return JSONValue.array(children.map { snapshot in
            .object([
                "subagent_id": .string(snapshot.id),
                "parent_session": .string(snapshot.parentSession),
                "depth": .number(Double(max(1, snapshot.delegationDepth - ownerDepth))),
                "label": .string(snapshot.label),
                "status": .string(snapshot.status.rawValue),
                "has_children": .bool(snapshot.hasChildren),
                "context_mode": .string(snapshot.contextMode.rawValue),
                "model": snapshot.model.map(JSONValue.string) ?? .null,
                "persona": snapshot.persona.map(JSONValue.string) ?? .null,
                "tool_filter": snapshot.toolFilter.map(Self.toolFilterJSON) ?? .null,
                "report_delivery": .string(snapshot.reportDelivery.rawValue),
                "active_job_id": snapshot.activeJobID.map(JSONValue.string) ?? .null,
                "last_job_id": snapshot.lastJobID.map(JSONValue.string) ?? .null,
                "created_at": .number(Double(snapshot.createdAt)),
                "updated_at": .number(Double(snapshot.updatedAt))
            ])
        }).displayText
    }

    private static func bool(_ value: JSONValue) -> Bool? {
        guard case let .bool(result) = value else { return nil }
        return result
    }

    private static func toolFilterJSON(_ filter: LocalSubagentToolFilter) -> JSONValue {
        var value: [String: JSONValue] = [:]
        if let allow = filter.allow {
            value["allow"] = .array(allow.map(JSONValue.string))
        }
        if let deny = filter.deny {
            value["deny"] = .array(deny.map(JSONValue.string))
        }
        return .object(value)
    }
}

private struct SubagentControlTool: LocalAgentTool {
    private static let maximumTimeoutMilliseconds = 600_000

    let registry: any HarnessJobManaging
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "subagent_control",
        description: "Wait for or interrupt a continuable local child Agent by stable subagent_id. Interrupt affects only its current activation; a later send_message can wake it again.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "subagent_id": .object([
                    "type": .string("string"),
                    "description": .string("Stable child address returned by subagent.")
                ]),
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([.string("wait"), .string("interrupt")])
                ]),
                "timeout_ms": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(maximumTimeoutMilliseconds))
                ]),
                "reason": .object(["type": .string("string")])
            ]),
            "required": .array([.string("subagent_id"), .string("action")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["subagent_id", "action", "timeout_ms", "reason"])
        _ = try arguments.requiredString("subagent_id", maximumUTF8Bytes: 256)
        let action = try arguments.requiredString("action", maximumUTF8Bytes: 32)
        guard ["wait", "interrupt"].contains(action) else {
            throw LocalToolError.invalidEnumValue(
                field: "action",
                value: action,
                allowed: ["wait", "interrupt"]
            )
        }
        if let timeout = arguments["timeout_ms"] {
            _ = try integer(timeout, range: 1...Self.maximumTimeoutMilliseconds)
        }
        if let reason = arguments["reason"] {
            _ = try arguments.requiredString("reason", maximumUTF8Bytes: 2 * 1_024)
            guard reason.stringValue != nil else { throw LocalToolError.invalidArguments }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "控制子 Agent \(arguments["subagent_id"]?.stringValue ?? "")"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["subagent:\(try arguments.requiredString("subagent_id", maximumUTF8Bytes: 256))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try arguments.requiredString("subagent_id", maximumUTF8Bytes: 256).lowercased()
        let action = try arguments.requiredString("action", maximumUTF8Bytes: 32)
        let child = try await registry.subagent(id: id, requesterSession: ownerSession)
        switch action {
        case "wait":
            let timeout = try arguments["timeout_ms"].map {
                try integer($0, range: 1...Self.maximumTimeoutMilliseconds)
            } ?? 30_000
            guard let jobID = child.activeJobID ?? child.lastJobID else {
                return snapshotJSON(child).displayText
            }
            _ = try await registry.wait(
                id: jobID,
                timeoutMilliseconds: timeout,
                ownerSession: child.parentSession
            )
            return snapshotJSON(
                try await registry.subagent(id: id, requesterSession: ownerSession)
            ).displayText
        case "interrupt":
            let result = try await registry.interruptSubagent(
                id: id,
                requesterSession: ownerSession,
                reason: arguments["reason"]?.stringValue
            )
            return JSONValue.object([
                "subagent_id": .string(id),
                "action": .string("interrupt"),
                "result": .string(result == .requested ? "requested" : "already_finished")
            ]).displayText
        default:
            throw LocalToolError.invalidArguments
        }
    }

    private func snapshotJSON(_ snapshot: HarnessSubagentSnapshot) -> JSONValue {
        .object([
            "subagent_id": .string(snapshot.id),
            "parent_session": .string(snapshot.parentSession),
            "delegation_depth": .number(Double(snapshot.delegationDepth)),
            "label": .string(snapshot.label),
            "status": .string(snapshot.status.rawValue),
            "has_children": .bool(snapshot.hasChildren),
            "active_job_id": snapshot.activeJobID.map(JSONValue.string) ?? .null,
            "last_job_id": snapshot.lastJobID.map(JSONValue.string) ?? .null,
            "created_at": .number(Double(snapshot.createdAt)),
            "updated_at": .number(Double(snapshot.updatedAt))
        ])
    }

    private func integer(_ value: JSONValue, range: ClosedRange<Int>) throws -> Int {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw LocalToolError.invalidArguments
        }
        let result = Int(number)
        guard range.contains(result) else { throw LocalToolError.invalidArguments }
        return result
    }
}

private struct JobOutputTool: LocalAgentTool {
    private static let defaultWaitMilliseconds = 30_000
    private static let maximumWaitMilliseconds = 600_000

    let registry: any HarnessJobManaging
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "job_output",
        description: "Read output from an on-device background job. Output is incremental. Set wait to true to wait for completion or timeout without stopping the job.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "job_id": .object([
                    "type": .string("string"),
                    "description": .string("Job id returned by shell_execute.")
                ]),
                "wait": .object([
                    "type": .string("boolean"),
                    "description": .string("Wait for a terminal state before reading. Defaults to false.")
                ]),
                "timeout_ms": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(maximumWaitMilliseconds)),
                    "description": .string("Wait bound in milliseconds. Defaults to 30000 and is capped at 600000.")
                ])
            ]),
            "required": .array([.string("job_id")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["job_id", "wait", "timeout_ms"])
        let id = try arguments.requiredString("job_id", maximumUTF8Bytes: 256)
        guard !id.isEmpty else { throw LocalToolError.invalidArguments }
        if let wait = arguments["wait"], Self.bool(wait) == nil {
            throw LocalToolError.invalidArguments
        }
        if let timeout = arguments["timeout_ms"] {
            _ = try Self.integer(timeout, range: 1...Self.maximumWaitMilliseconds)
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "读取后台任务 \(arguments["job_id"]?.stringValue ?? "")"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["job:\(try arguments.requiredString("job_id", maximumUTF8Bytes: 256))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try arguments.requiredString("job_id", maximumUTF8Bytes: 256)
        if arguments["wait"].flatMap(Self.bool) == true {
            let timeout = try arguments["timeout_ms"].map {
                try Self.integer($0, range: 1...Self.maximumWaitMilliseconds)
            } ?? Self.defaultWaitMilliseconds
            _ = try await registry.wait(
                id: id,
                timeoutMilliseconds: timeout,
                ownerSession: ownerSession
            )
        }
        let read = try await registry.read(id: id, ownerSession: ownerSession)
        let body = read.text.isEmpty ? "(no new output)" : read.text
        let separator = body.hasSuffix("\n") ? "" : "\n"
        return body + separator + Self.statusLine(read.snapshot)
    }

    private static func statusLine(_ snapshot: HarnessJobSnapshot) -> String {
        if let detail = snapshot.detail {
            return "[status: \(snapshot.status.rawValue), \(detail)]"
        }
        return "[status: \(snapshot.status.rawValue)]"
    }

    private static func bool(_ value: JSONValue) -> Bool? {
        guard case let .bool(result) = value else { return nil }
        return result
    }

    private static func integer(_ value: JSONValue, range: ClosedRange<Int>) throws -> Int {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw LocalToolError.invalidArguments
        }
        let result = Int(number)
        guard range.contains(result) else { throw LocalToolError.invalidArguments }
        return result
    }
}

private struct JobListTool: LocalAgentTool {
    let registry: any HarnessJobManaging
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "job_list",
        description: "List this conversation's on-device background jobs with ids, kinds, labels, and statuses.",
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

    func summary(arguments: [String: JSONValue]) -> String { "列出后台任务" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let jobs = await registry.list(ownerSession: ownerSession)
        guard !jobs.isEmpty else { return "(no background jobs)" }
        return jobs.map {
            "\($0.id) [\($0.kind)] \($0.status.rawValue) - \($0.label)"
        }.joined(separator: "\n")
    }
}

private struct JobKillTool: LocalAgentTool {
    let registry: any HarnessJobManaging
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "job_kill",
        description: "Request cancellation of an on-device background job. The job becomes killed after its work actually stops.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "job_id": .object([
                    "type": .string("string"),
                    "description": .string("Job id returned by shell_execute.")
                ]),
                "reason": .object([
                    "type": .string("string"),
                    "description": .string("Optional short cancellation reason.")
                ])
            ]),
            "required": .array([.string("job_id")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["job_id", "reason"])
        let id = try arguments.requiredString("job_id", maximumUTF8Bytes: 256)
        guard !id.isEmpty else { throw LocalToolError.invalidArguments }
        if arguments["reason"] != nil {
            _ = try arguments.requiredString("reason", maximumUTF8Bytes: 2 * 1_024)
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "停止后台任务 \(arguments["job_id"]?.stringValue ?? "")"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["job:\(try arguments.requiredString("job_id", maximumUTF8Bytes: 256))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try arguments.requiredString("job_id", maximumUTF8Bytes: 256)
        let reason = arguments["reason"]?.stringValue
        let result = try await registry.kill(
            id: id,
            ownerSession: ownerSession,
            reason: reason
        )
        switch result {
        case .requested:
            return "requested cancellation of job \(id)"
        case .alreadyFinished:
            let snapshot = try await registry.get(id: id, ownerSession: ownerSession)
            return "job \(id) had already finished [status: \(snapshot.status.rawValue)]"
        }
    }
}
