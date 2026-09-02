import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the DeepSeek search response mapping against upstream
/// `web-search-deepseek`: result blocks carry url/title, snippets come from a
/// separate text block's citations keyed by url, and dedupe is by url.
final class DeepSeekSearchProviderTests: XCTestCase {
    private func resultBlock(_ items: [JSONValue]) -> JSONValue {
        .object(["type": .string("web_search_tool_result"), "content": .array(items)])
    }

    private func webResult(url: String, title: String) -> JSONValue {
        .object([
            "type": .string("web_search_result"),
            "url": .string(url),
            "title": .string(title),
            "page_age": .string("2 days ago")
        ])
    }

    private func textBlockWithCitation(url: String, cited: String) -> JSONValue {
        .object([
            "type": .string("text"),
            "text": .string("sources"),
            "citations": .array([
                .object(["url": .string(url), "cited_text": .string(cited)])
            ])
        ])
    }

    func testSourcesJoinCitationSnippetsAndDedupeByURL() throws {
        let response: JSONValue = .object([
            "content": .array([
                resultBlock([
                    webResult(url: "https://example.com/a", title: "A"),
                    webResult(url: "https://example.com/b", title: "B"),
                    // Same URL surfacing twice across searches is deduped.
                    webResult(url: "https://example.com/a", title: "A duplicate")
                ]),
                textBlockWithCitation(
                    url: "https://example.com/a",
                    cited: "cited excerpt for a"
                ),
                textBlockWithCitation(
                    url: "https://example.com/c",
                    cited: "cited excerpt without a result item"
                )
            ])
        ])
        let sources = try DeepSeekSearchProvider.sources(from: response, maximumResults: 8)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].url, "https://example.com/a")
        XCTAssertEqual(sources[0].title, "A")
        XCTAssertEqual(sources[0].snippet, "cited excerpt for a")
        XCTAssertEqual(sources[1].url, "https://example.com/b")
        XCTAssertEqual(sources[1].snippet, "")
    }

    func testMissingResultBlocksFailsLoudInsteadOfScrapingProse() {
        let response: JSONValue = .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string("prose only")])
            ])
        ])
        XCTAssertThrowsError(try DeepSeekSearchProvider.sources(from: response, maximumResults: 8)) {
            XCTAssertEqual($0 as? DeepSeekSearchError, .noResultBlocks)
        }
    }

    func testMaximumResultsTruncates() throws {
        let response: JSONValue = .object([
            "content": .array([
                resultBlock([
                    webResult(url: "https://example.com/1", title: "1"),
                    webResult(url: "https://example.com/2", title: "2"),
                    webResult(url: "https://example.com/3", title: "3")
                ])
            ])
        ])
        let sources = try DeepSeekSearchProvider.sources(from: response, maximumResults: 2)
        XCTAssertEqual(sources.map(\.url), [
            "https://example.com/1",
            "https://example.com/2"
        ])
    }
}
