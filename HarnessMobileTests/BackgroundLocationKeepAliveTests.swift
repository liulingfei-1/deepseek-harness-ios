import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

@MainActor
private final class FakeBackgroundLocationKeepAlivePlatform: BackgroundLocationKeepAlivePlatform {
    var authorization: BackgroundLocationAuthorization
    var onAuthorizationChanged: ((BackgroundLocationAuthorization) -> Void)?
    private(set) var alwaysAuthorizationRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var beginActivityCount = 0
    private(set) var endActivityCount = 0
    private(set) var orphanRetractCount = 0

    init(authorization: BackgroundLocationAuthorization) {
        self.authorization = authorization
    }

    func requestAlwaysAuthorization() {
        alwaysAuthorizationRequestCount += 1
    }

    func startCoarseBackgroundUpdates() {
        startCount += 1
    }

    func stopCoarseBackgroundUpdates() {
        stopCount += 1
    }

    func beginBackgroundActivity() {
        beginActivityCount += 1
    }

    func endBackgroundActivity() {
        endActivityCount += 1
    }

    func retractOrphanedBackgroundActivity() {
        orphanRetractCount += 1
    }

    func setAuthorization(_ authorization: BackgroundLocationAuthorization) {
        self.authorization = authorization
        onAuthorizationChanged?(authorization)
    }
}

@MainActor
final class BackgroundLocationKeepAliveTests: XCTestCase {
    func testDisabledLocationLegNeverRequestsAlwaysAuthorization() {
        let platform = FakeBackgroundLocationKeepAlivePlatform(authorization: .notDetermined)
        let keepAlive = BackgroundLocationKeepAlive(platform: platform)

        keepAlive.requestAlwaysAuthorizationIfEnabled()

        XCTAssertEqual(platform.alwaysAuthorizationRequestCount, 0)
        XCTAssertEqual(platform.orphanRetractCount, 1)
    }

    func testWhenInUseAuthorizationDegradesWithoutStartingUpdates() {
        let platform = FakeBackgroundLocationKeepAlivePlatform(authorization: .whenInUse)
        let keepAlive = BackgroundLocationKeepAlive(platform: platform)

        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        keepAlive.requestAlwaysAuthorizationIfEnabled()

        XCTAssertEqual(keepAlive.snapshot.phase, .degraded(.whenInUse))
        XCTAssertEqual(platform.alwaysAuthorizationRequestCount, 1)
        XCTAssertEqual(platform.startCount, 0)
        XCTAssertEqual(platform.beginActivityCount, 0)
    }

    func testAlwaysAuthorizationStartsOnlyAfterBackgroundDelayAndLiveRoot() async throws {
        let platform = FakeBackgroundLocationKeepAlivePlatform(authorization: .always)
        let keepAlive = BackgroundLocationKeepAlive(
            platform: platform,
            armDelayNanoseconds: 20_000_000
        )

        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        XCTAssertEqual(keepAlive.snapshot.phase, .waitingForDelay)
        XCTAssertEqual(platform.startCount, 0)

        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(keepAlive.snapshot.phase, .running)
        XCTAssertEqual(platform.beginActivityCount, 1)
        XCTAssertEqual(platform.startCount, 1)
    }

    func testReturningForegroundCancelsPendingDelayBeforeItCanStart() async throws {
        let platform = FakeBackgroundLocationKeepAlivePlatform(authorization: .always)
        let keepAlive = BackgroundLocationKeepAlive(
            platform: platform,
            armDelayNanoseconds: 40_000_000
        )

        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        keepAlive.update(isBackgrounded: false, requested: true, hasLiveRoot: true)
        try await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertEqual(keepAlive.snapshot.phase, .idle)
        XCTAssertEqual(platform.startCount, 0)
        XCTAssertEqual(platform.beginActivityCount, 0)
    }

    func testNewGenerationPreventsAnOlderDelayFromReversingCurrentState() async throws {
        let platform = FakeBackgroundLocationKeepAlivePlatform(authorization: .always)
        let keepAlive = BackgroundLocationKeepAlive(
            platform: platform,
            armDelayNanoseconds: 40_000_000
        )

        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        let firstGeneration = keepAlive.snapshot.generation
        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: false)
        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        XCTAssertGreaterThan(keepAlive.snapshot.generation, firstGeneration)

        try await Task.sleep(nanoseconds: 70_000_000)

        XCTAssertEqual(keepAlive.snapshot.phase, .running)
        XCTAssertEqual(platform.startCount, 1)
        XCTAssertEqual(platform.beginActivityCount, 1)
    }

    func testLastLiveRootAndAuthorizationRevocationStopImmediately() async throws {
        let platform = FakeBackgroundLocationKeepAlivePlatform(authorization: .always)
        let keepAlive = BackgroundLocationKeepAlive(
            platform: platform,
            armDelayNanoseconds: 10_000_000
        )

        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: false)

        XCTAssertEqual(keepAlive.snapshot.phase, .idle)
        XCTAssertEqual(platform.stopCount, 1)
        XCTAssertEqual(platform.endActivityCount, 1)

        keepAlive.update(isBackgrounded: true, requested: true, hasLiveRoot: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        platform.setAuthorization(.denied)

        XCTAssertEqual(keepAlive.snapshot.phase, .degraded(.denied))
        XCTAssertEqual(platform.stopCount, 2)
        XCTAssertEqual(platform.endActivityCount, 2)
    }
}
