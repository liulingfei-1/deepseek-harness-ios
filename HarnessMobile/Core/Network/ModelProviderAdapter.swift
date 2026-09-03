import Foundation

enum ModelProviderStreamingDialect: String, Sendable, Equatable {
    case deepSeekChatCompletions
    case openAIChatCompletions
    case anthropicMessages
}

protocol ModelProviderAdapter: Sendable {
    var wireProtocol: ModelProviderWireProtocol { get }
    var streamingDialect: ModelProviderStreamingDialect { get }
    var modelListSchemaVersion: Int { get }

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL
    func modelListURL(for configuration: AgentConfiguration) throws -> URL
    func decodeModelList(_ data: Data) throws -> [ProviderModel]
    func prepareModelListRequest(_ request: inout URLRequest, apiKey: String?)
    func makeStreamingRequest(_ request: ModelRequest) throws -> URLRequest
    func httpFailureCode(
        status: Int,
        errorCode: String?,
        errorType: String?,
        message: String
    ) -> String?
    func requestID(from response: HTTPURLResponse) -> String?
}

extension ModelProviderAdapter {
    func prepareModelListRequest(_ request: inout URLRequest, apiKey: String?) {
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    func httpFailureCode(
        status: Int,
        errorCode: String?,
        errorType: String?,
        message: String
    ) -> String? {
        errorCode ?? errorType
    }

    func requestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "X-Request-ID")
    }
}

enum ModelProviderAdapterRegistry {
    static func adapter(for providerID: ModelProviderID) throws -> any ModelProviderAdapter {
        let descriptor = ModelProviderCatalog.descriptor(for: providerID)
        guard descriptor.supportsCurrentInferenceWire else {
            throw AgentConfigurationError.unsupportedProviderWire(providerID)
        }
        switch providerID {
        case .deepSeekOfficial:
            return DeepSeekChatCompletionsAdapter()
        case .openAI, .openRouter, .customOpenAICompatible:
            return OpenAIChatCompletionsAdapter()
        case .anthropic:
            return AnthropicMessagesAdapter()
        }
    }
}

/// The official DeepSeek route owns its Files API and reasoning dialect even
/// though its transport envelope is chat/completions. Keeping a distinct
/// adapter prevents provider-only behavior from leaking into generic OpenAI
/// gateways.
struct DeepSeekChatCompletionsAdapter: ModelProviderAdapter {
    let wireProtocol = ModelProviderWireProtocol.openAIChatCompletions
    let streamingDialect = ModelProviderStreamingDialect.deepSeekChatCompletions
    let modelListSchemaVersion = 1

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(appending: "chat/completions")
    }

    func modelListURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(
            appending: "models",
            replacingTrailingPath: "chat/completions"
        )
    }

    func decodeModelList(_ data: Data) throws -> [ProviderModel] {
        try OpenAIChatCompletionsAdapter.decodeOpenAIModelList(data)
    }

    func makeStreamingRequest(_ request: ModelRequest) throws -> URLRequest {
        try OpenAIChatCompletionsRequestBuilder.make(request)
    }

    func httpFailureCode(
        status: Int,
        errorCode: String?,
        errorType: String?,
        message: String
    ) -> String? {
        if status == 401 || status == 403 { return "AUTH" }
        if status == 413 { return "INVALID_REQUEST" }
        let detail = [errorCode, errorType, message]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if status == 429 { return "RATE_LIMIT" }
        if status == 400 {
            if Self.isContextWindowFailure(detail) {
                return ModelRetryPolicy.contextWindowExceededCode
            }
            return "INVALID_REQUEST"
        }
        if status >= 500 { return "SERVER" }
        return "HTTP_\(status)"
    }

    func requestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "X-Request-ID")
            ?? response.value(forHTTPHeaderField: "X-DeepSeek-Request-ID")
    }

    private static func isContextWindowFailure(_ value: String) -> Bool {
        value.contains("context_length_exceeded")
            || value.contains("context window")
            || value.contains("maximum context")
            || value.contains("too many tokens")
            || value.contains("request too large for model context")
    }
}

