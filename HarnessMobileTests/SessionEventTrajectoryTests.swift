import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionEventTrajectoryTests: XCTestCase {
    func testEnvelopeKeepsStringTypeAndDSHSurfaceFields() throws {
        let event = try SessionEvent(
            type: "plugin/example",
            seq: 5,
            time: 1_700_000_000_123,
            data: .object(["value": .string("kept")]),
            ignorable: true,
            sourceEventSeqs: [1, 2],
            surfaceOp: .replace(start: 1, end: 2)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "plugin/example")
        XCTAssertEqual(object["seq"] as? Int, 5)
        XCTAssertEqual(object["ignorable"] as? Bool, true)
        XCTAssertEqual(object["sourceEventSeqs"] as? [Int], [1, 2])
        XCTAssertEqual((object["surfaceOp"] as? [String: Any])?["op"] as? String, "replace")
        XCTAssertEqual(try JSONDecoder().decode(SessionEvent.self, from: data), event)

        let appendEvent = try SessionEvent(
            type: SessionEventVocabulary.userMessage,
            seq: 1,
            time: 2,
            data: .object([:]),
            surfaceOp: .append
        )
        let appendObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(appendEvent)) as? [String: Any]
        )
        XCTAssertEqual(appendObject["surfaceOp"] as? String, "append")
    }

    func testCoreBuildersExposeTypedAccessorsWithoutClosingEventVocabulary() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionEventJSONLStore(
            fileURL: root.appendingPathComponent("builders.jsonl"),
            streamID: "builders"
        )
        let header: JSONValue = .object([
            "config": .object(["provider": .string("deepseek"), "model": .string("deepseek-chat")])
        ])

        let events = try await store.append([
            .userMessage(.object(["content": .array([]), "source": .object(["kind": .string("user")])]), time: 1),
            .requestHeader(header: header, reason: .initial, time: 2),
            .requestContext(provider: "deepseek", model: "deepseek-chat", contextWindow: 128_000, time: 3),
            .sessionEndSeed(time: 4),
            SessionEventDraft(type: "plugin/custom", time: 5, data: .object(["v": .number(1)]), ignorable: true)
        ])

        XCTAssertNotNil(events[0].userMessageData)
        XCTAssertEqual(events[1].requestHeaderData, SessionRequestHeaderData(header: header, reason: .initial))
        XCTAssertEqual(
            events[2].requestContextData,
            SessionRequestContextData(provider: "deepseek", model: "deepseek-chat", contextWindow: 128_000)
        )
        XCTAssertEqual(events[3].type, SessionEventVocabulary.sessionEndSeed)
        XCTAssertEqual(events[4].type, "plugin/custom")
        try await store.close()
    }

    func testIncrementalSnapshotReturnsOnlyEventsAfterCursor() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionEventJSONLStore(
            fileURL: root.appendingPathComponent("events.jsonl"),
            streamID: "session-a"
        )

        let empty = try await store.recover()
        XCTAssertEqual(empty.cursor.nextSequence, 0)
        XCTAssertEqual(empty.events, [])

        _ = try await store.append([
            .turnStart(turn: 1, time: 100),
            .stepStart(turn: 1, step: 1, time: 110)
        ])
        let delta = try await store.snapshot(after: empty.cursor)
        XCTAssertEqual(delta.fromSequence, 0)
        XCTAssertEqual(delta.events.map(\.seq), [0, 1])
        XCTAssertEqual(delta.events.map(\.type), ["turn/start", "step/start"])

        _ = try await store.append(.assistantTextDelta(turn: 1, step: 1, text: "A", time: 120))
        let tokenDelta = try await store.snapshot(after: delta.cursor)
        XCTAssertEqual(tokenDelta.fromSequence, 2)
        XCTAssertEqual(tokenDelta.events.count, 1)
        XCTAssertEqual(tokenDelta.events.first?.assistantChunkData?.chunk.objectValue?["text"]?.stringValue, "A")

        let unchanged = try await store.snapshot(after: tokenDelta.cursor)
        XCTAssertTrue(unchanged.events.isEmpty)
        XCTAssertEqual(unchanged.cursor, tokenDelta.cursor)
        try await store.close()
    }

    func testRecoveryRejectsUnknownRequiredEventAndAcceptsIgnorableEvent() async throws {
        let requiredRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: requiredRoot) }
        let requiredURL = requiredRoot.appendingPathComponent("required.jsonl")
        try writeJSONL([
            try SessionEvent(
                type: "future/required",
                seq: 0,
                time: 1,
                data: .null
            )
        ], to: requiredURL)

        let requiredStore = SessionEventJSONLStore(fileURL: requiredURL, streamID: "required")
        do {
            _ = try await requiredStore.recover()
            XCTFail("A required event unknown to this build must stop recovery")
        } catch let error as SessionEventLogError {
            XCTAssertEqual(error, .unsupportedEventType(type: "future/required", sequence: 0))
        }

        let ignorableRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: ignorableRoot) }
        let ignorableURL = ignorableRoot.appendingPathComponent("ignorable.jsonl")
        let ignorable = try SessionEvent(
            type: "future/informational",
            seq: 0,
            time: 1,
            data: .object(["new": .bool(true)]),
            ignorable: true
        )
        try writeJSONL([ignorable], to: ignorableURL)

        let ignorableStore = SessionEventJSONLStore(fileURL: ignorableURL, streamID: "ignorable")
        let recovered = try await ignorableStore.recover()
        XCTAssertEqual(recovered.events, [ignorable])
        try await ignorableStore.close()
    }

    func testRegisteredPluginEventMayRemainRequired() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("plugin.jsonl")
        let event = try SessionEvent(
            type: "plugin/memory-index",
            seq: 0,
            time: 1,
            data: .object(["revision": .number(3)])
        )
        try writeJSONL([event], to: url)

        let store = SessionEventJSONLStore(fileURL: url, streamID: "plugin")
        try await store.registerKnownEventTypes(["plugin/memory-index"])
        let recovered = try await store.recover()
        XCTAssertEqual(recovered.events, [event])
        try await store.close()
    }

    func testRecoveryDropsOnlyMalformedTornTailThenContinuesContiguously() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("torn.jsonl")
        let writer = SessionEventJSONLStore(fileURL: url, streamID: "torn", durability: .synchronized)
        _ = try await writer.append([
            .turnStart(turn: 1, time: 1),
            .stepStart(turn: 1, step: 1, time: 2)
        ])
        try await writer.close()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"assistant/chunk\"".utf8))
        try handle.close()

        let recoveredStore = SessionEventJSONLStore(fileURL: url, streamID: "torn")
        let recovered = try await recoveredStore.recover()
        XCTAssertTrue(recovered.recoveredTornTail)
        XCTAssertEqual(recovered.events.map(\.seq), [0, 1])

        let appended = try await recoveredStore.append(
            .assistantTextDelta(turn: 1, step: 1, text: "continued", time: 3)
        )
        XCTAssertEqual(appended.seq, 2)
        try await recoveredStore.close()

        let reopened = SessionEventJSONLStore(fileURL: url, streamID: "torn")
        let complete = try await reopened.recover()
        XCTAssertFalse(complete.recoveredTornTail)
        XCTAssertEqual(complete.events.map(\.seq), [0, 1, 2])
        try await reopened.close()
    }

    func testActorSerializesConcurrentSequenceAssignment() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionEventJSONLStore(
            fileURL: root.appendingPathComponent("concurrent.jsonl"),
            streamID: "concurrent"
        )

        try await withThrowingTaskGroup(of: SessionEvent.self) { group in
            for value in 0..<64 {
                group.addTask {
                    try await store.append(
                        SessionEventDraft(
                            type: "plugin/concurrent",
                            time: Int64(value),
                            data: .number(Double(value)),
                            ignorable: true
                        )
                    )
                }
            }
            for try await _ in group {}
        }

        let events = try await store.allEvents()
        XCTAssertEqual(events.map(\.seq), Array(0..<64))
        XCTAssertEqual(Set(events.compactMap { value(from: $0.data) }), Set(0..<64))
        try await store.close()
    }

    func testMetricsFollowUpstreamStepTokenAndCacheRules() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionEventJSONLStore(
            fileURL: root.appendingPathComponent("metrics.jsonl"),
            streamID: "metrics"
        )
        let usage = SessionTokenUsage(
            inputTokens: 10,
            outputTokens: 20,
            cacheReadTokens: 80,
            cacheWriteTokens: 10,
            reasoningTokens: 5
        )
        let toolResultMessage: JSONValue = .object([
            "source": .object(["kind": .string("tool"), "callId": .string("call-1")]),
            "content": .array([])
        ])

        _ = try await store.append([
            .turnStart(turn: 1, time: 1_000),
            .stepStart(turn: 1, step: 1, time: 1_100),
            .assistantTextDelta(turn: 1, step: 1, text: "", time: 1_150),
            .assistantReasoningDelta(turn: 1, step: 1, text: "first", time: 1_200),
            .assistantUsage(turn: 1, step: 1, usage: usage, time: 1_250),
            .assistantMessage(
                turn: 1,
                step: 1,
                message: .object(["id": .string("assistant-1")]),
                usage: usage,
                sourceEventSeqs: [2, 3, 4],
                time: 1_500
            ),
            .toolCall(
                turn: 1,
                step: 1,
                callID: "call-1",
                name: "shell_execute",
                arguments: "{}",
                time: 1_510
            ),
            .toolResult(
                turn: 1,
                step: 1,
                message: toolResultMessage,
                sourceEventSeqs: [6],
                time: 1_610
            ),
            .stepEnd(turn: 1, step: 1, time: 1_620),
            .turnEnd(turn: 1, reason: .object(["kind": .string("completed")]), time: 1_700)
        ])

        let metrics = try await store.currentMetrics()
        XCTAssertEqual(metrics.durationMilliseconds, 700)
        XCTAssertEqual(metrics.turns, 1)
        XCTAssertEqual(metrics.steps, 1)
        XCTAssertEqual(metrics.calls, 1)
        XCTAssertEqual(metrics.modelDurationMilliseconds, 400)
        XCTAssertEqual(metrics.toolDurationMilliseconds, 100)
        XCTAssertEqual(metrics.totalTTFTMilliseconds, 100)
        XCTAssertEqual(metrics.ttftSamples, 1)
        XCTAssertEqual(metrics.averageTTFTMilliseconds, 100)
        XCTAssertEqual(metrics.decodeDurationMilliseconds, 300)
        XCTAssertEqual(metrics.decodeTokens, 20)
        XCTAssertEqual(metrics.uncachedInputTokens, 10)
        XCTAssertEqual(metrics.outputTokens, 20)
        XCTAssertEqual(metrics.cacheReadTokens, 80)
        XCTAssertEqual(metrics.cacheWriteTokens, 10)
        XCTAssertEqual(try XCTUnwrap(metrics.cacheHitRate), 0.8, accuracy: 0.000_001)
        try await store.close()
    }

    func testUsageChunkIsReplacedByFinalUsageForSameStep() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionEventJSONLStore(
            fileURL: root.appendingPathComponent("usage-replacement.jsonl"),
            streamID: "usage-replacement"
        )

        _ = try await store.append([
            .stepStart(turn: 1, step: 1, time: 10),
            .assistantUsage(
                turn: 1,
                step: 1,
                usage: SessionTokenUsage(inputTokens: 20, outputTokens: 5, cacheReadTokens: 80),
                time: 20
            ),
            .assistantMessage(
                turn: 1,
                step: 1,
                message: .object([:]),
                usage: SessionTokenUsage(inputTokens: 25, outputTokens: 7, cacheReadTokens: 75),
                sourceEventSeqs: [1],
                time: 30
            )
        ])

        let metrics = try await store.currentMetrics()
        XCTAssertEqual(metrics.uncachedInputTokens, 25)
        XCTAssertEqual(metrics.outputTokens, 7)
        XCTAssertEqual(metrics.cacheReadTokens, 75)
        XCTAssertEqual(try XCTUnwrap(metrics.cacheHitRate), 0.75, accuracy: 0.000_001)
        try await store.close()
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionEventTrajectoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeJSONL(_ events: [SessionEvent], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    private func value(from json: JSONValue) -> Int? {
        guard case let .number(number) = json else { return nil }
        return Int(number)
    }
}
