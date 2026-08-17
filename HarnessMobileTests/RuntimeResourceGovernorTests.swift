import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class RuntimeResourceGovernorTests: XCTestCase {
    func testNominalForegroundAllowsTwoBoundedCommands() {
        let limits = RuntimeResourceGovernor.limits(
            for: RuntimeResourceSignals(
                thermalLevel: .nominal,
                isLowPowerModeEnabled: false,
                isBackgrounded: false
            )
        )

        XCTAssertEqual(limits.maximumConcurrentCommands, 2)
        XCTAssertEqual(limits.maximumInlineOutputBytes, 512 * 1_024)
        XCTAssertEqual(limits.emulatorDutyCycle, 1)
    }

    func testBackgroundAndThermalPressureReduceWork() {
        let background = RuntimeResourceGovernor.limits(
            for: RuntimeResourceSignals(
                thermalLevel: .nominal,
                isLowPowerModeEnabled: false,
                isBackgrounded: true
            )
        )
        let critical = RuntimeResourceGovernor.limits(
            for: RuntimeResourceSignals(
                thermalLevel: .critical,
                isLowPowerModeEnabled: false,
                isBackgrounded: false
            )
        )

        XCTAssertEqual(background.maximumConcurrentCommands, 1)
        XCTAssertEqual(background.emulatorDutyCycle, 0.5)
        XCTAssertEqual(critical.maximumInlineOutputBytes, 128 * 1_024)
        XCTAssertEqual(critical.commandTimeoutSeconds, 60)
        XCTAssertEqual(critical.emulatorDutyCycle, 0.25)
    }

    func testLimitsClampRequestedTimeoutAndOutput() {
        let limits = RuntimeResourceGovernor.limits(
            for: RuntimeResourceSignals(
                thermalLevel: .critical,
                isLowPowerModeEnabled: false,
                isBackgrounded: false
            )
        )

        XCTAssertEqual(limits.effectiveCommandTimeout(requested: 600), 60)
        XCTAssertEqual(limits.effectiveCommandTimeout(requested: 0), 1)
        XCTAssertEqual(limits.effectiveInlineOutputBytes(requested: 512 * 1_024), 128 * 1_024)
        XCTAssertEqual(limits.effectiveInlineOutputBytes(requested: 128), 1_024)
    }

    func testISHOutputLimiterBoundsStreamingAndRetainedOutput() {
        let limiter = ISHOutputLimiter(maximumBytes: 128)
        let first = limiter.consume(channel: .stdout, text: String(repeating: "a", count: 32))
        let second = limiter.consume(channel: .stderr, text: String(repeating: "b", count: 256))
        let third = limiter.consume(channel: .stdout, text: "ignored")
        let streamed = [first, second].compactMap(\.self).map(\.text).joined()

        XCTAssertLessThanOrEqual(streamed.utf8.count, 128)
        XCTAssertTrue(streamed.contains(ISHOutputLimiter.truncationMarker))
        XCTAssertNil(third)

        let retained = ISHOutputLimiter.boundedOutputs(
            stdout: String(repeating: "c", count: 256),
            stderr: String(repeating: "d", count: 256),
            maximumBytes: 192
        )
        XCTAssertLessThanOrEqual(
            retained.stdout.utf8.count + retained.stderr.utf8.count,
            192
        )
        XCTAssertTrue(
            retained.stdout.contains(ISHOutputLimiter.truncationMarker)
                || retained.stderr.contains(ISHOutputLimiter.truncationMarker)
        )
    }
}
