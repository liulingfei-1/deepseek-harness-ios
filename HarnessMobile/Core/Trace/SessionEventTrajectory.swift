import Foundation

/// Event names understood by the bundled DeepSeek Harness compatibility layer.
///
/// The list mirrors the upstream generated persistence catalog. Plugins may add
/// out-of-tree names when opening ``SessionEventJSONLStore`` or by registering
/// them before the first recovery read.
enum SessionEventVocabulary {
    static let turnStart = "turn/start"
    static let turnEnd = "turn/end"
    static let stepStart = "step/start"
    static let stepEnd = "step/end"
    static let userMessage = "user/message"
    static let assistantChunk = "assistant/chunk"
    static let assistantMessage = "assistant/message"
    static let toolCall = "tool/call"
    static let toolResult = "tool/result"
    static let commandRun = "command/run"
    static let commandDone = "command/done"
    static let requestHeader = "request/header"
    static let requestContext = "request/context"
    static let questionRequested = "question/requested"
    static let questionResolved = "question/resolved"
    static let approvalAsked = "approval/asked"
    static let approvalDecided = "approval/decided"
    static let sessionEndSeed = "session/end-seed"
    static let subagentDescriptor = "subagent/descriptor"
    static let subagentLifecycle = "subagent/lifecycle"
    /// Metadata for one structured-output contract result. Raw model output
    /// is intentionally never stored in this event.
    static let subagentOutput = "subagent/output"
    /// Durable model route for one session, mirroring upstream v0.1.2
    /// `ModelSelection` (`provider`, `model`, optional `reasoningEffort`).
    static let modelSelection = "model/selection"
    /// Mirrors upstream `permission-presets` so the latest user-chosen
    /// permission preset for a session is durable; the payload is the
    /// preset table key (or `custom` when the effective knobs match none).
    static let permissionPreset = "permission/preset"
    static let deliveryAccepted = "session-log-deepseek/delivery-accepted"

    static let upstreamKnown: Set<String> = [
        "agent-preset/selected",
        "agent/inbox/spliced",
        "approval/asked",
        "approval/decided",
        "approval/policy",
        assistantChunk,
        assistantMessage,
        "command/done",
        "command/run",
        "compaction/end",
        "compaction/prune",
        "compaction/start",
        "compaction/summary",
        "feedback/record",
        "goal/change",
        "hook/invoked",
        "hook/result",
        "llm/retry",
        "llm/retry-started",
        "llm/request-audit",
        /// Mirrors upstream v0.1.2 `ModelSelection`; appended when the user
        /// selects a provider/model route for the session.
        "model/selection",
        "permission/preset",
        "plan/mode",
        questionRequested,
        questionResolved,
        requestContext,
        requestHeader,
        "sandbox/mode",
        "schedule/change",
        sessionEndSeed,
        /// Upstream v0.1.2 `session-log-deepseek` package; a delivery the
        /// DeepSeek session log has accepted.
        "session-log-deepseek/delivery-accepted",
        "session/title",
        "session/title-llm-request",
        stepEnd,
        stepStart,
        "subagent/descriptor",
        subagentLifecycle,
        /// Upstream v0.1.2: the model-selection policy a subagent run inherits.
        "subagent/model-selection-policy",
        subagentOutput,
        /// Upstream v0.1.2 `experimental/tool-agent-team`. Names are known so a
        /// log written by an agent-team build stays readable; the mobile build
        /// does not implement team orchestration itself.
        "team/member",
        "team/message/delivered",
        "team/message/queued",
        "team/task",
        "todo/write",
        "tool-workflow/agent-end",
        "tool-workflow/agent-start",
        "tool-workflow/run-end",
        "tool-workflow/run-start",
        toolCall,
        "tool/code-dispatch",
        "tool/code-dispatch-start",
        toolResult,
        turnEnd,
        turnStart,
        userMessage,
        "web/deepseek-search-llm-request"
    ]
}

/// Error identities used by the upstream session crash-repair contract.
enum SessionRecoveryErrorCode {
    static let toolNotStarted = "TOOL_NOT_STARTED"
    static let toolOutcomeUnknown = "TOOL_OUTCOME_UNKNOWN"
}

/// Builds deterministic events that close a cold session whose last turn was
/// interrupted. Complete durable events are preserved; only missing tool
/// results and lifecycle boundaries are synthesized.
enum SessionEventRecovery {
    private struct PendingTool {
        let step: Int
        var callSequence: UInt64?
    }

    static func interruptedTurnClosers(_ events: [SessionEvent]) throws -> [SessionEvent] {
        var openTurn: Int?
        var openStep: Int?
        var pending: [(String, PendingTool)] = []

        for event in events {
            switch event.type {
            case SessionEventVocabulary.turnStart:
                openTurn = event.turnStartData?.turn
                openStep = nil
                pending.removeAll(keepingCapacity: true)
            case SessionEventVocabulary.turnEnd:
                openTurn = nil
                openStep = nil
                pending.removeAll(keepingCapacity: true)
            case SessionEventVocabulary.stepStart:
                openStep = event.stepData?.step
            case SessionEventVocabulary.stepEnd:
                pending.removeAll(keepingCapacity: true)
                openStep = nil
            case SessionEventVocabulary.assistantMessage:
                guard let assistant = event.assistantMessageData,
                      case let .array(content)? = assistant.message.objectValue?["content"] else {
                    continue
                }
                for block in content {
                    guard let object = block.objectValue,
                          object["type"]?.stringValue == "tool-call",
                          let callID = object["id"]?.stringValue ?? object["callId"]?.stringValue,
                          !callID.isEmpty else { continue }
                    if let index = pending.firstIndex(where: { $0.0 == callID }) {
                        pending[index] = (
                            callID,
                            PendingTool(step: assistant.step, callSequence: nil)
                        )
                    } else {
                        pending.append(
                            (callID, PendingTool(step: assistant.step, callSequence: nil))
                        )
                    }
                }
            case SessionEventVocabulary.toolCall:
                guard let call = event.toolCallData,
                      let index = pending.firstIndex(where: { $0.0 == call.callID }) else { continue }
                pending[index].1.callSequence = event.seq
            case SessionEventVocabulary.toolResult:
                if let callID = event.toolResultData?.callID {
                    pending.removeAll { $0.0 == callID }
                }
            default:
                continue
            }
        }

        guard let turn = openTurn, let last = events.last else { return [] }

        var sequence = last.seq + 1
        let time = last.time
        var closers: [SessionEvent] = []
        for (callID, pendingTool) in pending {
            let started = pendingTool.callSequence != nil
            let code = started
                ? SessionRecoveryErrorCode.toolOutcomeUnknown
                : SessionRecoveryErrorCode.toolNotStarted
            let name = started ? "ToolOutcomeUnknownError" : "ToolNotStartedError"
            let text = started
                ? "The tool call was interrupted after it was recorded, but no result was durably recorded. Its outcome is unknown. Decide whether to retry from the tool semantics: retry only if the operation is read-only or idempotent; if it may have side effects, first verify external state or ask the user. Do not retry blindly."
                : "The tool call was interrupted before the Harness recorded it as started. Retry it if it is still needed."
            let message: JSONValue = .object([
                "id": .string("interrupted-tool-result-\(callID)-\(sequence)"),
                "role": .string("user"),
                "source": .object([
                    "kind": .string("tool"),
                    "callId": .string(callID)
                ]),
                "content": .array([
                    .object([
                        "type": .string("tool-result"),
                        "toolCallId": .string(callID),
                        "isError": .bool(true),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(text)
                            ])
                        ])
                    ])
                ])
            ])
            let sourceEventSeqs = pendingTool.callSequence.map { [$0] }
            closers.append(try SessionEvent(
                type: SessionEventVocabulary.toolResult,
                seq: sequence,
                time: time,
                data: .object([
                    "turn": .number(Double(turn)),
                    "step": .number(Double(pendingTool.step)),
                    "message": message,
                    "error": .object([
                        "name": .string(name),
                        "code": .string(code)
                    ])
                ]),
                sourceEventSeqs: sourceEventSeqs,
                surfaceOp: .append
            ))
            sequence += 1
        }

        if let step = openStep {
            closers.append(try SessionEvent(
                type: SessionEventVocabulary.stepEnd,
                seq: sequence,
                time: time,
                data: .object([
                    "turn": .number(Double(turn)),
                    "step": .number(Double(step))
                ])
            ))
            sequence += 1
        }
        closers.append(try SessionEvent(
            type: SessionEventVocabulary.turnEnd,
            seq: sequence,
            time: time,
            data: .object([
                "turn": .number(Double(turn)),
                "reason": .object(["kind": .string("interrupted")])
            ])
        ))
        return closers
    }
}

