import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class RuntimeTelemetryTests: XCTestCase {
    func testPerformanceSamplingIsDisabledByDefaultAndExplicitlyOptIn() async {
        let store = RuntimeTelemetryStore(markerURL: temporaryMarkerURL())
        let signals = RuntimeResourceSignals(
            thermalLevel: .serious,
            isLowPowerModeEnabled: true,
            isBackgrounded: true
        )

        await store.recordPerformanceSample(signals)
        let defaultSnapshot = await store.snapshot()
        let defaultSummary = await store.summary()
        XCTAssertTrue(defaultSnapshot.isEmpty)
        XCTAssertFalse(defaultSummary.performanceSamplingEnabled)

        await store.configurePerformanceSampling(enabled: true)
        await store.recordPerformanceSample(signals)
        let records = await store.snapshot()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].kind, .performanceSample)
        XCTAssertEqual(records[0].attributes, [
            "thermal_level": 2,
            "low_power_mode": 1,
            "is_backgrounded": 1
        ])
    }

    func testRecordsRejectTextLikeCodeAndUnknownAttributes() async {
        let store = RuntimeTelemetryStore(markerURL: temporaryMarkerURL())
        await store.record(
            kind: .watchdog,
            code: "https://example.invalid/?token=secret canary",
            attributes: [
                "gap_ms": 1_000,
                "prompt": 42,
                "api_key": 7
            ]
        )
        let records = await store.snapshot()
        let record = try! XCTUnwrap(records.first)

        XCTAssertEqual(record.code, "invalid_code")
        XCTAssertEqual(record.attributes, ["gap_ms": 1_000])
    }

    func testRingAndEncodedByteBoundsEvictOldestRecords() async {
        let store = RuntimeTelemetryStore(
            markerURL: temporaryMarkerURL(),
            capacity: 2,
            maximumEncodedBytes: 1_024
        )
        for index in 1...3 {
            await store.record(
                kind: .watchdog,
                code: "sample_\(index)",
                attributes: ["gap_ms": index]
            )
        }
        let records = await store.snapshot()
        let summary = await store.summary()

        XCTAssertEqual(records.map(\.code), ["sample_2", "sample_3"])
        XCTAssertLessThanOrEqual(summary.encodedBytes, 1_024)
    }

    func testLaunchMarkerReportsOnlyPriorUnfinishedBootstrap() async throws {
        let markerURL = temporaryMarkerURL()
        let first = RuntimeTelemetryStore(markerURL: markerURL)
        await first.beginBootstrap(now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))

        let second = RuntimeTelemetryStore(markerURL: markerURL)
        await second.beginBootstrap(now: Date(timeIntervalSince1970: 2))
        let secondRecords = await second.snapshot()
        let record = try XCTUnwrap(secondRecords.first)
        XCTAssertEqual(record.kind, .launchMarker)
        XCTAssertEqual(record.code, "previous_bootstrap_unfinished")
        XCTAssertNil(record.sessionID)
        XCTAssertTrue(record.attributes.isEmpty)

        await second.markBootstrapCompleted()
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testWatchdogGateThresholdDeduplicationAndRearming() async {
        let gate = RuntimeHangWatchdogGate(threshold: 3)
        let start = Date(timeIntervalSince1970: 10)
        await gate.start(now: start)

        let beforeThreshold = await gate.check(now: start.addingTimeInterval(2.9))
        let firstStall = await gate.check(now: start.addingTimeInterval(3))
        let deduplicatedStall = await gate.check(now: start.addingTimeInterval(4))
        XCTAssertNil(beforeThreshold)
        XCTAssertEqual(firstStall?.gapMilliseconds, 3_000)
        XCTAssertNil(deduplicatedStall)

        await gate.beat(now: start.addingTimeInterval(5))
        let rearmedStall = await gate.check(now: start.addingTimeInterval(8.2))
        XCTAssertEqual(rearmedStall?.gapMilliseconds, 3_200)

        await gate.suspend()
        let suspendedStall = await gate.check(now: start.addingTimeInterval(20))
        XCTAssertNil(suspendedStall)
    }

    @MainActor
    func testLifecycleWatchdogMonitorDoesNotTrapOnItsPrivateQueue() async throws {
        let store = RuntimeTelemetryStore(markerURL: temporaryMarkerURL())
        let watchdog = RuntimeHangWatchdog(telemetryStore: store, threshold: 1)

        watchdog.setApplicationActive(true)
        try await Task.sleep(for: .milliseconds(1_250))
        watchdog.setApplicationActive(false)

        let records = await store.snapshot()
        XCTAssertTrue(records.allSatisfy { $0.kind == .hang })
    }

    func testBackgroundTimeoutKeepsIdentityAndDeduplicatesWithinWindow() async {
        let store = RuntimeTelemetryStore(markerURL: temporaryMarkerURL())
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 9)
        let now = Date(timeIntervalSince1970: 100)

        await store.recordBackgroundTimeout(
            identity: identity,
            source: .finiteBackgroundLease,
            now: now
        )
        await store.recordBackgroundTimeout(
            identity: identity,
            source: .continuedProcessing,
            now: now.addingTimeInterval(1)
        )
        await store.recordBackgroundTimeout(
            identity: identity,
            source: .continuedProcessing,
            now: now.addingTimeInterval(2)
        )

        let records = await store.snapshot()
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0.sessionID == identity.sessionID })
        XCTAssertTrue(records.allSatisfy { $0.runID == identity.runID })
        XCTAssertTrue(records.allSatisfy { $0.generation == identity.generation })
        XCTAssertEqual(
            Set(records.map(\.code)),
            Set([
                RuntimeBackgroundTimeoutSource.finiteBackgroundLease.rawValue,
                RuntimeBackgroundTimeoutSource.continuedProcessing.rawValue
            ])
        )
    }

    func testExplicitDiagnosticExportIsHashedSessionWorkspacePath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        let export = try await store.writeDiagnosticExport(
            Data("redacted report".utf8),
            forSessionID: "session/secret-canary",
            filename: "Harness-Diagnostics-20260828-091500.log"
        )

        XCTAssertTrue(export.workspacePath.hasPrefix("Downloads/session-"))
        XCTAssertFalse(export.workspacePath.contains("session/secret-canary"))
        XCTAssertEqual(export.byteCount, 15)
        let storedData = try await store.readData(path: export.workspacePath)
        XCTAssertEqual(storedData, Data("redacted report".utf8))

        do {
            _ = try await store.writeDiagnosticExport(
                Data(),
                forSessionID: "session/secret-canary",
                filename: "report.log"
            )
            XCTFail("expected fixed diagnostic filename admission")
        } catch WorkspaceError.invalidPath {
            // Expected: exports cannot choose a path-like or arbitrary filename.
        } catch {
            XCTFail("unexpected export error: \(error)")
        }
    }

    private func temporaryMarkerURL() -> URL {
        temporaryDirectory().appendingPathComponent("runtime-marker.json")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeTelemetryTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
