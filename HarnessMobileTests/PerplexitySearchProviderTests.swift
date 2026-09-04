import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the Perplexity mapping against upstream
/// `web-search-perplexity`: `search_results[]` are primary; bare
/// `citations[]` URLs are the fallback when search results are absent.
final class PerplexitySearchProviderTests: XCTestCase {
    override func tearDown() {
        SearchProviderURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSearchResultsCarryTitleAndSnippet() {
        // Perplexity attaches these to the completion response's top level.
        let response: JSONValue = .object([
            "search_results": .array([
                .object([
                    "url": .string("https://example.com/a"),
                    "title": .string("A"),
                    "snippet": .string("snippet a")
                ])
            ])
        ])
        let sources = PerplexitySearchMapper.sources(from: response)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].title, "A")
        XCTAssertEqual(sources[0].snippet, "snippet a")
    }

    func testBareCitationsFallBackToURLsOnly() {
        let response: JSONValue = .object([
            "citations": .array([
                .string("https://example.com/x"),
                .string("https://example.com/y")
            ])
        ])
        let sources = PerplexitySearchMapper.sources(from: response)
        XCTAssertEqual(sources.map(\.url), [
            "https://example.com/x",
            "https://example.com/y"
        ])
        XCTAssertTrue(sources.allSatisfy { $0.snippet.isEmpty })
    }

    func testNeitherSourceYieldsEmpty() {
        XCTAssertEqual(PerplexitySearchMapper.sources(from: .object([:])), [])
    }

    func testTransportMapsUnauthorizedStatus() async throws {
        SearchProviderURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 401,
                httpVersion: "HTTP/1.1", headerFields: nil
            ))
            return (response, Data("unauthorized".utf8))
        }
        let provider = PerplexitySearchProvider(
            resolveApiKey: { "perplexity-test" },
            baseURL: "https://perplexity.test",
            protocolClasses: [SearchProviderURLProtocolStub.self]
        )
        do {
            _ = try await provider.search(query: "swift", maximumResults: 3)
            XCTFail("expected 401")
        } catch let error as PerplexitySearchError {
            XCTAssertEqual(error, .endpoint(status: 401, detail: "端点 https://perplexity.test 返回 401：unauthorized"))
        }
    }

    func testTransportMapsTimeout() async throws {
        SearchProviderURLProtocolStub.handler = { _ in throw URLError(.timedOut) }
        let provider = PerplexitySearchProvider(
            resolveApiKey: { "perplexity-test" },
            baseURL: "https://perplexity.test",
            protocolClasses: [SearchProviderURLProtocolStub.self]
        )
        do {
            _ = try await provider.search(query: "swift", maximumResults: 3)
            XCTFail("expected timeout")
        } catch let error as WebFetchError {
            XCTAssertEqual(error, .timedOut)
        }
    }
}