/// How a message-producing event entered the ordered conversation surface.
/// The custom representation is wire-compatible with DSH: either the JSON
/// string `"append"` or a replacement object.
enum SessionSurfaceOperation: Codable, Sendable, Equatable {
    case append
    case replace(start: UInt64, end: UInt64)

    private enum CodingKeys: String, CodingKey {
        case operation = "op"
        case start
        case end
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            guard value == "append" else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown surface operation \(value)")
                )
            }
            self = .append
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let operation = try container.decode(String.self, forKey: .operation)
        guard operation == "replace" else {
            throw DecodingError.dataCorruptedError(
                forKey: .operation,
                in: container,
                debugDescription: "Unknown surface operation \(operation)"
            )
        }
        let start = try container.decode(UInt64.self, forKey: .start)
        let end = try container.decode(UInt64.self, forKey: .end)
        guard start <= end else {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "Surface replacement end precedes start"
            )
        }
        self = .replace(start: start, end: end)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .append:
            var container = encoder.singleValueContainer()
            try container.encode("append")
        case let .replace(start, end):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("replace", forKey: .operation)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        }
    }
}

/// Extensible, lossless JSON event envelope used as the trajectory source of truth.
/// `type` deliberately remains a String so Cordis plugins can add vocabulary
/// without recompiling this module.
struct SessionEvent: Codable, Sendable, Equatable, Identifiable {
    var id: UInt64 { seq }

    let type: String
    let seq: UInt64
    let time: Int64
    let data: JSONValue
    let ignorable: Bool?
    let sourceEventSeqs: [UInt64]?
    let surfaceOp: SessionSurfaceOperation?

    init(
        type: String,
        seq: UInt64,
        time: Int64,
        data: JSONValue,
        ignorable: Bool? = nil,
        sourceEventSeqs: [UInt64]? = nil,
        surfaceOp: SessionSurfaceOperation? = nil
    ) throws {
        self.type = type
        self.seq = seq
        self.time = time
        self.data = data
        self.ignorable = ignorable
        self.sourceEventSeqs = sourceEventSeqs
        self.surfaceOp = surfaceOp
        try validateEnvelope()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        seq = try container.decode(UInt64.self, forKey: .seq)
        time = try container.decode(Int64.self, forKey: .time)
        data = try container.decode(JSONValue.self, forKey: .data)
        ignorable = try container.decodeIfPresent(Bool.self, forKey: .ignorable)
        sourceEventSeqs = try container.decodeIfPresent([UInt64].self, forKey: .sourceEventSeqs)
        surfaceOp = try container.decodeIfPresent(SessionSurfaceOperation.self, forKey: .surfaceOp)
        try validateEnvelope()
    }

    var isIgnorable: Bool { ignorable == true }

    private func validateEnvelope() throws {
        guard !type.isEmpty else { throw SessionEventLogError.invalidEnvelope("Event type is empty") }
        guard time >= 0 else { throw SessionEventLogError.invalidEnvelope("Event time is negative") }
        guard ignorable != false else {
            throw SessionEventLogError.invalidEnvelope("ignorable may be absent or true, never false")
        }
        if let sourceEventSeqs, sourceEventSeqs.contains(where: { $0 >= seq }) {
            throw SessionEventLogError.invalidEnvelope("Source event sequences must precede seq \(seq)")
        }
        if case let .replace(start, end) = surfaceOp, end >= seq || start > end {
            throw SessionEventLogError.invalidEnvelope("Surface replacement must reference an earlier ordered range")
        }
    }
}

/// An event before the session actor assigns its contiguous sequence number.
struct SessionEventDraft: Sendable, Equatable {
    let type: String
    let time: Int64
    let data: JSONValue
    let ignorable: Bool?
    let sourceEventSeqs: [UInt64]?
    let surfaceOp: SessionSurfaceOperation?

    init(
        type: String,
        time: Int64 = SessionEventTimestamp.nowMilliseconds(),
        data: JSONValue,
        ignorable: Bool? = nil,
        sourceEventSeqs: [UInt64]? = nil,
        surfaceOp: SessionSurfaceOperation? = nil
    ) {
        self.type = type
        self.time = time
        self.data = data
        self.ignorable = ignorable
        self.sourceEventSeqs = sourceEventSeqs
        self.surfaceOp = surfaceOp
    }
}

enum SessionEventTimestamp {
    static func nowMilliseconds(date: Date = .now) -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0 else { return 0 }
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds.rounded(.down))
    }
}

struct SessionTurnStartData: Codable, Sendable, Equatable {
    let turn: Int
}

struct SessionTurnEndData: Codable, Sendable, Equatable {
    let turn: Int
    let reason: JSONValue
}

struct SessionStepData: Codable, Sendable, Equatable, Hashable {
    let turn: Int
    let step: Int
}

enum SessionRequestHeaderReason: String, Codable, Sendable, Equatable {
    case initial
    case resume
    case change
}

struct SessionRequestHeaderData: Sendable, Equatable {
    let header: JSONValue
    let reason: SessionRequestHeaderReason
}

struct SessionRequestContextData: Sendable, Equatable {
    let provider: String
    let model: String
    let contextWindow: Int?
}

/// A bounded, content-free proof that a provider request was assembled only
/// from durable SessionEvent rows. The request body is deliberately omitted;
/// source sequence numbers are enough for replay and diagnostics without
/// copying prompts, tool arguments, or tool output into telemetry.
struct ModelVisibleEventAuditReport: Sendable, Equatable {
    let messageSourceEventSeqs: [UInt64]
    let requestHeaderEventSeq: UInt64
    let contextSourceEventSeqs: [UInt64]

    var sourceEventSeqs: [UInt64] {
        var result = [requestHeaderEventSeq]
        result.append(contentsOf: messageSourceEventSeqs)
        result.append(contentsOf: contextSourceEventSeqs)
        return Array(Set(result)).sorted()
    }
}

/// Fail-closed model-visible provenance gate. It compares message identity and
/// request header structure, never message text, so a missing tool response is
/// rejected without leaking the result into an error or report.
struct ModelVisibleEventAuditFailure: LocalizedError, Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case missingMessageSource = "missing-message-source"
        case missingToolResultSource = "missing-tool-result-source"
        case missingRequestHeader = "missing-request-header"
    }

    let kind: Kind
    let messageIndex: Int?

    var errorDescription: String? {
        switch kind {
        case .missingMessageSource:
            return "模型请求包含未记录的会话消息，已停止发送。"
        case .missingToolResultSource:
            return "模型请求包含未记录的工具响应，已停止发送。"
        case .missingRequestHeader:
            return "模型请求的系统提示或工具定义未记录，已停止发送。"
        }
    }
}

enum ModelVisibleEventAuditor {
    static func validate(
        request: ModelRequest,
        requestHeader: JSONValue,
        events: [SessionEvent]
    ) throws -> ModelVisibleEventAuditReport {
        let ordered = events.sorted { $0.seq < $1.seq }
        guard let headerEvent = ordered.last(where: {
            $0.type == SessionEventVocabulary.requestHeader
                && $0.data.objectValue?["header"] == requestHeader
        }) else {
            throw ModelVisibleEventAuditFailure(
                kind: .missingRequestHeader,
                messageIndex: nil
            )
        }

        var messageSources: [UInt64] = []
        var contextSources: [UInt64] = []
        for (index, message) in request.messages.enumerated() {
            if message.role == .tool {
                guard let callID = message.toolCallID,
                      let event = ordered.last(where: {
                          $0.type == SessionEventVocabulary.toolResult
                              && $0.toolResultData?.callID == callID
                      }) else {
                    throw ModelVisibleEventAuditFailure(
                        kind: .missingToolResultSource,
                        messageIndex: index
                    )
                }
                messageSources.append(event.seq)
                contextSources.append(contentsOf: event.sourceEventSeqs ?? [])
                continue
            }

            guard let event = ordered.last(where: {
                guard $0.type == SessionEventVocabulary.userMessage
                    || $0.type == SessionEventVocabulary.assistantMessage else {
                    return false
                }
                return Self.messageID(in: $0) == message.id
            }) else {
                throw ModelVisibleEventAuditFailure(
                    kind: .missingMessageSource,
                    messageIndex: index
                )
            }
            messageSources.append(event.seq)
            if message.source != nil || message.isHiddenContextMessage {
                contextSources.append(event.seq)
                contextSources.append(contentsOf: event.sourceEventSeqs ?? [])
            }
        }

        return ModelVisibleEventAuditReport(
            messageSourceEventSeqs: messageSources,
            requestHeaderEventSeq: headerEvent.seq,
            contextSourceEventSeqs: Array(Set(contextSources)).sorted()
        )
    }

