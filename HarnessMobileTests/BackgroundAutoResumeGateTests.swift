import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class BackgroundAutoResumeGateTests: XCTestCase {
    func testSystemExpirationResumesOnlyWhenForegroundAndCheckpointExists() {
        let runID = UUID()
        var gate = BackgroundAutoResumeGate()

        gate.markSystemExpiration(runID: runID)
        XCTAssertFalse(gate.shouldResume(isRunning: false, hasResumableRun: true))

        gate.updateApplicationActivity(isActive: true)
        XCTAssertFalse(gate.shouldResume(isRunning: true, hasResumableRun: true))
        XCTAssertFalse(gate.shouldResume(isRunning: false, hasResumableRun: false))
        XCTAssertTrue(gate.shouldResume(isRunning: false, hasResumableRun: true))
        XCTAssertEqual(gate.consumePendingRun(), runID)
        XCTAssertFalse(gate.shouldResume(isRunning: false, hasResumableRun: true))
    }

    func testResetDropsPendingSystemExpiration() {
        var gate = BackgroundAutoResumeGate()
        gate.updateApplicationActivity(isActive: true)
        gate.markSystemExpiration(runID: UUID())
        gate.reset()

        XCTAssertNil(gate.pendingRunID)
        XCTAssertFalse(gate.shouldResume(isRunning: false, hasResumableRun: true))
    }
}
