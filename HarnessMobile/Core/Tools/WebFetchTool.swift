import CoreFoundation
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

struct WebFetchLimits: Sendable, Equatable {
    static let standard = WebFetchLimits(
        maximumURLBytes: 2_048,
        maximumResponseBytes: 5_000_000,
        maximumBodyCharacters: 32_000,
        timeoutSeconds: 30,
        maximumRedirects: 5,
        userAgent: "harness-mobile/0.1 (on-device web_fetch)"
    )

    let maximumURLBytes: Int
    let maximumResponseBytes: Int
    let maximumBodyCharacters: Int
    let timeoutSeconds: TimeInterval
    let maximumRedirects: Int
    let userAgent: String

    init(
        maximumURLBytes: Int,
        maximumResponseBytes: Int,
        maximumBodyCharacters: Int,
        timeoutSeconds: TimeInterval,
        maximumRedirects: Int,
        userAgent: String
    ) {
        precondition(maximumURLBytes > 0)
        precondition(maximumResponseBytes > 0)
        precondition(maximumBodyCharacters > 0)
        precondition(timeoutSeconds.isFinite && timeoutSeconds > 0)
        precondition(maximumRedirects >= 0)
        precondition(!userAgent.isEmpty)

        self.maximumURLBytes = maximumURLBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumBodyCharacters = maximumBodyCharacters
        self.timeoutSeconds = timeoutSeconds
        self.maximumRedirects = maximumRedirects
        self.userAgent = userAgent
    }
}

enum WebFetchBodyKind: String, Codable, Sendable, Equatable {
    case html
    case text
}

struct WebFetchBody: Codable, Sendable, Equatable {
    let kind: WebFetchBodyKind
    let content: String
}

struct WebFetchResult: Codable, Sendable, Equatable {
    let url: String
    let statusCode: Int
    let body: WebFetchBody
    let truncated: Bool
}

enum WebFetchError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case urlTooLong(Int)
    case unsupportedScheme(String)
    case credentialsNotAllowed
    case redirectLimitExceeded(Int)
    case redirectMissingLocation(Int)
    case crossOriginRedirect(String)
    case unsupportedContentType(String)
    case unsupportedCharset(String)
    case responseTooLarge(Int)
    case invalidResponse
    case decodingFailed(String)
    case timedOut
    case networkFailure(String)

    var code: String {
        switch self {
        case .invalidURL, .urlTooLong, .unsupportedScheme:
            "WEB_INVALID_URL"
        case .credentialsNotAllowed:
            "WEB_BLOCKED_URL"
        case .redirectLimitExceeded, .crossOriginRedirect:
            "WEB_REDIRECT_BLOCKED"
        case .redirectMissingLocation, .invalidResponse, .decodingFailed, .networkFailure:
            "WEB_PROVIDER_ERROR"
        case .unsupportedContentType, .unsupportedCharset:
            "WEB_UNSUPPORTED_CONTENT_TYPE"
        case .responseTooLarge:
            "WEB_FETCH_TOO_LARGE"
        case .timedOut:
            "WEB_FETCH_TIMEOUT"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "网址格式无效。"
        case let .urlTooLong(limit):
            "网址超过 \(limit) 字节上限。"
        case let .unsupportedScheme(scheme):
            "不支持 \(scheme)://，web_fetch 只允许 HTTP 和 HTTPS。"
        case .credentialsNotAllowed:
            "网址中不能包含用户名或密码。"
        case let .redirectLimitExceeded(limit):
            "网页跳转超过 \(limit) 次上限。"
        case let .redirectMissingLocation(status):
            "HTTP \(status) 跳转响应缺少 Location。"
        case let .crossOriginRedirect(origin):
            "网页跳转到了新的来源 \(origin)，请对该网址单独调用 web_fetch。"
        case let .unsupportedContentType(contentType):
            "不支持网页响应类型：\(contentType)。"
        case let .unsupportedCharset(charset):
            "不支持网页字符集：\(charset)。"
        case let .responseTooLarge(limit):
            "网页响应超过 \(limit) 字节上限。"
        case .invalidResponse:
            "网页服务返回了无效的 HTTP 响应。"
        case let .decodingFailed(charset):
            "无法使用字符集 \(charset) 解码网页正文。"
        case .timedOut:
            "网页请求超时。"
        case let .networkFailure(message):
            "网页请求失败：\(message)"
        }
    }
}