    private static func messageID(in event: SessionEvent) -> UUID? {
        let value: JSONValue?
        switch event.type {
        case SessionEventVocabulary.userMessage:
            value = event.data.objectValue?["id"]
        case SessionEventVocabulary.assistantMessage,
             SessionEventVocabulary.toolResult:
            value = event.data.objectValue?["message"]?.objectValue?["id"]
        default:
            value = nil
        }
        guard let raw = value?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }
}

struct SessionTokenUsage: Codable, Sendable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let cacheWriteTokens: Int?
    let reasoningTokens: Int?

    init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    fileprivate var isValid: Bool {
        [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens]
            .compactMap { $0 }
            .allSatisfy { $0 >= 0 }
    }
}

enum CacheHitRateFormat {
    static let unavailable = "—"

    static func percent(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate >= 0 else { return unavailable }
        return String(format: "%.1f%%", rate * 100)
    }

    static func percent(
        inputTokens: Int,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?
    ) -> String {
        guard cacheReadTokens != nil || cacheWriteTokens != nil else {
            return unavailable
        }
        let read = Double(max(0, cacheReadTokens ?? 0))
        let billed = Double(max(0, inputTokens))
            + read
            + Double(max(0, cacheWriteTokens ?? 0))
        guard billed > 0 else { return unavailable }
        return percent(read / billed)
    }
}

struct SessionAssistantChunkData: Sendable, Equatable {
    let turn: Int
    let step: Int
    let chunk: JSONValue

    var isTokenDelta: Bool {
        guard let object = chunk.objectValue,
              let type = object["type"]?.stringValue else { return false }
        switch type {
        case "text-delta", "reasoning-delta":
            return object["text"]?.stringValue?.isEmpty == false
        case "tool-call-delta":
            return object["argumentsDelta"]?.stringValue?.isEmpty == false
                || object["name"]?.stringValue != nil
        default:
            return false
        }
    }

    var usage: SessionTokenUsage? {
        guard chunk.objectValue?["type"]?.stringValue == "usage",
              let value = chunk.objectValue?["usage"] else { return nil }
        return SessionTokenUsage(jsonValue: value)
    }
}

struct SessionAssistantMessageData: Sendable, Equatable {
    let turn: Int
    let step: Int
    let message: JSONValue
    let usage: SessionTokenUsage?
    let interrupted: Bool
    let incompleteReason: AgentMessageIncompleteReason?
}

struct SessionToolCallData: Sendable, Equatable {
    let turn: Int
    let step: Int
    let callID: String
    let name: String
    let arguments: String
}

struct SessionToolResultData: Sendable, Equatable {
    let turn: Int
    let step: Int
    let message: JSONValue
    let error: JSONValue?
    let meta: JSONValue?

    var callID: String? {
        message.objectValue?["source"]?.objectValue?["callId"]?.stringValue
            ?? message.objectValue?["source"]?.objectValue?["callID"]?.stringValue
            ?? message.objectValue?["callId"]?.stringValue
            ?? message.objectValue?["callID"]?.stringValue
    }
}

struct SessionCommandRunData: Sendable, Equatable {
    let commandID: String
    let name: String
    let args: String?
    let source: JSONValue
}

struct SessionCommandDoneData: Sendable, Equatable {
    let commandID: String
    let kind: String
    let text: String?
    let sourceEventSequence: Int?
}

struct SessionQuestionItemData: Sendable, Equatable {
    let id: String
    let question: String
    let header: String?
    let multiSelect: Bool
    let optionCount: Int
    let intent: String?
}

struct SessionQuestionRequestedData: Sendable, Equatable {
    let requestID: String
    let questionCount: Int
    let questions: [SessionQuestionItemData]
}

struct SessionQuestionResolvedData: Sendable, Equatable {
    let requestID: String
    let outcome: String
    let answerCount: Int?
    let skippedIDs: [String]
}

