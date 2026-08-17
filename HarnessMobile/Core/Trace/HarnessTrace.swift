import Foundation

enum HarnessTraceEventKind: String, Codable, Sendable, Equatable {
    case runStarted
    case runFinished
    case turnStarted
    case turnFinished
    case stepStarted
    case stepFinished
    case modelRequest
    case modelFirstToken
    case modelCompleted
    case toolStarted
    case toolFinished
    case checkpointStarted
    case checkpointFinished
    case checkpointFailed
    case pluginStateChanged
    case pluginCleanupFailed
    case backgroundTask
    case settingsRead
    case settingsWrite
    case settingsConflict
    case error
}

/// Trace copy of a conversation message. This type deliberately contains no API key,
/// credential reference, request headers, or Keychain material.
struct HarnessTraceMessage: Codable, Sendable, Equatable {
    let role: AgentRole
    let content: String
    let reasoning: String?
    let toolCalls: [AgentToolCall]
    let toolCallID: String?
    let toolName: String?
    let isToolError: Bool?

    init(_ message: AgentMessage) {
        role = message.role
        content = HarnessTraceRedactor.string(message.content)
        reasoning = message.reasoning.map { HarnessTraceRedactor.string($0) }
        toolCalls = message.toolCalls.prefix(32).map { call in
            AgentToolCall(
                id: call.id,
                name: call.name,
                arguments: HarnessTraceRedactor.string(call.arguments, maximumUTF8Bytes: 8 * 1_024)
            )
        }
        toolCallID = message.toolCallID
        toolName = message.toolName
        isToolError = message.isToolError
    }
}

/// Sanitized model request payload for the trajectory inspector. Constructing this
/// from `ModelRequest` is safe because the initializer intentionally omits `apiKey`.
struct HarnessTraceModelRequest: Codable, Sendable, Equatable {
    let providerID: String
    let baseURL: String
    let model: String
    let reasoningMode: String
    let maximumOutputTokens: Int
    let systemPrompt: String
    let messages: [HarnessTraceMessage]
    let toolNames: [String]

    init(_ request: ModelRequest) {
        providerID = request.configuration.providerID.rawValue
        baseURL = HarnessTraceRedactor.string(request.configuration.baseURL, maximumUTF8Bytes: 2_048)
        model = HarnessTraceRedactor.string(request.configuration.model, maximumUTF8Bytes: 512)
        reasoningMode = request.configuration.reasoningMode.rawValue
        maximumOutputTokens = request.configuration.maxOutputTokens
        systemPrompt = HarnessTraceRedactor.string(request.systemPrompt, maximumUTF8Bytes: 32 * 1_024)
        messages = request.messages.suffix(128).map(HarnessTraceMessage.init)
        toolNames = request.tools.prefix(128).map(\.name)
    }
}

struct HarnessTraceTokenUsage: Codable, Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedPromptTokens: Int?
    let reasoningTokens: Int?

    init(_ usage: ModelTokenUsage) {
        promptTokens = usage.promptTokens
        completionTokens = usage.completionTokens
        totalTokens = usage.totalTokens
        cachedPromptTokens = usage.cachedPromptTokens
        reasoningTokens = usage.reasoningTokens
    }
}

struct HarnessTraceModelResponse: Codable, Sendable, Equatable {
    let text: String
    let reasoning: String?
    let toolCalls: [AgentToolCall]
    let finishReason: String
    let usage: HarnessTraceTokenUsage?

    init(
        text: String,
        reasoning: String?,
        toolCalls: [AgentToolCall],
        finishReason: String,
        usage: HarnessTraceTokenUsage?
    ) {
        self.text = HarnessTraceRedactor.string(text, maximumUTF8Bytes: 32 * 1_024)
        self.reasoning = reasoning.map {
            HarnessTraceRedactor.string($0, maximumUTF8Bytes: 32 * 1_024)
        }
        self.toolCalls = toolCalls.prefix(32).map { call in
            AgentToolCall(
                id: call.id,
                name: call.name,
                arguments: HarnessTraceRedactor.string(call.arguments, maximumUTF8Bytes: 8 * 1_024)
            )
        }
        self.finishReason = finishReason
        self.usage = usage
    }
}

struct HarnessTraceTool: Codable, Sendable, Equatable {
    let callID: String
    let name: String
    let arguments: String
    let output: String?
    let isError: Bool?

    init(
        callID: String,
        name: String,
        arguments: String,
        output: String?,
        isError: Bool?
    ) {
        self.callID = callID
        self.name = name
        self.arguments = HarnessTraceRedactor.string(arguments, maximumUTF8Bytes: 16 * 1_024)
        self.output = output.map {
            HarnessTraceRedactor.string($0, maximumUTF8Bytes: 32 * 1_024)
        }
        self.isError = isError
    }
}

