import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

@MainActor
final class BackgroundKeepAliveCoordinatorTests: XCTestCase {
    private func makeCoordinator() -> BackgroundKeepAliveCoordinator {
        BackgroundKeepAliveCoordinator(
            audio: BackgroundAudioKeepAlive(
                factory: FakeCoordinatorAudioFactory(),
                observeNotifications: false
            ),
            location: BackgroundLocationKeepAlive(
                platform: FakeCoordinatorLocationPlatform(authorization: .always),
                armDelayNanoseconds: 1_000_000
            )
        )
    }

    func testForegroundAndNoLiveRootNeverExposeExtendedLayer() {
        let coordinator = makeCoordinator()
        coordinator.update(
            BackgroundKeepAliveInputs(
                isBackgrounded: true,
                hasLiveRoot: false,
                enhancedAudioRequested: true,
                locationRequested: true,
                hasFiniteBackgroundLease: true,
                hasContinuedProcessing: true,
                isLowPowerMode: false,
                isThermallyConstrained: false
            )
        )

        XCTAssertEqual(coordinator.state.layers, [.foreground])
    }

    func testCoordinatorPublishesFiniteContinuedAndAudioLayers() {
        let coordinator = makeCoordinator()
        coordinator.update(
            BackgroundKeepAliveInputs(
                isBackgrounded: true,
                hasLiveRoot: true,
                enhancedAudioRequested: true,
                locationRequested: false,
                hasFiniteBackgroundLease: true,
                hasContinuedProcessing: true,
                isLowPowerMode: false,
                isThermallyConstrained: false
            )
        )

        XCTAssertTrue(coordinator.state.layers.contains(.finiteBackgroundTask))
        XCTAssertTrue(coordinator.state.layers.contains(.continuedProcessing))
        XCTAssertTrue(coordinator.state.layers.contains(.extendedAudio))
        XCTAssertTrue(coordinator.hasHealthyExtendedLease)
    }

    func testThermalAndLowPowerConstraintsArePublishedAsDegradedLayers() {
        let coordinator = makeCoordinator()
        coordinator.update(
            BackgroundKeepAliveInputs(
                isBackgrounded: true,
                hasLiveRoot: true,
                enhancedAudioRequested: false,
                locationRequested: false,
                hasFiniteBackgroundLease: false,
                hasContinuedProcessing: false,
                isLowPowerMode: true,
                isThermallyConstrained: true
            )
        )

        XCTAssertTrue(coordinator.state.layers.contains(.degraded(.lowPowerMode)))
        XCTAssertTrue(coordinator.state.layers.contains(.degraded(.thermalPressure)))
        XCTAssertEqual(
            Set(coordinator.state.degradedDetails),
            ["low_power_mode", "thermal_pressure"]
        )
    }

    func testPermissionRevocationAndAudioFailurePublishEvidenceWithoutSensitiveContent() async throws {
        let locationPlatform = FaultMatrixLocationPlatform(authorization: .denied)
        let coordinator = BackgroundKeepAliveCoordinator(
            audio: BackgroundAudioKeepAlive(
                factory: FaultMatrixFailingAudioFactory(),
                retryDelayNanoseconds: 1_000_000,
                observeNotifications: false
            ),
            location: BackgroundLocationKeepAlive(
                platform: locationPlatform,
                armDelayNanoseconds: 1_000_000
            )
        )

        coordinator.update(
            BackgroundKeepAliveInputs(
                isBackgrounded: true,
                hasLiveRoot: true,
                enhancedAudioRequested: true,
                locationRequested: true,
                hasFiniteBackgroundLease: false,
                hasContinuedProcessing: false,
                isLowPowerMode: false,
                isThermallyConstrained: false
            )
        )
        try await Task.sleep(nanoseconds: 15_000_000)

        XCTAssertTrue(coordinator.state.layers.contains(.degraded(.audioUnavailable)))
        XCTAssertTrue(coordinator.state.layers.contains(.degraded(.locationUnavailable)))
        XCTAssertTrue(coordinator.state.degradedDetails.contains("engineStartFailed"))
        XCTAssertTrue(coordinator.state.degradedDetails.contains("location_denied"))
        XCTAssertFalse(coordinator.state.degradedDetails.contains(where: {
            $0.contains("prompt") || $0.contains("tool") || $0.contains("secret")
        }))
    }