extension SessionEventDraft {
    static func compactionStart(
        compactionID: String,
        turn: Int,
        step: Int,
        trigger: String,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: "compaction/start",
            time: time,
            data: .object([
                "compactionId": .string(compactionID),
                "turn": .number(Double(turn)),
                "step": .number(Double(step)),
                "trigger": .string(trigger)
            ])
        )
    }

    static func compactionSummary(
        compactionID: String,
        turn: Int,
        step: Int,
        omittedMessageCount: Int,
        beforeBytes: Int,
        afterBytes: Int,
        summary: String?,
        shadowedRange: ClosedRange<UInt64>? = nil,
        shadowedTokens: Int? = nil,
        beforeTokens: Int? = nil,
        afterTokens: Int? = nil,
        provider: String? = nil,
        model: String? = nil,
        maxTokens: Int? = nil,
        usage: SessionTokenUsage? = nil,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "compactionId": .string(compactionID),
            "turn": .number(Double(turn)),
            "step": .number(Double(step)),
            "omittedMessageCount": .number(Double(omittedMessageCount)),
            "beforeBytes": .number(Double(beforeBytes)),
            "afterBytes": .number(Double(afterBytes))
        ]
        if let summary, !summary.isEmpty { data["summary"] = .string(summary) }
        if let shadowedRange {
            data["shadowedRange"] = .object([
                "start": .number(Double(shadowedRange.lowerBound)),
                "end": .number(Double(shadowedRange.upperBound))
            ])
        }
        if let shadowedTokens { data["shadowedTokens"] = .number(Double(shadowedTokens)) }
        if let beforeTokens { data["beforeTokens"] = .number(Double(beforeTokens)) }
        if let afterTokens { data["afterTokens"] = .number(Double(afterTokens)) }
        if let provider { data["provider"] = .string(provider) }
        if let model { data["model"] = .string(model) }
        if let maxTokens { data["maxTokens"] = .number(Double(maxTokens)) }
        if let usage { data["usage"] = usage.jsonValue }
        return Self(type: "compaction/summary", time: time, data: .object(data))
    }

    static func compactionEnd(
        compactionID: String,
        turn: Int,
        step: Int,
        error: String? = nil,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "compactionId": .string(compactionID),
            "turn": .number(Double(turn)),
            "step": .number(Double(step))
        ]
        if let error, !error.isEmpty { data["error"] = .string(error) }
        return Self(type: "compaction/end", time: time, data: .object(data))
    }

    static func llmRetry(
        retryID: String,
        turn: Int,
        step: Int,
        provider: String,
        mode: String = "normal",
        policyKey: String,
        retry: Int,
        maxRetries: Int = 2,
        delayMilliseconds: Double,
        failure: JSONValue,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "retryId": .string(retryID),
            "turn": .number(Double(turn)),
            "step": .number(Double(step)),
            "provider": .string(provider),
            "mode": .string(mode),
            "policyKey": .string(policyKey),
            "retry": .number(Double(retry)),
            "delayMs": .number(Double(delayMilliseconds)),
            "failure": failure
        ]
        if mode == "normal" {
            data["maxRetries"] = .number(Double(maxRetries))
        }
        return Self(type: "llm/retry", time: time, data: .object(data))
    }

    static func llmRetryStarted(
        retryID: String,
        turn: Int,
        step: Int,
        retry: Int,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: "llm/retry-started",
            time: time,
            data: .object([
                "retryId": .string(retryID),
                "turn": .number(Double(turn)),
                "step": .number(Double(step)),
                "retry": .number(Double(retry))
            ])
        )
    }

    static func turnStart(
        turn: Int,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(type: SessionEventVocabulary.turnStart, time: time, data: .object(["turn": .number(Double(turn))]))
    }

    static func turnEnd(
        turn: Int,
        reason: JSONValue,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: SessionEventVocabulary.turnEnd,
            time: time,
            data: .object(["turn": .number(Double(turn)), "reason": reason])
        )
    }

    static func stepStart(
        turn: Int,
        step: Int,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        stepBoundary(type: SessionEventVocabulary.stepStart, turn: turn, step: step, time: time)
    }

    static func stepEnd(
        turn: Int,
        step: Int,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        stepBoundary(type: SessionEventVocabulary.stepEnd, turn: turn, step: step, time: time)
    }

    static func userMessage(
        _ message: JSONValue,
        sourceEventSeqs: [UInt64]? = nil,
        surfaceOp: SessionSurfaceOperation = .append,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: SessionEventVocabulary.userMessage,
            time: time,
            data: message,
            sourceEventSeqs: sourceEventSeqs,
            surfaceOp: surfaceOp
        )
    }

    static func assistantChunk(
        turn: Int,
        step: Int,
        chunk: JSONValue,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: SessionEventVocabulary.assistantChunk,
            time: time,
            data: .object([
                "turn": .number(Double(turn)),
                "step": .number(Double(step)),
                "chunk": chunk
            ])
        )
    }

    static func assistantTextDelta(
        turn: Int,
        step: Int,
        text: String,
        index: Int = 0,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        assistantChunk(
            turn: turn,
            step: step,
            chunk: .object([
                "type": .string("text-delta"),
                "index": .number(Double(index)),
                "text": .string(text)
            ]),
            time: time
        )
    }

    static func assistantReasoningDelta(
        turn: Int,
        step: Int,
        text: String,
        index: Int = 0,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        assistantChunk(
            turn: turn,
            step: step,
            chunk: .object([
                "type": .string("reasoning-delta"),
                "index": .number(Double(index)),
                "text": .string(text)
            ]),
            time: time
        )
    }

    static func assistantToolCallDelta(
        turn: Int,
        step: Int,
        argumentsDelta: String,
        name: String? = nil,
        index: Int = 0,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var chunk: [String: JSONValue] = [
            "type": .string("tool-call-delta"),
            "index": .number(Double(index)),
            "argumentsDelta": .string(argumentsDelta)
        ]
        if let name { chunk["name"] = .string(name) }
        return assistantChunk(turn: turn, step: step, chunk: .object(chunk), time: time)
    }

    static func assistantUsage(
        turn: Int,
        step: Int,
        usage: SessionTokenUsage,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        assistantChunk(
            turn: turn,
            step: step,
            chunk: .object(["type": .string("usage"), "usage": usage.jsonValue]),
            time: time
        )
    }

    static func assistantMessage(
        turn: Int,
        step: Int,
        message: JSONValue,
        usage: SessionTokenUsage? = nil,
        interrupted: Bool = false,
        incompleteReason: AgentMessageIncompleteReason? = nil,
        sourceEventSeqs: [UInt64]? = nil,
        surfaceOp: SessionSurfaceOperation = .append,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "turn": .number(Double(turn)),
            "step": .number(Double(step)),
            "message": message
        ]
        if let usage { data["usage"] = usage.jsonValue }
        if interrupted { data["interrupted"] = .bool(true) }
        if let incompleteReason {
            data["incompleteReason"] = .string(incompleteReason.rawValue)
        }
        return Self(
            type: SessionEventVocabulary.assistantMessage,
            time: time,
            data: .object(data),
            sourceEventSeqs: sourceEventSeqs,
            surfaceOp: surfaceOp
        )
    }

    static func toolCall(
        turn: Int,
        step: Int,
        callID: String,
        name: String,
        arguments: String,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: SessionEventVocabulary.toolCall,
            time: time,
            data: .object([
                "turn": .number(Double(turn)),
                "step": .number(Double(step)),
                "callId": .string(callID),
                "name": .string(name),
                "arguments": .string(arguments)
            ])
        )
    }

    static func toolResult(
        turn: Int,
        step: Int,
        message: JSONValue,
        error: JSONValue? = nil,
        meta: JSONValue? = nil,
        sourceEventSeqs: [UInt64]? = nil,
        surfaceOp: SessionSurfaceOperation = .append,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "turn": .number(Double(turn)),
            "step": .number(Double(step)),
            "message": message
        ]
        if let error { data["error"] = error }
        if let meta { data["meta"] = meta }
        return Self(
            type: SessionEventVocabulary.toolResult,
            time: time,
            data: .object(data),
            sourceEventSeqs: sourceEventSeqs,
            surfaceOp: surfaceOp
        )
    }

    /// Durable approval request lifecycle record. The payload mirrors the
    /// upstream `@deepseek-ai/dsh-user-approval` event contract and contains
    /// only the tool identity and user-facing reason, never raw credentials.
    static func approvalAsked(
        requestID: String,
        toolName: String,
        callID: String? = nil,
        reason: String? = nil,
        risk: ToolRisk? = nil,
        modelDestination: String? = nil,
        resources: [String] = [],
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "id": .string(requestID),
            "toolName": .string(toolName)
        ]
        if let callID, !callID.isEmpty {
            data["callId"] = .string(callID)
        }
        if let reason, !reason.isEmpty {
            data["reason"] = .string(reason)
        }
        if let risk {
            data["risk"] = .string(risk.rawValue)
        }
        if let modelDestination, !modelDestination.isEmpty {
            data["modelDestination"] = .string(modelDestination)
        }
        if !resources.isEmpty {
            data["resources"] = .array(resources.map(JSONValue.string))
        }
        return Self(
            type: SessionEventVocabulary.approvalAsked,
            time: time,
            data: .object(data)
        )
    }

    /// Durable approval decision record paired with ``approvalAsked``.
    /// Outcomes use the upstream closed vocabulary.
    static func approvalDecided(
        requestID: String,
        outcome: String,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: SessionEventVocabulary.approvalDecided,
            time: time,
            data: .object([
                "id": .string(requestID),
                "outcome": .string(outcome)
            ])
        )
    }

    /// Log-only lifecycle record for a resolved human command. This is kept
    /// outside the model surface and preserves the parser-owned raw argument
    /// whitespace when `recordInput` is enabled.
    static func commandRun(
        commandID: String,
        name: String,
        args: String? = nil,
        imageAttachments: [AgentImageAttachmentRef] = [],
        fileAttachments: [AgentFileAttachmentRef] = [],
        sourceKind: String = "user",
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "commandId": .string(commandID),
            "name": .string(name),
            "source": .object(["kind": .string(sourceKind)])
        ]
        if let args { data["args"] = .string(args) }
        if !imageAttachments.isEmpty {
            data["imageAttachments"] = .array(imageAttachments.map { attachment in
                .object([
                    "id": .string(attachment.id.uuidString.lowercased()),
                    "path": .string(attachment.path),
                    "mimeType": .string(attachment.mimeType),
                    "byteCount": .number(Double(attachment.byteCount))
                ])
            })
        }
        if !fileAttachments.isEmpty {
            data["fileAttachments"] = .array(fileAttachments.map { attachment in
                .object([
                    "id": .string(attachment.id.uuidString.lowercased()),
                    "path": .string(attachment.path),
                    "mimeType": .string(attachment.mimeType),
                    "byteCount": .number(Double(attachment.byteCount)),
                    "displayName": .string(attachment.displayName),
                    "expiresAt": .string(ISO8601DateFormatter().string(from: attachment.expiresAt))
                ])
            })
        }
        return Self(
            type: SessionEventVocabulary.commandRun,
            time: time,
            data: .object(data)
        )
    }

    /// Log-only settlement record paired with ``commandRun`` by command id.
    static func commandDone(
        commandID: String,
        kind: String,
        text: String? = nil,
        sourceEventSequence: Int? = nil,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "commandId": .string(commandID),
            "kind": .string(kind)
        ]
        if let text { data["text"] = .string(text) }
        if let sourceEventSequence {
            data["sourceEventSeq"] = .number(Double(sourceEventSequence))
        }
        return Self(
            type: SessionEventVocabulary.commandDone,
            time: time,
            data: .object(data)
        )
    }

    static func requestHeader(
        header: JSONValue,
        reason: SessionRequestHeaderReason,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: SessionEventVocabulary.requestHeader,
            time: time,
            data: .object(["header": header, "reason": .string(reason.rawValue)])
        )
    }

    static func requestContext(
        provider: String,
        model: String,
        contextWindow: Int? = nil,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "provider": .string(provider),
            "model": .string(model)
        ]
        if let contextWindow { data["contextWindow"] = .number(Double(contextWindow)) }
        return Self(type: SessionEventVocabulary.requestContext, time: time, data: .object(data))
    }

    static func modelRequestAudit(
        turn: Int,
        step: Int,
        report: ModelVisibleEventAuditReport,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(
            type: "llm/request-audit",
            time: time,
            data: .object([
                "turn": .number(Double(turn)),
                "step": .number(Double(step)),
                "headerEventSeq": .number(Double(report.requestHeaderEventSeq)),
                "messageEventSeqs": .array(report.messageSourceEventSeqs.map {
                    .number(Double($0))
                }),
                "contextEventSeqs": .array(report.contextSourceEventSeqs.map {
                    .number(Double($0))
                })
            ]),
            ignorable: true,
            sourceEventSeqs: report.sourceEventSeqs
        )
    }

    static func questionRequested(
        requestID: UUID,
        questions: [AskUserQuestionItem],
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        let items = questions.map { question in
            JSONValue.object([
                "id": .string(question.id),
                "question": .string(question.question),
                "header": question.header.map(JSONValue.string) ?? .null,
                "multiSelect": .bool(question.multiSelect),
                "optionCount": .number(Double(question.options?.count ?? 0)),
                "intent": question.intent.map { .string($0.kind.rawValue) } ?? .null
            ])
        }
        return Self(
            type: SessionEventVocabulary.questionRequested,
            time: time,
            data: .object([
                "requestId": .string(requestID.uuidString),
                "questionCount": .number(Double(questions.count)),
                "questions": .array(items)
            ]),
            ignorable: true
        )
    }

    static func questionResolved(
        requestID: UUID,
        outcome: String,
        answer: AskUserQuestionAnswer? = nil,
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "requestId": .string(requestID.uuidString),
            "outcome": .string(outcome)
        ]
        if let answer {
            data["answerCount"] = .number(Double(answer.answers.count))
            data["skippedIds"] = .array(
                answer.answers.filter(\.isSkipped).map { .string($0.id) }
            )
        }
        return Self(
            type: SessionEventVocabulary.questionResolved,
            time: time,
            data: .object(data),
            ignorable: true
        )
    }

    static func sessionEndSeed(
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        Self(type: SessionEventVocabulary.sessionEndSeed, time: time, data: .object([:]))
    }

    private static func stepBoundary(type: String, turn: Int, step: Int, time: Int64) -> Self {
        Self(
            type: type,
            time: time,
            data: .object(["turn": .number(Double(turn)), "step": .number(Double(step))])
        )
    }
}

