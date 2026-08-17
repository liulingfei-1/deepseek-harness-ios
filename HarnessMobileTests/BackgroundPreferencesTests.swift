import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

@available(macOS 14.0, *)
@MainActor
final class BackgroundPreferencesTests: XCTestCase {
    func testStoreDefaultsArePrivacyPreserving() {
        let defaults = makeDefaults()
        let store = BackgroundPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.load(), .defaults)
        XCTAssertFalse(store.load().isEnhancedBackgroundEnabled)
        XCTAssertTrue(store.load().isLiveActivityEnabled)
        XCTAssertFalse(store.load().areTaskNotificationsEnabled)
        XCTAssertTrue(store.load().isPrivacyModeEnabled)
    }

    func testStoreRoundTripsCodablePreferences() throws {
        let defaults = makeDefaults()
        let store = BackgroundPreferencesStore(defaults: defaults)
        let expected = BackgroundPreferences(
            isEnhancedBackgroundEnabled: true,
            isLiveActivityEnabled: false,
            areTaskNotificationsEnabled: true,
            isPrivacyModeEnabled: false
        )

        try store.save(expected)

        XCTAssertEqual(store.load(), expected)
    }

    func testModelPersistsEachPreferenceChange() {
        let defaults = makeDefaults()
        let store = BackgroundPreferencesStore(defaults: defaults)
        let model = BackgroundPreferencesModel(store: store)

        model.isEnhancedBackgroundEnabled = true
        model.isLiveActivityEnabled = false
        model.areTaskNotificationsEnabled = true
        model.isPrivacyModeEnabled = false

        XCTAssertEqual(store.load(), model.value)
        XCTAssertNil(model.persistenceErrorDescription)
    }

    func testClearRestoresDefaults() throws {
        let defaults = makeDefaults()
        let store = BackgroundPreferencesStore(defaults: defaults)
        try store.save(
            BackgroundPreferences(
                isEnhancedBackgroundEnabled: true,
                isLiveActivityEnabled: false,
                areTaskNotificationsEnabled: true,
                isPrivacyModeEnabled: false
            )
        )

        store.clear()

        XCTAssertEqual(store.load(), .defaults)
    }

    func testLegacyPayloadDefaultsLiveActivityWithoutDiscardingOtherValues() throws {
        let defaults = makeDefaults()
        let key = "background.preferences.v1"
        defaults.set(
            Data(#"{"isEnhancedBackgroundEnabled":true,"areTaskNotificationsEnabled":true,"isPrivacyModeEnabled":false}"#.utf8),
            forKey: key
        )

        let loaded = BackgroundPreferencesStore(defaults: defaults, key: key).load()

        XCTAssertTrue(loaded.isEnhancedBackgroundEnabled)
        XCTAssertTrue(loaded.isLiveActivityEnabled)
        XCTAssertTrue(loaded.areTaskNotificationsEnabled)
        XCTAssertFalse(loaded.isPrivacyModeEnabled)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "BackgroundPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
