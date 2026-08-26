import Foundation

enum CordisAgentStatus: String, Sendable, Equatable {
    case idle
    case running
}

enum CordisAgentSessionStartSource: String, Sendable, Equatable {
    case startup
    case resume
    case clear
    case compact
}

struct CordisAgentIdentityContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
}

struct CordisAgentStatusContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let status: CordisAgentStatus
}

struct CordisAgentSessionStartContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let source: CordisAgentSessionStartSource
}

struct CordisAgentPreStepContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let messages: [AgentMessage]
}

/// A frozen view of one pending queue occurrence immediately before the
/// native loop claims it. DeepSeek Harness treats MessageId as the sole inbox
/// identity; this mobile checkpoint exposes that identity and its ownership
/// envelope only as immutable facts.
struct CordisAgentInboxPreClaimContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let boundary: QueuedInputBoundary
    let message: QueuedAgentInput
    let source: String
    let workspaceBoundary: String
}

/// Durable inbox lifecycle facts. These are observe-only events: plugins may
/// not change MessageId, source, disposition, or queue ownership after the
/// native store has committed the transition.
struct CordisAgentInboxInsertedContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let message: QueuedAgentInput
    let source: String
    let boundary: QueuedInputBoundary
}

struct CordisAgentInboxClaimedContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let message: QueuedAgentInput
    let source: String
    let boundary: QueuedInputBoundary
}

struct CordisAgentInboxDiscardedContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let message: QueuedAgentInput
    let source: String
    let boundary: QueuedInputBoundary
    let reason: String
}

/// The deliberately narrow mutation surface for pending input. Plugins may
/// change text or consume the exact occurrence, but cannot replace its id,
/// source, disposition, timestamp, or workspace ownership.
enum CordisAgentInboxPreClaimDecision: Sendable, Equatable {
    case claim(text: String)
    case discard
}

enum CordisAgentPreStepDecision: Sendable, Equatable {
    case enter([AgentMessage])
    case reject(reason: String)
}

/// The only model-request state that `agent/request` may replace. Model-visible
/// messages, prompt text, and tools come from the durable session boundary and
/// are deliberately absent, matching the upstream reconstructability contract.
struct CordisModelRequestPlan: Sendable, Equatable {
    var configuration: AgentConfiguration

    init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    init(_ request: ModelRequest) {
        configuration = request.configuration
    }

    func modelRequest(
        apiKey: String,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ModelToolDefinition],
        imagePayloads: [ModelImagePayload] = [],
        route: ProviderRequestRoute? = nil
    ) -> ModelRequest {
        ModelRequest(
            configuration: configuration,
            apiKey: apiKey,
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools,
            imagePayloads: imagePayloads,
            route: route
        )
    }
}

struct CordisAgentRequestContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    /// The proposed call configuration only. It contains no prompt, messages,
    /// tools, or credentials; those remain owned by durable request state.
    let request: CordisModelRequestPlan
}

struct CordisAgentRequestErrorContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let providerID: String
    let model: String
    let error: String
}

enum CordisAgentRequestErrorAction: Sendable, Equatable {
    case fail
    case retry
}

struct CordisAgentErrorContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let error: String
}

/// Immutable model-visible request facts exposed to `llm/stream`. Provider
/// credentials are intentionally impossible to obtain from this value.
struct CordisModelStreamRequest: Sendable, Equatable {
    let configuration: AgentConfiguration
    let systemPrompt: String
    let messages: [AgentMessage]
    let tools: [ModelToolDefinition]

    init(_ request: ModelRequest) {
        configuration = request.configuration
        systemPrompt = request.systemPrompt
        messages = request.messages
        tools = request.tools
    }
}

typealias CordisModelEventStream = AsyncThrowingStream<LLMStreamEvent, Error>

struct CordisLLMStreamContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let request: CordisModelStreamRequest
}

