import Foundation

struct ModelToolDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let parameters: JSONValue
    /// Tool-owned local execution budget. It is deliberately omitted from
    /// provider wire payloads; the native timeout-policy reads it from the
    /// local registry before dispatch.
    let timeoutMs: Int?

    init(
        name: String,
        description: String,
        parameters: JSONValue,
        timeoutMs: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.timeoutMs = timeoutMs
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        parameters = try container.decode(JSONValue.self, forKey: .parameters)
        timeoutMs = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(parameters, forKey: .parameters)
    }
}

struct ModelRequest: Sendable, Equatable {
    let configuration: AgentConfiguration
    let apiKey: String
    let systemPrompt: String
    let messages: [AgentMessage]
    let tools: [ModelToolDefinition]
    /// Bytes are resolved immediately before dispatch and never persisted in
    /// the session or trace. Keeping them request-local avoids data URLs in
    /// durable conversation state.
    let imagePayloads: [ModelImagePayload]
    /// Immutable profile/endpoint identity captured before this request starts.
    /// It contains no credential material and is never inferred from mutable UI
    /// state during adapter dispatch.
    let route: ProviderRequestRoute?

    init(
        configuration: AgentConfiguration,
        apiKey: String,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ModelToolDefinition],
        imagePayloads: [ModelImagePayload] = [],
        route: ProviderRequestRoute? = nil
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.imagePayloads = imagePayloads
        self.route = route
    }
}

enum ModelFinishReason: String, Sendable, Equatable {
    case stop
    case toolCalls = "tool_calls"
    case length
    case contentFilter = "content_filter"
    case unknown
}

struct ModelTokenUsage: Sendable, Equatable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
    let cachedPromptTokens: Int?
    /// Provider-reported prompt tokens that were not served from cache.
    /// DeepSeek calls this `prompt_cache_miss_tokens`; other providers may
    /// omit it, in which case the client derives it from prompt and hit data.
    let uncachedPromptTokens: Int?
    /// Provider-reported prompt tokens used to create or refresh a cache.
    /// Anthropic calls this `cache_creation_input_tokens`; most providers omit it.
    let cacheWriteTokens: Int?
    let reasoningTokens: Int?

    init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        cachedPromptTokens: Int?,
        reasoningTokens: Int?,
        uncachedPromptTokens: Int? = nil,
        cacheWriteTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.uncachedPromptTokens = uncachedPromptTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }
}

enum LLMStreamEvent: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case toolCallDelta(
        index: Int,
        id: String?,
        type: String?,
        name: String?,
        arguments: String
    )
    case usage(ModelTokenUsage)
    case finish(ModelFinishReason)
}

protocol LLMStreamingClient: Sendable {
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

struct ModelDiscoveryRequest: Sendable {
    let configuration: AgentConfiguration
    let apiKey: String?
    let trustedOrigin: String
    let forceRefresh: Bool

    init(
        configuration: AgentConfiguration,
        apiKey: String?,
        trustedOrigin: String,
        forceRefresh: Bool = false
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.trustedOrigin = trustedOrigin
        self.forceRefresh = forceRefresh
    }
}

protocol ModelCatalogDiscovering: Sendable {
    func discoverModels(_ request: ModelDiscoveryRequest) async throws -> ModelCatalogSnapshot
}
