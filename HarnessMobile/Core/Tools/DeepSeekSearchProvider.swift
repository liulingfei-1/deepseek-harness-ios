import Foundation

/// Mirrors upstream `web-search-deepseek`: a search backend that drives
/// DeepSeek's Anthropic-compatible Messages endpoint with the native
/// `web_search_20250305` server tool. Each search costs one model turn but
/// returns structured result blocks; absence of those blocks is an error
/// rather than a prose-scraping fallback.
///
/// Transport lives in `DeepSeekSearchTransport` (inside the audited
/// web-fetch boundary); this type owns the pure response mapping.
struct DeepSeekSearchProvider: WebSearchProvider {
    static let identifierValue = "deepseek-official"
    static let defaultBaseURL = "https://api.deepseek.com/anthropic/v1"
    static let defaultModel = "deepseek-v4-flash"
    static let defaultAPIVersion = "2023-06-01"
    static let defaultMaxTokens = 4_096
    static let defaultMaxUses = 5

    let identifier: String
    let approvalResources: Set<String>

    /// Resolved per operation, mirroring upstream: the credential thunk is a
    /// closure so one search never mixes a key from an old settings section
    /// with an endpoint named by a new one.
    private let resolveApiKey: @Sendable () async -> String?
    private let baseURL: String
    private let model: String
    private let apiVersion: String
    private let maxTokens: Int
    private let maxUses: Int
    private let client: WebSearchHTTPClient

    init(
        resolveApiKey: @escaping @Sendable () async -> String?,
        baseURL: String = Self.defaultBaseURL,
        model: String = Self.defaultModel,
        apiVersion: String = Self.defaultAPIVersion,
        maxTokens: Int = Self.defaultMaxTokens,
        maxUses: Int = Self.defaultMaxUses,
        timeout: TimeInterval = 60
    ) {
        self.identifier = Self.identifierValue
        self.approvalResources = []
        self.resolveApiKey = resolveApiKey
        self.baseURL = baseURL
        self.model = model
        self.apiVersion = apiVersion
        self.maxTokens = maxTokens
        self.maxUses = maxUses
        self.client = WebSearchHTTPClient(timeout: timeout)
    }

    func search(query: String, maximumResults: Int) async throws -> [WebSearchProviderSource] {
        guard let apiKey = await resolveApiKey(), !apiKey.isEmpty else {
            throw DeepSeekSearchError.missingCredential
        }
        let response = try await DeepSeekSearchTransport.perform(
            query: query,
            apiKey: apiKey,
            baseURL: baseURL,
            model: model,
            apiVersion: apiVersion,
            maxTokens: maxTokens,
            maxUses: maxUses,
            client: client
        )
        return try Self.sources(from: response, maximumResults: maximumResults)
    }

    // MARK: - Response mapping (mirrors upstream `mapAnthropicResponse`)


    /// Builds a `url → cited_text` map from every `text` block's `citations[]`.
    /// Anthropic `web_search_result` items carry url/title/page_age but
    /// typically NO inline snippet — the excerpt lives in a separate text
    /// block's citation, keyed by url (first occurrence wins).
    static func citationSnippets(from blocks: [JSONValue]) -> [String: String] {
        var map: [String: String] = [:]
        for block in blocks {
            guard block.objectValue?["type"]?.stringValue == "text" else { continue }
            guard case let .array(citations)? = block.objectValue?["citations"] else { continue }
            for cite in citations {
                guard let url = cite.objectValue?["url"]?.stringValue, !url.isEmpty,
                      let cited = cite.objectValue?["cited_text"]?.stringValue, !cited.isEmpty
                else { continue }
                if map[url] == nil {
                    map[url] = cited
                }
            }
        }
        return map
    }

    /// Walks `web_search_tool_result` blocks for citeable `web_search_result`
    /// items, joins each to its citation excerpt as snippet, and dedupes by
    /// url (a `max_uses > 1` request can surface the same URL across
    /// searches).
    static func sources(
        from response: JSONValue,
        maximumResults: Int
    ) throws -> [WebSearchProviderSource] {
        guard case let .array(blocks)? = response.objectValue?["content"] else {
            throw DeepSeekSearchError.noResultBlocks
        }
        let resultBlocks = blocks.filter {
            $0.objectValue?["type"]?.stringValue == "web_search_tool_result"
        }
        guard !resultBlocks.isEmpty else {
            throw DeepSeekSearchError.noResultBlocks
        }

        let snippets = citationSnippets(from: blocks)
        var seen: Set<String> = []
        var sources: [WebSearchProviderSource] = []
        for block in resultBlocks {
            guard case let .array(items)? = block.objectValue?["content"] else { continue }
            for item in items {
                guard item.objectValue?["type"]?.stringValue == "web_search_result" else { continue }
                guard let url = item.objectValue?["url"]?.stringValue, !url.isEmpty,
                      !seen.contains(url) else { continue }
                seen.insert(url)
                sources.append(
                    WebSearchProviderSource(
                        title: item.objectValue?["title"]?.stringValue ?? "",
                        url: url,
                        snippet: snippets[url] ?? ""
                    )
                )
                if sources.count >= maximumResults {
                    return sources
                }
            }
        }
        return sources
    }
}

    enum DeepSeekSearchError: LocalizedError, Equatable {
    case missingCredential
    case transport(String)
    case endpoint(status: Int, detail: String)
    case noResultBlocks

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "DeepSeek 搜索需要 DeepSeek 凭据；当前配置缺失。可在设置中补齐或改用其他搜索后端。"
        case let .transport(detail):
            detail
        case let .endpoint(status, detail):
            "DeepSeek 搜索端点返回 \(status)。\(detail) 用户可在设置中检查 DeepSeek 凭据或改用其他搜索后端。"
        case .noResultBlocks:
            "DeepSeek 未返回 web_search_tool_result 块；请求可能未触发原生网页搜索。"
        }
    }
}
