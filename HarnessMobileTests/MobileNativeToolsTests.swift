import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class MobileNativeToolsTests: XCTestCase {
    func testLocationSuccessUsesProviderAndReturnsBoundedReading() async throws {
        let reading = DeviceLocationReading(
            latitude: 39.9042,
            longitude: 116.4074,
            altitude: 43,
            horizontalAccuracy: 12,
            verticalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            isReducedAccuracy: false,
            isSimulatedBySoftware: false
        )
        let provider = LocationProviderFake(result: .success(reading))
        let tool = LocationCurrentTool(provider: provider)

        let result = try decodeObject(try await tool.execute(arguments: [:]))
        let timeoutWasPositive = await provider.timeoutWasPositive

        XCTAssertEqual(result["latitude"], .number(39.9042))
        XCTAssertEqual(result["longitude"], .number(116.4074))
        XCTAssertEqual(result["horizontalAccuracyMeters"], .number(12))
        XCTAssertEqual(tool.risk, .sensitiveRead)
        XCTAssertTrue(timeoutWasPositive)
    }

    func testLocationRejectsArgumentsAndPropagatesTypedDenial() async throws {
        let denied = LocationCurrentTool(
            provider: LocationProviderFake(result: .failure(.permissionDenied("定位")))
        )

        XCTAssertThrowsError(try denied.validate(arguments: ["precision": .string("exact")]))
        await XCTAssertThrowsMobileError(
            try await denied.execute(arguments: [:]),
            expected: .permissionDenied("定位")
        )
    }

    func testMotionSuccessUsesRequestedLookback() async throws {
        let provider = MotionProviderFake(result: .success(DeviceMotionActivityReading(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            confidence: .high,
            activities: ["walking"]
        )))
        let tool = MotionActivityTool(provider: provider)

        let result = try decodeObject(try await tool.execute(arguments: [
            "lookback_minutes": .number(90)
        ]))
        let lastLookbackMinutes = await provider.lastLookbackMinutes
        let timeoutWasPositive = await provider.timeoutWasPositive

        XCTAssertEqual(result["confidence"], .string("high"))
        XCTAssertEqual(result["activities"], .array([.string("walking")]))
        XCTAssertEqual(lastLookbackMinutes, 90)
        XCTAssertTrue(timeoutWasPositive)
    }

    func testMotionRejectsFractionalAndOutOfRangeLookbacks() throws {
        let tool = MotionActivityTool(
            provider: MotionProviderFake(result: .failure(.noData("运动活动")))
        )

        for arguments: [String: JSONValue] in [
            ["lookback_minutes": .number(0)],
            ["lookback_minutes": .number(1_441)],
            ["lookback_minutes": .number(1.5)],
            ["lookback_minutes": .string("60")],
            ["unexpected": .number(1)]
        ] {
            XCTAssertThrowsError(try tool.validate(arguments: arguments))
        }
        XCTAssertNoThrow(try tool.validate(arguments: [:]))
        XCTAssertNoThrow(try tool.validate(arguments: ["lookback_minutes": .number(1)]))
        XCTAssertNoThrow(try tool.validate(arguments: ["lookback_minutes": .number(1_440)]))
    }

    func testMotionPropagatesTypedPermissionDenial() async {
        let tool = MotionActivityTool(
            provider: MotionProviderFake(result: .failure(.permissionDenied("运动与健身")))
        )

        await XCTAssertThrowsMobileError(
            try await tool.execute(arguments: [:]),
            expected: .permissionDenied("运动与健身")
        )
    }

    func testNotificationSuccessSchedulesOnlyLocalBoundedRequest() async throws {
        let provider = NotificationSchedulerFake(result: .success(()))
        let tool = NotificationScheduleTool(provider: provider)

        let output = try decodeObject(try await tool.execute(arguments: [
            "title": .string("  本地提醒  "),
            "body": .string("检查任务结果"),
            "delay_seconds": .number(30)
        ]))

        let capturedRequest = await provider.lastRequest
        let timeoutWasPositive = await provider.timeoutWasPositive
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.title, "本地提醒")
        XCTAssertEqual(request.body, "检查任务结果")
        XCTAssertEqual(request.delaySeconds, 30)
        XCTAssertTrue(request.identifier.hasPrefix("harness-mobile-local-"))
        XCTAssertEqual(output["status"], .string("scheduled"))
        XCTAssertEqual(tool.risk, .sideEffect)
        XCTAssertTrue(timeoutWasPositive)
    }

    func testNotificationRejectsInvalidContentAndDelayBoundaries() throws {
        let tool = NotificationScheduleTool(
            provider: NotificationSchedulerFake(result: .success(()))
        )
        let valid: [String: JSONValue] = [
            "title": .string("提醒"),
            "body": .string(""),
            "delay_seconds": .number(1)
        ]
        XCTAssertNoThrow(try tool.validate(arguments: valid))
        XCTAssertNoThrow(try tool.validate(arguments: [
            "title": .string("提醒"),
            "body": .string("内容"),
            "delay_seconds": .number(604_800)
        ]))

        let invalid: [[String: JSONValue]] = [
            ["title": .string(" "), "body": .string(""), "delay_seconds": .number(1)],
            ["title": .string(String(repeating: "a", count: 129)), "body": .string(""), "delay_seconds": .number(1)],
            ["title": .string("提醒"), "body": .string(String(repeating: "a", count: 1_025)), "delay_seconds": .number(1)],
            ["title": .string("提醒"), "body": .string(""), "delay_seconds": .number(0)],
            ["title": .string("提醒"), "body": .string(""), "delay_seconds": .number(604_801)],
            ["title": .string("提醒"), "body": .string(""), "delay_seconds": .number(1.5)],
            ["title": .string("提醒"), "body": .string(""), "delay_seconds": .number(1), "url": .string("https://example.com")]
        ]
        for arguments in invalid {
            XCTAssertThrowsError(try tool.validate(arguments: arguments))
        }
    }

    func testNotificationPropagatesTypedPermissionDenial() async {
        let tool = NotificationScheduleTool(
            provider: NotificationSchedulerFake(result: .failure(.permissionDenied("通知")))
        )

        await XCTAssertThrowsMobileError(
            try await tool.execute(arguments: [
                "title": .string("提醒"),
                "body": .string("内容"),
                "delay_seconds": .number(10)
            ]),
            expected: .permissionDenied("通知")
        )
    }

    func testSecureAuthenticationSuccessSharesNoBiometricData() async throws {
        let provider = AuthenticatorFake(result: .success(()))
        let tool = SecureAuthenticateTool(provider: provider)

        let output = try decodeObject(try await tool.execute(arguments: [:]))
        let lastReason = await provider.lastReason
        let timeoutWasPositive = await provider.timeoutWasPositive

        XCTAssertEqual(output["authenticated"], .bool(true))
        XCTAssertEqual(output["biometricDataShared"], .bool(false))
        XCTAssertEqual(lastReason, "验证你本人后继续执行当前本机 Agent 操作")
        XCTAssertTrue(timeoutWasPositive)
        XCTAssertEqual(tool.risk, .sideEffect)
    }

    func testSecureAuthenticationRejectsArgumentsAndPropagatesDenial() async throws {
        let tool = SecureAuthenticateTool(
            provider: AuthenticatorFake(result: .failure(.authenticationCancelled))
        )

        XCTAssertThrowsError(try tool.validate(arguments: ["reason": .string("伪造提示")]))
        await XCTAssertThrowsMobileError(
            try await tool.execute(arguments: [:]),
            expected: .authenticationCancelled
        )
    }

    func testProviderCancellationPropagatesAsCancellationError() async throws {
        let tool = SecureAuthenticateTool(provider: CancellableAuthenticatorFake())
        let task = Task {
            try await tool.execute(arguments: [:])
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must escape instead of becoming a tool result")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testMigratedCapabilityCatalogIsTypedAndDoesNotExposeGenericBridge() {
        XCTAssertEqual(IOSCapabilityToolKit.approvedNames.count, 12)
        XCTAssertTrue(IOSCapabilityToolKit.approvedNames.contains("health_query"))
        XCTAssertTrue(IOSCapabilityToolKit.approvedNames.contains("speech_transcribe"))
        XCTAssertTrue(IOSCapabilityToolKit.approvedNames.contains("vision_analyze"))
        XCTAssertFalse(IOSCapabilityToolKit.approvedNames.contains("ios_native"))
    }

    func testNaturalLanguageAnalyzeRunsLocallyAndUsesStrictSchema() async throws {
        let tool = NaturalLanguageAnalyzeTool()
        XCTAssertThrowsError(try tool.validate(arguments: ["text": .string("hello"), "extra": .bool(true)]))
        XCTAssertThrowsError(try tool.validate(arguments: ["text": .string("hello"), "mode": .string("unknown")]))

        let output = try decodeObject(try await tool.execute(arguments: [
            "text": .string("Apple announced a great product in Cupertino."),
            "mode": .string("analyze")
        ]))
        XCTAssertEqual(output["mode"], .string("analyze"))
        XCTAssertNotNil(output["language"])
        XCTAssertNotNil(output["tokens"])
        XCTAssertNotNil(output["sentiment"])
    }

    private func decodeObject(_ text: String) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw TestFailure.notJSONObject
        }
        return object
    }
}

