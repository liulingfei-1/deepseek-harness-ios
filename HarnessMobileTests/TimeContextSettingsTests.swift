import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class TimeContextSettingsTests: XCTestCase {
    func testSettingsPersistAndInvalidValuesFallBackToDisabledDefaults() throws {
        let suiteName = "com.llf.harnessmobile.time-context.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let settings = TimeContextSettings(
            isEnabled: true,
            timeZoneIdentifier: "UTC",
            refreshIntervalMilliseconds: 300_000
        )

        try store.saveTimeContextSettings(settings)
        XCTAssertEqual(store.loadTimeContextSettings(), settings)

        defaults.set(Data("not-json".utf8), forKey: "agent.time-context.v1")
        XCTAssertEqual(store.loadTimeContextSettings(), TimeContextSettings())
        XCTAssertThrowsError(
            try store.saveTimeContextSettings(
                TimeContextSettings(
                    isEnabled: true,
                    timeZoneIdentifier: "not/a-real-zone",
                    refreshIntervalMilliseconds: 0
                )
            )
        )
    }

    func testOverlayUsesSelectedZoneAndExactElapsedBaseline() throws {
        let previous = AgentMessage(
            role: .assistant,
            content: "done",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let now = Date(timeIntervalSince1970: 1_700_000_125)
        let injection = try XCTUnwrap(
            TimeContextOverlay.injection(
                settings: TimeContextSettings(
                    isEnabled: true,
                    timeZoneIdentifier: "UTC",
                    refreshIntervalMilliseconds: 0
                ),
                messages: [previous],
                turn: 3,
                step: 1,
                now: now
            )
        )

        XCTAssertTrue(injection.content.contains("turn 3, step 1"))
        XCTAssertTrue(injection.content.contains("+00:00[UTC]"))
        XCTAssertTrue(injection.content.contains("2m 5s"))
        XCTAssertEqual(
            injection.source.objectValue?["plugin"]?.stringValue,
            TimeContextOverlay.pluginID
        )
    }

    func testRefreshIntervalSkipsWithoutMutatingStablePrefix() throws {
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try XCTUnwrap(
            TimeContextOverlay.injection(
                settings: TimeContextSettings(
                    isEnabled: true,
                    timeZoneIdentifier: "UTC",
                    refreshIntervalMilliseconds: 60_000
                ),
                messages: [],
                turn: 1,
                step: 1,
                now: firstDate
            )
        )
        let durable = AgentMessage(
            role: .user,
            content: first.content,
            source: first.source,
            createdAt: firstDate
        )

        XCTAssertNil(
            try TimeContextOverlay.injection(
                settings: TimeContextSettings(
                    isEnabled: true,
                    timeZoneIdentifier: "UTC",
                    refreshIntervalMilliseconds: 60_000
                ),
                messages: [durable],
                turn: 1,
                step: 2,
                now: firstDate.addingTimeInterval(59)
            )
        )
        XCTAssertNotNil(
            try TimeContextOverlay.injection(
                settings: TimeContextSettings(
                    isEnabled: true,
                    timeZoneIdentifier: "UTC",
                    refreshIntervalMilliseconds: 60_000
                ),
                messages: [durable],
                turn: 1,
                step: 2,
                now: firstDate.addingTimeInterval(60)
            )
        )
    }
}
