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
    static let sessionEndSeed = "session/end-seed"

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
        "permission/preset",
        "plan/mode",
        requestContext,
        requestHeader,
        "sandbox/mode",
        "schedule/change",
        sessionEndSeed,
        "session/title",
        "session/title-llm-request",
        stepEnd,
        stepStart,
        "subagent/descriptor",
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

extension SessionEventDraft {
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

    /// Log-only lifecycle record for a resolved human command. This is kept
    /// outside the model surface and preserves the parser-owned raw argument
    /// whitespace when `recordInput` is enabled.
    static func commandRun(
        commandID: String,
        name: String,
        args: String? = nil,
        sourceKind: String = "user",
        time: Int64 = SessionEventTimestamp.nowMilliseconds()
    ) -> Self {
        var data: [String: JSONValue] = [
            "commandId": .string(commandID),
            "name": .string(name),
            "source": .object(["kind": .string(sourceKind)])
        ]
        if let args { data["args"] = .string(args) }
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
        return SessionAssistantMessageData(turn: turn, step: step, message: message, usage: usage)
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
        case .closed:
            return "Session event store is closed"
        }
    }
}

/// Device-local, append-only JSONL persistence. Actor isolation serializes file
/// writes, sequence assignment, recovery, and the incremental metrics fold.
actor SessionEventJSONLStore {
    private let fileURL: URL
    private let streamID: String
    private let durability: SessionEventDurability
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var knownEventTypes: Set<String>
    private var events: [SessionEvent] = []
    private var metrics = SessionTrajectoryAccumulator()
    private var nextSequence: UInt64 = 0
    private var fileHandle: FileHandle?
    private var isLoaded = false
    private var isClosed = false
    private var recoveredTornTail = false

    init(
        fileURL: URL,
        streamID: String? = nil,
        knownEventTypes: Set<String> = SessionEventVocabulary.upstreamKnown,
        durability: SessionEventDurability = .buffered
    ) {
        self.fileURL = fileURL
        self.streamID = streamID ?? fileURL.deletingPathExtension().lastPathComponent
        self.knownEventTypes = knownEventTypes
        self.durability = durability
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

    func allEvents() throws -> [SessionEvent] {
        try ensureLoaded()
        return events
    }

    func currentMetrics() throws -> SessionTrajectoryMetrics {
        try ensureLoaded()
        return metrics.snapshot
    }

    func flush() throws {
        try ensureLoaded()
        try fileHandle?.synchronize()
    }

    func close() throws {
        guard !isClosed else { return }
        if !isLoaded {
            isClosed = true
            return
        }
        try fileHandle?.synchronize()
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
        try fileHandle?.write(contentsOf: data)
        events.append(contentsOf: assignedEvents)
        nextSequence = expected
        for event in assignedEvents { metrics.apply(event) }
        if durability == .synchronized { try fileHandle?.synchronize() }
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
            for event in recovery.events { try assertSupported(event) }

            if recovery.truncateTo < UInt64(data.count) {
                try handle.truncate(atOffset: recovery.truncateTo)
                recoveredTornTail = true
            }
            if recovery.needsTrailingNewline {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0x0A]))
            }
            try handle.seekToEnd()

            events = recovery.events
            nextSequence = UInt64(events.count)
            metrics = SessionTrajectoryAccumulator()
            for event in events { metrics.apply(event) }
            fileHandle = handle
            isLoaded = true
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func decodeLog(_ data: Data) throws -> SessionLogRecovery {
        guard !data.isEmpty else {
            return SessionLogRecovery(events: [], truncateTo: 0, needsTrailingNewline: false)
        }

        let bytes = [UInt8](data)
        var decoded: [SessionEvent] = []
        var lineStart = 0
        var lineNumber = 1
        var expectedSequence: UInt64 = 0

        func decodeLine(_ range: Range<Int>, isTrailingFragment: Bool) throws -> Bool {
            guard !range.isEmpty else {
                if isTrailingFragment { return true }
                throw SessionEventLogError.corruptLine(line: lineNumber, description: "Empty JSONL record")
            }
            do {
                let event = try decoder.decode(SessionEvent.self, from: Data(bytes[range]))
                guard event.seq == expectedSequence else {
                    throw SessionEventLogError.invalidSequence(expected: expectedSequence, actual: event.seq)
                }
                decoded.append(event)
                expectedSequence &+= 1
                return true
            } catch let error as SessionEventLogError {
                throw error
            } catch {
                if isTrailingFragment { return false }
                throw SessionEventLogError.corruptLine(line: lineNumber, description: String(describing: error))
            }
        }

        for index in bytes.indices where bytes[index] == 0x0A {
            _ = try decodeLine(lineStart..<index, isTrailingFragment: false)
            lineStart = index + 1
            lineNumber += 1
        }

        if lineStart == bytes.count {
            return SessionLogRecovery(
                events: decoded,
                truncateTo: UInt64(bytes.count),
                needsTrailingNewline: false
            )
        }

        let trailingWasValid = try decodeLine(lineStart..<bytes.count, isTrailingFragment: true)
        if trailingWasValid {
            return SessionLogRecovery(
                events: decoded,
                truncateTo: UInt64(bytes.count),
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
        let startIndex = Int(fromSequence)
        return SessionTrajectorySnapshot(
            schemaVersion: SessionTrajectorySnapshot.currentSchemaVersion,
            streamID: streamID,
            fromSequence: fromSequence,
            cursor: SessionTrajectoryCursor(streamID: streamID, nextSequence: nextSequence),
            events: Array(events[startIndex...]),
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

        case SessionEventVocabulary.toolResult:
            guard let callID = event.toolResultData?.callID,
                  let start = pendingCalls.removeValue(forKey: callID) else { return }
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
        let cacheHitRate = billedInput == 0
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

    var billedInputTokens: Int {
        saturatingAdd(saturatingAdd(uncachedInputTokens, cacheReadTokens), cacheWriteTokens)
    }

    mutating func replace(previous: SessionTokenUsage?, with next: SessionTokenUsage) {
        uncachedInputTokens = replacing(uncachedInputTokens, previous?.inputTokens, next.inputTokens)
        outputTokens = replacing(outputTokens, previous?.outputTokens, next.outputTokens)
        cacheReadTokens = replacing(cacheReadTokens, previous?.cacheReadTokens ?? 0, next.cacheReadTokens ?? 0)
        cacheWriteTokens = replacing(cacheWriteTokens, previous?.cacheWriteTokens ?? 0, next.cacheWriteTokens ?? 0)
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