extension SessionEvent {
    var turnStartData: SessionTurnStartData? {
        guard type == SessionEventVocabulary.turnStart,
              let turn = data.jsonInteger(named: "turn") else { return nil }
        return SessionTurnStartData(turn: turn)
    }

    var turnEndData: SessionTurnEndData? {
        guard type == SessionEventVocabulary.turnEnd,
              let turn = data.jsonInteger(named: "turn"),
              let reason = data.objectValue?["reason"] else { return nil }
        return SessionTurnEndData(turn: turn, reason: reason)
    }

    var stepData: SessionStepData? {
        guard type == SessionEventVocabulary.stepStart || type == SessionEventVocabulary.stepEnd,
              let turn = data.jsonInteger(named: "turn"),
              let step = data.jsonInteger(named: "step") else { return nil }
        return SessionStepData(turn: turn, step: step)
    }

    var userMessageData: JSONValue? {
        type == SessionEventVocabulary.userMessage ? data : nil
    }

    var assistantChunkData: SessionAssistantChunkData? {
        guard type == SessionEventVocabulary.assistantChunk,
              let turn = data.jsonInteger(named: "turn"),
              let step = data.jsonInteger(named: "step"),
              let chunk = data.objectValue?["chunk"] else { return nil }
        return SessionAssistantChunkData(turn: turn, step: step, chunk: chunk)
    }

    var assistantMessageData: SessionAssistantMessageData? {
        guard type == SessionEventVocabulary.assistantMessage,
              let turn = data.jsonInteger(named: "turn"),
              let step = data.jsonInteger(named: "step"),
              let message = data.objectValue?["message"] else { return nil }
        let usage = data.objectValue?["usage"].flatMap(SessionTokenUsage.init(jsonValue:))
        let interrupted = data.objectValue?["interrupted"] == .bool(true)
        let incompleteReason: AgentMessageIncompleteReason?
        if let rawIncompleteReason = data.objectValue?["incompleteReason"]?.stringValue {
            incompleteReason = AgentMessageIncompleteReason(rawValue: rawIncompleteReason)
        } else {
            incompleteReason = nil
        }
        return SessionAssistantMessageData(
            turn: turn,
            step: step,
            message: message,
            usage: usage,
            interrupted: interrupted,
            incompleteReason: incompleteReason
        )
    }

    var toolCallData: SessionToolCallData? {
        guard type == SessionEventVocabulary.toolCall,
              let turn = data.jsonInteger(named: "turn"),
              let step = data.jsonInteger(named: "step"),
              let object = data.objectValue,
              let callID = object["callId"]?.stringValue ?? object["callID"]?.stringValue,
              let name = object["name"]?.stringValue,
              let arguments = object["arguments"]?.stringValue else { return nil }
        return SessionToolCallData(
            turn: turn,
            step: step,
            callID: callID,
            name: name,
            arguments: arguments
        )
    }

    var toolResultData: SessionToolResultData? {
        guard type == SessionEventVocabulary.toolResult,
              let turn = data.jsonInteger(named: "turn"),
              let step = data.jsonInteger(named: "step"),
              let object = data.objectValue,
              let message = object["message"] else { return nil }
        return SessionToolResultData(
            turn: turn,
            step: step,
            message: message,
            error: object["error"],
            meta: object["meta"]
        )
    }

    var commandRunData: SessionCommandRunData? {
        guard type == SessionEventVocabulary.commandRun,
              let object = data.objectValue,
              let commandID = object["commandId"]?.stringValue,
              let name = object["name"]?.stringValue,
              let source = object["source"] else { return nil }
        return SessionCommandRunData(
            commandID: commandID,
            name: name,
            args: object["args"]?.stringValue,
            source: source
        )
    }

    var commandDoneData: SessionCommandDoneData? {
        guard type == SessionEventVocabulary.commandDone,
              let object = data.objectValue,
              let commandID = object["commandId"]?.stringValue,
              let kind = object["kind"]?.stringValue else { return nil }
        return SessionCommandDoneData(
            commandID: commandID,
            kind: kind,
            text: object["text"]?.stringValue,
            sourceEventSequence: object.jsonInteger(named: "sourceEventSeq")
        )
    }

    var requestHeaderData: SessionRequestHeaderData? {
        guard type == SessionEventVocabulary.requestHeader,
              let object = data.objectValue,
              let header = object["header"],
              let reasonValue = object["reason"]?.stringValue,
              let reason = SessionRequestHeaderReason(rawValue: reasonValue) else { return nil }
        return SessionRequestHeaderData(header: header, reason: reason)
    }

    var requestContextData: SessionRequestContextData? {
        guard type == SessionEventVocabulary.requestContext,
              let object = data.objectValue,
              let provider = object["provider"]?.stringValue,
              let model = object["model"]?.stringValue else { return nil }
        return SessionRequestContextData(
            provider: provider,
            model: model,
            contextWindow: object.jsonInteger(named: "contextWindow")
        )
    }

    var questionRequestedData: SessionQuestionRequestedData? {
        guard type == SessionEventVocabulary.questionRequested,
              let object = data.objectValue,
              let requestID = object["requestId"]?.stringValue,
              let questionCount = object.jsonInteger(named: "questionCount"),
              case let .array(values)? = object["questions"] else { return nil }
        let questions = values.compactMap { value -> SessionQuestionItemData? in
            guard let item = value.objectValue,
                  let id = item["id"]?.stringValue,
                  let question = item["question"]?.stringValue,
                  case let .bool(multiSelect)? = item["multiSelect"],
                  let optionCount = item.jsonInteger(named: "optionCount") else { return nil }
            return SessionQuestionItemData(
                id: id,
                question: question,
                header: item["header"]?.stringValue,
                multiSelect: multiSelect,
                optionCount: optionCount,
                intent: item["intent"]?.stringValue
            )
        }
        guard questions.count == values.count else { return nil }
        return SessionQuestionRequestedData(
            requestID: requestID,
            questionCount: questionCount,
            questions: questions
        )
    }