struct CordisToolExecution: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let call: AgentToolCall
    let arguments: [String: JSONValue]
    let risk: ToolRisk
    let summary: String
    private let signalBox: ToolCancellationSignalBox

    var signal: ToolCancellationSignal { signalBox.get() }

    init(
        agentID: UUID? = nil,
        runID: UUID,
        turn: Int = 1,
        step: Int,
        call: AgentToolCall,
        arguments: [String: JSONValue],
        risk: ToolRisk,
        summary: String,
        signal: ToolCancellationSignal = ToolCancellationSignal()
    ) {
        self.agentID = agentID ?? runID
        self.runID = runID
        self.turn = turn
        self.step = step
        self.call = call
        self.arguments = arguments
        self.risk = risk
        self.summary = summary
        signalBox = ToolCancellationSignalBox(signal)
    }

    func replacingSignal(_ signal: ToolCancellationSignal) {
        signalBox.replace(signal)
    }

    static func == (lhs: CordisToolExecution, rhs: CordisToolExecution) -> Bool {
        lhs.agentID == rhs.agentID
            && lhs.runID == rhs.runID
            && lhs.turn == rhs.turn
            && lhs.step == rhs.step
            && lhs.call == rhs.call
            && lhs.arguments == rhs.arguments
            && lhs.risk == rhs.risk
            && lhs.summary == rhs.summary
    }
}

enum CordisPreToolDecision: Sendable, Equatable {
    case allow
    case ask
    case deny(reason: String)
}

struct CordisToolExecutionResult: Sendable, Equatable {
    let text: String
    let isError: Bool
    /// Canonical JSON value returned by the tool. `text` is the current
    /// presentation content for model/session compatibility; finalizers may
    /// replace only that content.
    let value: JSONValue?
    /// Stable structured error code for model/session routing.
    let errorCode: String?
    /// Model-visible context folded by post-execute plugins. These messages are
    /// persisted immediately after the tool result and never veto execution.
    let additionalContexts: [AgentMessage]

    init(
        text: String,
        isError: Bool,
        value: JSONValue? = nil,
        errorCode: String? = nil,
        additionalContexts: [AgentMessage] = []
    ) {
        self.text = text
        self.isError = isError
        self.value = value
        self.errorCode = errorCode
        self.additionalContexts = additionalContexts
    }

    func replacingContent(_ text: String) -> Self {
        Self(
            text: text,
            isError: isError,
            value: value,
            errorCode: errorCode,
            additionalContexts: additionalContexts
        )
    }
}

struct CordisPostToolExecutionContext: Sendable, Equatable {
    let execution: CordisToolExecution
    let result: CordisToolExecutionResult
}

struct CordisToolResultContext: Sendable, Equatable {
    let execution: CordisToolExecution
    let result: CordisToolExecutionResult
}

struct CordisAgentTurnStoppingContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let messages: [AgentMessage]
}

struct CordisCodeDispatchLogContext: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let turn: Int
    let step: Int
    let parentCallID: String
    let dispatchCallID: String
    let toolName: String
}

struct CordisMemoryRecordContext: Sendable, Equatable {
    let runID: UUID
    let step: Int
    let messages: [AgentMessage]
}

enum CordisAgentLoopEvents {
    static let agentCreated = CordisEventKey<CordisAgentIdentityContext>("agent/created")
    static let agentDisposed = CordisEventKey<CordisAgentIdentityContext>("agent/disposed")
    static let agentStatus = CordisEventKey<CordisAgentStatusContext>("agent/status")
    static let agentSessionStart = CordisEventKey<CordisAgentSessionStartContext>(
        "agent/session-start"
    )
    static let agentError = CordisEventKey<CordisAgentErrorContext>("agent/error")
    static let toolsResult = CordisEventKey<CordisToolResultContext>("tools/result")
    static let toolsChange = CordisEventKey<CordisNoPayload>("tools/change")
    static let agentInboxInserted = CordisEventKey<CordisAgentInboxInsertedContext>(
        "agent/inbox/inserted"
    )
    static let agentInboxClaimed = CordisEventKey<CordisAgentInboxClaimedContext>(
        "agent/inbox/claimed"
    )
    static let agentInboxDiscarded = CordisEventKey<CordisAgentInboxDiscardedContext>(
        "agent/inbox/discarded"
    )
}

