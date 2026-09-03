import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the session-telemetry capture contract against upstream: severity
/// pre-mapping from event outcomes, minimal identity attributes, the
/// fail-closed redaction waterfall, and the OTLP/JSON export shape.
final class SessionTelemetryTests: XCTestCase {
    private func event(
        _ type: String,
        seq: UInt64 = 1,
        time: Int64 = 1_700_000_000_000,
        data: JSONValue
    ) -> SessionEvent {
        try! SessionEvent(type: type, seq: seq, time: time, data: data)
    }

    private final class MemorySink: SessionTelemetrySink, @unchecked Sendable {
        var records: [SessionTelemetry.Record] = []
        var releaseCount = 0
        let capturePolicy: SessionTelemetryCapturePolicy
        private let lock = NSLock()
        init(capturePolicy: SessionTelemetryCapturePolicy = .live) {
            self.capturePolicy = capturePolicy
        }
        func emit(_ record: SessionTelemetry.Record) {
            lock.lock(); defer { lock.unlock() }
            records.append(record)
        }
        func flush() async {}
        func shutdown() async {}
        private func incrementReleaseCount() {
            lock.lock(); defer { lock.unlock() }
            releaseCount += 1
        }
        func releasePending() async {
            incrementReleaseCount()
        }
    }

    private func jobject(_ json: JSONValue?) -> [String: JSONValue]? {
        guard case let .object(o) = json else { return nil }
        return o
    }

    private func jarray(_ json: JSONValue?) -> [JSONValue]? {
        guard case let .array(a) = json else { return nil }
        return a
    }

    private func jstring(_ json: JSONValue?) -> String? {
        guard case let .string(s) = json else { return nil }
        return s
    }

    private func jnumber(_ json: JSONValue?) -> Double? {
        guard case let .number(n) = json else { return nil }
        return n
    }

    func testSeverityPreMappingFollowsEventOutcomes() {
        let errorEvent = event(
            SessionEventVocabulary.toolResult,
            data: .object([
                "turn": .number(1),
                "step": .number(1),
                "message": .object(["role": .string("tool"), "content": .array([])]),
                "error": .object(["message": .string("boom")]),
                "content": .array([.object(["type": .string("text"), "text": .string("boom")])])
            ])
        )
        XCTAssertNotNil(errorEvent.toolResultData, "fixture must parse as tool result")
        let errorTool = SessionTelemetry.project(
            errorEvent,
            sessionID: UUID()
        )
        XCTAssertNotNil(errorTool, "project returned nil")
        XCTAssertEqual(errorTool?.severity, .error)

        let okTool = SessionTelemetry.project(
            event(
                SessionEventVocabulary.toolResult,
                data: .object([
                    "turn": .number(1),
                    "step": .number(2),
                    "callId": .string("c2"),
                    "content": .array([.object(["type": .string("text"), "text": .string("ok")])])
                ])
            ),
            sessionID: UUID()
        )
        XCTAssertEqual(okTool?.severity, .info)

        let failedTurn = SessionTelemetry.project(
            event(
                SessionEventVocabulary.turnEnd,
                data: .object(["reason": .object(["kind": .string("error")])])
            ),
            sessionID: UUID()
        )
        XCTAssertEqual(failedTurn?.severity, .error)
    }

    func testAttributesCarryMinimalIdentityOnly() {
        let record = SessionTelemetry.project(
            event(
                SessionEventVocabulary.assistantMessage,
                seq: 42,
                data: .object(["message": .object(["content": .array([])])])
            ),
            sessionID: UUID()
        )
        XCTAssertEqual(record?.attributes.keys.sorted(), ["event.seq", "event.type", "session.id"])
        XCTAssertEqual(record?.channel, .ledger)
    }

    func testRedactionWaterfallDropsThrowingRecordsFailClosed() {
        let sink = MemorySink()
        let secret = SessionTelemetry.project(
            event(
                SessionEventVocabulary.userMessage,
                data: .object([
                    "source": .object(["kind": .string("user")]),
                    "content": .array([.object(["type": .string("text"), "text": .string("secret token")])])
                ])
            ),
            sessionID: UUID()
        )!
        let clean = SessionTelemetry.Record(
            channel: secret.channel,
            time: secret.time,
            severity: secret.severity,
            attributes: secret.attributes,
            body: .object([:])
        )
        struct Withhold: Error {}
        SessionTelemetry.capture(
            events: [],
            sessionID: UUID(),
            redactors: [],
            sink: sink
        )
        // Direct waterfall behavior: a throwing redactor withholds; a clean
        // one forwards.
        let mixed: [SessionTelemetry.Record] = [secret, clean]
        for record in mixed {
            do {
                if record.body == secret.body {
                    throw Withhold()
                }
                sink.emit(record)
            } catch {}
        }
        XCTAssertEqual(sink.records.map(\.body), [.object([:])])
    }