    var questionResolvedData: SessionQuestionResolvedData? {
        guard type == SessionEventVocabulary.questionResolved,
              let object = data.objectValue,
              let requestID = object["requestId"]?.stringValue,
              let outcome = object["outcome"]?.stringValue else { return nil }
        let skippedIDs: [String]
        if case let .array(values)? = object["skippedIds"] {
            skippedIDs = values.compactMap(\.stringValue)
            guard skippedIDs.count == values.count else { return nil }
        } else {
            skippedIDs = []
        }
        return SessionQuestionResolvedData(
            requestID: requestID,
            outcome: outcome,
            answerCount: object.jsonInteger(named: "answerCount"),
            skippedIDs: skippedIDs
        )
    }
}

struct SessionTrajectoryCursor: Codable, Sendable, Equatable, Hashable {
    let streamID: String
    let nextSequence: UInt64
}

/// Cumulative metrics folded using the same event boundaries as upstream DSH.
struct SessionTrajectoryMetrics: Codable, Sendable, Equatable {
    let durationMilliseconds: Double
    let turns: Int
    let steps: Int
    let calls: Int
    let modelDurationMilliseconds: Double
    let toolDurationMilliseconds: Double
    let totalTTFTMilliseconds: Double
    let ttftSamples: Int
    let averageTTFTMilliseconds: Double?
    let decodeDurationMilliseconds: Double
    let decodeTokens: Int
    let uncachedInputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let cacheHitRate: Double?
}

/// A cursor-based DTO. `events` contains only the raw append-only delta after
/// the supplied cursor; cumulative metrics are already folded. A token update
/// therefore does not require rebuilding or formatting the previous transcript.
struct SessionTrajectorySnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let streamID: String
    let fromSequence: UInt64
    let cursor: SessionTrajectoryCursor
    let events: [SessionEvent]
    let metrics: SessionTrajectoryMetrics
    let recoveredTornTail: Bool
}

enum SessionEventDurability: Sendable, Equatable {
    /// Write through the file handle and let the OS coalesce storage flushes.
    case buffered
    /// Call `fsync`-equivalent synchronization after each append operation.
    case synchronized
}

enum SessionEventLogError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedEventType(type: String, sequence: UInt64)
    case invalidSequence(expected: UInt64, actual: UInt64)
    case invalidCursorStream(expected: String, actual: String)
    case cursorBeyondEnd(cursor: UInt64, end: UInt64)
    case invalidEnvelope(String)
    case corruptLine(line: Int, description: String)
    case fileHandleUnavailable
    case closed

    var errorDescription: String? {
        switch self {
        case let .unsupportedEventType(type, sequence):
            return "Event type \(type) at seq \(sequence) is unknown and not marked ignorable"
        case let .invalidSequence(expected, actual):
            return "Non-contiguous event sequence: expected \(expected), found \(actual)"
        case let .invalidCursorStream(expected, actual):
            return "Trajectory cursor belongs to \(actual), expected \(expected)"
        case let .cursorBeyondEnd(cursor, end):
            return "Trajectory cursor \(cursor) is beyond log end \(end)"
        case let .invalidEnvelope(message):
            return "Invalid session event envelope: \(message)"
        case let .corruptLine(line, description):
            return "Corrupt session JSONL line \(line): \(description)"
        case .fileHandleUnavailable:
            return "Session event file handle is unavailable"
        case .closed:
            return "Session event store is closed"
        }
    }
}

