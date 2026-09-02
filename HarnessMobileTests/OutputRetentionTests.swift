import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the output-retention primitives and the tool-result pruner against
/// upstream contracts: byte-oriented budgets, UTF-8-safe cuts, precise
/// omission counts, and head+marker+tail pruning.
final class OutputRetentionTests: XCTestCase {
    func testHeadTailWindowsCountBytesAndReportOmission() {
        // "héllo" — é is two bytes, so byte budgets cut differently than
        // character counts would.
        let text = "héllo world"
        let head = OutputRetention.retainText(text, strategy: .head(maxBytes: 4))
        XCTAssertEqual(head.text, "hél")
        XCTAssertEqual(head.omittedBytes, .exact(count: 8))

        let tail = OutputRetention.retainText(text, strategy: .tail(maxBytes: 5))
        XCTAssertEqual(tail.text, "world")
        XCTAssertEqual(tail.omittedBytes, .exact(count: 7))

        let within = OutputRetention.retainText(text, strategy: .head(maxBytes: 100))
        XCTAssertEqual(within.text, text)
        XCTAssertEqual(within.omittedBytes, .none)
        XCTAssertFalse(within.truncated)
    }

    func testHeadTailStrategySplitsWithoutLossWhenBudgetCoversAll() {
        let text = "abcdef"
        let covering = OutputRetention.retainText(
            text,
            strategy: .headTail(headBytes: 10, tailBytes: 10)
        )
        XCTAssertEqual(covering.text, text)
        XCTAssertFalse(covering.truncated)
    }

    func testPrunerProducesHeadMarkerTailWithinBudget() {
        let original = String(repeating: "A", count: 500) + "MIDDLE" + String(repeating: "B", count: 500)
        let pruned = ToolResultPruner.prune(original, maxBytes: 200)
        XCTAssertLessThanOrEqual(pruned.utf8.count, ToolResultPruner.defaultMaxBytes)
        XCTAssertTrue(pruned.contains(ToolResultPruner.middleMarker))
        XCTAssertTrue(pruned.hasPrefix("AAA"))
        XCTAssertTrue(pruned.hasSuffix("BBB"))
        // Full original stays out of the pruned copy — replay keeps it in the
        // durable log instead.
        XCTAssertFalse(pruned.contains("MIDDLE"))
    }

    func testPrunerPassesThroughWithinBudget() {
        let original = "small result"
        XCTAssertEqual(ToolResultPruner.prune(original, maxBytes: 1024), original)
    }

    func testCutsNeverSplitMultibyteCharacters() {
        // 汉字 are three bytes each; a byte budget of 4 must keep exactly one.
        let text = "字字字字"
        let head = OutputRetention.safeHead(text, maxBytes: 4)
        XCTAssertEqual(head, "字")
        let tail = OutputRetention.safeTail(text, maxBytes: 4)
        XCTAssertEqual(tail, "字")
    }
}