struct WebFetchTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "web_fetch",
        description: "Fetch one public HTTP or HTTPS URL directly from this iPhone. Returns bounded text or HTML with the final URL and HTTP status. It never sends model-provider credentials.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("Absolute HTTP or HTTPS URL without embedded credentials.")
                ])
            ]),
            "required": .array([.string("url")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    private let client: WebFetchHTTPClient

    init(client: WebFetchHTTPClient = WebFetchHTTPClient()) {
        self.client = client
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["url"])
        let rawURL = try arguments.requiredString(
            "url",
            maximumUTF8Bytes: client.limits.maximumURLBytes
        )
        _ = try WebFetchURLPolicy.validate(rawURL, limits: client.limits)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        guard let rawURL = arguments["url"]?.stringValue,
              let url = try? WebFetchURLPolicy.validate(rawURL, limits: client.limits),
              let origin = try? WebFetchURLPolicy.normalizedOrigin(for: url) else {
            return "从手机访问网页"
        }
        return "从手机访问网页：\(origin)"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try approvalResources(arguments: arguments)
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let rawURL = try arguments.requiredString(
            "url",
            maximumUTF8Bytes: client.limits.maximumURLBytes
        )
        let url = try WebFetchURLPolicy.validate(rawURL, limits: client.limits)
        return ["web:origin:\(try WebFetchURLPolicy.normalizedOrigin(for: url))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let rawURL = try arguments.requiredString(
            "url",
            maximumUTF8Bytes: client.limits.maximumURLBytes
        )
        let result = try await client.fetch(rawURL)
        return try Self.encodeBounded(result)
    }

    private static func encodeBounded(_ result: WebFetchResult) throws -> String {
        let maximumResultBytes = 48 * 1_024
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var data = try encoder.encode(result)
        if data.count <= maximumResultBytes {
            return String(decoding: data, as: UTF8.self)
        }

        let scalars = result.body.content.unicodeScalars
        var lowerBound = 0
        var upperBound = scalars.count
        var bestData: Data?
        while lowerBound <= upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            let content = String(scalars.prefix(midpoint))
            let candidate = WebFetchResult(
                url: result.url,
                statusCode: result.statusCode,
                body: WebFetchBody(kind: result.body.kind, content: content),
                truncated: true
            )
            data = try encoder.encode(candidate)
            if data.count <= maximumResultBytes {
                bestData = data
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint - 1
            }
        }

        guard let bestData else {
            throw LocalToolError.resultTooLarge
        }
        return String(decoding: bestData, as: UTF8.self)
    }
}

/// A small on-device search adapter for the upstream `web_search` capability.
/// Search is deliberately separate from `web_fetch`: providers may return
/// ranked sources without granting the model arbitrary request construction.
/// The provider seam keeps the tool contract independent from any particular
/// public search endpoint while all implementations still execute on-device.
protocol WebSearchProvider: Sendable {
    var identifier: String { get }
    var approvalResources: Set<String> { get }
    func search(query: String, maximumResults: Int) async throws -> [WebSearchProviderSource]
}

struct WebSearchProviderSource: Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String
}

struct WebSearchTool: LocalAgentTool {
    struct Limits: Sendable, Equatable {
        var timeout: TimeInterval = 30
        var maximumQueryBytes = 2 * 1_024
        var maximumResults = 8
        var maximumQueries = 4
        var maximumResponseBytes = 512 * 1_024
    }

    private struct DuckDuckGoResponse: Decodable, Sendable {
        let heading: String?
        let abstractText: String?
        let abstractURL: String?
        let relatedTopics: [RelatedTopic]?

        enum CodingKeys: String, CodingKey {
            case heading = "Heading"
            case abstractText = "AbstractText"
            case abstractURL = "AbstractURL"
            case relatedTopics = "RelatedTopics"
        }
    }

    private struct RelatedTopic: Decodable, Sendable {
        let text: String?
        let firstURL: String?
        let topics: [RelatedTopic]?

        enum CodingKeys: String, CodingKey {
            case text = "Text"
            case firstURL = "FirstURL"
            case topics = "Topics"
        }
    }

