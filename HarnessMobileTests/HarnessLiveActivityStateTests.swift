import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessLiveActivityStateTests: XCTestCase {
    func testPrivacyModeRemovesSensitiveActivityContent() {
        let state = HarnessLiveActivityState.make(
            sessionTitle: "修复 SecretProject 的登录故障",
            phase: .usingTool,
            detail: "正在读取 /private/workspace/token.txt",
            toolName: "shell_execute",
            toolSummary: "cat /private/workspace/token.txt",
            completedUnitCount: 2,
            totalUnitCount: 8,
            privacyModeEnabled: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(state.sessionTitle, "Harness 任务")
        XCTAssertEqual(state.detail, "正在执行已批准的本机工具")
        XCTAssertNil(state.toolName)
        XCTAssertNil(state.toolSummary)
        XCTAssertEqual(state.completedUnitCount, 2)
        XCTAssertEqual(state.totalUnitCount, 8)
        XCTAssertTrue(state.privacyModeEnabled)
    }

    func testVisibleStateNormalizesAndBoundsText() {
        let state = HarnessLiveActivityState.make(
            sessionTitle: "  会话\n标题  ",
            phase: .working,
            detail: String(repeating: "a", count: 200),
            toolName: "  read_file  ",
            toolSummary: "  reading\nfile  ",
            completedUnitCount: 20,
            totalUnitCount: 8,
            privacyModeEnabled: false
        )

        XCTAssertEqual(state.sessionTitle, "会话 标题")
        XCTAssertEqual(state.detail.count, 160)
        XCTAssertEqual(state.toolName, "read_file")
        XCTAssertEqual(state.toolSummary, "reading file")
        XCTAssertEqual(state.completedUnitCount, 8)
        XCTAssertEqual(state.progressFraction, 1)
    }

    func testPresentationComparisonIgnoresTimestampOnly() {
        let first = HarnessLiveActivityState.make(
            sessionTitle: "Session",
            phase: .working,
            detail: "Step 1",
            completedUnitCount: 0,
            totalUnitCount: 4,
            privacyModeEnabled: false,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        var second = first
        second.updatedAt = Date(timeIntervalSince1970: 20)

        XCTAssertTrue(first.hasSamePresentation(as: second))
        second.detail = "Step 2"
        XCTAssertFalse(first.hasSamePresentation(as: second))
    }

    func testMultiRunProjectionStoreDoesNotCrossFinishRuns() {
        let firstID = UUID()
        let secondID = UUID()
        let first = HarnessLiveActivityState.make(
            sessionTitle: "First",
            phase: .working,
            detail: "one",
            completedUnitCount: 1,
            totalUnitCount: 3,
            privacyModeEnabled: true
        )
        let second = HarnessLiveActivityState.make(
            sessionTitle: "Second",
            phase: .usingTool,
            detail: "two",
            completedUnitCount: 2,
            totalUnitCount: 4,
            privacyModeEnabled: true
        )
        var store = HarnessLiveActivityProjectionStore()
        store.upsert(first, for: firstID)
        store.upsert(second, for: secondID)

        XCTAssertEqual(store.activeRunIDs, [firstID, secondID])
        XCTAssertEqual(store.remove(runID: firstID), first)
        XCTAssertEqual(store.activeRunIDs, [secondID])
        XCTAssertEqual(store.states[secondID], second)
    }

    func testBackgroundProjectionPrioritizesContinuedProcessingAndKeepsDegradedReasons() {
        let keepAlive = BackgroundKeepAliveState(
            inputs: BackgroundKeepAliveInputs(
                isBackgrounded: true,
                hasLiveRoot: true,
                enhancedAudioRequested: true,
                locationRequested: false,
                hasFiniteBackgroundLease: true,
                hasContinuedProcessing: true,
                isLowPowerMode: true,
                isThermallyConstrained: false
            ),
            layers: [
                .finiteBackgroundTask,
                .continuedProcessing,
                .extendedAudio,
                .degraded(.lowPowerMode)
            ],
            generation: 4,
            degradedDetails: ["low_power_mode"]
        )

        let projection = BackgroundSystemProjection.make(
            activeRunCount: 2,
            keepAliveState: keepAlive,
            isBackgrounded: true,
            liveActivitySupported: true,
            liveActivityEnabled: true,
            notificationAuthorization: "已允许",
            locationAuthorization: "始终允许",
            privacyModeEnabled: true
        )

        XCTAssertEqual(projection.activeRunCount, 2)
        XCTAssertEqual(projection.survivalTier, .continuedProcessing)
        XCTAssertEqual(projection.degradedReasons, [.lowPowerMode])
        XCTAssertEqual(projection.degradedDetails, ["low_power_mode"])
        XCTAssertTrue(projection.privacyModeEnabled)
    }
}
