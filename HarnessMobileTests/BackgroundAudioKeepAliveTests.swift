import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

@MainActor
private final class FakeKeepAliveEngine: BackgroundAudioKeepAliveEngine {
    var isHealthy = false
    var startCount = 0
    var stopCount = 0
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func start() throws {
        startCount += 1
        if shouldFail {
            throw BackgroundAudioKeepAliveError.engineStartFailed
        }
        isHealthy = true
    }

    func stop() {
        stopCount += 1
        isHealthy = false
    }
}

@MainActor
private final class FakeKeepAliveFactory: BackgroundAudioKeepAliveEngineFactory {
    var engines: [FakeKeepAliveEngine] = []
    let shouldFail: Bool

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func makeEngine() throws -> any BackgroundAudioKeepAliveEngine {
        let engine = FakeKeepAliveEngine(shouldFail: shouldFail)
        engines.append(engine)
        return engine
    }
}

@MainActor
final class BackgroundAudioKeepAliveTests: XCTestCase {
    func testOnlyBackgroundRequestedRunStartsEngineAndForegroundStopIsDebounced() async throws {
        let factory = FakeKeepAliveFactory()
        let keepAlive = BackgroundAudioKeepAlive(
            factory: factory,
            stopDebounceNanoseconds: 50_000_000,
            retryDelayNanoseconds: 10_000_000,
            observeNotifications: false
        )

        keepAlive.update(isBackgrounded: false, requested: true)
        XCTAssertEqual(keepAlive.snapshot.phase, .idle)
        keepAlive.update(isBackgrounded: true, requested: true)
        XCTAssertEqual(keepAlive.snapshot.phase, .running)
        XCTAssertEqual(factory.engines.count, 1)

        keepAlive.update(isBackgrounded: false, requested: true)
        XCTAssertEqual(keepAlive.snapshot.phase, .running)
        keepAlive.update(isBackgrounded: true, requested: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(keepAlive.snapshot.phase, .running)
        XCTAssertEqual(factory.engines.count, 1)

        keepAlive.update(isBackgrounded: false, requested: false)
        XCTAssertEqual(keepAlive.snapshot.phase, .idle)
    }

    func testMediaSuspendUsesRefcountAndRestoresOnlyAfterLastResume() {
        let factory = FakeKeepAliveFactory()
        let keepAlive = BackgroundAudioKeepAlive(
            factory: factory,
            observeNotifications: false
        )
        keepAlive.update(isBackgrounded: true, requested: true)
        keepAlive.suspendForMedia()
        keepAlive.suspendForMedia()
        XCTAssertEqual(keepAlive.snapshot.suspendCount, 2)
        XCTAssertEqual(keepAlive.snapshot.phase, .suspended)
        keepAlive.resumeForMedia()
        XCTAssertEqual(keepAlive.snapshot.suspendCount, 1)
        XCTAssertEqual(keepAlive.snapshot.phase, .suspended)
        keepAlive.resumeForMedia()
        XCTAssertEqual(keepAlive.snapshot.suspendCount, 0)
        XCTAssertEqual(keepAlive.snapshot.phase, .running)
    }

    func testFailedStartRetriesThreeTimesThenReleasesIntentAndDegrades() async throws {
        let factory = FakeKeepAliveFactory(shouldFail: true)
        let keepAlive = BackgroundAudioKeepAlive(
            factory: factory,
            retryDelayNanoseconds: 10_000_000,
            observeNotifications: false
        )
        keepAlive.update(isBackgrounded: true, requested: true)
        // Each start attempt touches the real AVAudioSession, which on the
        // simulator can block the main actor for well over the 10ms retry
        // delay, so a fixed sleep under-waits and flaked. Poll instead.
        try await pollUntil(timeoutNanoseconds: 5_000_000_000) {
            factory.engines.count >= 3
        }
        XCTAssertEqual(factory.engines.count, 3)
        XCTAssertEqual(keepAlive.snapshot.phase, .degraded)
        XCTAssertEqual(keepAlive.snapshot.attempt, 3)

        keepAlive.update(isBackgrounded: false, requested: false)
        XCTAssertEqual(keepAlive.snapshot.phase, .idle)
    }

    /// Polls a condition on the main actor until it holds or the wall-clock
    /// budget is spent.
    @MainActor
    private func pollUntil(
        timeoutNanoseconds: UInt64,
        condition: @escaping () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met within timeout")
    }

    func testNewBackgroundGenerationGetsFreshRetryBudgetAfterDegradation() async throws {
        let factory = FakeKeepAliveFactory(shouldFail: true)
        let keepAlive = BackgroundAudioKeepAlive(
            factory: factory,
            retryDelayNanoseconds: 10_000_000,
            observeNotifications: false
        )
        keepAlive.update(isBackgrounded: true, requested: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(factory.engines.count, 3)
        XCTAssertEqual(keepAlive.snapshot.phase, .degraded)

        keepAlive.update(isBackgrounded: false, requested: true)
        keepAlive.update(isBackgrounded: true, requested: true)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(factory.engines.count, 6)
        XCTAssertEqual(keepAlive.snapshot.phase, .degraded)
        XCTAssertEqual(keepAlive.snapshot.attempt, 3)
    }

    func testGenerationBoundSystemResetRestartsCurrentEngine() {
        let factory = FakeKeepAliveFactory()
        let keepAlive = BackgroundAudioKeepAlive(factory: factory, observeNotifications: false)
        keepAlive.update(isBackgrounded: true, requested: true)
        let firstGeneration = keepAlive.snapshot.generation
        keepAlive.handleMediaServicesReset()
        XCTAssertGreaterThan(keepAlive.snapshot.generation, firstGeneration)
        XCTAssertEqual(factory.engines.count, 2)
        XCTAssertEqual(keepAlive.snapshot.phase, .running)
    }
}