    func testOneHundredBackgroundLifecycleTransitionsLeaveNoStaleSurvivalLayer() {
        let coordinator = makeCoordinator()
        for index in 0..<100 {
            coordinator.update(
                BackgroundKeepAliveInputs(
                    isBackgrounded: index.isMultiple(of: 2),
                    hasLiveRoot: true,
                    enhancedAudioRequested: true,
                    locationRequested: false,
                    hasFiniteBackgroundLease: index.isMultiple(of: 3),
                    hasContinuedProcessing: index.isMultiple(of: 5),
                    isLowPowerMode: index.isMultiple(of: 7),
                    isThermallyConstrained: index.isMultiple(of: 11)
                )
            )
        }

        coordinator.update(
            BackgroundKeepAliveInputs(
                isBackgrounded: true,
                hasLiveRoot: true,
                enhancedAudioRequested: true,
                locationRequested: false,
                hasFiniteBackgroundLease: false,
                hasContinuedProcessing: false,
                isLowPowerMode: false,
                isThermallyConstrained: false
            )
        )

        XCTAssertFalse(coordinator.state.layers.contains(.foreground))
        XCTAssertTrue(coordinator.state.layers.contains(.extendedAudio))
        XCTAssertGreaterThanOrEqual(coordinator.state.generation, 99)

        coordinator.update(.idle)
        XCTAssertEqual(coordinator.state.layers, [.foreground])
        XCTAssertTrue(coordinator.state.degradedDetails.isEmpty)
        XCTAssertFalse(coordinator.hasHealthyExtendedLease)
    }
}

@MainActor
private final class FakeCoordinatorAudioEngine: BackgroundAudioKeepAliveEngine {
    var isHealthy = false
    func start() throws { isHealthy = true }
    func stop() { isHealthy = false }
}

@MainActor
private final class FakeCoordinatorAudioFactory: BackgroundAudioKeepAliveEngineFactory {
    func makeEngine() throws -> any BackgroundAudioKeepAliveEngine {
        FakeCoordinatorAudioEngine()
    }
}

@MainActor
private final class FakeCoordinatorLocationPlatform: BackgroundLocationKeepAlivePlatform {
    var authorization: BackgroundLocationAuthorization
    var onAuthorizationChanged: ((BackgroundLocationAuthorization) -> Void)?
    init(authorization: BackgroundLocationAuthorization) { self.authorization = authorization }
    func requestAlwaysAuthorization() {}
    func startCoarseBackgroundUpdates() {}
    func stopCoarseBackgroundUpdates() {}
    func beginBackgroundActivity() {}
    func endBackgroundActivity() {}
    func retractOrphanedBackgroundActivity() {}
}

@MainActor
private final class FaultMatrixFailingAudioEngine: BackgroundAudioKeepAliveEngine {
    var isHealthy = false
    func start() throws { throw BackgroundAudioKeepAliveError.engineStartFailed }
    func stop() { isHealthy = false }
}

@MainActor
private final class FaultMatrixFailingAudioFactory: BackgroundAudioKeepAliveEngineFactory {
    func makeEngine() throws -> any BackgroundAudioKeepAliveEngine {
        FaultMatrixFailingAudioEngine()
    }
}

@MainActor
private final class FaultMatrixLocationPlatform: BackgroundLocationKeepAlivePlatform {
    var authorization: BackgroundLocationAuthorization
    var onAuthorizationChanged: ((BackgroundLocationAuthorization) -> Void)?

    init(authorization: BackgroundLocationAuthorization) {
        self.authorization = authorization
    }

    func requestAlwaysAuthorization() {}
    func startCoarseBackgroundUpdates() {}
    func stopCoarseBackgroundUpdates() {}
    func beginBackgroundActivity() {}
    func endBackgroundActivity() {}
    func retractOrphanedBackgroundActivity() {}
}
