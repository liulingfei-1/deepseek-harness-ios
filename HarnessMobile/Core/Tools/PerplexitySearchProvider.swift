import Foundation

/// Mirrors upstream `web-search-perplexity`: search over Perplexity's
/// OpenAI-compatible chat-completions endpoint (`sonar` model). The answer's
/// `search_results` blocks are the primary source; bare `citations[]` URLs
/// are the fallback when `search_results` is absent.
struct PerplexitySearchProvider: WebSearchProvider {
    static let identifierValue = "perplexity"
    static let defaultBaseURL = "https://api.perplexity.ai"
    static let defaultModel = "sonar"
    static let defaultMaxTokens = 1_024

    let identifier: String
    let approvalResources: Set<String>

    private let resolveApiKey: @Sendable () async -> String?
    private let baseURL: String
    private let model: String
    private let maxTokens: Int
    private let client: WebSearchHTTPClient

    init(
        resolveApiKey: @escaping @Sendable () async -> String?,
        baseURL: String = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        maxTokens: Int = Self.defaultMaxTokens,
        timeout: TimeInterval = 60
    ) {
        self.identifier = Self.identifierValue
        self.approvalResources = []
        self.resolveApiKey = resolveApiKey
        self.baseURL = baseURL
        self.model = model
        self.maxTokens = maxTokens
        self.client = WebSearchHTTPClient(timeout: timeout)
    }

    func search(query: String, maximumResults: Int) async throws -> [WebSearchProviderSource] {
        guard let apiKey = await resolveApiKey(), !apiKey.isEmpty else {
            throw PerplexitySearchError.missingCredential
        }
        let response = try await PerplexitySearchTransport.perform(
            query: query,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            maxTokens: maxTokens,
            client: client
        )
        return PerplexitySearchMapper.sources(from: response)
    }

}

    enum PerplexitySearchError: LocalizedError, Equatable {
    case missingCredential
    case transport(String)
    case endpoint(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Perplexity 搜索需要 Perplexity API key；当前配置缺失。"
        case let .transport(detail):
            detail
        case let .endpoint(status, detail):
            "Perplexity 搜索端点返回 \(status)。\(detail)"
        }
    }
}