private enum TestFailure: Error {
    case notJSONObject
}

private func XCTAssertThrowsMobileError<T>(
    _ operation: @autoclosure () async throws -> T,
    expected: MobileNativeToolError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected MobileNativeToolError", file: file, line: line)
    } catch let error as MobileNativeToolError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

private actor LocationProviderFake: DeviceLocationProviding {
    let result: Result<DeviceLocationReading, MobileNativeToolError>
    private(set) var timeoutWasPositive = false

    init(result: Result<DeviceLocationReading, MobileNativeToolError>) {
        self.result = result
    }

    func currentLocation(timeout: Duration) throws -> DeviceLocationReading {
        timeoutWasPositive = timeout > .zero
        return try result.get()
    }
}

private actor MotionProviderFake: DeviceMotionActivityProviding {
    let result: Result<DeviceMotionActivityReading, MobileNativeToolError>
    private(set) var lastLookbackMinutes: Int?
    private(set) var timeoutWasPositive = false

    init(result: Result<DeviceMotionActivityReading, MobileNativeToolError>) {
        self.result = result
    }

    func recentActivity(
        lookbackMinutes: Int,
        timeout: Duration
    ) throws -> DeviceMotionActivityReading {
        lastLookbackMinutes = lookbackMinutes
        timeoutWasPositive = timeout > .zero
        return try result.get()
    }
}

private actor NotificationSchedulerFake: LocalNotificationScheduling {
    let result: Result<Void, MobileNativeToolError>
    private(set) var lastRequest: LocalNotificationScheduleRequest?
    private(set) var timeoutWasPositive = false

    init(result: Result<Void, MobileNativeToolError>) {
        self.result = result
    }

    func schedule(
        _ request: LocalNotificationScheduleRequest,
        timeout: Duration
    ) throws {
        lastRequest = request
        timeoutWasPositive = timeout > .zero
        try result.get()
    }
}

private actor AuthenticatorFake: DeviceOwnerAuthenticating {
    let result: Result<Void, MobileNativeToolError>
    private(set) var lastReason: String?
    private(set) var timeoutWasPositive = false

    init(result: Result<Void, MobileNativeToolError>) {
        self.result = result
    }

    func authenticateDeviceOwner(reason: String, timeout: Duration) throws {
        lastReason = reason
        timeoutWasPositive = timeout > .zero
        try result.get()
    }
}

private struct CancellableAuthenticatorFake: DeviceOwnerAuthenticating {
    func authenticateDeviceOwner(reason: String, timeout: Duration) async throws {
        try await Task.sleep(for: .seconds(30))
    }
}
