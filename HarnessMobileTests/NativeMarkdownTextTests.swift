import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class NativeMarkdownTextTests: XCTestCase {
    func testParserRecognizesGFMTableAndColumnAlignment() throws {
        let blocks = NativeMarkdownBlock.parse("""
        Intro

        | Name | Status | Score |
        | :--- | :----: | ----: |
        | **Agent** | ready | 99.5 |
        | Phone | running | 80 |
        """)

        XCTAssertEqual(blocks.count, 2)
        guard case let .table(table) = blocks[1] else {
            return XCTFail("expected table block")
        }
        XCTAssertEqual(table.header, ["Name", "Status", "Score"])
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0], ["**Agent**", "ready", "99.5"])
    }

    func testParserKeepsEscapedAndInlineCodePipesInsideCells() throws {
        let blocks = NativeMarkdownBlock.parse("""
        A | B
        --- | ---
        left \\| right | `a|b`
        """)

        guard case let .table(table) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected table block")
        }
        XCTAssertEqual(table.rows, [["left \\| right", "`a|b`"]])
    }

    func testParserPadsShortRowsAndEndsTableAtBlankLine() throws {
        let blocks = NativeMarkdownBlock.parse("""
        A | B | C
        --- | --- | ---
        one | two

        After
        """)

        guard case let .table(table) = try XCTUnwrap(blocks.first) else {
            return XCTFail("expected table block")
        }
        XCTAssertEqual(table.rows, [["one", "two", ""]])
        XCTAssertEqual(blocks.last, .paragraph("After"))
    }

    func testParserDoesNotTreatCodeFenceOrInvalidDelimiterAsTable() {
        let fenced = NativeMarkdownBlock.parse("""
        ```
        A | B
        --- | ---
        ```
        """)
        XCTAssertEqual(fenced, [.code("A | B\n--- | ---")])

        let invalid = NativeMarkdownBlock.parse("""
        A | B
        -- | text
        """)
        XCTAssertEqual(invalid, [.paragraph("A | B -- | text")])
    }
}