struct OpenAIChatCompletionsAdapter: ModelProviderAdapter {
    let wireProtocol = ModelProviderWireProtocol.openAIChatCompletions
    let streamingDialect = ModelProviderStreamingDialect.openAIChatCompletions
    let modelListSchemaVersion = 1

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(appending: "chat/completions")
    }

    func modelListURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(
            appending: "models",
            replacingTrailingPath: "chat/completions"
        )
    }

    func decodeModelList(_ data: Data) throws -> [ProviderModel] {
        try Self.decodeOpenAIModelList(data)
    }

    func makeStreamingRequest(_ request: ModelRequest) throws -> URLRequest {
        try OpenAIChatCompletionsRequestBuilder.make(request)
    }

    fileprivate static func decodeOpenAIModelList(_ data: Data) throws -> [ProviderModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelDiscoveryError.malformedResponse
        }
        let values: [(String?, Any)]
        if let dataItems = root["data"] as? [Any] {
            values = dataItems.map { (nil, $0) }
        } else if let modelMap = root["models"] as? [String: Any] {
            values = modelMap.keys.sorted().compactMap { key in
                modelMap[key].map { (key, $0) }
            }
        } else {
            throw ModelDiscoveryError.malformedResponse
        }

        var seen = Set<String>()
        var models: [ProviderModel] = []
        models.reserveCapacity(min(values.count, 1_024))
        for (mapKey, rawValue) in values {
            guard JSONSerialization.isValidJSONObject(rawValue),
                  let itemData = try? JSONSerialization.data(withJSONObject: rawValue),
                  let item = try? JSONDecoder().decode(OpenAIModelListItem.self, from: itemData),
                  let id = Self.normalizedLabel(mapKey, item.id),
                  id.utf8.count <= 512,
                  seen.insert(id).inserted else {
                continue
            }
            guard models.count < 10_000 else {
                throw ModelDiscoveryError.tooManyModels
            }
            models.append(
                ProviderModel(
                    id: id,
                    name: Self.normalizedLabel(item.name, item.displayName) ?? id,
                    description: item.description,
                    contextWindow: Self.positiveCapacity(
                        item.contextWindow,
                        item.contextLength
                    ),
                    maxOutputTokens: Self.positiveCapacity(
                        item.maxOutputTokens,
                        item.maxTokens
                    ),
                    inputModalities: Self.validatedInputModalities(
                        item.inputModalities ?? item.input
                    ),
                    reasoningModes: Self.validatedReasoningModes(
                        item.reasoningModes ?? item.reasoningEfforts
                    ),
                    defaultReasoningMode: item.defaultReasoningMode.flatMap(ReasoningMode.init)
                )
            )
        }
        return models
    }

    private static func normalizedLabel(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.utf8.count <= 512 else {
                continue
            }
            return value
        }
        return nil
    }

    private static func positiveCapacity(_ candidates: Int?...) -> Int? {
        candidates.compactMap { $0 }.first(where: { $0 > 0 })
    }

    /// A model name is not a capability declaration. Unknown or incomplete
    /// modality lists stay text-only so the Agent cannot accidentally send
    /// private images to a route that never advertised image input.
    static func validatedInputModalities(_ rawValues: [String]?) -> [ModelInputModality] {
        guard let rawValues, !rawValues.isEmpty else { return [.text] }
        let normalized = rawValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ ModelInputModality(rawValue: $0) != nil }) else {
            return [.text]
        }
        let values = normalized.compactMap(ModelInputModality.init(rawValue:))
        guard values.contains(.text), Set(values).count == values.count else {
            return [.text]
        }
        return values
    }

    static func validatedReasoningModes(_ rawValues: [String]?) -> [ReasoningMode]? {
        guard let rawValues, !rawValues.isEmpty else { return nil }
        let modes = rawValues.compactMap(ReasoningMode.init(rawValue:))
        guard modes.count == rawValues.count, Set(modes).count == modes.count else {
            return nil
        }
        return modes
    }
}

