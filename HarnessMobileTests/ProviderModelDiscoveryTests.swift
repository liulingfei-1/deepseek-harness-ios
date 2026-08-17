import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ProviderModelDiscoveryTests: XCTestCase {
    func testProviderCatalogIsVersionedAndKeepsDesktopDeepSeekDefaults() {
        XCTAssertEqual(ModelProviderCatalog.schemaVersion, 1)
        XCTAssertFalse(ModelProviderCatalog.version.isEmpty)
        XCTAssertEqual(
            ModelProviderCatalog.descriptor(for: .deepSeekOfficial)
                .builtInModels.map(\.id),
            ["deepseek-v4-flash", "deepseek-v4-pro"]
        )
    }

    func testAnthropicMessagesInferenceUsesBuiltInModelCatalog() throws {
        let descriptor = ModelProviderCatalog.descriptor(for: .anthropic)
        XCTAssertEqual(descriptor.wireProtocol, .anthropicMessages)
        XCTAssertTrue(descriptor.supportsCurrentInferenceWire)
        XCTAssertFalse(descriptor.supportsRemoteModelDiscovery)
        XCTAssertNotNil(descriptor.compatibilityNotice)

        let configuration = ModelProviderCatalog.applying(.anthropic, to: AgentConfiguration())
        XCTAssertEqual(
            try configuration.chatCompletionsURL().absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(try configuration.validated().providerID, .anthropic)
        XCTAssertEqual(
            ReasoningMode.supportedModes(for: .anthropic),
            [.providerDefault, .off]
        )
    }

    func testPresetEndpointsAndUnlistedModelPassThrough() throws {
        var openAI = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        openAI.model = "private-deployment-model"
        XCTAssertEqual(
            try openAI.chatCompletionsURL().absoluteString,
            "https://api.openai.com/v1/chat/completions"
        )
        XCTAssertEqual(
            try openAI.modelsURL().absoluteString,
            "https://api.openai.com/v1/models"
        )
        XCTAssertEqual(try openAI.validated().model, "private-deployment-model")

        let openRouter = ModelProviderCatalog.applying(.openRouter, to: AgentConfiguration())
        XCTAssertEqual(
            try openRouter.modelsURL().absoluteString,
            "https://openrouter.ai/api/v1/models"
        )
    }

    func testLegacyConfigurationInfersProviderAndUnknownProviderFallsBackToCustom() throws {
        let legacy = Data(
            """
            {"baseURL":"https://api.openai.com/v1","model":"gpt-5","reasoningMode":"providerDefault","maxSteps":8,"maxOutputTokens":4096}
            """.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AgentConfiguration.self, from: legacy).providerID,
            .openAI
        )

        let futureProvider = Data(
            """
            {"providerID":"future-provider","baseURL":"https://gateway.example/v1","model":"future-model","reasoningMode":"providerDefault","maxSteps":8,"maxOutputTokens":4096}
            """.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AgentConfiguration.self, from: futureProvider).providerID,
            .customOpenAICompatible
        )
    }

    func testOpenAIModelListFixtureDecodesLossilyWithStableSchema() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
            .appendingPathComponent("provider-models", isDirectory: true)
            .appendingPathComponent("openai-models-v1.json")
        let fixture = try JSONDecoder().decode(
            ProviderModelsFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.source.commit,
            "47f943859bef60e4160492346772ded9b24f765a"
        )
        let models = try OpenAIChatCompletionsAdapter()
            .decodeModelList(try JSONEncoder().encode(fixture.response))

        XCTAssertEqual(models.map(\.id), ["deepseek-v4-pro", "gateway-chat"])
        XCTAssertEqual(models[0].name, "DeepSeek V4 Pro")
        XCTAssertEqual(models[0].contextWindow, 1_000_000)
        XCTAssertEqual(models[0].maxOutputTokens, 262_144)
        XCTAssertEqual(models[1].contextWindow, 131_072)
        XCTAssertEqual(models[1].maxOutputTokens, 8_192)
        XCTAssertEqual(OpenAIChatCompletionsAdapter().modelListSchemaVersion, 1)
    }

    func testDiscoveryRejectsAnOriginThatDoesNotOwnTheCredential() async {
        let configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        let request = ModelDiscoveryRequest(
            configuration: configuration,
            apiKey: "fixture-secret-not-sent",
            trustedOrigin: "https://other.example:443"
        )

        do {
            _ = try await OpenAICompatibleClient().discoverModels(request)
            XCTFail("Expected an origin rejection before network access")
        } catch let error as ModelDiscoveryError {
            XCTAssertEqual(error, .untrustedOrigin)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCustomProviderCanDiscoverBeforeAModelIsSelected() async throws {
        var configuration = ModelProviderCatalog.applying(
            .customOpenAICompatible,
            to: AgentConfiguration()
        )
        configuration.baseURL = "https://gateway.example/openai/v1"
        XCTAssertTrue(configuration.model.isEmpty)
        XCTAssertEqual(
            try configuration.modelsURL().absoluteString,
            "https://gateway.example/openai/v1/models"
        )

        let request = ModelDiscoveryRequest(
            configuration: configuration,
            apiKey: nil,
            trustedOrigin: "https://not-the-configured-origin.example:443"
        )
        do {
            _ = try await OpenAICompatibleClient().discoverModels(request)
            XCTFail("Expected origin validation before network access")
        } catch let error as ModelDiscoveryError {
            XCTAssertEqual(error, .untrustedOrigin)
        }
    }

    func testVersionedCacheDoesNotPersistRawCredentialAndRejectsSchemaDrift() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let cache = ModelDiscoveryCache(
            directoryURL: directory,
            timeToLive: 3_600,
            now: { fixedDate }
        )
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example/v1/models"))
        let rawCredential = "fixture-secret-must-not-be-persisted"
        let key = ModelDiscoveryCacheKey(
            providerID: .customOpenAICompatible,
            endpoint: endpoint,
            apiKey: rawCredential
        )
        let models = [ProviderModel(id: "gateway-chat", name: "Gateway Chat")]

        try await cache.store(
            key: key,
            adapterSchemaVersion: 1,
            fetchedAt: fixedDate,
            models: models
        )
        let loaded = await cache.load(key: key, adapterSchemaVersion: 1)
        XCTAssertEqual(loaded?.source, .cache)
        XCTAssertEqual(loaded?.models, models)
        let adapterDrift = await cache.load(key: key, adapterSchemaVersion: 2)
        XCTAssertNil(adapterDrift)

        let fileURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first
        )
        let persisted = try Data(contentsOf: fileURL)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(rawCredential))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL, options: .atomic)
        let rejected = await cache.load(key: key, adapterSchemaVersion: 1)
        XCTAssertNil(rejected)
    }
}

private struct ProviderModelsFixture: Decodable {
    let schemaVersion: Int
    let source: Source
    let response: JSONValue

    struct Source: Decodable {
        let project: String
        let commit: String
        let contract: String
    }
}
