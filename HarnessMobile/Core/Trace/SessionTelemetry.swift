import Foundation

/// The minimum backend contract. `emit` must be a non-blocking enqueue —
/// the coordinator calls it from the append hot path. Errors thrown here are
/// contained by the coordinator and never reach the agent loop.
protocol SessionTelemetrySink: Sendable {
    func emit(_ record: SessionTelemetry.Record)
    func flush() async
    func shutdown() async
}

/// Mirrors upstream `dsh-session-telemetry`: the capture side of session
/// event reporting. The coordinator projects durable session events into
/// telemetry records, runs them through the deployment's redaction waterfall,
/// and hands them to a sink; batching, retry, and loss policy belong to the
/// sink's own pipeline.
///
/// Severity is pre-mapped at capture so a receiver can alert with zero
/// configuration: events whose own outcome flag says so (tool-result errors,
/// turn-end error reasons) and `agent-error` ops records are `error`;
/// everything else defaults to `info`.
enum SessionTelemetry {
    enum Channel: String, Codable, Sendable {
        case ledger
        case ops
    }

    enum Severity: String, Codable, Sendable, Comparable {
        case info
        case warn
        case error

        private var rank: Int {
            switch self {
            case .info: 0
            case .warn: 1
            case .error: 2
            }
        }

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// One logical record handed to a backend — the capture contract's whole
    /// outbound vocabulary. Ledger records mirror session-log events
    /// one-to-one; ops records carry signals with no log home and
    /// deliberately omit event-seq identity so they can never be mistaken
    /// for ledger rows.
    struct Record: Codable, Sendable, Equatable {
        let channel: Channel
        /// Unix epoch milliseconds.
        let time: Int64
        let severity: Severity
        /// Minimal identity attributes: `session.id`, `event.type`,
        /// `event.seq` for ledger records; `telemetry.op`, `session.id` for
        /// ops records. Recoverable body fields are intentionally not
        /// duplicated.
        let attributes: [String: String]
        /// The complete payload: a copy of the event's `data` for ledger
        /// records, or the op payload for ops records.
        let body: JSONValue
    }



    /// The redaction waterfall: each listener transforms the record before it
    /// reaches the sink. A throwing listener withholds that one record
    /// (fail-closed). Redaction applies to the exported copy only; the
    /// canonical session log is never rewritten.
    typealias Redactor = @Sendable (Record) throws -> Record

    // MARK: - Capture projection

    /// Projects one durable session event into a ledger record. Returns nil
    /// for events that carry no reportable payload.
    static func project(
        _ event: SessionEvent,
        sessionID: UUID
    ) -> Record? {
        let severity: Severity
        switch event.type {
        case SessionEventVocabulary.toolResult:
            // A present, non-null error payload marks a failed tool run
            // (same rule the trajectory UI uses).
            if let error = event.toolResultData?.error, error != .null {
                severity = .error
            } else {
                severity = .info
            }
        case SessionEventVocabulary.turnEnd:
            severity = turnEndIsError(event) ? .error : .info
        default:
            severity = .info
        }
        let body = event.data
        guard body != .null else { return nil }
        return Record(
            channel: .ledger,
            time: event.time,
            severity: severity,
            attributes: [
                "session.id": sessionID.uuidString,
                "event.type": event.type,
                "event.seq": String(event.seq)
            ],
            body: body
        )
    }

    private static func turnEndIsError(_ event: SessionEvent) -> Bool {
        guard let reason = event.data.objectValue?["reason"]?.objectValue else { return false }
        let kind = reason["kind"]?.stringValue ?? ""
        return kind == "error" || kind == "failed"
    }

    /// On-demand canonical capture: projects a whole event window and runs the
    /// redaction waterfall, dropping records a redactor rejects.
    static func capture(
        events: [SessionEvent],
        sessionID: UUID,
        redactors: [Redactor] = [],
        sink: SessionTelemetrySink
    ) {
        for event in events {
            guard var record = project(event, sessionID: sessionID) else { continue }
            var withheld = false
            for redactor in redactors {
                do {
                    record = try redactor(record)
                } catch {
                    withheld = true
                    break
                }
            }
            guard !withheld else { continue }
            sink.emit(record)
        }
    }
}

/// Mirrors upstream `dsh-session-telemetry-otel`: an OpenTelemetry backend
/// that delivers session records as OTel log records in OTLP/JSON format.
///
/// `mode` decides how records are shared: `full` forwards every record
/// immediately, `feedbackOnly` keeps records locally until explicitly
/// released, and `disabled` (the default) constructs nothing and shares
/// nothing. The exporter owns batching and delivery; it never rewrites the
/// canonical session log.
final class SessionTelemetryOtelSink: SessionTelemetrySink, @unchecked Sendable {
    enum Mode: String, Codable, Sendable {
        case full
        case feedbackOnly
        case disabled
    }