private enum OpenAIChatCompletionsRequestBuilder {
    static func make(_ request: ModelRequest) throws -> URLRequest {
        let endpoint = try request.configuration.chatCompletionsURL()
        try request.route?.validate(endpoint: endpoint)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try OpenAICompatibleWireSerializer.encode(request)
        return urlRequest
    }
}

struct AnthropicMessagesAdapter: ModelProviderAdapter {
    let wireProtocol = ModelProviderWireProtocol.anthropicMessages
    let streamingDialect = ModelProviderStreamingDialect.anthropicMessages
    let modelListSchemaVersion = 1

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(appending: "messages")
    }

    func modelListURL(for configuration: AgentConfiguration) throws -> URL {
        var components = URLComponents(string: configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        guard components?.scheme?.lowercased() == "https",
              components?.host?.isEmpty == false,
              components?.user == nil,
              components?.password == nil,
              components?.query == nil,
              components?.fragment == nil else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        var path = components?.path ?? ""
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        if !path.hasSuffix("/v1") { path += "/v1" }
        path += "/models"
        components?.path = path
        components?.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        guard let url = components?.url else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        return url
    }

    func decodeModelList(_ data: Data) throws -> [ProviderModel] {
        try OpenAIChatCompletionsAdapter.decodeOpenAIModelList(data)
    }

    func prepareModelListRequest(_ request: inout URLRequest, apiKey: String?) {
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    func makeStreamingRequest(_ request: ModelRequest) throws -> URLRequest {
        let endpoint = try request.configuration.chatCompletionsURL()
        try request.route?.validate(endpoint: endpoint)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try AnthropicWireSerializer.encodeRequest(request)
        return urlRequest
    }

    func httpFailureCode(
        status: Int,
        errorCode: String?,
        errorType: String?,
        message: String
    ) -> String? {
        if let errorType, !errorType.isEmpty { return errorType }
        if let errorCode, !errorCode.isEmpty { return errorCode }
        if status == 401 || status == 403 { return "AUTH" }
        if status == 429 { return "RATE_LIMIT" }
        if status >= 500 { return "SERVER" }
        return "HTTP_\(status)"
    }

    func requestID(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "request-id")
            ?? response.value(forHTTPHeaderField: "X-Request-ID")
    }
}

private struct OpenAIModelListItem: Decodable {
    let id: String?
    let name: String?
    let displayName: String?
    let description: String?
    let reasoningModes: [String]?
    let reasoningEfforts: [String]?
    let defaultReasoningMode: String?
    let contextWindow: Int?
    let contextLength: Int?
    let maxTokens: Int?
    let maxOutputTokens: Int?
    let inputModalities: [String]?
    let input: [String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName = "display_name"
        case description
        case reasoningModes = "reasoning_modes"
        case reasoningEfforts = "reasoning_efforts"
        case defaultReasoningMode = "reasoning_default"
        case contextWindow = "context_window"
        case contextLength = "context_length"
        case maxTokens = "max_tokens"
        case maxOutputTokens = "max_output_tokens"
        case inputModalities = "input_modalities"
        case input
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        displayName = try? container.decode(String.self, forKey: .displayName)
        description = try? container.decode(String.self, forKey: .description)
        reasoningModes = try? container.decode([String].self, forKey: .reasoningModes)
        reasoningEfforts = try? container.decode([String].self, forKey: .reasoningEfforts)
        defaultReasoningMode = try? container.decode(String.self, forKey: .defaultReasoningMode)
        contextWindow = try? container.decode(Int.self, forKey: .contextWindow)
        contextLength = try? container.decode(Int.self, forKey: .contextLength)
        maxTokens = try? container.decode(Int.self, forKey: .maxTokens)
        maxOutputTokens = try? container.decode(Int.self, forKey: .maxOutputTokens)
        inputModalities = try? container.decode([String].self, forKey: .inputModalities)
        input = try? container.decode([String].self, forKey: .input)
    }
}
