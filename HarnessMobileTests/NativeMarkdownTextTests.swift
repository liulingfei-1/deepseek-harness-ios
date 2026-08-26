import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class NativeMarkdownTextTests: XCTestCase {
    func testSemanticSegmentsPreserveExactSourceAndParsedBlocksAtRequiredScales() {
        for characterCount in [50_000, 250_000, 1_000_000] {
            let source = makeLargeMarkdown(characterCount: characterCount)
            XCTAssertEqual(source.count, characterCount)

            let segments = NativeMarkdownSegmentation.makeSegments(
                source: source,
                documentID: "scale-\(characterCount)",
                targetSize: 10_000
            )

            XCTAssertGreaterThan(segments.count, 1, "expected segmented scale \(characterCount)")
            XCTAssertEqual(segments.map(\.source).joined(), source)
            XCTAssertEqual(
                segments.flatMap { NativeMarkdownBlock.parse($0.source) },
                NativeMarkdownBlock.parse(source),
                "segment boundaries changed Markdown semantics at \(characterCount) characters"
            )
            XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
        }
    }

    func testSemanticSegmentsDoNotCutFenceTableOrQuoteGroups() throws {
        let source = """
        Prelude paragraph that makes the target boundary arrive soon.

        > quoted line one
        > quoted line two
        > quoted line three

        | Name | Status |
        | :--- | :----: |
        | Harness | ready |
        | Phone | local |

        ~~~~swift
        let table = "A | B"

        print(table)
        ~~~~

        After the protected structures.
        """
        let segments = NativeMarkdownSegmentation.makeSegments(
            source: source,
            documentID: "protected",
            targetSize: 64
        )

        XCTAssertEqual(segments.map(\.source).joined(), source)
        XCTAssertEqual(
            segments.flatMap { NativeMarkdownBlock.parse($0.source) },
            NativeMarkdownBlock.parse(source)
        )

        let quoteSegment = try XCTUnwrap(segments.first { $0.source.contains("> quoted line one") })
        XCTAssertTrue(quoteSegment.source.contains("> quoted line three"))
        let tableSegment = try XCTUnwrap(segments.first { $0.source.contains("| Name | Status |") })
        XCTAssertTrue(tableSegment.source.contains("| Phone | local |"))
        let fenceSegment = try XCTUnwrap(segments.first { $0.source.contains("~~~~swift") })
        XCTAssertTrue(fenceSegment.source.contains("print(table)"))
        XCTAssertTrue(fenceSegment.source.contains("~~~~\n"))
    }

    func testSemanticSegmentIDsSurvivePrefixInsertion() {
        let original = NativeMarkdownSegmentation.makeSegments(
            source: makeSegmentIdentityFixture(prefix: ""),
            documentID: "message-1",
            targetSize: 80
        )
        let inserted = NativeMarkdownSegmentation.makeSegments(
            source: makeSegmentIdentityFixture(prefix: "Inserted paragraph.\n\n"),
            documentID: "message-1",
            targetSize: 80
        )

        XCTAssertTrue(original.dropFirst().allSatisfy { item in
            inserted.contains { $0.id == item.id && $0.source == item.source }
        })
    }

    func testOneMillionCharacterSegmentationCompletesWithinCrashGateBudget() {
        let source = makeLargeMarkdown(characterCount: 1_000_000)
        let started = ContinuousClock.now
        let segments = NativeMarkdownSegmentation.makeSegments(
            source: source,
            documentID: "million-character-gate",
            targetSize: 10_000
        )
        let elapsed = started.duration(to: ContinuousClock.now)

        XCTAssertEqual(segments.map(\.source).joined(), source)
        XCTAssertLessThan(elapsed, .seconds(5))
    }

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

    func testParserRecognizesTildeFenceAndRequiresMatchingClosingMarker() {
        let fenced = NativeMarkdownBlock.parse("""
        ~~~~swift
        let value = "``` is not the closer"
        ~~~
        ~~~~
        """)

        XCTAssertEqual(
            fenced,
            [.code("let value = \"``` is not the closer\"\n~~~")]
        )
    }

    func testMarkdownPresentationIDsDoNotUseArrayOffsets() {
        let original = NativeMarkdownBlockItem.makeItems(
            NativeMarkdownBlock.parse("First\n\nSecond\n\nThird"),
            documentID: "message-1"
        )
        let inserted = NativeMarkdownBlockItem.makeItems(
            NativeMarkdownBlock.parse("Inserted\n\nFirst\n\nSecond\n\nThird"),
            documentID: "message-1"
        )

        XCTAssertTrue(original.dropFirst().allSatisfy { item in
            inserted.contains { $0.id == item.id }
        })
        XCTAssertFalse(original.contains { $0.id.description.contains(":0") && $0.block == .paragraph("Inserted") })
    }

    func testMarkdownRenderCacheKeyIncludesSourceWidthAndDynamicType() {
        let narrow = MarkdownRenderCacheKey(source: "same", width: 320, dynamicType: "large")
        let wide = MarkdownRenderCacheKey(source: "same", width: 640, dynamicType: "large")
        let accessibility = MarkdownRenderCacheKey(source: "same", width: 320, dynamicType: "accessibility3")
        let changed = MarkdownRenderCacheKey(source: "changed", width: 320, dynamicType: "large")

        XCTAssertNotEqual(narrow, wide)
        XCTAssertNotEqual(narrow, accessibility)
        XCTAssertNotEqual(narrow, changed)

        let itemID = ConversationPresentationItemID.message(UUID())
        let measured = ConversationPresentationMeasurementKey(
            itemID: itemID,
            kind: "markdown",
            content: "same",
            width: 320,
            dynamicType: "large"
        )
        XCTAssertNotEqual(
            measured,
            ConversationPresentationMeasurementKey(
                itemID: itemID,
                kind: "reasoning",
                content: "same",
                width: 320,
                dynamicType: "large"
            )
        )
        XCTAssertNotEqual(
            measured,
            ConversationPresentationMeasurementKey(
                itemID: itemID,
                kind: "markdown",
                content: "changed",
                width: 320,
                dynamicType: "large"
            )
        )
    }

    func testMarkdownRenderCacheIsBoundedAndPreservesCompleteSource() {
        let cache = MarkdownRenderCache(capacity: 8)
        let source = String(repeating: "完整正文 ", count: 200)
        XCTAssertEqual(cache.blocks(for: source), NativeMarkdownBlock.parse(source))

        for index in 0..<1000 {
            _ = cache.blocks(for: "message \(index)")
            _ = cache.attributedString(source: "**message \(index)**", width: 320, dynamicType: "large")
            let key = ConversationPresentationMeasurementKey(
                itemID: .event(sequence: UInt64(index), kind: "markdown"),
                kind: "markdown",
                content: "message \(index)",
                width: 320,
                dynamicType: "large"
            )
            cache.recordMeasuredHeight(CGFloat(index + 1), for: key)
            XCTAssertEqual(cache.measuredHeight(for: key), CGFloat(index + 1))
        }

        let counts = cache.counts()
        XCTAssertLessThanOrEqual(counts.parsed, 8)
        XCTAssertLessThanOrEqual(counts.attributed, 8)
        XCTAssertLessThanOrEqual(counts.measurements, 8)
        XCTAssertEqual(cache.blocks(for: source), NativeMarkdownBlock.parse(source))
    }

    func testPresentationItemIDsScaleAcrossThousandMessagesHundredToolsAndFiveMinuteStream() {
        var IDs = Set<ConversationPresentationItemID>()
        var firstMessageID: UUID?
        for messageIndex in 0..<1_000 {
            let messageID = UUID()
            firstMessageID = firstMessageID ?? messageID
            IDs.insert(ConversationPresentationItem.message(
                AgentMessage(id: messageID, role: .assistant, content: "message \(messageIndex)")
            ).id)
        }

        let toolOwner = try! XCTUnwrap(firstMessageID)
        for toolIndex in 0..<100 {
            let call = AgentToolCall(id: "call-\(toolIndex)", name: "tool", arguments: "{}")
            IDs.insert(ConversationPresentationItem.toolCall(messageID: toolOwner, call: call).id)
        }

        // Five minutes at the production 8 Hz presentation cadence must retain
        // one streaming identity; content revisions are not list identities.
        let streamingID = ConversationPresentationItemID.streaming(runID: "run-1", kind: "text")
        for _ in 0..<(5 * 60 * 8) {
            IDs.insert(streamingID)
        }
        IDs.insert(.event(sequence: 42, kind: "assistant-message"))

        XCTAssertEqual(IDs.count, 1_000 + 100 + 1 + 1)
        XCTAssertTrue(IDs.contains(streamingID))
    }


    private func makeLargeMarkdown(characterCount: Int) -> String {
        let semanticPrefix = """
        # large-markdown-start

        [OpenAI](https://openai.com)

        > quoted line one
        > quoted line two

        | Name | Status |
        | :--- | :----: |
        | Harness | ready |

        ```swift
        let localOnly = true
        ```

        """
        let paragraph = String(repeating: "bounded markdown paragraph word ", count: 120) + "\n\n"
        var source = semanticPrefix
        while source.count + paragraph.count <= characterCount {
            source += paragraph
        }
        source += String(repeating: "x", count: characterCount - source.count)
        return source
    }

    private func makeSegmentIdentityFixture(prefix: String) -> String {
        prefix + (0..<8).map { index in
            "Stable paragraph \(index) " + String(repeating: "word ", count: 16)
        }.joined(separator: "\n\n")
    }
}
