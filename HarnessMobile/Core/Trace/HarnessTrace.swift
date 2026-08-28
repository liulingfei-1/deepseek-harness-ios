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
    let profileID: String?
    let routeGeneration: UInt64?
    let finalRoute: String?
    let systemPrompt: String
    let messages: [HarnessTraceMessage]
    let toolNames: [String]

    init(_ request: ModelRequest) {
        providerID = request.configuration.providerID.rawValue
        baseURL = HarnessTraceRedactor.string(request.configuration.baseURL, maximumUTF8Bytes: 2_048)
        model = HarnessTraceRedactor.string(request.configuration.model, maximumUTF8Bytes: 512)
        reasoningMode = request.configuration.reasoningMode.rawValue
        maximumOutputTokens = request.configuration.maxOutputTokens
        profileID = request.route?.profileID
        routeGeneration = request.route?.generation
        finalRoute = request.route.map { route in
            HarnessTraceRedactor.string(route.endpoint.absoluteString, maximumUTF8Bytes: 2_048)
        }
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
    let uncachedPromptTokens: Int?
    let reasoningTokens: Int?

    init(_ usage: ModelTokenUsage) {
        promptTokens = usage.promptTokens
        completionTokens = usage.completionTokens
        totalTokens = usage.totalTokens
        cachedPromptTokens = usage.cachedPromptTokens
        uncachedPromptTokens = usage.uncachedPromptTokens
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
    /// Owning conversation identity. A run id alone is not sufficient because
    /// an activation may be reused or reported while another session is active.
    var sessionID: UUID?
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
        sessionID: UUID? = nil,
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
        self.sessionID = sessionID
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
    let sessionID: UUID?
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

    init(
        id: UUID,
        sequence: UInt64,
        kind: HarnessTraceEventKind,
        timestamp: Date,
        sessionID: UUID? = nil,
        runID: UUID?,
        turn: Int?,
        step: Int?,
        callID: String?,
        pluginID: String?,
        name: String?,
        durationMilliseconds: Double?,
        attributes: [String: JSONValue],
        payload: HarnessTracePayload?,
        error: String?
    ) {
        self.id = id
        self.sequence = sequence
        self.kind = kind
        self.timestamp = timestamp
        self.sessionID = sessionID
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
    /// Run ownership is registered before an Agent starts emitting events.
    /// This lets plugin/Cordis traces, which carry a run id but are produced
    /// outside the AppModel closure, inherit the exact conversation session.
    private var runSessions: [UUID: UUID] = [:]

    init(capacity: Int = 10_000) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(min(capacity, 10_000))
    }

    func register(runID: UUID, sessionID: UUID) {
        runSessions[runID] = sessionID
    }

    @discardableResult
    func record(_ draft: HarnessTraceDraft) -> HarnessTraceEvent {
        nextSequence &+= 1
        let event = HarnessTraceEvent(
            id: UUID(),
            sequence: nextSequence,
            kind: draft.kind,
            timestamp: draft.timestamp,
            sessionID: draft.sessionID ?? draft.runID.flatMap { runSessions[$0] },
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

    /// Strict identity projection used by diagnostics and session inspectors.
    /// Events without an owning session are intentionally excluded: including
    /// them would reintroduce global/plugin lifecycle rows into a child run.
    func events(sessionID: UUID, runID: UUID? = nil) -> [HarnessTraceEvent] {
        storage.filter { event in
            guard event.sessionID == sessionID else { return false }
            if let runID { return event.runID == runID }
            return true
        }
    }

    func events(after sequence: UInt64, sessionID: UUID, runID: UUID? = nil) -> [HarnessTraceEvent] {
        storage.filter { event in
            guard event.sequence > sequence, event.sessionID == sessionID else { return false }
            if let runID { return event.runID == runID }
            return true
        }
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
        var cachePromptTokens = 0
        var cachedTokens = 0
        var hasCacheData = false
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
                    if usage.cachedPromptTokens != nil || usage.uncachedPromptTokens != nil {
                        hasCacheData = true
                        cachePromptTokens += usage.promptTokens
                        let cached = usage.cachedPromptTokens ?? max(
                            0,
                            usage.promptTokens - (usage.uncachedPromptTokens ?? usage.promptTokens)
                        )
                        cachedTokens += min(usage.promptTokens, max(0, cached))
                    }
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
        let cacheHitRate = hasCacheData && cachePromptTokens > 0
            ? Double(cachedTokens) / Double(cachePromptTokens)
            : nil
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
    let runtimeTelemetryRecords: [RuntimeTelemetryRecord]
    let traceEvents: [HarnessTraceEvent]
    let sessionEvents: [SessionEvent]
}

enum HarnessDiagnosticReportBuilder {
    private static let maximumRuntimeTelemetryRows = 128
    private static let maximumRuntimeTelemetryUTF8Bytes = 64 * 1_024
    private static let maximumTraceRows = 800
    private static let maximumTraceUTF8Bytes = 384 * 1_024
    private static let maximumSessionRows = 1_600
    private static let maximumSessionUTF8Bytes = 512 * 1_024

    static func build(_ input: HarnessDiagnosticReportInput) throws -> Data {
        var report = "DeepSeek Harness Mobile Diagnostic Log\n"
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

        try appendSection("RUNTIME TELEMETRY JSONL", to: &report) { section in
            section += try boundedJSONLines(
                input.runtimeTelemetryRecords,
                maximumRows: maximumRuntimeTelemetryRows,
                maximumUTF8Bytes: maximumRuntimeTelemetryUTF8Bytes,
                filteredCount: 0,
                transform: { $0 }
            )
        }

        try appendSection("HARNESS TRACE JSONL", to: &report) { section in
            section += try boundedJSONLines(
                input.traceEvents,
                maximumRows: maximumTraceRows,
                maximumUTF8Bytes: maximumTraceUTF8Bytes,
                filteredCount: 0,
                transform: DiagnosticHarnessTraceEvent.init
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
        data = DiagnosticJSONProjection.compact(event.data)
        ignorable = event.ignorable
        sourceEventSeqs = event.sourceEventSeqs
        surfaceOp = event.surfaceOp
    }
}

/// Diagnostics need causal metadata and error detail, not repeated copies of
/// complete prompts, fetched web pages, or plugin source snapshots. The live
/// trajectory remains lossless; only the exported projection is compacted.
private struct DiagnosticHarnessTraceEvent: Encodable {
    let id: UUID
    let sequence: UInt64
    let kind: HarnessTraceEventKind
    let timestamp: Date
    let sessionID: UUID?
    let runID: UUID?
    let turn: Int?
    let step: Int?
    let callID: String?
    let pluginID: String?
    let name: String?
    let durationMilliseconds: Double?
    let attributes: JSONValue
    let payload: JSONValue?
    let error: String?

    init(_ event: HarnessTraceEvent) {
        id = event.id
        sequence = event.sequence
        kind = event.kind
        timestamp = event.timestamp
        sessionID = event.sessionID
        runID = event.runID
        turn = event.turn
        step = event.step
        callID = event.callID
        pluginID = event.pluginID
        name = event.name
        durationMilliseconds = event.durationMilliseconds
        attributes = DiagnosticJSONProjection.compact(.object(event.attributes))
        payload = event.payload.flatMap(DiagnosticJSONProjection.encodeAndCompact)
        error = event.error.map {
            HarnessTraceRedactor.string($0, maximumUTF8Bytes: 8 * 1_024)
        }
    }
}

private enum DiagnosticJSONProjection {
    static func encodeAndCompact<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return compact(json)
    }

    static func compact(
        _ value: JSONValue,
        depth: Int = 0,
        maximumDepth: Int = 12
    ) -> JSONValue {
        guard depth < maximumDepth else { return .string("<depth-limit>") }
        switch value {
        case let .string(text):
            return .string(HarnessTraceRedactor.string(text, maximumUTF8Bytes: 1_024))
        case let .array(values):
            var projected = values.prefix(12).map {
                compact($0, depth: depth + 1, maximumDepth: maximumDepth)
            }
            if values.count > projected.count {
                projected.append(.string("<\(values.count - projected.count) more items>"))
            }
            return .array(projected)
        case let .object(object):
            var projected: [String: JSONValue] = [:]
            for key in object.keys.sorted().prefix(32) {
                guard let child = object[key] else { continue }
                projected[key] = compact(
                    child,
                    depth: depth + 1,
                    maximumDepth: maximumDepth
                )
            }
            if object.count > projected.count {
                projected["<truncated>"] = .number(Double(object.count - projected.count))
            }
            return HarnessTraceRedactor.json(.object(projected), maximumDepth: maximumDepth)
        case .number, .bool, .null:
            return value
        }
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

enum AgentDiagnosticsScope: String, Sendable, CaseIterable {
    case summary
    case errors
    case pluginHost = "plugin_host"
    case compilation
    case trace
    case session
    case full
}

struct AgentDiagnosticsQuery: Sendable, Equatable {
    let scope: AgentDiagnosticsScope
    let limit: Int
}

typealias AgentDiagnosticsProvider = @Sendable (AgentDiagnosticsQuery) async throws -> JSONValue

struct AgentDiagnosticsTool: LocalAgentTool {
    let provider: AgentDiagnosticsProvider

    init(
        provider: @escaping AgentDiagnosticsProvider = { query in
            .object([
                "available": .bool(false),
                "scope": .string(query.scope.rawValue),
                "message": .string("The AppModel diagnostics provider is not mounted.")
            ])
        }
    ) {
        self.provider = provider
    }

    let definition = ModelToolDefinition(
        name: "diagnostics_read",
        description: "Read a bounded, credential-redacted diagnostic snapshot from this iPhone. Use it after an unexplained model, tool, plugin, native compilation, background, or Plugin Host failure before attempting a repair.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "scope": .object([
                    "type": .string("string"),
                    "enum": .array(AgentDiagnosticsScope.allCases.map {
                        .string($0.rawValue)
                    }),
                    "description": .string("Diagnostic area. Use errors first for an unexplained failure, then inspect the matching subsystem.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(32),
                    "description": .string("Maximum recent rows returned for trace and session sections. Defaults to 32.")
                ])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["scope", "limit"])
        if let rawScope = arguments["scope"]?.stringValue,
           AgentDiagnosticsScope(rawValue: rawScope) == nil {
            throw LocalToolError.invalidArguments
        }
        if let value = arguments["limit"] {
            guard case let .number(number) = value,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= 1,
                  number <= 32 else {
                throw LocalToolError.invalidArguments
            }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let scope = arguments["scope"]?.stringValue ?? AgentDiagnosticsScope.summary.rawValue
        return "读取本机脱敏诊断：\(scope)"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let scope = arguments["scope"]?.stringValue
            .flatMap(AgentDiagnosticsScope.init(rawValue:)) ?? .summary
        let limit: Int
        if case let .number(number)? = arguments["limit"] {
            limit = Int(number)
        } else {
            limit = 32
        }
        let snapshot = try await provider(
            AgentDiagnosticsQuery(scope: scope, limit: limit)
        )
        return HarnessTraceRedactor.json(snapshot, maximumDepth: 20).displayText
    }
}
