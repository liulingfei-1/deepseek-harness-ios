import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessTraceStoreTests: XCTestCase {
    func testAgentDiagnosticsToolBoundsScopeAndRedactsCredentials() async throws {
        let tool = AgentDiagnosticsTool { query in
            .object([
                "scope": .string(query.scope.rawValue),
                "limit": .number(Double(query.limit)),
                "apiKey": .string("sk-abcdefghijklmnopqrstuvwxyz"),
                "message": .string("Bearer abcdefghijklmnopqrstuvwxyz")
            ])
        }

        let output = try await tool.execute(arguments: [
            "scope": .string("errors"),
            "limit": .number(12)
        ])

        XCTAssertTrue(output.contains("errors"))
        XCTAssertTrue(output.contains("12"))
        XCTAssertFalse(output.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(output.contains("Bearer abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(output.contains("redacted"))
        XCTAssertThrowsError(
            try tool.validate(arguments: ["limit": .number(33)])
        )
    }

    func testIncrementalReadsAdvancePastBoundedStoreEviction() async {
        let store = HarnessTraceStore(capacity: 2)
        for index in 1...4 {
            _ = await store.record(
                HarnessTraceDraft(
                    kind: .stepStarted,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        let retained = await store.events(after: 0)
        let delta = await store.events(after: 3)
        let noDelta = await store.events(after: 4)
        XCTAssertEqual(retained.map(\.sequence), [3, 4])
        XCTAssertEqual(delta.map(\.sequence), [4])
        XCTAssertTrue(noDelta.isEmpty)

        await store.clear()
        _ = await store.record(HarnessTraceDraft(kind: .runFinished))
        let afterClear = await store.events(after: 4)
        XCTAssertEqual(afterClear.map(\.sequence), [5])
    }

    func testSessionAndRunIdentityFilteringExcludesParentAndUnownedEvents() async {
        let store = HarnessTraceStore(capacity: 20)
        let parentSession = UUID()
        let childSession = UUID()
        let parentRun = UUID()
        let childRun = UUID()
        await store.register(runID: parentRun, sessionID: parentSession)
        await store.register(runID: childRun, sessionID: childSession)

        _ = await store.record(HarnessTraceDraft(kind: .runStarted, runID: parentRun))
        _ = await store.record(HarnessTraceDraft(kind: .runStarted, runID: childRun))
        _ = await store.record(HarnessTraceDraft(kind: .error, name: "unowned"))

        let childEvents = await store.events(sessionID: childSession)
        XCTAssertEqual(childEvents.map(\.runID), [childRun])
        let foreignEvents = await store.events(sessionID: childSession, runID: parentRun)
        let incrementalEvents = await store.events(
            after: 0,
            sessionID: childSession,
            runID: childRun
        )
        XCTAssertTrue(foreignEvents.isEmpty)
        XCTAssertEqual(incrementalEvents.count, 1)
    }

    func testDiagnosticReportDropsStreamingDeltasAndKeepsFinalizedEvents() throws {
        var events: [SessionEvent] = []
        for sequence in 1...6_000 {
            events.append(
                try SessionEvent(
                    type: SessionEventVocabulary.assistantChunk,
                    seq: UInt64(sequence),
                    time: Int64(sequence),
                    data: .object([
                        "turn": .number(1),
                        "step": .number(1),
                        "chunk": .object([
                            "type": .string("text-delta"),
                            "text": .string(String(repeating: "x", count: 512))
                        ])
                    ])
                )
            )
        }
        events.append(
            try SessionEvent(
                type: SessionEventVocabulary.assistantChunk,
                seq: 6_001,
                time: 6_001,
                data: .object([
                    "turn": .number(1),
                    "step": .number(1),
                    "chunk": .object([
                        "type": .string("usage"),
                        "usage": .object([
                            "inputTokens": .number(42),
                            "outputTokens": .number(7)
                        ])
                    ])
                ])
            )
        )
        events.append(
            try SessionEvent(
                type: SessionEventVocabulary.toolResult,
                seq: 6_002,
                time: 6_002,
                data: .object([
                    "turn": .number(1),
                    "step": .number(1),
                    "message": .object(["content": .string("tool result retained")])
                ])
            )
        )

        let report = try HarnessDiagnosticReportBuilder.build(
            HarnessDiagnosticReportInput(
                metadata: [:],
                pluginHostStderr: "",
                pluginSnapshots: [],
                pluginHostInventory: [],
                pluginPackageVersions: [:],
                toolContributionNames: [],
                nativeClientFailures: [],
                traceEvents: [],
                sessionEvents: events
            )
        )
        let text = String(decoding: report, as: UTF8.self)

        XCTAssertLessThan(report.count, 4 * 1_024 * 1_024)
        XCTAssertFalse(text.contains("text-delta"))
        XCTAssertTrue(text.contains("streamingDeltaOmissionCount"))
        XCTAssertTrue(text.contains("tool result retained"))
        XCTAssertTrue(text.contains("inputTokens"))
    }

    func testDiagnosticReportCompactsRepeatedLargeToolAndWebPayloads() throws {
        let repeatedPage = String(repeating: "<html>large fetched page</html>", count: 8_000)
        var traces: [HarnessTraceEvent] = []
        var sessionEvents: [SessionEvent] = []
        for sequence in 1...300 {
            traces.append(
                HarnessTraceEvent(
                    id: UUID(),
                    sequence: UInt64(sequence),
                    kind: .toolFinished,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
                    runID: nil,
                    turn: 1,
                    step: sequence,
                    callID: "web-\(sequence)",
                    pluginID: nil,
                    name: "web_fetch",
                    durationMilliseconds: 10,
                    attributes: [:],
                    payload: .tool(
                        HarnessTraceTool(
                            callID: "web-\(sequence)",
                            name: "web_fetch",
                            arguments: "{\"url\":\"https://example.com\"}",
                            output: repeatedPage,
                            isError: false
                        )
                    ),
                    error: nil
                )
            )
            sessionEvents.append(
                try SessionEvent(
                    type: SessionEventVocabulary.toolResult,
                    seq: UInt64(sequence),
                    time: Int64(sequence),
                    data: .object([
                        "tool": .string("web_fetch"),
                        "output": .string(repeatedPage)
                    ])
                )
            )
        }
        traces.append(
            HarnessTraceEvent(
                id: UUID(),
                sequence: 301,
                kind: .error,
                timestamp: Date(timeIntervalSince1970: 301),
                runID: nil,
                turn: 1,
                step: 301,
                callID: nil,
                pluginID: nil,
                name: "terminal.error",
                durationMilliseconds: nil,
                attributes: [:],
                payload: nil,
                error: "terminal diagnostic sentinel"
            )
        )

        let report = try HarnessDiagnosticReportBuilder.build(
            HarnessDiagnosticReportInput(
                metadata: [:],
                pluginHostStderr: "",
                pluginSnapshots: [],
                pluginHostInventory: [],
                pluginPackageVersions: [:],
                toolContributionNames: [],
                nativeClientFailures: [],
                traceEvents: traces,
                sessionEvents: sessionEvents
            )
        )
        let text = String(decoding: report, as: UTF8.self)

        XCTAssertLessThan(report.count, 1 * 1_024 * 1_024)
        XCTAssertTrue(text.contains("terminal diagnostic sentinel"))
        XCTAssertTrue(text.contains("boundedOmissionCount"))
    }

    func testSummaryLeavesCacheHitRateUnavailableWhenProviderOmitsCacheFields() async {
        let store = HarnessTraceStore(capacity: 10)
        _ = await store.record(
            HarnessTraceDraft(
                kind: .modelCompleted,
                payload: .modelResponse(
                    HarnessTraceModelResponse(
                        text: "ok",
                        reasoning: nil,
                        toolCalls: [],
                        finishReason: "stop",
                        usage: HarnessTraceTokenUsage(
                            ModelTokenUsage(
                                promptTokens: 100,
                                completionTokens: 1,
                                totalTokens: 101,
                                cachedPromptTokens: nil,
                                reasoningTokens: nil
                            )
                        )
                    )
                )
            )
        )

        let summary = HarnessTraceStore.summarize(await store.events())
        XCTAssertNil(summary.cacheHitRate)
    }

    func testSummaryPreservesExplicitZeroCacheHitRate() async {
        let store = HarnessTraceStore(capacity: 10)
        _ = await store.record(
            HarnessTraceDraft(
                kind: .modelCompleted,
                payload: .modelResponse(
                    HarnessTraceModelResponse(
                        text: "ok",
                        reasoning: nil,
                        toolCalls: [],
                        finishReason: "stop",
                        usage: HarnessTraceTokenUsage(
                            ModelTokenUsage(
                                promptTokens: 100,
                                completionTokens: 1,
                                totalTokens: 101,
                                cachedPromptTokens: 0,
                                reasoningTokens: nil,
                                uncachedPromptTokens: 100
                            )
                        )
                    )
                )
            )
        )

        let summary = HarnessTraceStore.summarize(await store.events())
        guard let rate = summary.cacheHitRate else {
            return XCTFail("expected explicit cache data to produce a rate")
        }
        XCTAssertEqual(rate, 0, accuracy: 0.000_001)
    }
}