/// Checkpoint names and semantics intentionally mirror DeepSeek Harness' public
/// `agent/*` and `tools/*` Cordis waterfalls. `AgentRuntime` can adopt them one
/// boundary at a time without coupling the plugin kernel to UI state.
enum CordisAgentLoopCheckpoints {
    /// Mobile-only admission node placed immediately before the durable queue
    /// claim. Its ordering follows the vendored Inbox claim contract while
    /// keeping the supported mutation surface smaller than `agent/pre-step`.
    static let inboxPreClaim = CordisCheckpointKey<
        CordisAgentInboxPreClaimContext,
        CordisAgentInboxPreClaimDecision
    >("agent/inbox/pre-claim")

    /// Mobile memory providers may rewrite or reject the messages entering a
    /// step before the canonical `agent/pre-step` waterfall runs.
    static let memoryRecall = CordisCheckpointKey<
        CordisAgentPreStepContext,
        CordisAgentPreStepDecision
    >("memory/recall")

    /// A distinct orchestration layer keeps routing/loop policy replaceable
    /// without pretending it is durable memory or core AgentLoop behavior.
    static let orchestrationPreStep = CordisCheckpointKey<
        CordisAgentPreStepContext,
        CordisAgentPreStepDecision
    >("orchestration/pre-step")

    static let preStep = CordisCheckpointKey<
        CordisAgentPreStepContext,
        CordisAgentPreStepDecision
    >("agent/pre-step")

    static let request = CordisCheckpointKey<
        CordisAgentRequestContext,
        CordisModelRequestPlan
    >("agent/request")

    static let orchestrationRequest = CordisCheckpointKey<
        CordisAgentRequestContext,
        CordisModelRequestPlan
    >("orchestration/request")

    static let requestError = CordisCheckpointKey<
        CordisAgentRequestErrorContext,
        CordisAgentRequestErrorAction
    >("agent/request-error")

    static let orchestrationRequestError = CordisCheckpointKey<
        CordisAgentRequestErrorContext,
        CordisAgentRequestErrorAction
    >("orchestration/request-error")

    static let llmStream = CordisCheckpointKey<
        CordisLLMStreamContext,
        CordisModelEventStream
    >("llm/stream")

    static let toolsPreExecute = CordisCheckpointKey<
        CordisToolExecution,
        CordisPreToolDecision
    >("tools/pre-execute")

    /// Sandbox policy is evaluated independently and combined monotonically
    /// with the platform permission mode and ordinary tool policy.
    static let sandboxPreExecute = CordisCheckpointKey<
        CordisToolExecution,
        CordisPreToolDecision
    >("sandbox/pre-execute")

    static let toolsExecute = CordisCheckpointKey<
        CordisToolExecution,
        CordisToolExecutionResult
    >("tools/execute")

    static let toolsPostExecute = CordisCheckpointKey<
        CordisPostToolExecutionContext,
        CordisToolExecutionResult
    >("tools/post-execute")

    static let toolsCodeDispatchLog = CordisCheckpointKey<
        CordisCodeDispatchLogContext,
        CordisToolExecutionResult
    >("tools/code-dispatch-log")

    static let memoryRecord = CordisEventKey<CordisMemoryRecordContext>("memory/record")

    static let turnStopping = CordisEventKey<CordisAgentTurnStoppingContext>(
        "agent/turn-stopping"
    )

    static let orchestrationTurnStopping = CordisEventKey<CordisAgentTurnStoppingContext>(
        "orchestration/turn-stopping"
    )
}
