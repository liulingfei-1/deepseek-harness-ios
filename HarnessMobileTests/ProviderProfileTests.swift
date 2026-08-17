import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ProviderProfileTests: XCTestCase {
    func testLegacySingleConnectionMigratesFromCompatibilityFixture() throws {
        let fixture: ProviderProfileMigrationFixture = try loadProviderFixture(
            "provider-profile-migration-v1.json"
        )
        XCTAssertEqual(fixture.schemaVersion, 1)

        let suiteName = "com.llf.harnessmobile.provider-migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        try store.save(fixture.legacyConfiguration)

        let loaded = store.loadProviderDirectory()
        let profile = try XCTUnwrap(loaded.directory.activeProfile)
        XCTAssertEqual(loaded.legacyConfiguration, fixture.legacyConfiguration)
        XCTAssertEqual(profile.id, fixture.expected.profileID)
        XCTAssertEqual(
            profile.credentialReference.rawValue,
            fixture.expected.credentialReference
        )
        XCTAssertEqual(profile.displayName, fixture.expected.displayName)
        XCTAssertEqual(profile.configuration().profileID, fixture.expected.profileID)

        try store.save(loaded.directory)
        let persisted = store.loadProviderDirectory()
        XCTAssertNil(persisted.legacyConfiguration)
        XCTAssertEqual(persisted.directory, loaded.directory)
    }

    func testCredentialReferenceCompatibilityFixtureUsesStableStringEncoding() throws {
        let fixture: CredentialReferenceFixture = try loadProviderFixture(
            "credential-ref-v1.json"
        )
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.encoded.rawValue, fixture.expectedRawValue)

        let encoded = try JSONEncoder().encode(fixture.encoded)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(fixture.expectedRawValue)\"")
        XCTAssertEqual(
            try JSONDecoder().decode(CredentialReference.self, from: encoded),
            fixture.encoded
        )
    }

    func testDirectoryFixtureRoundTripPreservesPermanentIDs() throws {
        let fixture: ProviderDirectoryFixture = try loadProviderFixture(
            "provider-directory-v1.json"
        )
        XCTAssertEqual(fixture.schemaVersion, 1)

        let directory = try fixture.directory.validated()
        XCTAssertEqual(directory.profiles.map(\.id), fixture.expectedProfileIDs)
        XCTAssertEqual(
            directory.profiles.map { $0.credentialReference.rawValue },
            fixture.expectedCredentialReferences
        )

        let data = try JSONEncoder().encode(directory)
        let decoded = try JSONDecoder().decode(ProviderProfileDirectory.self, from: data)
        XCTAssertEqual(try decoded.validated(), directory)
        XCTAssertEqual(
            decoded.activeProfile?.configuration().credentialReference,
            directory.activeProfile?.credentialReference
        )
    }

    func testDirectoryRejectsCredentialReferenceSharedByTwoProfiles() throws {
        let sharedReference = CredentialReference(rawValue: "provider.shared.api-key")
        let first = makeProfile(
            id: "deepseek-main",
            providerID: .deepSeekOfficial,
            credentialReference: sharedReference
        )
        let second = makeProfile(
            id: "openai-main",
            providerID: .openAI,
            credentialReference: sharedReference
        )
        let directory = ProviderProfileDirectory(
            activeProfileID: first.id,
            profiles: [first, second]
        )

        XCTAssertThrowsError(try directory.validated()) { error in
            XCTAssertEqual(
                error as? ProviderProfileError,
                .duplicateCredentialReference(sharedReference)
            )
        }
    }

    private func makeProfile(
        id: String,
        providerID: ModelProviderID,
        credentialReference: CredentialReference
    ) -> ProviderProfile {
        let descriptor = ModelProviderCatalog.descriptor(for: providerID)
        return ProviderProfile(
            id: id,
            displayName: descriptor.displayName,
            providerID: providerID,
            wireProtocol: descriptor.wireProtocol,
            baseURL: descriptor.defaultBaseURL,
            credentialReference: credentialReference,
            models: descriptor.builtInModels,
            defaultModel: descriptor.defaultModel,
            reasoningMode: descriptor.defaultReasoningMode,
            isCustom: false
        )
    }
}

final class ProviderCredentialIsolationTests: XCTestCase {
    func testMultipleProfileCredentialsCoexistAndDeleteIndependently() async throws {
        let store = CredentialStore(
            service: "com.llf.harnessmobile.provider-credentials.\(UUID().uuidString)"
        )
        let firstReference = CredentialReference(rawValue: "provider.first.api-key")
        let secondReference = CredentialReference(rawValue: "provider.second.api-key")
        let firstOrigin = "https://first.example:443"
        let secondOrigin = "https://second.example:443"

        do {
            try await store.saveAPIKey(
                "first-fixture-secret",
                for: firstReference,
                origin: firstOrigin
            )
            try await store.saveAPIKey(
                "second-fixture-secret",
                for: secondReference,
                origin: secondOrigin
            )

            let first = try await store.readAPIKey(
                for: firstReference,
                expectedOrigin: firstOrigin
            )
            let second = try await store.readAPIKey(
                for: secondReference,
                expectedOrigin: secondOrigin
            )
            XCTAssertEqual(first, "first-fixture-secret")
            XCTAssertEqual(second, "second-fixture-secret")

            try await store.deleteAPIKey(for: firstReference)
            let removed = try await store.readAPIKey(
                for: firstReference,
                expectedOrigin: firstOrigin
            )
            let retained = try await store.readAPIKey(
                for: secondReference,
                expectedOrigin: secondOrigin
            )
            XCTAssertNil(removed)
            XCTAssertEqual(retained, "second-fixture-secret")
            try await store.deleteAllAPIKeys()
        } catch {
            try? await store.deleteAllAPIKeys()
            throw error
        }
    }

    func testCredentialReadRejectsOriginMismatch() async throws {
        let store = CredentialStore(
            service: "com.llf.harnessmobile.provider-origin.\(UUID().uuidString)"
        )
        let reference = CredentialReference(rawValue: "provider.origin.api-key")

        do {
            try await store.saveAPIKey(
                "origin-fixture-secret",
                for: reference,
                origin: "https://expected.example:443"
            )

            do {
                _ = try await store.readAPIKey(
                    for: reference,
                    expectedOrigin: "https://other.example:443"
                )
                XCTFail("Expected the origin-bound credential read to fail")
            } catch CredentialStoreError.credentialOriginMismatch {
                // Expected.
            }

            let status = try await store.describeAPIKey(
                for: reference,
                expectedOrigin: "https://other.example:443"
            )
            XCTAssertEqual(status, .originMismatch)
            try await store.deleteAllAPIKeys()
        } catch {
            try? await store.deleteAllAPIKeys()
            throw error
        }
    }
}

private struct ProviderProfileMigrationFixture: Decodable {
    let schemaVersion: Int
    let legacyConfiguration: AgentConfiguration
    let expected: Expected

    struct Expected: Decodable {
        let profileID: String
        let credentialReference: String
        let displayName: String
    }
}

private struct CredentialReferenceFixture: Decodable {
    let schemaVersion: Int
    let encoded: CredentialReference
    let expectedRawValue: String
}

private struct ProviderDirectoryFixture: Decodable {
    let schemaVersion: Int
    let directory: ProviderProfileDirectory
    let expectedProfileIDs: [String]
    let expectedCredentialReferences: [String]
}

private func loadProviderFixture<T: Decodable>(_ name: String) throws -> T {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
        .appendingPathComponent("provider-models", isDirectory: true)
        .appendingPathComponent(name)
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: fixtureURL))
}
