import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessTraceStoreTests: XCTestCase {
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
}