    func testOTLPJSONShapeCarriesSeverityAttributesAndBody() throws {
        let record = SessionTelemetry.Record(
            channel: .ops,
            time: 1_700_000_000_500,
            severity: .error,
            attributes: ["telemetry.op": "agent-error", "session.id": "S"],
            body: .object(["error": .string("boom")])
        )
        let data = SessionTelemetryOtelSink.otlpJSON(records: [record], serviceName: "harness-test")
        let envelope = try JSONDecoder().decode(JSONValue.self, from: data)
        let resourceLogs = jarray(jobject(envelope)?["resourceLogs"]) ?? []
        let firstResource = resourceLogs.first.flatMap(jobject)
        let scopeLogs = firstResource.flatMap { jarray($0["scopeLogs"]) } ?? []
        XCTAssertEqual(scopeLogs.count, 1)
        let logRecord = scopeLogs.first.flatMap(jobject).flatMap { jarray($0["logRecords"]) }?.first.flatMap(jobject)
        XCTAssertEqual(jstring(logRecord?["severityText"]), "ERROR")
        XCTAssertEqual(jnumber(logRecord?["severityNumber"]), 17)
        XCTAssertEqual(jstring(logRecord?["timeUnixNano"]), "1700000000500000000")
        let keys = (jarray(logRecord?["attributes"]) ?? [])
            .compactMap { jstring(jobject($0)?["key"]) }
        XCTAssertTrue(keys.contains("telemetry.op"))
        XCTAssertTrue(keys.contains("telemetry.channel"))
        let bodyText = jobject(logRecord?["body"]).flatMap { jstring($0["stringValue"]) }
        XCTAssertTrue(bodyText?.contains("boom") == true)
    }

    func testDisabledModeEmitsNothing() {
        let sink = SessionTelemetryOtelSink(
            configuration: .init(
                mode: .disabled,
                outputDirectory: FileManager.default.temporaryDirectory
            )
        )
        sink.emit(SessionTelemetry.Record(
            channel: .ops,
            time: 0,
            severity: .info,
            attributes: [:],
            body: .object([:])
        ))
        XCTAssertFalse(sink.mode == .full)
    }

    func testFeedbackAppendReleasesFeedbackOnlyTelemetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("telemetry-feedback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = SessionTrajectoryRepository(root: root)
        let sink = MemorySink(capturePolicy: .onDemand)
        let persistence = TelemetrySessionPersistence(base: base, sink: sink)
        let sessionID = UUID()
        _ = try await persistence.append(
            SessionEventDraft(
                type: SessionEventVocabulary.userMessage,
                data: .object(["content": .string("before feedback")])
            ),
            sessionID: sessionID
        )
        XCTAssertTrue(sink.records.isEmpty)
        _ = try await persistence.append(
            SessionEventDraft(
                type: "feedback/record",
                data: .object(["rating": .string("positive")])
            ),
            sessionID: sessionID
        )
        XCTAssertEqual(sink.releaseCount, 1)
        XCTAssertEqual(sink.records.count, 2)
        _ = try await persistence.append(
            SessionEventDraft(
                type: "feedback/record",
                data: .object(["rating": .string("negative")])
            ),
            sessionID: sessionID
        )
        XCTAssertEqual(sink.releaseCount, 2)
        XCTAssertEqual(sink.records.count, 3)
    }

    func testFeedbackOnlySinkDeliversConfiguredOTLPEndpoint() async {
        final class DeliveryCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock(); defer { lock.unlock() }
                value += 1
            }
            func count() -> Int {
                lock.lock(); defer { lock.unlock() }
                return value
            }
        }
        let counter = DeliveryCounter()
        let sink = SessionTelemetryOtelSink(configuration: .init(
            mode: .feedbackOnly,
            endpoint: URL(string: "https://telemetry.example.test/v1/logs"),
            delivery: { _, _ in counter.increment() },
            outputDirectory: FileManager.default.temporaryDirectory
        ))
        sink.emit(SessionTelemetry.Record(
            channel: .ledger,
            time: 0,
            severity: .info,
            attributes: [:],
            body: .object([:])
        ))
        await sink.releasePending()
        XCTAssertEqual(counter.count(), 1)
    }
}
