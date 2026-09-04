import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the Exa mapping against upstream `web-search-exa`: results carry
/// url/title, highlights join as the snippet, and snippet-less entries are
/// dropped only when they have no url.
final class ExaSearchProviderTests: XCTestCase {
    override func tearDown() {
        SearchProviderURLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSourcesJoinHighlightsAsSnippet() {
        let response: JSONValue = .object([
            "results": .array([
                .object([
                    "url": .string("https://example.com/a"),
                    "title": .string("A"),
                    "highlights": .array([.string("first highlight"), .string("second")])
                ]),
                .object([
                    "url": .string("https://example.com/b"),
                    "title": .string("B")
                ])
            ])
        ])
        let sources = ExaSearchProvider.sources(from: response)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].snippet, "first highlight")
        XCTAssertEqual(sources[0].url, "https://example.com/a")
    }

    func testEntriesWithoutURLOrHighlightAreDropped() {
        let response: JSONValue = .object([
            "results": .array([
                .object(["title": .string("no url")]),
                .object(["url": .string("https://example.com/no-highlight"), "title": .string("No highlight")]),
                .object([
                    "url": .string("https://example.com/ok"),
                    "title": .string("OK"),
                    "highlights": .array([.string("  "), .string("usable highlight")])
                ])
            ])
        ])
        let sources = ExaSearchProvider.sources(from: response)
        XCTAssertEqual(sources.map(\.url), ["https://example.com/ok"])
        XCTAssertEqual(sources[0].snippet, "usable highlight")
    }

    func testNonArrayResultsYieldEmpty() {
        XCTAssertEqual(ExaSearchProvider.sources(from: .object([:])), [])
    }

    func testTransportPreservesEndpointStatus() async throws {
        SearchProviderURLProtocolStub.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 429,
                httpVersion: "HTTP/1.1", headerFields: nil
            ))
            return (response, Data(#"{"error":"rate limited"}"#.utf8))
        }
        let provider = ExaSearchProvider(
            resolveApiKey: { "exa-test" },
            baseURL: "https://exa.test",
            protocolClasses: [SearchProviderURLProtocolStub.self]
        )
        do {
            _ = try await provider.search(query: "swift", maximumResults: 3)
            XCTFail("expected 429")
        } catch let error as ExaSearchError {
            XCTAssertEqual(error, .endpoint(status: 429, detail: "端点 https://exa.test 返回 429：{\"error\":\"rate limited\"}"))
        }
    }
}

final class SearchProviderURLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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
