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
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].snippet, "first highlight second")
        XCTAssertEqual(sources[1].snippet, "")
    }

    func testEntriesWithoutURLAreDropped() {
        let response: JSONValue = .object([
            "results": .array([
                .object(["title": .string("no url")]),
                .object(["url": .string("https://example.com/ok"), "title": .string("OK")])
            ])
        ])
        let sources = ExaSearchProvider.sources(from: response)
        XCTAssertEqual(sources.map(\.url), ["https://example.com/ok"])
    }

    func testNonArrayResultsYieldEmpty() {
        XCTAssertEqual(ExaSearchProvider.sources(from: .object([:])), [])
    }
}
