import Foundation

struct ModelToolDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let parameters: JSONValue
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

    init(
        configuration: AgentConfiguration,
        apiKey: String,
        systemPrompt: String,
        messages: [AgentMessage],
        tools: [ModelToolDefinition],
        imagePayloads: [ModelImagePayload] = []
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.imagePayloads = imagePayloads
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
    let reasoningTokens: Int?

    init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int,
        cachedPromptTokens: Int?,
        reasoningTokens: Int?,
        uncachedPromptTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.uncachedPromptTokens = uncachedPromptTokens
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
