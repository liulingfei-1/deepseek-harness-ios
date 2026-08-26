import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

private final class FakeAudioSessionPlatform: HarnessAudioSessionPlatform {
    var state: HarnessAudioSessionState
    var categoryCalls: [(HarnessAudioSessionCategory, HarnessAudioSessionMode, HarnessAudioSessionOptions)] = []
    var activeCalls: [Bool] = []

    init(state: HarnessAudioSessionState) {
        self.state = state
    }

    func setCategory(
        _ category: HarnessAudioSessionCategory,
        mode: HarnessAudioSessionMode,
        options: HarnessAudioSessionOptions
    ) throws {
        categoryCalls.append((category, mode, options))
        state.category = category
        state.mode = mode
        state.options = options
    }

    func setActive(_ active: Bool) throws {
        activeCalls.append(active)
        state.isActive = active
    }
}

@MainActor
final class HarnessAudioSessionCoordinatorTests: XCTestCase {
    func testReferenceCountingAndOriginalStateRestoration() {
        let original = HarnessAudioSessionState(category: .playback, mode: .default, options: [], isActive: false)
        let platform = FakeAudioSessionPlatform(state: original)
        let coordinator = HarnessAudioSessionCoordinator(platform: platform, observeNotifications: false)

        coordinator.begin(.backgroundKeepAlive)
        coordinator.begin(.backgroundKeepAlive)
        XCTAssertEqual(coordinator.snapshot.counts[.backgroundKeepAlive], 2)
        XCTAssertEqual(platform.state.options, [.mixWithOthers])
        coordinator.end(.backgroundKeepAlive)
        XCTAssertEqual(coordinator.snapshot.counts[.backgroundKeepAlive], 1)
        XCTAssertTrue(platform.state.isActive)
        coordinator.end(.backgroundKeepAlive)
        XCTAssertEqual(platform.state, original)
        XCTAssertEqual(coordinator.snapshot.highestIntent, nil)
    }

    func testHighestPriorityProfileWinsAndCaptureReplacesKeepAliveAndTTS() {
        let platform = FakeAudioSessionPlatform(
            state: HarnessAudioSessionState(category: .playback, mode: .default, options: [], isActive: false)
        )
        let coordinator = HarnessAudioSessionCoordinator(platform: platform, observeNotifications: false)

        coordinator.begin(.backgroundKeepAlive)
        coordinator.begin(.replyTTS)
        XCTAssertEqual(coordinator.snapshot.highestIntent, .replyTTS)
        XCTAssertEqual(platform.state.mode, .spokenAudio)
        coordinator.begin(.capture)
        XCTAssertEqual(coordinator.snapshot.highestIntent, .capture)
        XCTAssertEqual(platform.state.category, .record)
        coordinator.end(.capture)
        XCTAssertEqual(coordinator.snapshot.highestIntent, .replyTTS)
        XCTAssertEqual(platform.state.mode, .spokenAudio)
        coordinator.end(.replyTTS)
        XCTAssertEqual(coordinator.snapshot.highestIntent, .backgroundKeepAlive)
        XCTAssertEqual(platform.state.options, [.mixWithOthers])
        coordinator.end(.backgroundKeepAlive)
    }

    func testInterruptionRouteAndMediaResetReapplyCurrentIntent() {
        let platform = FakeAudioSessionPlatform(
            state: HarnessAudioSessionState(category: .playback, mode: .default, options: [], isActive: false)
        )
        let coordinator = HarnessAudioSessionCoordinator(platform: platform, observeNotifications: false)
        coordinator.begin(.replyTTS)
        let initialCategoryCalls = platform.categoryCalls.count

        coordinator.handleInterruptionBegan()
        XCTAssertTrue(coordinator.snapshot.interrupted)
        XCTAssertEqual(platform.activeCalls.last, false)
        coordinator.handleInterruptionEnded()
        XCTAssertFalse(coordinator.snapshot.interrupted)
        XCTAssertEqual(platform.activeCalls.last, true)

        coordinator.handleRouteChange()
        XCTAssertGreaterThan(platform.categoryCalls.count, initialCategoryCalls)
        coordinator.handleMediaServicesReset()
        XCTAssertEqual(coordinator.snapshot.lastEvent, .mediaServicesReset)
        XCTAssertEqual(platform.state.mode, .spokenAudio)
        XCTAssertTrue(platform.state.isActive)
    }
}
