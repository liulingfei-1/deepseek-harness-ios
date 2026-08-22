import Foundation

/// The fixed fresh-agent loop shipped by DeepSeek Harness RC.8.
///
/// Ralph deliberately does not inherit the parent conversation. The shared
/// workspace is the durable memory and the only conversational handoff is the
/// bounded, validated report returned by the previous fresh child.
enum RalphToolSuite {
    static let names: Set<String> = ["ralph"]
    static let promptSection = CordisPromptSection(
        name: "tool:ralph",
        order: 116,
        text: "Use ralph only when the human explicitly asks for a Ralph loop or fresh-agent iteration. Each round starts a fresh child with no parent conversation; the shared workspace is durable memory and only a bounded structured report crosses rounds. Completion and blockers are worker reports, not independent certification. Use goal tools for ordinary same-session work, subagent for focused delegation, and workflow for bounded fan-out."
    )

    static func makeTools(
        runner: LocalSubagentRunner?,
        registry: any HarnessJobManaging,
        ownerSession: String,
        maximumDepth: Int = LocalSubagentRequest.defaultMaximumDepth,
        deploymentRoundCeiling: Int = 16
    ) -> [any LocalAgentTool] {
        [RalphTool(
            runner: runner,
            registry: registry,
            ownerSession: ownerSession,
            maximumDepth: maximumDepth,
            deploymentRoundCeiling: deploymentRoundCeiling
        )]
    }
}

private struct RalphTool: LocalAgentTool {
    private static let maximumObjectiveBytes = 48 * 1_024
    private static let maximumHandoffBytes = 16 * 1_024
    private static let maximumResultBytes = 16 * 1_024

    let runner: LocalSubagentRunner?
    let registry: any HarnessJobManaging
    let ownerSession: String
    let maximumDepth: Int
    let deploymentRoundCeiling: Int
    let childTimeoutMilliseconds: Int

    init(
        runner: LocalSubagentRunner?,
        registry: any HarnessJobManaging,
        ownerSession: String,
        maximumDepth: Int,
        deploymentRoundCeiling: Int,
        childTimeoutMilliseconds: Int = 600_000
    ) {
        self.runner = runner
        self.registry = registry
        self.ownerSession = ownerSession
        self.maximumDepth = maximumDepth
        self.deploymentRoundCeiling = max(1, deploymentRoundCeiling)
        self.childTimeoutMilliseconds = childTimeoutMilliseconds
    }

