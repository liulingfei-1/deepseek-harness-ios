import Foundation

/// Mirrors upstream `web-search-exa`: a search backend backed by Exa's
/// `POST /search` with highlight extraction. Snippet-less entries are
/// dropped, mirroring upstream `mapExaResult`.
struct ExaSearchProvider: WebSearchProvider {
    static let identifierValue = "exa"
    static let defaultBaseURL = "https://api.exa.ai"
    static let defaultSearchType = "auto"
    static let defaultHighlightsPerResult = 1

    let identifier: String
    let approvalResources: Set<String>

    private let resolveApiKey: @Sendable () async -> String?
    private let baseURL: String
    private let searchType: String
    private let highlightsPerResult: Int
    private let client: WebSearchHTTPClient

    init(
        resolveApiKey: @escaping @Sendable () async -> String?,
        baseURL: String = Self.defaultBaseURL,
        searchType: String = Self.defaultSearchType,
        highlightsPerResult: Int = Self.defaultHighlightsPerResult,
        timeout: TimeInterval = 60,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.identifier = Self.identifierValue
        self.approvalResources = []
        self.resolveApiKey = resolveApiKey
        self.baseURL = baseURL
        self.searchType = searchType
        self.highlightsPerResult = highlightsPerResult
        self.client = WebSearchHTTPClient(timeout: timeout, protocolClasses: protocolClasses)
    }

    func search(query: String, maximumResults: Int) async throws -> [WebSearchProviderSource] {
        guard let apiKey = await resolveApiKey(), !apiKey.isEmpty else {
            throw ExaSearchError.missingCredential
        }
        let response = try await ExaSearchTransport.perform(
            query: query,
            apiKey: apiKey,
            baseURL: baseURL,
            searchType: searchType,
            highlightsPerResult: highlightsPerResult,
            numResults: maximumResults,
            client: client
        )
        return Self.sources(from: response)
    }


    /// Maps a `POST /search` response. Entries without a usable URL or a
    /// non-blank highlight are dropped, matching upstream `mapExaResult`.
    static func sources(from response: JSONValue) -> [WebSearchProviderSource] {
        guard case let .array(results)? = response.objectValue?["results"] else { return [] }
        return results.compactMap { result in
            guard let url = result.objectValue?["url"]?.stringValue, !url.isEmpty else { return nil }
            guard case let .array(highlights)? = result.objectValue?["highlights"],
                  let snippet = highlights.compactMap(\.stringValue).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            return WebSearchProviderSource(
                title: result.objectValue?["title"]?.stringValue ?? "",
                url: url,
                snippet: snippet
            )
        }
    }
}

/// Maps the OpenAI-compatible Perplexity response: top-level `search_results[]`
/// carry url/title/snippet; when absent, bare top-level `citations[]` URLs are
/// used (Perplexity attaches these to the completion response itself).
enum PerplexitySearchMapper {
    static func sources(from response: JSONValue) -> [WebSearchProviderSource] {
        if case let .array(blocks)? = response.objectValue?["search_results"], !blocks.isEmpty {
            return blocks.compactMap { block in
                guard let url = block.objectValue?["url"]?.stringValue, !url.isEmpty else { return nil }
                return WebSearchProviderSource(
                    title: block.objectValue?["title"]?.stringValue ?? "",
                    url: url,
                    snippet: block.objectValue?["snippet"]?.stringValue ?? ""
                )
            }
        }
        guard case let .array(citations)? = response.objectValue?["citations"] else { return [] }
        return citations.compactMap { citation in
            guard let url = citation.stringValue, !url.isEmpty else { return nil }
            return WebSearchProviderSource(title: "", url: url, snippet: "")
        }
    }
}

    enum ExaSearchError: LocalizedError, Equatable {
    case missingCredential
    case transport(String)
    case endpoint(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            "Exa 搜索需要 Exa API key；当前配置缺失。"
        case let .transport(detail):
            detail
        case let .endpoint(status, detail):
            "Exa 搜索端点返回 \(status)。\(detail)"
        }
    }
}
