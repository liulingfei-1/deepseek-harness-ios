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
    let reasoningTokens: Int?
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
