import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class AgentConfigurationTests: XCTestCase {
    func testDeepSeekRootUsesChatCompletionsWithoutV1() throws {
        var configuration = AgentConfiguration()
        configuration.baseURL = "https://api.deepseek.com/"

        XCTAssertEqual(
            try configuration.chatCompletionsURL().absoluteString,
            "https://api.deepseek.com/chat/completions"
        )
    }

    func testOpenAICompatiblePathIsPreserved() throws {
        var configuration = AgentConfiguration()
        configuration.baseURL = "https://example.com/openai/v1/"

        XCTAssertEqual(
            try configuration.chatCompletionsURL().absoluteString,
            "https://example.com/openai/v1/chat/completions"
        )
    }

    func testExistingEndpointIsNotDuplicated() throws {
        var configuration = AgentConfiguration()
        configuration.baseURL = "https://example.com/v1/chat/completions"

        XCTAssertEqual(
            try configuration.chatCompletionsURL().absoluteString,
            "https://example.com/v1/chat/completions"
        )
    }

    func testUnsafeURLFormsAreRejected() {
        for value in [
            "http://api.deepseek.com",
            "https://user:password@example.com",
            "https://example.com?debug=true",
            "https://example.com/#fragment"
        ] {
            var configuration = AgentConfiguration()
            configuration.baseURL = value
            XCTAssertThrowsError(try configuration.chatCompletionsURL(), value)
        }
    }

    func testCredentialOriginBindsKeyToSchemeHostAndEffectivePort() throws {
        var first = AgentConfiguration()
        first.baseURL = "https://EXAMPLE.com/custom/path"
        XCTAssertEqual(try first.credentialOrigin(), "https://example.com:443")

        first.baseURL = "https://example.com:8443/custom/path"
        XCTAssertEqual(try first.credentialOrigin(), "https://example.com:8443")
    }
}

final class CredentialStoreTests: XCTestCase {
    func testReplacingOriginRemovesEveryOlderCredential() async throws {
        let store = CredentialStore(
            service: "com.llf.harnessmobile.tests.\(UUID().uuidString)"
        )

        do {
            try await store.saveAPIKey("first-secret", for: "https://first.example:443")
            try await store.saveAPIKey("orphan-secret", for: "https://orphan.example:443")
            try await store.replaceAllAPIKeys(
                with: "replacement-secret",
                for: "https://second.example:443"
            )

            let first = try await store.readAPIKey(for: "https://first.example:443")
            let orphan = try await store.readAPIKey(for: "https://orphan.example:443")
            let replacement = try await store.readAPIKey(for: "https://second.example:443")
            XCTAssertNil(first)
            XCTAssertNil(orphan)
            XCTAssertEqual(replacement, "replacement-secret")

            try await store.deleteAllAPIKeys()
            let removed = try await store.readAPIKey(for: "https://second.example:443")
            XCTAssertNil(removed)
        } catch {
            try? await store.deleteAllAPIKeys()
            throw error
        }
    }
}