enum HarnessTracePayload: Codable, Sendable, Equatable {
    case modelRequest(HarnessTraceModelRequest)
    case modelResponse(HarnessTraceModelResponse)
    case tool(HarnessTraceTool)
    case messages([HarnessTraceMessage])
    case json(JSONValue)
}

/// Unsequenced event accepted by trace sinks. Producers may supply deterministic
/// timestamps in tests; the store assigns stable sequence and event ids.
struct HarnessTraceDraft: Sendable, Equatable {
    var kind: HarnessTraceEventKind
    var timestamp: Date
    var runID: UUID?
    var turn: Int?
    var step: Int?
    var callID: String?
    var pluginID: String?
    var name: String?
    var durationMilliseconds: Double?
    var attributes: [String: JSONValue]
    var payload: HarnessTracePayload?
    var error: String?

    init(
        kind: HarnessTraceEventKind,
        timestamp: Date = .now,
        runID: UUID? = nil,
        turn: Int? = nil,
        step: Int? = nil,
        callID: String? = nil,
        pluginID: String? = nil,
        name: String? = nil,
        durationMilliseconds: Double? = nil,
        attributes: [String: JSONValue] = [:],
        payload: HarnessTracePayload? = nil,
        error: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.runID = runID
        self.turn = turn
        self.step = step
        self.callID = callID
        self.pluginID = pluginID
        self.name = name
        self.durationMilliseconds = durationMilliseconds
        self.attributes = attributes
        self.payload = payload
        self.error = error
    }
}

struct HarnessTraceEvent: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sequence: UInt64
    let kind: HarnessTraceEventKind
    let timestamp: Date
    let runID: UUID?
    let turn: Int?
    let step: Int?
    let callID: String?
    let pluginID: String?
    let name: String?
    let durationMilliseconds: Double?
    let attributes: [String: JSONValue]
    let payload: HarnessTracePayload?
    let error: String?
}

struct HarnessTraceSummary: Sendable, Equatable {
    let durationMilliseconds: Double
    let turns: Int
    let steps: Int
    let calls: Int
    let modelDurationMilliseconds: Double
    let toolDurationMilliseconds: Double
    let averageFirstTokenMilliseconds: Double?
    let cacheHitRate: Double?
}

/// Bounded, process-local trajectory ledger. It is intentionally independent of
/// remote telemetry; callers decide whether and where a redacted export is written.
actor HarnessTraceStore {
    private let capacity: Int
    private var nextSequence: UInt64 = 0
    private var storage: [HarnessTraceEvent] = []

    init(capacity: Int = 10_000) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(capacity, 10_000))
    }

    @discardableResult
    func record(_ draft: HarnessTraceDraft) -> HarnessTraceEvent {
        nextSequence &+= 1
        let event = HarnessTraceEvent(
            id: UUID(),
            sequence: nextSequence,
            kind: draft.kind,
            timestamp: draft.timestamp,
            runID: draft.runID,
            turn: draft.turn,
            step: draft.step,
            callID: draft.callID,
            pluginID: draft.pluginID,
            name: draft.name,
            durationMilliseconds: draft.durationMilliseconds,
            attributes: draft.attributes,
            payload: draft.payload,
            error: draft.error
        )
        storage.append(event)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        return event
    }

    func events(runID: UUID? = nil) -> [HarnessTraceEvent] {
        guard let runID else { return storage }
        return storage.filter { $0.runID == runID }
    }

    /// Returns only events appended after a previously observed sequence.
    /// Sequence values are monotonic even when the bounded store evicts older
    /// rows, so callers can advance a cursor without copying the full trace
    /// on every streamed model or tool update.
    func events(after sequence: UInt64) -> [HarnessTraceEvent] {
        storage.filter { $0.sequence > sequence }
    }

    func clear() {
        storage.removeAll(keepingCapacity: true)
    }

    func summary(runID: UUID) -> HarnessTraceSummary {
        Self.summarize(storage.filter { $0.runID == runID })
    }

    static func summarize(_ events: [HarnessTraceEvent]) -> HarnessTraceSummary {
        let ordered = events.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.sequence < rhs.sequence
            }
            return lhs.timestamp < rhs.timestamp
        }
        guard let first = ordered.first, let last = ordered.last else {
            return HarnessTraceSummary(
                durationMilliseconds: 0,
                turns: 0,
                steps: 0,
                calls: 0,
                modelDurationMilliseconds: 0,
                toolDurationMilliseconds: 0,
                averageFirstTokenMilliseconds: nil,
                cacheHitRate: nil
            )
        }

        var openModel: [TraceStepKey: Date] = [:]
        var openTools: [String: Date] = [:]
        var firstTokenDurations: [Double] = []
        var modelDuration = 0.0
        var toolDuration = 0.0
        var promptTokens = 0
        var cachedTokens = 0
        var turns = Set<Int>()
        var steps = Set<TraceStepKey>()
        var calls = 0

        for event in ordered {
            if let turn = event.turn, event.kind == .turnStarted || event.kind == .turnFinished {
                turns.insert(turn)
            }
            if let key = TraceStepKey(event), event.kind == .stepStarted || event.kind == .stepFinished {
                steps.insert(key)
            }

            switch event.kind {
            case .modelRequest:
                if let key = TraceStepKey(event) {
                    openModel[key] = event.timestamp
                }
            case .modelFirstToken:
                if let key = TraceStepKey(event), let start = openModel[key] {
                    firstTokenDurations.append(max(0, event.timestamp.timeIntervalSince(start) * 1_000))
                }
            case .modelCompleted:
                if let key = TraceStepKey(event), let start = openModel.removeValue(forKey: key) {
                    modelDuration += max(0, event.timestamp.timeIntervalSince(start) * 1_000)
                }
                if case let .modelResponse(response) = event.payload,
                   let usage = response.usage,
                   usage.promptTokens > 0 {
                    promptTokens += usage.promptTokens
                    cachedTokens += min(usage.promptTokens, max(0, usage.cachedPromptTokens ?? 0))
                }
            case .toolStarted:
                guard let callID = event.callID else { break }
                calls += 1
                openTools[callID] = event.timestamp
            case .toolFinished:
                guard let callID = event.callID,
                      let start = openTools.removeValue(forKey: callID) else { break }
                toolDuration += max(0, event.timestamp.timeIntervalSince(start) * 1_000)
            default:
                break
            }
        }

        let duration = max(0, last.timestamp.timeIntervalSince(first.timestamp) * 1_000)
        let averageTTFT = firstTokenDurations.isEmpty
            ? nil
            : firstTokenDurations.reduce(0, +) / Double(firstTokenDurations.count)
        let cacheHitRate = promptTokens == 0 ? nil : Double(cachedTokens) / Double(promptTokens)
        return HarnessTraceSummary(
            durationMilliseconds: duration,
            turns: turns.count,
            steps: steps.count,
            calls: calls,
            modelDurationMilliseconds: modelDuration,
            toolDurationMilliseconds: toolDuration,
            averageFirstTokenMilliseconds: averageTTFT,
            cacheHitRate: cacheHitRate
        )
    }
}