    private struct ProviderResult: Sendable, Equatable {
        let provider: String
        let sources: [WebSearchProviderSource]
    }

    let limits: Limits
    private let provider: any WebSearchProvider
    let definition = ModelToolDefinition(
        name: "web_search",
        description: "Search the web from the iPhone and return bounded ranked sources. Search runs over the phone network, never on a remote command executor; use web_fetch to inspect a selected result in detail.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "queries": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "minItems": .number(1),
                    "maxItems": .number(4),
                    "description": .string("Required non-empty search queries. One to four queries run concurrently on the phone.")
                ])
            ]),
            "required": .array([.string("queries")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    init(
        limits: Limits = Limits(),
        protocolClasses: [AnyClass]? = nil,
        provider: (any WebSearchProvider)? = nil
    ) {
        self.limits = limits
        if let provider {
            self.provider = provider
        } else {
            self.provider = OnDeviceWebSearchProvider(
                limits: limits,
                protocolClasses: protocolClasses
            )
        }
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["queries"])
        _ = try parsedQueries(arguments: arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let queries = (try? parsedQueries(arguments: arguments)) ?? []
        return "联网搜索：\(String(queries.joined(separator: ", ").prefix(72)))"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["web-search:phone"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        provider.approvalResources
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let queries = try parsedQueries(arguments: arguments)
        let batch = try await withThrowingTaskGroup(of: (Int, ProviderResult).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    let sources = try await self.provider.search(
                        query: query,
                        maximumResults: self.limits.maximumResults
                    )
                    return (index, ProviderResult(provider: self.provider.identifier, sources: sources))
                }
            }
            var values: [(Int, ProviderResult)] = []
            for try await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }
        }
        let merged = Self.roundRobinMerge(batch, queries: queries, maximumResults: limits.maximumResults)
        return JSONValue.object([
            "queries": .array(queries.map { .string($0) }),
            "sources": .array(merged.sources.map { item in
                .object([
                    "query": .string(item.query),
                    "provider": .string(item.provider),
                    "title": .string(item.source.title),
                    "url": .string(item.source.url),
                    "snippet": .string(String(item.source.snippet.prefix(1_000)))
                ])
            }),
            "source_count": .number(Double(merged.sources.count)),
            "truncated": .bool(merged.truncated),
            "query_count": .number(Double(queries.count)),
            "note": .string("搜索在手机上并发执行；结果按查询 round-robin 合并并按 URL 去重。使用 web_fetch 获取页面正文并核对来源。")
        ]).displayText
    }

    private func parsedQueries(arguments: [String: JSONValue]) throws -> [String] {
        guard case let .array(values)? = arguments["queries"],
              !values.isEmpty,
              values.count <= limits.maximumQueries else {
            throw LocalToolError.invalidArguments
        }
        var seen = Set<String>()
        var queries: [String] = []
        for value in values {
            guard let query = value.stringValue,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.utf8.count <= limits.maximumQueryBytes else {
                throw LocalToolError.invalidArguments
            }
            if seen.insert(query).inserted { queries.append(query) }
        }
        return queries
    }

    private struct MergedSource: Sendable, Equatable {
        let query: String
        let provider: String
        let source: WebSearchProviderSource
    }

    private struct MergedResult: Sendable, Equatable {
        let sources: [MergedSource]
        let truncated: Bool
    }

    private static func roundRobinMerge(
        _ batch: [(Int, ProviderResult)],
        queries: [String],
        maximumResults: Int
    ) -> MergedResult {
        var sources: [MergedSource] = []
        var seenURLs = Set<String>()
        var rank = 0
        while sources.count < maximumResults {
            var appended = false
            for (index, result) in batch {
                guard let source = result.sources[safe: rank] else { continue }
                appended = true
                guard seenURLs.insert(source.url).inserted else { continue }
                sources.append(MergedSource(query: queries[index], provider: result.provider, source: source))
                if sources.count == maximumResults { break }
            }
            guard appended else { break }
            rank += 1
        }
        let hadMore = batch.contains { result in
            result.1.sources.contains { !seenURLs.contains($0.url) }
        }
        return MergedResult(sources: sources, truncated: sources.count == maximumResults && hadMore)
    }

    private struct OnDeviceWebSearchProvider: WebSearchProvider {
        let identifier = "bing-rss+duckduckgo-instant"
        let approvalResources: Set<String> = [
            "web:search:www.bing.com",
            "web:search:api.duckduckgo.com"
        ]
        let limits: Limits
        let client: WebSearchHTTPClient

        init(limits: Limits, protocolClasses: [AnyClass]?) {
            self.limits = limits
            client = WebSearchHTTPClient(
                timeout: limits.timeout,
                protocolClasses: protocolClasses
            )
        }

        func search(query: String, maximumResults: Int) async throws -> [WebSearchProviderSource] {
            var failures: [String] = []
            do {
                let sources = try await searchBingRSS(
                    terms: query,
                    maximumResults: maximumResults
                )
                if !sources.isEmpty { return sources }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("Bing RSS: \(error.localizedDescription)")
            }

            do {
                let sources = try await searchDuckDuckGo(
                    terms: query,
                    maximumResults: maximumResults
                )
                if !sources.isEmpty { return sources }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("DuckDuckGo: \(error.localizedDescription)")
            }

            guard failures.isEmpty else {
                throw WebFetchError.networkFailure(
                    "手机直连搜索源均不可用（\(failures.joined(separator: "; "))）"
                )
            }
            return []
        }

        private func searchBingRSS(
            terms: String,
            maximumResults: Int
        ) async throws -> [WebSearchProviderSource] {
            var components = URLComponents(string: "https://www.bing.com/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: terms),
                URLQueryItem(name: "format", value: "rss")
            ]
            guard let url = components.url else { throw WebFetchError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = min(limits.timeout, 12)
            request.setValue("application/rss+xml, application/xml;q=0.9", forHTTPHeaderField: "Accept")
            request.setValue("harness-mobile/0.1 (on-device web_search)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await client.data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw WebFetchError.invalidResponse
            }
            guard data.count <= limits.maximumResponseBytes else {
                throw WebFetchError.responseTooLarge(limits.maximumResponseBytes)
            }
            return try BingSearchRSSParser.parse(data).compactMap { item in
                guard let url = WebSearchTool.normalizedPublicResultURL(item.link) else { return nil }
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return WebSearchProviderSource(
                    title: title.isEmpty ? url : title,
                    url: url,
                    snippet: WebSearchTool.plainSearchSnippet(item.description)
                )
            }.uniqued(by: \.url, maximumCount: maximumResults)
        }

        private func searchDuckDuckGo(
            terms: String,
            maximumResults: Int
        ) async throws -> [WebSearchProviderSource] {
            var components = URLComponents(string: "https://api.duckduckgo.com/")!
            components.queryItems = [
                URLQueryItem(name: "q", value: terms),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "no_html", value: "1"),
                URLQueryItem(name: "no_redirect", value: "1"),
                URLQueryItem(name: "skip_disambig", value: "1")
            ]
            guard let url = components.url else { throw WebFetchError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = min(limits.timeout, 12)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await client.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as WebFetchError {
                throw error
            } catch {
                throw WebFetchError.networkFailure(error.localizedDescription)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw WebFetchError.invalidResponse
            }
            guard data.count <= limits.maximumResponseBytes else {
                throw WebFetchError.responseTooLarge(limits.maximumResponseBytes)
            }
            let payload: DuckDuckGoResponse
            do {
                payload = try JSONDecoder().decode(DuckDuckGoResponse.self, from: data)
            } catch {
                throw WebFetchError.decodingFailed("JSON")
            }
            var sources: [WebSearchProviderSource] = []
            var seenURLs = Set<String>()
            func appendSource(title: String, rawURL: String, snippet: String) {
                guard sources.count < maximumResults,
                      let url = WebSearchTool.normalizedPublicResultURL(rawURL),
                      seenURLs.insert(url).inserted else { return }
                let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                sources.append(WebSearchProviderSource(
                    title: normalizedTitle.isEmpty ? url : normalizedTitle,
                    url: url,
                    snippet: snippet
                ))
            }
            if let heading = payload.heading,
               let abstractURL = payload.abstractURL,
               !abstractURL.isEmpty {
                appendSource(
                    title: heading,
                    rawURL: abstractURL,
                    snippet: payload.abstractText ?? ""
                )
            }
            func flatten(_ topics: [RelatedTopic]) {
                for topic in topics where sources.count < maximumResults {
                    if let nested = topic.topics, !nested.isEmpty {
                        flatten(nested)
                    } else if let firstURL = topic.firstURL,
                              !firstURL.isEmpty,
                              let text = topic.text,
                              !text.isEmpty {
                        let title = text.split(separator: " - ", maxSplits: 1).first.map(String.init) ?? text
                        appendSource(title: title, rawURL: firstURL, snippet: text)
                    }
                }
            }
            flatten(payload.relatedTopics ?? [])
            return Array(sources.prefix(maximumResults))
        }
    }

    private static func integer(
        _ value: JSONValue?,
        defaultValue: Int? = nil,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value else {
            if let defaultValue { return defaultValue }
            throw LocalToolError.invalidArguments
        }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw LocalToolError.invalidArguments
        }
        let integer = Int(number)
        guard range.contains(integer) else { throw LocalToolError.invalidArguments }
        return integer
    }

    private static func isValidDomain(_ value: String) -> Bool {
        let value = value.lowercased()
        guard value.utf8.count <= 253,
              !value.contains("/"),
              !value.contains(":") else { return false }
        return value.split(separator: ".").count >= 2
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
            }
    }

    private static func normalizedPublicResultURL(_ rawValue: String) -> String? {
        guard rawValue.utf8.count <= 4 * 1_024,
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else { return nil }
        return url.absoluteString
    }

    private static func plainSearchSnippet(_ value: String) -> String {
        var output = ""
        var isInsideTag = false
        for character in value {
            switch character {
            case "<": isInsideTag = true
            case ">":
                isInsideTag = false
                output.append(" ")
            default:
                if !isInsideTag { output.append(character) }
            }
        }
        return output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private struct BingSearchRSSItem: Sendable, Equatable {
    let title: String
    let link: String
    let description: String
}

private final class BingSearchRSSParser: NSObject, XMLParserDelegate {
    private var items: [BingSearchRSSItem] = []
    private var currentElement = ""
    private var title = ""
    private var link = ""
    private var itemDescription = ""
    private var isInsideItem = false

    static func parse(_ data: Data) throws -> [BingSearchRSSItem] {
        let delegate = BingSearchRSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw WebFetchError.decodingFailed("RSS XML")
        }
        return delegate.items
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        if currentElement == "item" {
            isInsideItem = true
            title = ""
            link = ""
            itemDescription = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInsideItem else { return }
        switch currentElement {
        case "title": title.append(string)
        case "link": link.append(string)
        case "description": itemDescription.append(string)
        default: break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName.lowercased() == "item" {
            items.append(BingSearchRSSItem(
                title: title,
                link: link.trimmingCharacters(in: .whitespacesAndNewlines),
                description: itemDescription
            ))
            isInsideItem = false
        }
        currentElement = ""
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func uniqued<Key: Hashable>(
        by keyPath: KeyPath<Element, Key>,
        maximumCount: Int
    ) -> [Element] {
        var seen = Set<Key>()
        var output: [Element] = []
        for element in self where output.count < maximumCount {
            guard seen.insert(element[keyPath: keyPath]).inserted else { continue }
            output.append(element)
        }
        return output
    }
}

/// Isolates URLSession construction so web search can be tested without making
/// a real network request. No cookies, credentials, or provider key storage are
/// attached to this phone-direct search session.
final class WebSearchHTTPClient: @unchecked Sendable {
    private let session: URLSession

    init(timeout: TimeInterval, protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebFetchError.invalidResponse
            }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw WebFetchError.timedOut
        } catch let error as WebFetchError {
            throw error
        } catch {
            throw WebFetchError.networkFailure(error.localizedDescription)
        }
    }
}

// URLSession is documented as thread-safe and both stored properties are immutable after init.
// Remove this escape hatch if Foundation gives URLSession/its delegate fully checked Sendable APIs.
final class WebFetchHTTPClient: @unchecked Sendable {
    let limits: WebFetchLimits

    private let redirectDelegate: WebFetchRejectRedirectDelegate
    private let session: URLSession

    init(
        limits: WebFetchLimits = .standard,
        protocolClasses: [AnyClass]? = nil
    ) {
        self.limits = limits

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = limits.timeoutSeconds
        configuration.timeoutIntervalForResource = limits.timeoutSeconds
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = [:]
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }

        let redirectDelegate = WebFetchRejectRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func fetch(_ rawURL: String) async throws -> WebFetchResult {
        let initialURL = try WebFetchURLPolicy.validate(rawURL, limits: limits)
        do {
            return try await withThrowingTaskGroup(of: WebFetchResult.self) { group in
                group.addTask {
                    try await self.followRedirectsAndRead(initialURL)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(self.limits.timeoutSeconds))
                    throw WebFetchError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                return result
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func followRedirectsAndRead(_ initialURL: URL) async throws -> WebFetchResult {
        var currentURL = initialURL
        var redirectsFollowed = 0

        while true {
            try Task.checkCancellation()
            let (bytes, response) = try await requestOnce(currentURL)
            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw WebFetchError.invalidResponse
            }

            if Self.isRedirectStatus(httpResponse.statusCode) {
                guard redirectsFollowed < limits.maximumRedirects else {
                    bytes.task.cancel()
                    throw WebFetchError.redirectLimitExceeded(limits.maximumRedirects)
                }
                guard let location = httpResponse.value(forHTTPHeaderField: "Location") else {
                    bytes.task.cancel()
                    throw WebFetchError.redirectMissingLocation(httpResponse.statusCode)
                }
                guard let resolved = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    bytes.task.cancel()
                    throw WebFetchError.invalidURL
                }

                do {
                    let target = try WebFetchURLPolicy.validate(
                        resolved.absoluteString,
                        limits: limits
                    )
                    guard WebFetchURLPolicy.isSameOrigin(currentURL, target) else {
                        throw WebFetchError.crossOriginRedirect(
                            try WebFetchURLPolicy.normalizedOrigin(for: target)
                        )
                    }
                    bytes.task.cancel()
                    currentURL = target
                    redirectsFollowed += 1
                } catch {
                    bytes.task.cancel()
                    throw error
                }
                continue
            }

            return try await readBody(
                bytes: bytes,
                response: httpResponse,
                finalURL: currentURL
            )
        }
    }

    private func requestOnce(_ url: URL) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: limits.timeoutSeconds
        )
        request.httpMethod = "GET"
        request.setValue(
            "text/html,application/xhtml+xml,text/*;q=0.9,application/json;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(limits.userAgent, forHTTPHeaderField: "User-Agent")

        do {
            return try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw WebFetchError.timedOut
        } catch {
            throw WebFetchError.networkFailure(error.localizedDescription)
        }
    }

    private func readBody(
        bytes: URLSession.AsyncBytes,
        response: HTTPURLResponse,
        finalURL: URL
    ) async throws -> WebFetchResult {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        let kind = try WebFetchContentPolicy.classify(contentType)
        let charset = WebFetchContentPolicy.parseCharset(contentType)
        let encoding = try WebFetchContentPolicy.encoding(for: charset)
        let capped = try await readCapped(
            bytes: bytes,
            declaredLength: response.value(forHTTPHeaderField: "Content-Length")
        )
        let decoded = try WebFetchContentPolicy.decode(
            capped.data,
            encoding: encoding,
            charsetLabel: charset ?? "utf-8"
        )
        let characterCapped = Self.prefixUnicodeScalars(
            decoded,
            maximumCount: limits.maximumBodyCharacters
        )

        return WebFetchResult(
            url: finalURL.absoluteString,
            statusCode: response.statusCode,
            body: WebFetchBody(kind: kind, content: characterCapped.text),
            truncated: capped.truncated || characterCapped.truncated
        )
    }

    private func readCapped(
        bytes: URLSession.AsyncBytes,
        declaredLength: String?
    ) async throws -> (data: Data, truncated: Bool) {
        if let declaredLength,
           let length = Int64(declaredLength),
           length > Int64(limits.maximumResponseBytes) {
            bytes.task.cancel()
            throw WebFetchError.responseTooLarge(limits.maximumResponseBytes)
        }

        var data = Data()
        if let declaredLength,
           let length = Int(declaredLength),
           length > 0 {
            data.reserveCapacity(min(length, limits.maximumResponseBytes))
        }
        var truncated = false

        do {
            try await withTaskCancellationHandler {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if data.count >= limits.maximumResponseBytes {
                        truncated = true
                        bytes.task.cancel()
                        break
                    }
                    data.append(byte)
                }
            } onCancel: {
                bytes.task.cancel()
            }
        } catch is CancellationError {
            bytes.task.cancel()
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw WebFetchError.timedOut
        } catch {
            throw WebFetchError.networkFailure(error.localizedDescription)
        }
        return (data, truncated)
    }

    private static func prefixUnicodeScalars(
        _ text: String,
        maximumCount: Int
    ) -> (text: String, truncated: Bool) {
        let scalars = text.unicodeScalars
        var end = scalars.startIndex
        var count = 0
        while end != scalars.endIndex, count < maximumCount {
            scalars.formIndex(after: &end)
            count += 1
        }
        guard end != scalars.endIndex else {
            return (text, false)
        }
        return (String(scalars[..<end]), true)
    }

    private static func isRedirectStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 301, 302, 303, 307, 308:
            true
        default:
            false
        }
    }
}

