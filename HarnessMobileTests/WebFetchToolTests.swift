import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WebFetchToolTests: XCTestCase {
    override func tearDown() {
        WebFetchURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testURLPolicyRejectsUnsafeSchemesCredentialsAndOversizedURLs() {
        let limits = WebFetchLimits(
            maximumURLBytes: 32,
            maximumResponseBytes: 1_024,
            maximumBodyCharacters: 1_024,
            timeoutSeconds: 2,
            maximumRedirects: 1,
            userAgent: "web-fetch-tests"
        )

        XCTAssertThrowsError(try WebFetchURLPolicy.validate("file:///etc/passwd", limits: limits)) {
            XCTAssertEqual($0 as? WebFetchError, .unsupportedScheme("file"))
        }
        XCTAssertThrowsError(try WebFetchURLPolicy.validate("https://user:pass@example.com", limits: limits)) {
            XCTAssertEqual($0 as? WebFetchError, .credentialsNotAllowed)
        }
        XCTAssertThrowsError(
            try WebFetchURLPolicy.validate(
                "https://example.com/" + String(repeating: "x", count: 64),
                limits: limits
            )
        ) {
            XCTAssertEqual($0 as? WebFetchError, .urlTooLong(32))
        }
    }

    func testOriginNormalizationUsesEffectivePortsAndSameOriginPolicy() throws {
        let first = try XCTUnwrap(URL(string: "https://EXAMPLE.com/path"))
        let same = try XCTUnwrap(URL(string: "https://example.com:443/other"))
        let otherPort = try XCTUnwrap(URL(string: "https://example.com:8443/other"))

        XCTAssertEqual(try WebFetchURLPolicy.normalizedOrigin(for: first), "https://example.com")
        XCTAssertTrue(WebFetchURLPolicy.isSameOrigin(first, same))
        XCTAssertFalse(WebFetchURLPolicy.isSameOrigin(first, otherPort))
        XCTAssertEqual(
            try WebFetchURLPolicy.normalizedOrigin(for: otherPort),
            "https://example.com:8443"
        )
    }

    func testToolScopesApprovalToOneWebOrigin() throws {
        let tool = WebFetchTool()
        let arguments: [String: JSONValue] = [
            "url": .string("https://example.com/docs/page")
        ]

        try tool.validate(arguments: arguments)
        XCTAssertEqual(
            try tool.approvalResources(arguments: arguments),
            ["web:origin:https://example.com"]
        )
        XCTAssertEqual(tool.summary(arguments: arguments), "从手机访问网页：https://example.com")
    }

    func testClientReadsTextWithoutCookiesCredentialsOrRealNetwork() async throws {
        let limits = WebFetchLimits(
            maximumURLBytes: 2_048,
            maximumResponseBytes: 1_024,
            maximumBodyCharacters: 5,
            timeoutSeconds: 2,
            maximumRedirects: 1,
            userAgent: "web-fetch-tests"
        )
        WebFetchURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "web-fetch-tests")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain; charset=utf-8"]
                )
            )
            return (response, Data("abcdef".utf8))
        }

        let client = WebFetchHTTPClient(
            limits: limits,
            protocolClasses: [WebFetchURLProtocolStub.self]
        )
        let result = try await client.fetch("https://example.com/readme")

        XCTAssertEqual(result.url, "https://example.com/readme")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, WebFetchBody(kind: .text, content: "abcde"))
        XCTAssertTrue(result.truncated)
    }

    func testDeclaredOversizedResponseFailsBeforeBufferingBody() async throws {
        let limits = WebFetchLimits(
            maximumURLBytes: 2_048,
            maximumResponseBytes: 4,
            maximumBodyCharacters: 100,
            timeoutSeconds: 2,
            maximumRedirects: 1,
            userAgent: "web-fetch-tests"
        )
        WebFetchURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "text/plain",
                        "Content-Length": "10"
                    ]
                )
            )
            return (response, Data("0123456789".utf8))
        }

        let client = WebFetchHTTPClient(
            limits: limits,
            protocolClasses: [WebFetchURLProtocolStub.self]
        )
        do {
            _ = try await client.fetch("https://example.com/large")
            XCTFail("Expected the declared response size to be rejected")
        } catch let error as WebFetchError {
            XCTAssertEqual(error, .responseTooLarge(4))
        }
    }

    func testWebSearchDecodesFiltersResultsAndUsesPhoneNetworkOnly() async throws {
        WebFetchURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.host, "www.bing.com")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/rss+xml"]
                )
            )
            let payload = """
            <rss version="2.0"><channel>
              <item><title>Swift</title><link>https://swift.org/</link><description>Language</description></item>
              <item><title>Valid result</title><link>https://swift.org/documentation/</link><description>Docs &amp; examples</description></item>
              <item><title>Credential leak</title><link>https://user:pass@example.com/private</link><description>private</description></item>
              <item><title>Duplicate</title><link>https://swift.org/</link><description>duplicate</description></item>
              <item><title>Invalid scheme</title><link>file:///tmp/no</link><description>invalid</description></item>
            </channel></rss>
            """
            return (response, Data(payload.utf8))
        }

        let tool = WebSearchTool(protocolClasses: [WebFetchURLProtocolStub.self])
        let output = try await tool.execute(arguments: [
            "queries": .array([.string("swift")])
        ])
        XCTAssertTrue(output.contains("https://swift.org/"))
        XCTAssertTrue(output.contains("https://swift.org/documentation/"))
        XCTAssertFalse(output.contains("user:pass"))
        XCTAssertFalse(output.contains("file:///tmp/no"))
        XCTAssertTrue(output.contains("\"source_count\""))
        XCTAssertTrue(output.contains("bing-rss"))
    }

    func testWebSearchFallsBackToDuckDuckGoWhenBingIsUnavailable() async throws {
        WebFetchURLProtocolStub.handler = { request in
            if request.url?.host == "www.bing.com" {
                throw URLError(.timedOut)
            }
            XCTAssertEqual(request.url?.host, "api.duckduckgo.com")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            )
            let payload = """
            {"Heading":"Swift","AbstractText":"Language","AbstractURL":"https://swift.org/","RelatedTopics":[]}
            """
            return (response, Data(payload.utf8))
        }

        let tool = WebSearchTool(protocolClasses: [WebFetchURLProtocolStub.self])
        let output = try await tool.execute(arguments: ["queries": .array([.string("swift")])])

        XCTAssertTrue(output.contains("https://swift.org/"))
        XCTAssertTrue(output.contains("duckduckgo-instant"))
    }

    func testWebSearchProviderFailureIsReportedAsProviderError() async throws {
        WebFetchURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )
            )
            return (response, Data())
        }
        let tool = WebSearchTool(protocolClasses: [WebFetchURLProtocolStub.self])
        do {
            _ = try await tool.execute(arguments: ["queries": .array([.string("offline")])])
            XCTFail("Expected provider failure")
        } catch let error as WebFetchError {
            guard case .networkFailure(let message) = error else {
                return XCTFail("Expected an aggregate provider error, got \(error)")
            }
            XCTAssertTrue(message.contains("Bing RSS"))
            XCTAssertTrue(message.contains("DuckDuckGo"))
        }
    }

    func testWebSearchRequiresQueriesAndMergesBatchRoundRobinWithGlobalCap() async throws {
        WebFetchURLProtocolStub.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            let links: [(String, String)] = query.contains("first")
                ? [("First one", "https://example.com/one"), ("Shared", "https://example.com/shared")]
                : [("Second shared", "https://example.com/shared"), ("Second two", "https://example.com/two")]
            let items = links.map {
                "<item><title>\($0.0)</title><link>\($0.1)</link><description>snippet</description></item>"
            }.joined()
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/rss+xml"]
                )
            )
            return (response, Data("<rss><channel>\(items)</channel></rss>".utf8))
        }

        let tool = WebSearchTool(
            limits: .init(maximumResults: 3),
            protocolClasses: [WebFetchURLProtocolStub.self]
        )
        XCTAssertThrowsError(try tool.validate(arguments: ["query": .string("legacy")]))

        let output = try await tool.execute(arguments: [
            "queries": .array([.string("first"), .string("second"), .string("first")])
        ])
        XCTAssertTrue(output.contains("\"source_count\""))
        XCTAssertTrue(output.contains("https://example.com/one"))
        XCTAssertTrue(output.contains("https://example.com/shared"))
        XCTAssertTrue(output.contains("https://example.com/two"))
        XCTAssertTrue(output.contains("\"query_count\""))
    }

    func testWebSearchUsesInjectedOnDeviceProviderSeam() async throws {
        let provider = StubWebSearchProvider(
            identifier: "fixture-provider",
            approvalResources: ["web:search:fixture.example"],
            results: [
                "one": [WebSearchProviderSource(title: "One", url: "https://fixture.example/one", snippet: "first")],
                "two": [WebSearchProviderSource(title: "Two", url: "https://fixture.example/two", snippet: "second")]
            ]
        )
        let tool = WebSearchTool(provider: provider)

        XCTAssertEqual(
            try tool.approvalResources(arguments: ["queries": .array([.string("one")])]),
            ["web:search:fixture.example"]
        )
        let output = try await tool.execute(arguments: [
            "queries": .array([.string("one"), .string("two")])
        ])

        XCTAssertTrue(output.contains("fixture-provider"))
        XCTAssertTrue(output.contains("https://fixture.example/one"))
        XCTAssertTrue(output.contains("https://fixture.example/two"))
    }
}

private final class StubWebSearchProvider: WebSearchProvider, @unchecked Sendable {
    let identifier: String
    let approvalResources: Set<String>
    let results: [String: [WebSearchProviderSource]]

    init(
        identifier: String,
        approvalResources: Set<String>,
        results: [String: [WebSearchProviderSource]]
    ) {
        self.identifier = identifier
        self.approvalResources = approvalResources
        self.results = results
    }

    func search(query: String, maximumResults: Int) async throws -> [WebSearchProviderSource] {
        return Array((results[query] ?? []).prefix(maximumResults))
    }
}

private final class WebFetchURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

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