struct HarnessDiagnosticReportInput: Sendable {
    let metadata: [String: String]
    let pluginHostStderr: String
    let pluginSnapshots: [CordisPluginSnapshot]
    let pluginHostInventory: [ISHPluginHostInventoryEntry]
    let pluginPackageVersions: [String: String]
    let toolContributionNames: [String]
    let nativeClientFailures: [String]
    let traceEvents: [HarnessTraceEvent]
    let sessionEvents: [SessionEvent]
}

enum HarnessDiagnosticReportBuilder {
    private static let maximumTraceRows = 1_200
    private static let maximumTraceUTF8Bytes = 1_500 * 1_024
    private static let maximumSessionRows = 4_000
    private static let maximumSessionUTF8Bytes = 2_500 * 1_024

    static func build(_ input: HarnessDiagnosticReportInput) throws -> Data {
        var report = "Harness Mobile Diagnostic Log\n"
        report += "Format: harness-mobile-diagnostics-v2\n"
        report += "Credentials: redacted; model API keys are never recorded\n\n"

        appendSection("RUNTIME", to: &report) { section in
            for key in input.metadata.keys.sorted() {
                let value = HarnessTraceRedactor.string(
                    input.metadata[key] ?? "",
                    maximumUTF8Bytes: 64 * 1_024
                )
                section += "\(key): \(value)\n"
            }
        }

        appendSection("PLUGIN HOST STDERR", to: &report) { section in
            let stderr = HarnessTraceRedactor.string(
                input.pluginHostStderr,
                maximumUTF8Bytes: 128 * 1_024
            )
            section += stderr.isEmpty ? "(empty)\n" : stderr + "\n"
        }

        try appendSection("CORDIS PLUGINS", to: &report) { section in
            section += try redactedJSON(input.pluginSnapshots, pretty: true) + "\n"
        }

        try appendSection("PLUGIN HOST INVENTORY", to: &report) { section in
            section += try redactedJSON(input.pluginHostInventory, pretty: true) + "\n"
        }

        try appendSection("PLUGIN PACKAGES", to: &report) { section in
            section += try redactedJSON(input.pluginPackageVersions, pretty: true) + "\n"
        }

        appendSection("ACTIVE TOOL CONTRIBUTIONS", to: &report) { section in
            section += input.toolContributionNames.isEmpty
                ? "(none)\n"
                : input.toolContributionNames.sorted().joined(separator: "\n") + "\n"
        }

        appendSection("NATIVE CLIENT FAILURES", to: &report) { section in
            section += input.nativeClientFailures.isEmpty
                ? "(none)\n"
                : input.nativeClientFailures.joined(separator: "\n") + "\n"
        }

        try appendSection("HARNESS TRACE JSONL", to: &report) { section in
            section += try boundedJSONLines(
                input.traceEvents,
                maximumRows: maximumTraceRows,
                maximumUTF8Bytes: maximumTraceUTF8Bytes,
                filteredCount: 0,
                transform: { $0 }
            )
        }

        try appendSection("SESSION EVENT JSONL", to: &report) { section in
            let retained = input.sessionEvents.filter { event in
                event.type != SessionEventVocabulary.assistantChunk
                    || event.assistantChunkData?.usage != nil
            }
            section += try boundedJSONLines(
                retained,
                maximumRows: maximumSessionRows,
                maximumUTF8Bytes: maximumSessionUTF8Bytes,
                filteredCount: input.sessionEvents.count - retained.count,
                transform: DiagnosticSessionEvent.init
            )
        }

        return Data(report.utf8)
    }