enum WebFetchURLPolicy {
    static func validate(_ input: String, limits: WebFetchLimits) throws -> URL {
        guard input.utf8.count <= limits.maximumURLBytes else {
            throw WebFetchError.urlTooLong(limits.maximumURLBytes)
        }
        guard let components = URLComponents(string: input),
              let rawScheme = components.scheme,
              !rawScheme.isEmpty else {
            throw WebFetchError.invalidURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw WebFetchError.unsupportedScheme(String(rawScheme.prefix(24)))
        }
        if !(components.user ?? "").isEmpty || !(components.password ?? "").isEmpty {
            throw WebFetchError.credentialsNotAllowed
        }
        guard let url = components.url,
              let host = url.host,
              !host.isEmpty else {
            throw WebFetchError.invalidURL
        }
        return url
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else {
            return false
        }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    static func normalizedOrigin(for url: URL) throws -> String {
        guard let scheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(),
              !rawHost.isEmpty else {
            throw WebFetchError.invalidURL
        }
        let host = rawHost.contains(":") ? "[\(rawHost)]" : rawHost
        let port = effectivePort(for: url)
        let defaultPort = scheme == "https" ? 443 : 80
        if port == defaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private static func effectivePort(for url: URL) -> Int {
        if let port = url.port {
            return port
        }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}

private enum WebFetchContentPolicy {
    static func classify(_ contentType: String?) throws -> WebFetchBodyKind {
        let mimeType = (contentType ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if mimeType == "text/html" || mimeType == "application/xhtml+xml" {
            return .html
        }
        if mimeType.hasPrefix("text/")
            || mimeType == "application/json"
            || mimeType == "application/xml"
            || mimeType.hasSuffix("+json")
            || mimeType.hasSuffix("+xml") {
            return .text
        }
        let label = contentType.map { String($0.prefix(128)) } ?? "unknown"
        throw WebFetchError.unsupportedContentType(label)
    }

    static func parseCharset(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pieces = parameter.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "charset" else {
                continue
            }
            var value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : String(value.lowercased().prefix(128))
        }
        return nil
    }

    static func encoding(for charset: String?) throws -> String.Encoding {
        guard let charset else { return .utf8 }
        let converted = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard converted != kCFStringEncodingInvalidId else {
            throw WebFetchError.unsupportedCharset(charset)
        }
        return String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(converted)
        )
    }

    static func decode(
        _ data: Data,
        encoding: String.Encoding,
        charsetLabel: String
    ) throws -> String {
        if encoding == .utf8 {
            return String(decoding: data, as: UTF8.self)
        }
        guard let text = String(data: data, encoding: encoding) else {
            throw WebFetchError.decodingFailed(charsetLabel)
        }
        return text
    }
}

// The delegate is stateless; Foundation can invoke it from arbitrary delegate queues.
// Remove @unchecked Sendable once URLSessionTaskDelegate is fully Sendable-annotated.
private final class WebFetchRejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