    struct Configuration: Sendable {
        var mode: Mode = .disabled
        /// OTLP/HTTP JSON endpoint. When set together with `delivery`, FULL
        /// mode posts released batches there; otherwise batches are written
        /// to `outputDirectory` as OTLP/JSON files.
        var endpoint: URL?
        /// The HTTP transport closure lives outside this file because raw
        /// network I/O is confined to the audited network boundary.
        var delivery: (@Sendable (_ endpoint: URL, _ payload: Data) async -> Void)?
        var outputDirectory: URL
        var serviceName: String = "deepseek-harness-mobile"

        init(
            mode: Mode = .disabled,
            endpoint: URL? = nil,
            delivery: (@Sendable (_ endpoint: URL, _ payload: Data) async -> Void)? = nil,
            outputDirectory: URL
        ) {
            self.mode = mode
            self.endpoint = endpoint
            self.delivery = delivery
            self.outputDirectory = outputDirectory
        }
    }

    private let configuration: Configuration
    private let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private var pending: [SessionTelemetry.Record] = []
    nonisolated(unsafe) private var releasedBatchCount = 0

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var mode: Mode { configuration.mode }

    func emit(_ record: SessionTelemetry.Record) {
        guard configuration.mode == .full || configuration.mode == .feedbackOnly else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        pending.append(record)
        // FULL forwards immediately; FEEDBACK_ONLY parks records until
        // `releasePending` is called from a feedback/record flow.
        if configuration.mode == .full {
            Task { [weak self] in
                await self?.deliverPending()
            }
        }
    }

    func flush() async {
        await deliverPending()
    }

    func shutdown() async {
        await deliverPending()
    }

    /// FEEDBACK_ONLY: hands the parked records to delivery when a feedback
    /// record lands.
    func releasePending() async {
        await deliverPending()
    }

    private func deliverPending() async {
        guard configuration.mode != .disabled else { return }
        let batch: [SessionTelemetry.Record] = {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { return [] }
            let batch = pending
            pending.removeAll()
            return batch
        }()
        guard !batch.isEmpty else { return }

        let payload = Self.otlpJSON(records: batch, serviceName: configuration.serviceName)
        releasedBatchCount += 1
        if let endpoint = configuration.endpoint,
           let delivery = configuration.delivery,
           configuration.mode == .full {
            await delivery(endpoint, payload)
        } else {
            let file = configuration.outputDirectory
                .appendingPathComponent("session-telemetry-\(releasedBatchCount).json")
            try? FileManager.default.createDirectory(
                at: configuration.outputDirectory,
                withIntermediateDirectories: true
            )
            try? payload.write(to: file, options: .atomic)
        }
    }

    // MARK: - OTLP/JSON mapping

    /// Serializes records into the OTLP/JSON `exportLogsServiceRequest`
    /// shape: one resource (the harness) with two scope groups — ledger and
    /// ops — each carrying its records as log records with severity and
    /// attributes.
    static func otlpJSON(records: [SessionTelemetry.Record], serviceName: String) -> Data {
        func attributeValue(_ value: String) -> JSONValue {
            .object(["stringValue": .string(value)])
        }

        var scopeGroups: [String: [JSONValue]] = [:]
        for record in records {
            var attributes: [JSONValue] = []
            for (key, value) in record.attributes.sorted(by: { $0.key < $1.key }) {
                attributes.append(.object([
                    "key": .string(key),
                    "value": attributeValue(value)
                ]))
            }
            attributes.append(.object([
                "key": .string("telemetry.channel"),
                "value": attributeValue(record.channel.rawValue)
            ]))
            let severityText: String
            switch record.severity {
            case .info: severityText = "INFO"
            case .warn: severityText = "WARN"
            case .error: severityText = "ERROR"
            }
            scopeGroups[record.channel.rawValue, default: []].append(.object([
                "timeUnixNano": .string(String(Int64(record.time) * 1_000_000)),
                "severityNumber": .number(severityNumber(record.severity)),
                "severityText": .string(severityText),
                "attributes": .array(attributes),
                "body": .object(["stringValue": .string({
                let encoded = try? JSONEncoder().encode(record.body)
                return encoded.map { String(decoding: $0, as: UTF8.self) } ?? "null"
            }())])
            ]))
        }

        let scopeLogs = scopeGroups.keys.sorted().map { channel in
            JSONValue.object([
                "scope": .object(["name": .string("deepseek-harness-mobile/session-telemetry.\(channel)")]),
                "logRecords": .array(scopeGroups[channel] ?? [])
            ])
        }

        let envelope: JSONValue = .object([
            "resourceLogs": .array([
                .object([
                    "resource": .object([
                        "attributes": .array([
                            .object([
                                "key": .string("service.name"),
                                "value": attributeValue(serviceName)
                            ])
                        ])
                    ]),
                    "scopeLogs": .array(scopeLogs)
                ])
            ])
        ])
        return (try? JSONEncoder().encode(envelope)) ?? Data("{}".utf8)
    }

    /// OTel severity numbers: INFO 9, WARN 13, ERROR 17.
    static func severityNumber(_ severity: SessionTelemetry.Severity) -> Double {
        switch severity {
        case .info: 9
        case .warn: 13
        case .error: 17
        }
    }
}
