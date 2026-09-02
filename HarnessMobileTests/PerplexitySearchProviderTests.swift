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
    func testSearchResultsCarryTitleAndSnippet() {
        let response: JSONValue = .object([
            "choices": .array([
                .object([
                    "message": .object([
                        "search_results": .array([
                            .object([
                                "url": .string("https://example.com/a"),
                                "title": .string("A"),
                                "snippet": .string("snippet a")
                            ])
                        ])
                    ])
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
}
