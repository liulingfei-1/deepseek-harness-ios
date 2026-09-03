import Foundation
import XCTest
@testable import HarnessMobile

@MainActor
final class AppModelProviderProfileTests: XCTestCase {
    func testSavingProfileAdvancesRequestRouteGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }
        let model = fixture.makeModel()
        let profile = try XCTUnwrap(model.activeProviderProfile)
        let configuration = try profile.configuration().validated()

        let before = try model.providerRequestRoute(for: configuration)
        try await model.saveProviderProfile(
            profile,
            apiKey: "generation-fixture-secret",
            makeActive: true,
            existingProfileID: profile.id
        )
        let after = try model.providerRequestRoute(for: configuration)

        XCTAssertEqual(before.profileID, profile.id)
        XCTAssertEqual(after.profileID, profile.id)
        XCTAssertEqual(after.generation, before.generation + 1)
        XCTAssertEqual(after.endpoint, before.endpoint)
        try await fixture.credentialStore.deleteAllAPIKeys()
    }

    func testSearchProviderCredentialLifecycleUsesCanonicalOrigin() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }
        let model = fixture.makeModel()
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "harness.web-search-provider")
        defer {
            if let previous { defaults.set(previous, forKey: "harness.web-search-provider") }
            else { defaults.removeObject(forKey: "harness.web-search-provider") }
        }

        model.setWebSearchProvider(ExaSearchProvider.identifierValue)
        try await model.saveSearchProviderAPIKey("exa-fixture-secret", providerID: ExaSearchProvider.identifierValue)
        let configuredStatus = await model.searchProviderCredentialStatus(for: ExaSearchProvider.identifierValue)
        XCTAssertEqual(configuredStatus, .configured)
        XCTAssertNotNil(model.configuredWebSearchProvider())

        try await model.deleteSearchProviderAPIKey(providerID: ExaSearchProvider.identifierValue)
        let missingStatus = await model.searchProviderCredentialStatus(for: ExaSearchProvider.identifierValue)
        XCTAssertEqual(missingStatus, .missing)
    }

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

    func testRemovingCompactionProviderAtomicallyReturnsSummaryRouteToInherited() async throws {
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
        let route = CompactionSummaryRoute(
            profileID: second.id,
            model: second.defaultModel
        )
        try model.setCompactionSummaryRoute(route)
        try model.setSessionTitleSettings(
            SessionTitleSettings(automaticMode: .allPrompts, route: route)
        )

        try await model.removeProviderProfile(id: second.id)

        XCTAssertNil(model.compactionSummaryRoute)
        XCTAssertEqual(model.sessionTitleSettings.automaticMode, .allPrompts)
        XCTAssertNil(model.sessionTitleSettings.route)
        XCTAssertNil(
            fixture.settingsStore.loadCompactionSummaryRoute(in: model.providerDirectory)
        )
        XCTAssertEqual(
            fixture.settingsStore.loadSessionTitleSettings(in: model.providerDirectory),
            SessionTitleSettings(automaticMode: .allPrompts, route: nil)
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

    func testSwitchingSessionsKeepsBothLiveRootRunsAndProjectsNonSelectedStatus() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanFilesAndDefaults() }
        let model = fixture.makeModel()
        await model.bootstrap()

        let firstID = try XCTUnwrap(model.activeSessionID)
        let firstIdentity = await model.sessionRunRegistry.allocateIdentity(sessionID: firstID)
        let first = try await model.sessionRunRegistry.register(identity: firstIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: firstID)
        }
        let didBeginFirstRun = await first.handle.beginRunning(for: firstIdentity)
        XCTAssertTrue(didBeginFirstRun)

        // Use the production new-session route. It must leave the first
        // session's root registered while making the new session active.
        await model.createConversation(title: "第二个会话")
        let secondID = try XCTUnwrap(model.activeSessionID)
        XCTAssertNotEqual(secondID, firstID)
        let firstLookupAfterCreate = await model.sessionRunRegistry.lookup(sessionID: firstID)
        XCTAssertNotNil(firstLookupAfterCreate)

        let secondIdentity = await model.sessionRunRegistry.allocateIdentity(sessionID: secondID)
        let secondRun = try await model.sessionRunRegistry.register(identity: secondIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: secondID)
        }
        let didBeginSecondRun = await secondRun.handle.beginRunning(for: secondIdentity)
        XCTAssertTrue(didBeginSecondRun)
        await model.switchConversation(to: firstID)

        XCTAssertEqual(model.activeSessionID, firstID)
        let firstLookup = await model.sessionRunRegistry.lookup(sessionID: firstID)
        let secondLookup = await model.sessionRunRegistry.lookup(sessionID: secondID)
        XCTAssertNotNil(firstLookup)
        XCTAssertNotNil(secondLookup)
        XCTAssertEqual(model.sessionRunSnapshots[firstID]?.identity, firstIdentity)
        XCTAssertEqual(model.sessionRunSnapshots[secondID]?.identity, secondIdentity)
        _ = await first.handle.dispose()
        _ = await secondRun.handle.dispose()
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

    var sessionStore: SessionStore {
        SessionStore(root: root.appendingPathComponent("Sessions"))
    }

    func makeModel() -> AppModel {
        AppModel(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            sessionStore: sessionStore,
            sessionQueryReadModel: SessionQueryReadModel(
                root: root.appendingPathComponent("SessionQuery.sqlite")
            ),
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
