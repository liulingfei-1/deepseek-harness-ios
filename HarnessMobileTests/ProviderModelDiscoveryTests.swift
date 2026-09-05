import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ProviderModelDiscoveryTests: XCTestCase {
    override func tearDown() {
        ProviderDiscoveryURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testProviderCapabilityCacheReplacesSnapshotOnRefreshAndRemovesProfile() async {
        let cache = ProviderCapabilityCache()
        let first = ModelCatalogSnapshot(
            providerID: .openAI,
            source: .remote,
            catalogVersion: "v1",
            fetchedAt: Date(timeIntervalSince1970: 1),
            models: [ProviderModel(id: "gpt-5")]
        )
        let second = ModelCatalogSnapshot(
            providerID: .openAI,
            source: .remote,
            catalogVersion: "v2",
            fetchedAt: Date(timeIntervalSince1970: 2),
            models: [ProviderModel(id: "gpt-5-mini")]
        )
        await cache.update(profileID: "openai", snapshot: first)
        let firstSnapshot = await cache.snapshot(profileID: "openai")
        XCTAssertEqual(firstSnapshot?.catalog.catalogVersion, "v1")
        await cache.update(profileID: "openai", snapshot: second)
        let secondSnapshot = await cache.snapshot(profileID: "openai")
        XCTAssertEqual(secondSnapshot?.catalog.models.map(\.id), ["gpt-5-mini"])
        XCTAssertEqual(secondSnapshot?.reasoningModes, ReasoningMode.allCases)
        await cache.remove(profileID: "openai")
        let removed = await cache.snapshot(profileID: "openai")
        XCTAssertNil(removed)
    }

    func testProviderCapabilityCacheRestoresAcrossInstancesAndPersistsRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-capabilities-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("snapshots.json")
        let snapshot = ModelCatalogSnapshot(
            providerID: .anthropic,
            source: .builtIn,
            catalogVersion: "catalog-v1",
            fetchedAt: Date(timeIntervalSince1970: 10),
            models: [ProviderModel(id: "claude-sonnet-4-5", inputModalities: [.text, .image])]
        )

        let first = ProviderCapabilityCache(storageURL: storageURL)
        await first.update(profileID: "profile-anthropic", snapshot: snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        let reloaded = ProviderCapabilityCache(storageURL: storageURL)
        let restored = await reloaded.snapshot(profileID: "profile-anthropic")
        XCTAssertEqual(restored?.catalog.models, snapshot.models)
        XCTAssertEqual(restored?.catalog.source, .builtIn)

        await reloaded.remove(profileID: "profile-anthropic")
        let removed = ProviderCapabilityCache(storageURL: storageURL)
        let removedSnapshot = await removed.snapshot(profileID: "profile-anthropic")
        XCTAssertNil(removedSnapshot)
    }

    func testProviderCatalogIsVersionedAndKeepsDesktopDeepSeekDefaults() {
        XCTAssertEqual(ModelProviderCatalog.schemaVersion, 1)
        XCTAssertFalse(ModelProviderCatalog.version.isEmpty)
        XCTAssertEqual(
            ModelProviderCatalog.descriptor(for: .deepSeekOfficial)
                .builtInModels.map(\.id),
            ["deepseek-v4-flash", "deepseek-v4-pro", "deepseek-v4-flash-vision-exp"]
        )
        let vision = ModelProviderCatalog.descriptor(for: .deepSeekOfficial)
            .builtInModels.first { $0.id == "deepseek-v4-flash-vision-exp" }
        XCTAssertEqual(vision?.inputModalities, [.text, .image])
    }

    func testAnthropicMessagesInferenceUsesBuiltInModelCatalog() throws {
        let descriptor = ModelProviderCatalog.descriptor(for: .anthropic)
        XCTAssertEqual(descriptor.wireProtocol, .anthropicMessages)
        XCTAssertTrue(descriptor.supportsCurrentInferenceWire)
        XCTAssertTrue(descriptor.supportsRemoteModelDiscovery)
        XCTAssertNotNil(descriptor.compatibilityNotice)

        let configuration = ModelProviderCatalog.applying(.anthropic, to: AgentConfiguration())
        XCTAssertEqual(
            try configuration.chatCompletionsURL().absoluteString,
            "https://api.anthropic.com/v1/messages"
        )
        XCTAssertEqual(try configuration.validated().providerID, .anthropic)
        XCTAssertEqual(
            ReasoningMode.supportedModes(for: .anthropic),
            ReasoningMode.allCases
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

        XCTAssertEqual(
            models.map(\.id),
            ["deepseek-v4-pro", "gateway-chat", "deepseek-v4-flash-vision-exp"]
        )
        XCTAssertEqual(models[0].name, "DeepSeek V4 Pro")
        XCTAssertEqual(models[0].contextWindow, 1_000_000)
        XCTAssertEqual(models[0].maxOutputTokens, 262_144)
        XCTAssertEqual(models[0].inputModalities, [.text])
        XCTAssertEqual(models[1].contextWindow, 131_072)
        XCTAssertEqual(models[1].maxOutputTokens, 8_192)
        XCTAssertEqual(models[1].inputModalities, [.text])
        XCTAssertEqual(models[2].inputModalities, [.text, .image])
        XCTAssertEqual(OpenAIChatCompletionsAdapter().modelListSchemaVersion, 1)
    }

    func testRemoteModelImageCapabilityRequiresExplicitValidatedModalities() throws {
        XCTAssertEqual(
            OpenAIChatCompletionsAdapter.validatedInputModalities(["text", "image"]),
            [.text, .image]
        )
        XCTAssertEqual(
            OpenAIChatCompletionsAdapter.validatedInputModalities(["text", "audio", "image"]),
            [.text]
        )
        XCTAssertEqual(
            OpenAIChatCompletionsAdapter.validatedInputModalities(["image"]),
            [.text]
        )

        let data = Data(
            #"{"data":[{"id":"vision-by-name"},{"id":"declared-image","input":["text","image"]},{"id":"unknown-input","input_modalities":["text","audio","image"]}]}"#.utf8
        )
        let models = try OpenAIChatCompletionsAdapter().decodeModelList(data)
        XCTAssertEqual(
            models.map(\.inputModalities),
            [[.text], [.text, .image], [.text]]
        )

        var remoteVision = ModelProviderCatalog.applying(
            .customOpenAICompatible,
            to: AgentConfiguration()
        )
        remoteVision.model = "gateway-vl-32b"
        XCTAssertFalse(ModelProviderCatalog.supportsImageInput(remoteVision))
        remoteVision.inputModalities = [.text, .image]
        XCTAssertTrue(ModelProviderCatalog.supportsImageInput(remoteVision))
    }

    func testEnrichedModelsMapUsesPropertyKeyAndIgnoresPrimitiveEntries() throws {
        let data = Data(#"{"models":{"gateway-chat":{"id":"canonical-name","display_name":"Gateway Chat","context_window":65536,"max_tokens":4096},"count":3,"vision":{"input_modalities":["text","image"]}}}"#.utf8)
        let models = try OpenAIChatCompletionsAdapter().decodeModelList(data)
        XCTAssertEqual(models.map(\.id), ["gateway-chat", "vision"])
        XCTAssertEqual(models[0].name, "Gateway Chat")
        XCTAssertEqual(models[0].contextWindow, 65_536)
        XCTAssertEqual(models[1].inputModalities, [.text, .image])
    }

    func testModelListingCarriesPerModelReasoningCapabilities() throws {
        let data = Data(#"{"data":[{"id":"reasoning-gateway","reasoning_modes":["off","low","xhigh","max"],"reasoning_default":"low"}]}"#.utf8)
        let model = try XCTUnwrap(OpenAIChatCompletionsAdapter().decodeModelList(data).first)
        XCTAssertEqual(model.reasoningModes, [.off, .low, .xhigh, .max])
        XCTAssertEqual(model.defaultReasoningMode, .low)

        var configuration = AgentConfiguration(
            providerID: .customOpenAICompatible,
            baseURL: "https://gateway.example/v1",
            model: model.id,
            supportedReasoningModes: model.reasoningModes,
            reasoningMode: .low
        )
        XCTAssertNoThrow(try configuration.validated())
        configuration.reasoningMode = .high
        XCTAssertThrowsError(try configuration.validated()) { error in
            guard case .unsupportedReasoningMode(.customOpenAICompatible, .high)? = error as? AgentConfigurationError else {
                return XCTFail("expected unsupported per-model reasoning mode")
            }
        }
    }

    func testModelListingReadsUpstreamReasoningOptionsEffortValues() throws {
        let data = Data(#"{"models":{"claude-opus-4-7":{"reasoning":true,"reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}],"modalities":{"input":["text","image"]},"limit":{"context":1000000,"output":128000}},"claude-haiku-4-5":{"reasoning_options":[{"type":"budget_tokens","min":1024}]}}}"#.utf8)
        let models = try OpenAIChatCompletionsAdapter().decodeModelList(data)
        XCTAssertEqual(models.map(\.id), ["claude-haiku-4-5", "claude-opus-4-7"])
        XCTAssertNil(models[0].reasoningModes)
        XCTAssertEqual(models[1].reasoningModes, [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(models[1].contextWindow, 1_000_000)
        XCTAssertEqual(models[1].maxOutputTokens, 128_000)
        XCTAssertEqual(models[1].inputModalities, [.text, .image])
    }

    func testAnthropicListingUsesNativeURLAndHeaders() throws {
        var configuration = ModelProviderCatalog.applying(.anthropic, to: AgentConfiguration())
        configuration.baseURL = "https://api.anthropic.com"
        let adapter = AnthropicMessagesAdapter()
        XCTAssertEqual(
            try adapter.modelListURL(for: configuration).absoluteString,
            "https://api.anthropic.com/v1/models?limit=1000"
        )
        var request = URLRequest(url: try adapter.modelListURL(for: configuration))
        adapter.prepareModelListRequest(&request, apiKey: "fixture-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicDiscoveryUsesNativeListingWire() async throws {
        var configuration = ModelProviderCatalog.applying(.anthropic, to: AgentConfiguration())
        configuration.baseURL = "https://api.anthropic.com"
        let sessionConfiguration = OpenAICompatibleClient.makeSessionConfiguration()
        sessionConfiguration.protocolClasses = [ProviderDiscoveryURLProtocolStub.self]
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anthropic-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let client = OpenAICompatibleClient(
            filesClient: DeepSeekFilesClient(),
            sessionConfiguration: sessionConfiguration,
            modelDiscoveryCache: ModelDiscoveryCache(directoryURL: cacheDirectory)
        )
        ProviderDiscoveryURLProtocolStub.handler = { urlRequest in
            XCTAssertEqual(urlRequest.url?.path, "/v1/models")
            XCTAssertEqual(urlRequest.url?.query, "limit=1000")
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "fixture-key")
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(urlRequest.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, Data(#"{"data":[{"id":"claude-3-7","display_name":"Claude 3.7"}]}"#.utf8))
        }
        let snapshot = try await client.discoverModels(
            ModelDiscoveryRequest(
                configuration: configuration,
                apiKey: "fixture-key",
                trustedOrigin: try configuration.credentialOrigin(),
                forceRefresh: true
            )
        )
        XCTAssertEqual(snapshot.models.map(\.id), ["claude-3-7"])
        XCTAssertEqual(snapshot.models[0].name, "Claude 3.7")
    }

    func testExactModelResolutionFallsBackToAdvisoryIdentity() async throws {
        let configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        let builtIn = try await OpenAICompatibleClient().resolveModelInfo(
            ModelResolutionRequest(
                configuration: configuration,
                apiKey: nil,
                trustedOrigin: try configuration.credentialOrigin(),
                modelID: "gpt-5"
            )
        )
        XCTAssertEqual(builtIn.name, "GPT-5")
    }

    func testProviderRegistryOwnsThreeDistinctStreamingRequestDialects() throws {
        let deepSeek = try ModelProviderAdapterRegistry.adapter(for: .deepSeekOfficial)
        let openAI = try ModelProviderAdapterRegistry.adapter(for: .openAI)
        let anthropic = try ModelProviderAdapterRegistry.adapter(for: .anthropic)
        XCTAssertEqual(deepSeek.streamingDialect, .deepSeekChatCompletions)
        XCTAssertEqual(openAI.streamingDialect, .openAIChatCompletions)
        XCTAssertEqual(anthropic.streamingDialect, .anthropicMessages)

        func request(_ configuration: AgentConfiguration) -> ModelRequest {
            ModelRequest(
                configuration: configuration,
                apiKey: "test-only",
                systemPrompt: "system",
                messages: [.user("hello")],
                tools: []
            )
        }

        let deepSeekRequest = try deepSeek.makeStreamingRequest(request(AgentConfiguration()))
        XCTAssertEqual(deepSeekRequest.url?.path, "/v1/chat/completions")
        XCTAssertEqual(
            deepSeekRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-only"
        )
        XCTAssertNil(deepSeekRequest.value(forHTTPHeaderField: "x-api-key"))

        let openAIConfiguration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        let openAIRequest = try openAI.makeStreamingRequest(request(openAIConfiguration))
        XCTAssertEqual(openAIRequest.url?.path, "/v1/chat/completions")
        XCTAssertEqual(
            openAIRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer test-only"
        )
        let openAIBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(openAIRequest.httpBody))
                as? [String: Any]
        )
        XCTAssertNil(openAIBody["thinking"])
        XCTAssertNil(openAIBody["system"])

        var xhighConfiguration = openAIConfiguration
        xhighConfiguration.reasoningMode = .xhigh
        let xhighBody = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(openAI.makeStreamingRequest(request(xhighConfiguration)).httpBody)
            ) as? [String: Any]
        )
        XCTAssertEqual(xhighBody["reasoning_effort"] as? String, "xhigh")

        let anthropicConfiguration = ModelProviderCatalog.applying(
            .anthropic,
            to: AgentConfiguration()
        )
        let anthropicRequest = try anthropic.makeStreamingRequest(request(anthropicConfiguration))
        XCTAssertEqual(anthropicRequest.url?.path, "/v1/messages")
        XCTAssertEqual(anthropicRequest.value(forHTTPHeaderField: "x-api-key"), "test-only")
        XCTAssertEqual(
            anthropicRequest.value(forHTTPHeaderField: "anthropic-version"),
            "2023-06-01"
        )
        XCTAssertNil(anthropicRequest.value(forHTTPHeaderField: "Authorization"))
        let anthropicBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(anthropicRequest.httpBody))
                as? [String: Any]
        )
        XCTAssertEqual(anthropicBody["system"] as? String, "system")
        XCTAssertNil(anthropicBody["stream_options"])
    }

    func testProviderAdaptersOwnFailureCodeAndRequestIDContracts() throws {
        let deepSeek = DeepSeekChatCompletionsAdapter()
        XCTAssertEqual(
            deepSeek.httpFailureCode(
                status: 401,
                errorCode: nil,
                errorType: nil,
                message: "bad key"
            ),
            "AUTH"
        )
        XCTAssertEqual(
            deepSeek.httpFailureCode(
                status: 400,
                errorCode: "invalid_request_error",
                errorType: nil,
                message: "maximum context length exceeded"
            ),
            ModelRetryPolicy.contextWindowExceededCode
        )
        XCTAssertEqual(
            deepSeek.httpFailureCode(
                status: 418,
                errorCode: "teapot",
                errorType: nil,
                message: "short and stout"
            ),
            "HTTP_418"
        )

        let anthropic = AnthropicMessagesAdapter()
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                statusCode: 529,
                httpVersion: "HTTP/1.1",
                headerFields: ["request-id": "anthropic-request-1"]
            )
        )
        XCTAssertEqual(
            anthropic.httpFailureCode(
                status: 529,
                errorCode: nil,
                errorType: "overloaded_error",
                message: "busy"
            ),
            "overloaded_error"
        )
        XCTAssertEqual(anthropic.requestID(from: response), "anthropic-request-1")
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

    func testDiscoveryRedirectPolicyRejectsCrossOriginAndUnsafeURLForms() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://api.openai.com/v1/models"))
        XCTAssertTrue(
            OpenAICompatibleClient.isSameHTTPSOrigin(
                endpoint,
                try XCTUnwrap(URL(string: "https://API.OPENAI.COM:443/models-next"))
            )
        )
        XCTAssertFalse(
            OpenAICompatibleClient.isSameHTTPSOrigin(
                endpoint,
                try XCTUnwrap(URL(string: "https://mirror.example/v1/models"))
            )
        )
        XCTAssertFalse(
            OpenAICompatibleClient.isSameHTTPSOrigin(
                endpoint,
                try XCTUnwrap(URL(string: "http://api.openai.com/v1/models"))
            )
        )
        XCTAssertFalse(
            OpenAICompatibleClient.isSameHTTPSOrigin(
                endpoint,
                try XCTUnwrap(URL(string: "https://user:secret@api.openai.com/v1/models"))
            )
        )
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

    func testDiscoveryFailureFixtureCovers401MalformedOversizedAndManualFallback() async throws {
        let fixture = try loadDiscoveryFailureFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-discovery-failures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        let request = ModelDiscoveryRequest(
            configuration: configuration,
            apiKey: "fixture-secret",
            trustedOrigin: try configuration.credentialOrigin(),
            forceRefresh: true
        )
        let sessionConfiguration = OpenAICompatibleClient.makeSessionConfiguration()
        sessionConfiguration.protocolClasses = [ProviderDiscoveryURLProtocolStub.self]
        let client = OpenAICompatibleClient(
            filesClient: DeepSeekFilesClient(),
            sessionConfiguration: sessionConfiguration,
            modelDiscoveryCache: ModelDiscoveryCache(directoryURL: directory)
        )

        ProviderDiscoveryURLProtocolStub.handler = { urlRequest in
            XCTAssertEqual(urlRequest.httpMethod, "GET")
            XCTAssertEqual(
                urlRequest.value(forHTTPHeaderField: "Authorization"),
                "Bearer fixture-secret"
            )
            let failure = fixture.unauthorized
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(urlRequest.url),
                    statusCode: failure.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: failure.headers
                )
            )
            return (response, try JSONEncoder().encode(failure.body))
        }
        do {
            _ = try await client.discoverModels(request)
            XCTFail("Expected 401 discovery failure")
        } catch let ModelClientError.httpFailure(metadata, message) {
            XCTAssertEqual(metadata.status, 401)
            XCTAssertEqual(metadata.code, "invalid_api_key")
            XCTAssertEqual(metadata.requestID, "openai-request-1")
            XCTAssertEqual(message, "bad key")
        }

        ProviderDiscoveryURLProtocolStub.handler = { urlRequest in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(urlRequest.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            return (response, try JSONEncoder().encode(fixture.malformed.body))
        }
        do {
            _ = try await client.discoverModels(request)
            XCTFail("Expected malformed model list")
        } catch let error as ModelDiscoveryError {
            XCTAssertEqual(error, .malformedResponse)
        }

        ProviderDiscoveryURLProtocolStub.handler = { urlRequest in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(urlRequest.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Content-Length": String(fixture.oversized.declaredContentLength)
                    ]
                )
            )
            return (response, Data(#"{"data":[]}"#.utf8))
        }
        do {
            _ = try await client.discoverModels(request)
            XCTFail("Expected oversized model list")
        } catch let error as ModelDiscoveryError {
            XCTAssertEqual(error, .responseTooLarge)
        }

        // A failed refresh never invalidates a manually entered model. The
        // same unlisted model remains a valid request snapshot and profile
        // catalog entry while the UI displays the discovery error.
        let manualModel = try XCTUnwrap(fixture.manualFallback.models.first)
        var manualConfiguration = configuration
        manualConfiguration.model = manualModel.id
        let validated = try manualConfiguration.validated()
        XCTAssertEqual(validated.model, manualModel.id)
        let profile = ProviderProfile(
            id: "manual-fallback",
            displayName: "Manual fallback",
            providerID: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: configuration.baseURL,
            credentialReference: .providerAPIKey(profileID: "manual-fallback"),
            models: fixture.manualFallback.models,
            defaultModel: manualModel.id,
            reasoningMode: .providerDefault,
            maxSteps: 8,
            maxOutputTokens: 4_096,
            isCustom: false
        )
        XCTAssertEqual(try profile.validated().configuration().model, manualModel.id)
    }

    func testCacheExpiresAndPartitionsCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-cache-expiry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_004_000)
        let cache = ModelDiscoveryCache(
            directoryURL: directory,
            timeToLive: 3_600,
            now: { now }
        )
        let endpoint = try XCTUnwrap(URL(string: "https://gateway.example/v1/models"))
        let keyA = ModelDiscoveryCacheKey(
            providerID: .customOpenAICompatible,
            endpoint: endpoint,
            apiKey: "credential-a"
        )
        let keyB = ModelDiscoveryCacheKey(
            providerID: .customOpenAICompatible,
            endpoint: endpoint,
            apiKey: "credential-b"
        )
        let models = [ProviderModel(id: "manual-model")]

        try await cache.store(
            key: keyA,
            adapterSchemaVersion: 1,
            fetchedAt: now.addingTimeInterval(-3_601),
            models: models
        )
        let expiredA = await cache.load(key: keyA, adapterSchemaVersion: 1)
        let missingB = await cache.load(key: keyB, adapterSchemaVersion: 1)
        XCTAssertNil(expiredA)
        XCTAssertNil(missingB)

        try await cache.store(
            key: keyA,
            adapterSchemaVersion: 1,
            fetchedAt: now,
            models: models
        )
        let currentA = await cache.load(key: keyA, adapterSchemaVersion: 1)
        let stillMissingB = await cache.load(key: keyB, adapterSchemaVersion: 1)
        XCTAssertNotNil(currentA)
        XCTAssertNil(stillMissingB)
    }

    private func loadDiscoveryFailureFixture() throws -> ProviderDiscoveryFailureFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
            .appendingPathComponent("provider-models", isDirectory: true)
            .appendingPathComponent("openai-model-discovery-failures-v1.json")
        return try JSONDecoder().decode(
            ProviderDiscoveryFailureFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
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

private struct ProviderDiscoveryFailureFixture: Decodable {
    let schemaVersion: Int
    let unauthorized: HTTPFailure
    let malformed: Malformed
    let oversized: Oversized
    let manualFallback: ManualFallback

    struct HTTPFailure: Decodable {
        let status: Int
        let headers: [String: String]
        let body: JSONValue
    }

    struct Malformed: Decodable {
        let body: JSONValue
    }

    struct Oversized: Decodable {
        let declaredContentLength: Int
    }

    struct ManualFallback: Decodable {
        let models: [ProviderModel]
    }
}

private final class ProviderDiscoveryURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
