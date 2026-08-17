import XCTest
@testable import HarnessMobile

@MainActor
final class AppModelModelDiscoveryTests: XCTestCase {
    func testTemporaryCredentialIsScopedToDiscoveryAndIsNotPersisted() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
            try? FileManager.default.removeItem(at: fixture.root)
        }

        var configuration = ModelProviderCatalog.applying(
            .customOpenAICompatible,
            to: AgentConfiguration()
        )
        configuration.baseURL = "https://gateway.example/openai/v1"
        XCTAssertTrue(configuration.model.isEmpty)

        let temporaryKey = "temporary-discovery-secret"
        _ = try await fixture.model.discoverModels(
            for: configuration,
            temporaryAPIKey: temporaryKey,
            forceRefresh: true
        )

        let capturedRequest = await fixture.discoverer.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.apiKey, temporaryKey)
        XCTAssertEqual(request.trustedOrigin, try configuration.credentialOrigin())
        XCTAssertTrue(request.forceRefresh)
        XCTAssertTrue(request.configuration.model.isEmpty)
        let persistedCredential = try await fixture.credentialStore.readAPIKey(
            for: configuration.credentialOrigin()
        )
        XCTAssertNil(persistedCredential)
        XCTAssertFalse(
            fixture.defaults.dictionaryRepresentation().description.contains(temporaryKey)
        )
    }

    func testDiscoveryFallsBackToCredentialBoundToCurrentOrigin() async throws {
        let fixture = try makeFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName)
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        let origin = try configuration.credentialOrigin()
        try await fixture.credentialStore.saveAPIKey("stored-origin-secret", for: origin)
        do {
            _ = try await fixture.model.discoverModels(for: configuration)

            let capturedRequest = await fixture.discoverer.lastRequest()
            let request = try XCTUnwrap(capturedRequest)
            XCTAssertEqual(request.apiKey, "stored-origin-secret")
            XCTAssertEqual(request.trustedOrigin, origin)
            XCTAssertFalse(request.forceRefresh)
            try await fixture.credentialStore.deleteAllAPIKeys()
        } catch {
            try? await fixture.credentialStore.deleteAllAPIKeys()
            throw error
        }
    }

    private func makeFixture() throws -> Fixture {
        let identifier = UUID().uuidString
        let defaultsSuiteName = "com.llf.harnessmobile.discovery-tests.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-model-discovery-\(identifier)", isDirectory: true)
        let credentialStore = CredentialStore(
            service: "com.llf.harnessmobile.discovery-tests.\(identifier)"
        )
        let discoverer = CapturingModelDiscoverer()
        let model = AppModel(
            settingsStore: SettingsStore(defaults: defaults),
            credentialStore: credentialStore,
            sessionStore: SessionStore(root: root.appendingPathComponent("Sessions")),
            workspaceStore: WorkspaceStore(root: root.appendingPathComponent("Workspace")),
            modelCatalogDiscoverer: discoverer,
            backgroundPreferences: BackgroundPreferencesModel(
                store: BackgroundPreferencesStore(
                    defaults: defaults,
                    key: "background.preferences.discovery-tests"
                )
            )
        )
        return Fixture(
            model: model,
            discoverer: discoverer,
            credentialStore: credentialStore,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName,
            root: root
        )
    }
}

private struct Fixture {
    let model: AppModel
    let discoverer: CapturingModelDiscoverer
    let credentialStore: CredentialStore
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let root: URL
}

private actor CapturingModelDiscoverer: ModelCatalogDiscovering {
    private var requests: [ModelDiscoveryRequest] = []

    func discoverModels(_ request: ModelDiscoveryRequest) async throws -> ModelCatalogSnapshot {
        requests.append(request)
        return ModelCatalogSnapshot(
            providerID: request.configuration.providerID,
            source: .remote,
            catalogVersion: "test",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            models: [ProviderModel(id: "fixture-model", name: "Fixture Model")]
        )
    }

    func lastRequest() -> ModelDiscoveryRequest? {
        requests.last
    }
}