    private static func appendSection(
        _ title: String,
        to report: inout String,
        body: (inout String) throws -> Void
    ) rethrows {
        report += "===== \(title) =====\n"
        try body(&report)
        report += "\n"
    }

    private static func redactedJSON<T: Encodable>(
        _ value: T,
        pretty: Bool
    ) throws -> String {
        let sourceData = try JSONEncoder().encode(value)
        let sourceJSON = try JSONDecoder().decode(JSONValue.self, from: sourceData)
        let redacted = HarnessTraceRedactor.json(sourceJSON, maximumDepth: 20)
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(redacted), as: UTF8.self)
    }

    /// Diagnostic exports favor recent finalized events. Per-token streaming
    /// deltas are reconstructable from assistant/message and otherwise make a
    /// single report grow by tens of megabytes on long conversations.
    private static func boundedJSONLines<Input, Output: Encodable>(
        _ values: [Input],
        maximumRows: Int,
        maximumUTF8Bytes: Int,
        filteredCount: Int,
        transform: (Input) -> Output
    ) throws -> String {
        guard !values.isEmpty else {
            if filteredCount == 0 { return "(none)\n" }
            return omissionSummary(
                exportedCount: 0,
                boundedOmissionCount: 0,
                filteredCount: filteredCount
            ) + "\n"
        }

        var selected: [String] = []
        selected.reserveCapacity(min(values.count, maximumRows))
        var usedBytes = 0
        var boundedOmissionCount = 0

        for value in values.reversed() {
            let line = try redactedJSON(transform(value), pretty: false) + "\n"
            let lineBytes = line.utf8.count
            guard selected.count < maximumRows,
                  usedBytes + lineBytes <= maximumUTF8Bytes else {
                boundedOmissionCount += 1
                continue
            }
            selected.append(line)
            usedBytes += lineBytes
        }

        selected.reverse()
        let summary = omissionSummary(
            exportedCount: selected.count,
            boundedOmissionCount: boundedOmissionCount,
            filteredCount: filteredCount
        )
        return summary + "\n" + selected.joined()
    }

    private static func omissionSummary(
        exportedCount: Int,
        boundedOmissionCount: Int,
        filteredCount: Int
    ) -> String {
        let summary: JSONValue = .object([
            "diagnosticExport": .object([
                "policy": .string("newest-relevant-events"),
                "exportedCount": .number(Double(exportedCount)),
                "boundedOmissionCount": .number(Double(boundedOmissionCount)),
                "streamingDeltaOmissionCount": .number(Double(filteredCount))
            ])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(
            decoding: (try? encoder.encode(summary)) ?? Data("{}".utf8),
            as: UTF8.self
        )
    }
}

private struct DiagnosticSessionEvent: Encodable {
    let type: String
    let seq: UInt64
    let time: Int64
    let data: JSONValue
    let ignorable: Bool?
    let sourceEventSeqs: [UInt64]?
    let surfaceOp: SessionSurfaceOperation?

    init(_ event: SessionEvent) {
        type = event.type
        seq = event.seq
        time = event.time
        data = HarnessTraceRedactor.json(event.data, maximumDepth: 20)
        ignorable = event.ignorable
        sourceEventSeqs = event.sourceEventSeqs
        surfaceOp = event.surfaceOp
    }
}

private struct TraceStepKey: Hashable {
    let turn: Int
    let step: Int

    init?(_ event: HarnessTraceEvent) {
        guard let turn = event.turn, let step = event.step else { return nil }
        self.turn = turn
        self.step = step
    }
}