/// Device-local, append-only JSONL persistence. Actor isolation serializes file
/// writes, sequence assignment, recovery, and the incremental metrics fold.
actor SessionEventJSONLStore {
    private struct PendingBatch {
        let events: [SessionEvent]
        let data: Data
    }

    private let fileURL: URL
    private let streamID: String
    private let durability: SessionEventDurability
    private let maximumRetainedEvents: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var knownEventTypes: Set<String>
    private var events: [SessionEvent] = []
    private var metrics = SessionTrajectoryAccumulator()
    private var nextSequence: UInt64 = 0
    private var durableNextSequence: UInt64 = 0
    private var pendingBatches: [PendingBatch] = []
    private var fileHandle: FileHandle?
    private var isLoaded = false
    private var isClosed = false
    private var recoveredTornTail = false

    init(
        fileURL: URL,
        streamID: String? = nil,
        knownEventTypes: Set<String> = SessionEventVocabulary.upstreamKnown,
        durability: SessionEventDurability = .buffered,
        maximumRetainedEvents: Int = 4_096
    ) {
        self.fileURL = fileURL
        self.streamID = streamID ?? fileURL.deletingPathExtension().lastPathComponent
        self.knownEventTypes = knownEventTypes
        self.durability = durability
        self.maximumRetainedEvents = max(1, maximumRetainedEvents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    /// Adds plugin-owned event names. Knowledge is monotonic for the lifetime
    /// of an opened log so unloading a plugin cannot make its history unreadable.
    func registerKnownEventTypes(_ types: Set<String>) throws {
        guard !isClosed else { throw SessionEventLogError.closed }
        knownEventTypes.formUnion(types)
    }

    @discardableResult
    func recover() throws -> SessionTrajectorySnapshot {
        try ensureLoaded()
        return try makeSnapshot(after: nil)
    }

    @discardableResult
    func append(_ draft: SessionEventDraft) throws -> SessionEvent {
        try append([draft])[0]
    }

    @discardableResult
    func append(_ drafts: [SessionEventDraft]) throws -> [SessionEvent] {
        try ensureLoaded()
        guard !drafts.isEmpty else { return [] }

        var sequence = nextSequence
        let assigned = try drafts.map { draft -> SessionEvent in
            defer { sequence &+= 1 }
            return try SessionEvent(
                type: draft.type,
                seq: sequence,
                time: draft.time,
                data: draft.data,
                ignorable: draft.ignorable,
                sourceEventSeqs: draft.sourceEventSeqs,
                surfaceOp: draft.surfaceOp
            )
        }
        return try appendAssigned(assigned)
    }

    /// Imports an already-sequenced DSH event without rewriting its identity.
    @discardableResult
    func append(_ event: SessionEvent) throws -> SessionEvent {
        try append([event])[0]
    }

    @discardableResult
    func append(_ assignedEvents: [SessionEvent]) throws -> [SessionEvent] {
        try ensureLoaded()
        guard !assignedEvents.isEmpty else { return [] }
        return try appendAssigned(assignedEvents)
    }

    func snapshot(after cursor: SessionTrajectoryCursor? = nil) throws -> SessionTrajectorySnapshot {
        try ensureLoaded()
        return try makeSnapshot(after: cursor)
    }

    func allEvents() async throws -> [SessionEvent] {
        try ensureLoaded()
        try flush()
        // The live actor deliberately retains only a tail. Read the lossless
        // JSONL stream when an export or forensic caller explicitly asks for it.
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let recovery = try decodeLog(data)
        return recovery.events
    }

    /// Decodes the complete persisted stream while retaining only matching
    /// events. Sequence and event-vocabulary validation still covers every
    /// JSONL record, which keeps this suitable for compact downstream views.
    func persistedEvents(
        matching shouldRetain: @Sendable (SessionEvent) -> Bool
    ) async throws -> [SessionEvent] {
        try ensureLoaded()
        try flush()
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return try decodeLog(data, retaining: shouldRetain).events
    }

    /// Reads one bounded page immediately before `sequence`. The full stream is
    /// still validated, while only matching rows are retained for the caller.
    /// This keeps long trajectory history out of observable UI state.
    func persistedEventPage(
        before sequence: UInt64,
        limit: Int,
        matching shouldRetain: @Sendable (SessionEvent) -> Bool
    ) async throws -> [SessionEvent] {
        try ensureLoaded()
        try flush()
        guard limit > 0 else { return [] }
        let boundary = min(sequence, nextSequence)
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let matches = try decodeLog(data, retaining: { event in
            event.seq < boundary && shouldRetain(event)
        }).events
        return Array(matches.suffix(limit))
    }

    func currentMetrics() throws -> SessionTrajectoryMetrics {
        try ensureLoaded()
        return metrics.snapshot
    }

    func persistenceRevision() throws -> SessionPersistenceRevision {
        try ensureLoaded()
        return SessionPersistenceRevision(
            streamID: streamID,
            nextSequence: durableNextSequence,
            recoveredTornTail: recoveredTornTail
        )
    }

    func flush() throws {
        try ensureLoaded()
        guard !pendingBatches.isEmpty else {
            guard let fileHandle else {
                throw SessionEventLogError.fileHandleUnavailable
            }
            try fileHandle.synchronize()
            return
        }
        guard let fileHandle else {
            throw SessionEventLogError.fileHandleUnavailable
        }
        let barrierOffset = try fileHandle.offset()
        let barrierRevision = durableNextSequence
        do {
            for batch in pendingBatches {
                try fileHandle.write(contentsOf: batch.data)
                durableNextSequence = batch.events.last.map { $0.seq &+ 1 }
                    ?? durableNextSequence
            }
            try fileHandle.synchronize()
            pendingBatches.removeAll(keepingCapacity: true)
        } catch {
            // A write or synchronize failure leaves the barrier uncommitted.
            // Roll back the complete barrier so retrying the same pending
            // batches cannot duplicate a partially written suffix.
            durableNextSequence = barrierRevision
            try? fileHandle.truncate(atOffset: barrierOffset)
            _ = try? fileHandle.seekToEnd()
            throw error
        }
    }

    func close() throws {
        guard !isClosed else { return }
        if !isLoaded {
            isClosed = true
            return
        }
        try flush()
        try fileHandle?.close()
        fileHandle = nil
        isClosed = true
    }

    private func appendAssigned(_ assignedEvents: [SessionEvent]) throws -> [SessionEvent] {
        var expected = nextSequence
        for event in assignedEvents {
            guard event.seq == expected else {
                throw SessionEventLogError.invalidSequence(expected: expected, actual: event.seq)
            }
            try assertSupported(event)
            expected &+= 1
        }

        let data = try encodedLines(assignedEvents)
        pendingBatches.append(PendingBatch(events: assignedEvents, data: data))
        events.append(contentsOf: assignedEvents)
        if events.count > maximumRetainedEvents {
            events.removeFirst(events.count - maximumRetainedEvents)
        }
        nextSequence = expected
        for event in assignedEvents { metrics.apply(event) }
        if durability == .synchronized { try flush() }
        return assignedEvents
    }

    private func ensureLoaded() throws {
        guard !isClosed else { throw SessionEventLogError.closed }
        guard !isLoaded else { return }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let handle = try FileHandle(forUpdating: fileURL)
        do {
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            let recovery = try decodeLog(data)

            if recovery.truncateTo < UInt64(data.count) {
                try handle.truncate(atOffset: recovery.truncateTo)
                recoveredTornTail = true
            }
            if recovery.needsTrailingNewline {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.seekToEnd()

            metrics = SessionTrajectoryAccumulator()
            for event in recovery.events { metrics.apply(event) }
            events = Array(recovery.events.suffix(maximumRetainedEvents))
            nextSequence = UInt64(recovery.events.count)
            durableNextSequence = UInt64(recovery.events.count)
            fileHandle = handle
            isLoaded = true

            // Cold recovery must leave the logical session balanced. The
            // repair is append-only and therefore idempotent: once the
            // synthetic closers are present, a subsequent open sees a closed
            // turn and produces no additional events.
            let closers = try SessionEventRecovery.interruptedTurnClosers(recovery.events)
            if !closers.isEmpty {
                _ = try appendAssigned(closers)
                try flush()
            }
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func decodeLog(
        _ data: Data,
        retaining shouldRetain: (SessionEvent) -> Bool = { _ in true }
    ) throws -> SessionLogRecovery {
        guard !data.isEmpty else {
            return SessionLogRecovery(events: [], truncateTo: 0, needsTrailingNewline: false)
        }

        var decoded: [SessionEvent] = []
        var lineStart = data.startIndex
        var lineNumber = 1
        var expectedSequence: UInt64 = 0

        func decodeLine(_ range: Range<Data.Index>, isTrailingFragment: Bool) throws -> Bool {
            guard !range.isEmpty else {
                if isTrailingFragment { return true }
                throw SessionEventLogError.corruptLine(line: lineNumber, description: "Empty JSONL record")
            }
            do {
                let event = try decoder.decode(SessionEvent.self, from: data.subdata(in: range))
                guard event.seq == expectedSequence else {
                    throw SessionEventLogError.invalidSequence(expected: expectedSequence, actual: event.seq)
                }
                try assertSupported(event)
                if shouldRetain(event) {
                    decoded.append(event)
                }
                expectedSequence &+= 1
                return true
            } catch let error as SessionEventLogError {
                throw error
            } catch {
                if isTrailingFragment { return false }
                throw SessionEventLogError.corruptLine(line: lineNumber, description: String(describing: error))
            }
        }

        for index in data.indices where data[index] == 0x0A {
            _ = try decodeLine(lineStart..<index, isTrailingFragment: false)
            lineStart = index + 1
            lineNumber += 1
        }

        if lineStart == data.endIndex {
            return SessionLogRecovery(
                events: decoded,
                truncateTo: UInt64(data.count),
                needsTrailingNewline: false
            )
        }

        let trailingWasValid = try decodeLine(lineStart..<data.endIndex, isTrailingFragment: true)
        if trailingWasValid {
            return SessionLogRecovery(
                events: decoded,
                truncateTo: UInt64(data.count),
                needsTrailingNewline: true
            )
        }
        return SessionLogRecovery(
            events: decoded,
            truncateTo: UInt64(lineStart),
            needsTrailingNewline: false
        )
    }

    private func assertSupported(_ event: SessionEvent) throws {
        guard knownEventTypes.contains(event.type) || event.isIgnorable else {
            throw SessionEventLogError.unsupportedEventType(type: event.type, sequence: event.seq)
        }
    }

    private func makeSnapshot(after cursor: SessionTrajectoryCursor?) throws -> SessionTrajectorySnapshot {
        if let cursor, cursor.streamID != streamID {
            throw SessionEventLogError.invalidCursorStream(expected: streamID, actual: cursor.streamID)
        }
        let fromSequence = cursor?.nextSequence ?? 0
        guard fromSequence <= nextSequence else {
            throw SessionEventLogError.cursorBeyondEnd(cursor: fromSequence, end: nextSequence)
        }
        let oldestRetainedSequence = events.first?.seq ?? nextSequence
        let effectiveStartSequence = max(fromSequence, oldestRetainedSequence)
        let startIndex = effectiveStartSequence >= oldestRetainedSequence
            ? Int(effectiveStartSequence - oldestRetainedSequence)
            : 0
        return SessionTrajectorySnapshot(
            schemaVersion: SessionTrajectorySnapshot.currentSchemaVersion,
            streamID: streamID,
            fromSequence: fromSequence,
            cursor: SessionTrajectoryCursor(streamID: streamID, nextSequence: nextSequence),
            events: startIndex < events.count ? Array(events[startIndex...]) : [],
            metrics: metrics.snapshot,
            recoveredTornTail: recoveredTornTail
        )
    }

    private func encodedLines(_ events: [SessionEvent]) throws -> Data {
        var output = Data()
        for event in events {
            output.append(try encoder.encode(event))
            output.append(0x0A)
        }
        return output
    }
}

private struct SessionLogRecovery {
    let events: [SessionEvent]
    let truncateTo: UInt64
    let needsTrailingNewline: Bool
}

private struct SessionTrajectoryAccumulator {
    private struct OpenStep {
        let coordinates: SessionStepData
        let startTime: Int64
        var firstTokenTime: Int64?
    }

    private struct UsageSample {
        let coordinates: SessionStepData
        let usage: SessionTokenUsage
    }

    private var firstTime: Int64?
    private var lastTime: Int64?
    private var turns = 0
    private var steps = 0
    private var calls = 0
    private var modelMilliseconds = 0.0
    private var toolMilliseconds = 0.0
    private var ttftMilliseconds = 0.0
    private var ttftSamples = 0
    private var decodeMilliseconds = 0.0
    private var decodeTokens = 0
    private var lastClosedTurn: Int?
    private var openStep: OpenStep?
    private var pendingCalls: [String: Int64] = [:]
    private var usageTotals = SessionUsageTotals()
    private var lastUsage: UsageSample?

    mutating func apply(_ event: SessionEvent) {
        firstTime = firstTime ?? event.time
        lastTime = max(lastTime ?? event.time, event.time)

        switch event.type {
        case SessionEventVocabulary.stepStart:
            guard let coordinates = event.stepData else { return }
            openStep = OpenStep(coordinates: coordinates, startTime: event.time)

        case SessionEventVocabulary.assistantChunk:
            guard let chunk = event.assistantChunkData else { return }
            let coordinates = SessionStepData(turn: chunk.turn, step: chunk.step)
            if chunk.isTokenDelta,
               openStep?.coordinates == coordinates,
               openStep?.firstTokenTime == nil {
                openStep?.firstTokenTime = event.time
            }
            if let usage = chunk.usage { applyUsage(usage, coordinates: coordinates) }

        case SessionEventVocabulary.assistantMessage:
            guard let message = event.assistantMessageData else { return }
            let coordinates = SessionStepData(turn: message.turn, step: message.step)
            if let usage = message.usage { applyUsage(usage, coordinates: coordinates) }
            guard let open = openStep, open.coordinates == coordinates else { return }
            modelMilliseconds += elapsed(from: open.startTime, to: event.time)
            if let firstTokenTime = open.firstTokenTime {
                ttftMilliseconds += elapsed(from: open.startTime, to: firstTokenTime)
                ttftSamples = saturatingAdd(ttftSamples, 1)
                if let usage = message.usage, usage.outputTokens >= 0 {
                    decodeMilliseconds += elapsed(from: firstTokenTime, to: event.time)
                    decodeTokens = saturatingAdd(decodeTokens, usage.outputTokens)
                }
            }
            openStep = nil

        case SessionEventVocabulary.toolCall:
            guard let call = event.toolCallData else { return }
            pendingCalls[call.callID] = event.time
            calls = saturatingAdd(calls, 1)

        case "tool/code-dispatch-start":
            guard let subCallID = event.data.objectValue?["subCallId"]?.stringValue else { return }
            pendingCalls[subCallID] = event.time
            calls = saturatingAdd(calls, 1)

        case SessionEventVocabulary.toolResult:
            guard let callID = event.toolResultData?.callID,
                  let start = pendingCalls.removeValue(forKey: callID) else { return }
            toolMilliseconds += elapsed(from: start, to: event.time)

        case "tool/code-dispatch":
            guard let subCallID = event.data.objectValue?["subCallId"]?.stringValue,
                  let start = pendingCalls.removeValue(forKey: subCallID) else { return }
            toolMilliseconds += elapsed(from: start, to: event.time)

        case SessionEventVocabulary.stepEnd:
            guard let coordinates = event.stepData else { return }
            if lastClosedTurn != coordinates.turn {
                turns = saturatingAdd(turns, 1)
                lastClosedTurn = coordinates.turn
            }
            steps = saturatingAdd(steps, 1)
            openStep = nil

        case SessionEventVocabulary.turnEnd:
            pendingCalls.removeAll(keepingCapacity: true)

        default:
            break
        }
    }

    var snapshot: SessionTrajectoryMetrics {
        let duration: Double
        if let firstTime, let lastTime {
            duration = elapsed(from: firstTime, to: lastTime)
        } else {
            duration = 0
        }
        let averageTTFT = ttftSamples == 0 ? nil : ttftMilliseconds / Double(ttftSamples)
        let billedInput = usageTotals.billedInputTokens
        let cacheHitRate = !usageTotals.hasCacheData || billedInput == 0
            ? nil
            : Double(usageTotals.cacheReadTokens) / Double(billedInput)
        return SessionTrajectoryMetrics(
            durationMilliseconds: duration,
            turns: turns,
            steps: steps,
            calls: calls,
            modelDurationMilliseconds: modelMilliseconds,
            toolDurationMilliseconds: toolMilliseconds,
            totalTTFTMilliseconds: ttftMilliseconds,
            ttftSamples: ttftSamples,
            averageTTFTMilliseconds: averageTTFT,
            decodeDurationMilliseconds: decodeMilliseconds,
            decodeTokens: decodeTokens,
            uncachedInputTokens: usageTotals.uncachedInputTokens,
            outputTokens: usageTotals.outputTokens,
            cacheReadTokens: usageTotals.cacheReadTokens,
            cacheWriteTokens: usageTotals.cacheWriteTokens,
            cacheHitRate: cacheHitRate
        )
    }

    private mutating func applyUsage(_ usage: SessionTokenUsage, coordinates: SessionStepData) {
        guard usage.isValid else { return }
        let previous = lastUsage?.coordinates == coordinates ? lastUsage?.usage : nil
        guard previous != usage else { return }
        usageTotals.replace(previous: previous, with: usage)
        lastUsage = UsageSample(coordinates: coordinates, usage: usage)
    }
}

private struct SessionUsageTotals {
    var uncachedInputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var cacheDataSamples = 0

    var hasCacheData: Bool {
        cacheDataSamples > 0
    }

    var billedInputTokens: Int {
        saturatingAdd(saturatingAdd(uncachedInputTokens, cacheReadTokens), cacheWriteTokens)
    }

    mutating func replace(previous: SessionTokenUsage?, with next: SessionTokenUsage) {
        uncachedInputTokens = replacing(uncachedInputTokens, previous?.inputTokens, next.inputTokens)
        outputTokens = replacing(outputTokens, previous?.outputTokens, next.outputTokens)
        cacheReadTokens = replacing(cacheReadTokens, previous?.cacheReadTokens ?? 0, next.cacheReadTokens ?? 0)
        cacheWriteTokens = replacing(cacheWriteTokens, previous?.cacheWriteTokens ?? 0, next.cacheWriteTokens ?? 0)

        let previousHasCacheData = previous?.cacheReadTokens != nil || previous?.cacheWriteTokens != nil
        let nextHasCacheData = next.cacheReadTokens != nil || next.cacheWriteTokens != nil
        if previousHasCacheData && !nextHasCacheData {
            cacheDataSamples = max(0, cacheDataSamples - 1)
        } else if !previousHasCacheData && nextHasCacheData {
            cacheDataSamples = saturatingAdd(cacheDataSamples, 1)
        }
    }

    private func replacing(_ total: Int, _ previous: Int?, _ next: Int) -> Int {
        let removed = max(0, total - (previous ?? 0))
        return saturatingAdd(removed, next)
    }
}

private extension SessionTokenUsage {
    init?(jsonValue: JSONValue) {
        guard let object = jsonValue.objectValue,
              let inputTokens = object.jsonInteger(named: "inputTokens"),
              let outputTokens = object.jsonInteger(named: "outputTokens") else { return nil }
        self.init(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: object.jsonInteger(named: "cacheReadTokens"),
            cacheWriteTokens: object.jsonInteger(named: "cacheWriteTokens"),
            reasoningTokens: object.jsonInteger(named: "reasoningTokens")
        )
        guard isValid else { return nil }
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "inputTokens": .number(Double(inputTokens)),
            "outputTokens": .number(Double(outputTokens))
        ]
        if let cacheReadTokens { object["cacheReadTokens"] = .number(Double(cacheReadTokens)) }
        if let cacheWriteTokens { object["cacheWriteTokens"] = .number(Double(cacheWriteTokens)) }
        if let reasoningTokens { object["reasoningTokens"] = .number(Double(reasoningTokens)) }
        return .object(object)
    }
}

private extension JSONValue {
    func jsonInteger(named key: String) -> Int? {
        objectValue?.jsonInteger(named: key)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func jsonInteger(named key: String) -> Int? {
        guard case let .number(number)? = self[key],
              number.isFinite,
              number.rounded() == number,
              number >= 0,
              number <= Double(Int.max) else { return nil }
        return Int(number)
    }
}

private func elapsed(from start: Int64, to end: Int64) -> Double {
    guard end > start else { return 0 }
    return Double(end - start)
}

private func saturatingAdd(_ left: Int, _ right: Int) -> Int {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int.max : sum
}