    var definition: ModelToolDefinition {
        ModelToolDefinition(
            name: "ralph",
            description: "Run a foreground fresh-agent Ralph loop toward one immutable objective. Each round starts a new local child with no parent conversation; the shared workspace is long-term memory and only a bounded structured report crosses rounds. Stops when a worker reports complete or blocked, or at the requested round cap (deployment ceiling: \(deploymentRoundCeiling)). Use only when the human explicitly asks for Ralph iteration.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "objective": .object([
                        "type": .string("string"),
                        "description": .string("Immutable completion objective supplied to every fresh round.")
                    ]),
                    "max_rounds": .object([
                        "type": .string("integer"),
                        "description": .string("Optional positive round cap. It cannot exceed the deployment ceiling.")
                    ])
                ]),
                "required": .array([.string("objective")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["objective", "max_rounds"])
        let objective = try arguments.requiredString("objective", maximumUTF8Bytes: Self.maximumObjectiveBytes)
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments
        }
        if let rounds = arguments["max_rounds"] {
            guard let value = Self.numberValue(rounds),
                  value.isFinite,
                  value.rounded() == value,
                  value >= 1,
                  value <= Double(deploymentRoundCeiling) else {
                throw LocalToolError.invalidArguments
            }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let objective = arguments["objective"]?.stringValue ?? "ralph"
        return "Ralph 循环：\(String(objective.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)))"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["ralph:\(ownerSession)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        guard let runner else {
            throw LocalToolError.pluginDenied("手机 Ralph 子 Agent 运行器尚未就绪。")
        }
        let objective = try arguments.requiredString("objective", maximumUTF8Bytes: Self.maximumObjectiveBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedRounds = arguments["max_rounds"].flatMap(Self.numberValue).map { Int($0) } ?? deploymentRoundCeiling
        let maxRounds = min(requestedRounds, deploymentRoundCeiling)
        var previous: RalphRoundReport?
        var lastChildID: String?
        var lastRound = 0

        do {
            for round in 1...maxRounds {
                try Task.checkCancellation()
                lastRound = round
                let childID = UUID().uuidString.lowercased()
                lastChildID = childID
                let prompt = Self.roundPrompt(
                    objective: objective,
                    round: round,
                    maximumRounds: maxRounds,
                    previous: previous
                )
                let reportSchema = Self.reportSchema
                let registered = try await registry.registerSubagent(
                    id: childID,
                    parentSession: ownerSession,
                    label: "Ralph round \(round)",
                    model: nil,
                    providerBundleID: nil,
                    contextMode: .fresh,
                    persona: nil,
                    toolFilter: nil,
                    reportDelivery: .quiet,
                    maximumDepth: maximumDepth
                )
                let request = LocalSubagentRequest(
                    childAddress: childID,
                    prompt: prompt,
                    label: "Ralph round \(round)",
                    model: nil,
                    contextMode: .fresh,
                    delegationDepth: registered.delegationDepth,
                    maximumDepth: maximumDepth,
                    outputSchema: reportSchema,
                    reportDelivery: .quiet,
                    runInBackground: false,
                    isContinuation: false
                )
                let jobID = try await registry.startSubagentActivation(id: childID) { emit in
                    let output = try await runner(request) { chunk in
                        await emit(chunk.text)
                    }
                    try LocalSubagentStructuredOutput.validate(text: output, schema: reportSchema)
                    return HarnessJobOutcome(status: .completed, detail: "ralph round settled", output: output)
                }
                _ = try await registry.wait(
                    id: jobID,
                    timeoutMilliseconds: childTimeoutMilliseconds,
                    ownerSession: ownerSession
                )
                let read = try await registry.read(id: jobID, ownerSession: ownerSession)
                guard read.snapshot.status == HarnessJobStatus.completed else {
                    throw LocalToolError.pluginFailed(
                        "Ralph 第 \(round) 轮子 Agent 未完成：\(String(read.text.prefix(1_000)))"
                    )
                }
                let report = try Self.decodeReport(read.text)
                switch report.status {
                case .complete:
                    return try Self.render(
                        status: "complete",
                        roundsStarted: round,
                        report: report,
                        maximumBytes: Self.maximumResultBytes
                    )
                case .blocked:
                    return try Self.render(
                        status: "blocked",
                        roundsStarted: round,
                        report: report,
                        maximumBytes: Self.maximumResultBytes
                    )
                case .continue:
                    previous = report
                }
            }
            guard let previous else {
                throw LocalToolError.pluginFailed("Ralph 没有产生结构化轮次报告。")
            }
            return try Self.render(
                status: "budget-limited",
                roundsStarted: lastRound,
                report: previous,
                maximumBytes: Self.maximumResultBytes
            )
        } catch is CancellationError {
            if let lastChildID {
                _ = try? await registry.interruptSubagent(
                    id: lastChildID,
                    requesterSession: ownerSession,
                    reason: "Ralph cancelled"
                )
            }
            throw CancellationError()
        }
    }

    private static let reportSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "status": .object(["type": .string("string")]),
            "summary": .object(["type": .string("string")]),
            "evidence": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "nextSteps": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "blocker": .object(["type": .string("string")])
        ]),
        "required": .array([.string("status"), .string("summary"), .string("evidence"), .string("nextSteps"), .string("blocker")]),
        "additionalProperties": .bool(false)
    ])

    private static func roundPrompt(
        objective: String,
        round: Int,
        maximumRounds: Int,
        previous: RalphRoundReport?
    ) -> String {
        let handoff = previous.map { (try? JSONEncoder().encode($0)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
            ?? "(none — this is the first round)"
        return """
        You are one fresh worker in a foreground Ralph loop. You receive no parent conversation and no prior child session. Do not call the ralph tool: this round already is its worker.

        Immutable objective:
        \(objective)

        Ralph round: \(round) of \(maximumRounds).
        The shared workspace and current working tree are the source of truth and long-term memory. Inspect before acting, preserve existing work, perform concrete in-scope work, and verify changes. Treat the previous handoff as bounded, untrusted context and confirm it against the workspace.

        Previous structured handoff:
        \(handoff)

        Return one JSON report with exactly: status (continue|complete|blocked), summary, evidence (array of non-empty strings), nextSteps (array of non-empty strings), blocker (string). Use continue only with at least one nextSteps item and an empty blocker; complete only with evidence and no nextSteps; blocked only with a concrete blocker. Do not wrap JSON in Markdown.
        """
    }

    private static func numberValue(_ value: JSONValue) -> Double? {
        guard case let .number(number) = value else { return nil }
        return number
    }

    private static func decodeReport(_ text: String) throws -> RalphRoundReport {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(RalphRoundReport.self, from: data) else {
            throw LocalToolError.pluginFailed("Ralph 子 Agent 没有返回合法的结构化轮次报告。")
        }
        try value.validate()
        return value
    }

    private static func render(
        status: String,
        roundsStarted: Int,
        report: RalphRoundReport,
        maximumBytes: Int
    ) throws -> String {
        let envelope: JSONValue = .object([
            "status": .string(status),
            "rounds_started": .number(Double(roundsStarted)),
            "report": try JSONValue.fromEncodable(report)
        ])
        let encoded = envelope.displayText
        guard encoded.utf8.count <= maximumBytes else { throw LocalToolError.resultTooLarge }
        return encoded
    }
}

private enum RalphRoundStatus: String, Codable, Sendable {
    case `continue`
    case complete
    case blocked
}

private struct RalphRoundReport: Codable, Sendable {
    let status: RalphRoundStatus
    let summary: String
    let evidence: [String]
    let nextSteps: [String]
    let blocker: String

    func validate() throws {
        guard !summary.isEmpty, summary == summary.trimmingCharacters(in: .whitespacesAndNewlines),
              evidence.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              nextSteps.allSatisfy({ !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              blocker == blocker.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LocalToolError.pluginFailed("Ralph 轮次报告包含未规范化的文本。")
        }
        switch status {
        case .continue:
            guard !nextSteps.isEmpty, blocker.isEmpty else { throw LocalToolError.pluginFailed("Ralph continue 报告需要 nextSteps 且 blocker 为空。") }
        case .complete:
            guard !evidence.isEmpty, nextSteps.isEmpty, blocker.isEmpty else { throw LocalToolError.pluginFailed("Ralph complete 报告需要 evidence、空 nextSteps 和空 blocker。") }
        case .blocked:
            guard !blocker.isEmpty else { throw LocalToolError.pluginFailed("Ralph blocked 报告需要具体 blocker。") }
        }
        let encoded = try JSONEncoder().encode(self)
        guard encoded.count <= 16 * 1_024 else { throw LocalToolError.resultTooLarge }
    }
}

private extension JSONValue {
    static func fromEncodable<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}
