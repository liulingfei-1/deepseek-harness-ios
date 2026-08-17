import Foundation
import XCTest
@testable import HarnessMobile

@MainActor
final class AppModelProviderProfileTests: XCTestCase {
    func testBootstrapMigratesLegacyCredentialIntoProfileReference() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }

        var legacyConfiguration = ModelProviderCatalog.applying(
            .openAI,
            to: AgentConfiguration()
        )
        legacyConfiguration.maxSteps = 12
        legacyConfiguration.maxOutputTokens = 8_192
        try fixture.settingsStore.save(legacyConfiguration)
        let origin = try legacyConfiguration.credentialOrigin()
        try await fixture.credentialStore.saveAPIKey(
            "legacy-fixture-secret",
            for: origin
        )

        let model = fixture.makeModel()
        await model.bootstrap()

        let profile = try XCTUnwrap(model.activeProviderProfile)
        let migrated = try await fixture.credentialStore.readAPIKey(
            for: profile.credentialReference,
            expectedOrigin: origin
        )
        let legacy = try await fixture.credentialStore.readAPIKey(for: origin)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(migrated, "legacy-fixture-secret")
        XCTAssertNil(legacy)
        XCTAssertNil(fixture.settingsStore.loadProviderDirectory().legacyConfiguration)
        XCTAssertEqual(model.credentialStatuses[profile.id], .configured)

        try await fixture.credentialStore.deleteAllAPIKeys()
    }

    func testRemovingProfileDoesNotAffectAnotherProfileCredential() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }
        let model = fixture.makeModel()

        let first = try XCTUnwrap(model.activeProviderProfile)
        try await model.saveProviderProfile(
            first,
            apiKey: "deepseek-fixture-secret",
            makeActive: true,
            existingProfileID: first.id
        )
        let second = ProviderProfile.catalogDefault(for: .openAI)
        try await model.saveProviderProfile(
            second,
            apiKey: "openai-fixture-secret",
            makeActive: false
        )

        try await model.removeProviderProfile(id: first.id)

        let firstOrigin = try first.configuration().credentialOrigin()
        let secondOrigin = try second.configuration().credentialOrigin()
        let removed = try await fixture.credentialStore.readAPIKey(
            for: first.credentialReference,
            expectedOrigin: firstOrigin
        )
        let retained = try await fixture.credentialStore.readAPIKey(
            for: second.credentialReference,
            expectedOrigin: secondOrigin
        )
        XCTAssertNil(removed)
        XCTAssertEqual(retained, "openai-fixture-secret")
        XCTAssertNil(model.providerDirectory.profile(id: first.id))
        XCTAssertEqual(model.activeProviderProfile?.id, second.id)
        XCTAssertEqual(
            fixture.settingsStore.loadProviderDirectory().directory,
            model.providerDirectory
        )

        try await fixture.credentialStore.deleteAllAPIKeys()
    }

    func testDirectorySaveFailureLeavesCredentialAndProfileIntact() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }
        let model = fixture.makeModel()
        let profile = try XCTUnwrap(model.activeProviderProfile)
        let origin = try profile.configuration().credentialOrigin()

        try await fixture.credentialStore.saveAPIKey(
            "rollback-fixture-secret",
            for: profile.credentialReference,
            origin: origin
        )
        try fixture.settingsStore.save(model.providerDirectory)
        model.providerDirectory.schemaVersion = 999

        do {
            try await model.removeProviderProfile(id: profile.id)
            XCTFail("Expected provider directory validation to fail")
        } catch let error as ProviderProfileError {
            XCTAssertEqual(error, .unsupportedDirectorySchema(999))
        }

        let retained = try await fixture.credentialStore.readAPIKey(
            for: profile.credentialReference,
            expectedOrigin: origin
        )
        XCTAssertEqual(retained, "rollback-fixture-secret")
        XCTAssertNotNil(model.providerDirectory.profile(id: profile.id))
        XCTAssertNotNil(
            fixture.settingsStore.loadProviderDirectory().directory.profile(id: profile.id)
        )

        try await fixture.credentialStore.deleteAllAPIKeys()
    }

    func testMarketplaceFailureStaysFeatureLocalAndCancellationIsSilent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }
        let model = fixture.makeModel()

        model.reportISHPluginMarketplaceError(MarketplaceFixtureError.offline)

        XCTAssertEqual(model.ishPluginMarketplaceFailure?.message, "目录暂时不可用")
        XCTAssertFalse(model.ishPluginMarketplaceFailure?.canRetry ?? true)
        XCTAssertNil(model.errorMessage)

        model.clearISHPluginMarketplaceFailure()
        model.reportISHPluginMarketplaceError(CancellationError())
        XCTAssertNil(model.ishPluginMarketplaceFailure)
        XCTAssertNil(model.errorMessage)

        model.reportISHPluginMarketplaceError(URLError(.cancelled))
        XCTAssertNil(model.ishPluginMarketplaceFailure)
        XCTAssertNil(model.errorMessage)
    }

    private func makeFixture() throws -> AppModelProviderFixture {
        let identifier = UUID().uuidString
        let defaultsSuiteName = "com.llf.harnessmobile.provider-app-model.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-provider-\(identifier)", isDirectory: true)
        return AppModelProviderFixture(
            settingsStore: SettingsStore(defaults: defaults),
            credentialStore: CredentialStore(
                service: "com.llf.harnessmobile.provider-app-model.\(identifier)"
            ),
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName,
            root: root
        )
    }
}

private enum MarketplaceFixtureError: LocalizedError {
    case offline

    var errorDescription: String? { "目录暂时不可用" }
}

@MainActor
private struct AppModelProviderFixture {
    let settingsStore: SettingsStore
    let credentialStore: CredentialStore
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let root: URL

    func makeModel() -> AppModel {
        AppModel(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionStore: SessionStore(root: root.appendingPathComponent("Sessions")),
            workspaceStore: WorkspaceStore(root: root.appendingPathComponent("Workspace")),
            backgroundPreferences: BackgroundPreferencesModel(
                store: BackgroundPreferencesStore(
                    defaults: defaults,
                    key: "background.preferences.provider-tests"
                )
            )
        )
    }

    func cleanFilesAndDefaults() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
