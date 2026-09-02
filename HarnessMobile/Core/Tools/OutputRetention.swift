import Foundation

/// Mirrors upstream `dsh-output-retention`: bounded retention of tool output
/// with precise omission metadata. The library only answers "what was kept
/// and what was omitted" — grouping, line numbers, spill files, and recovery
/// instructions stay with each tool.
///
/// Text retention is BYTE-oriented for body safety; every cut preserves UTF-8
/// boundaries so the returned text never carries a replacement character
/// introduced by the cut itself.
enum OutputRetention {
    // MARK: - Omission bookkeeping

    enum Omitted: Equatable, Sendable {
        case none
        case exact(count: Int)
        /// Reserved for a caller that omits without a count; the retainers
        /// themselves never return it.
        case unknown

        var isEmpty: Bool {
            if case .none = self { return true }
            return false
        }
    }

    struct RetainedText: Equatable, Sendable {
        var text: String
        var truncated: Bool
        var omittedBytes: Omitted
    }

    struct RetainedItems<T> {
        var items: [T]
        var truncated: Bool
        var seen: Int
        var kept: Int
        var omitted: Omitted
    }

    // MARK: - Text retention

    enum TextStrategy: Equatable, Sendable {
        /// Keep the first `maxBytes` bytes.
        case head(maxBytes: Int)
        /// Keep the final `maxBytes` bytes.
        case tail(maxBytes: Int)
        /// Keep a stable prefix and suffix, omitting the middle.
        case headTail(headBytes: Int, tailBytes: Int)
    }

    /// Retains `text` under the byte strategy, cutting only on UTF-8
    /// boundaries.
    static func retainText(_ text: String, strategy: TextStrategy) -> RetainedText {
        let bytes = Array(text.utf8)
        switch strategy {
        case let .head(maxBytes):
            let keptCount = min(maxBytes, bytes.count)
            let kept = utf8SafePrefix(bytes, count: keptCount)
            return RetainedText(
                text: kept,
                truncated: keptCount < bytes.count,
                omittedBytes: omitted(bytes.count - keptCount)
            )
        case let .tail(maxBytes):
            let keptCount = min(maxBytes, bytes.count)
            let kept = utf8SafeSuffix(bytes, count: keptCount)
            return RetainedText(
                text: kept,
                truncated: keptCount < bytes.count,
                omittedBytes: omitted(bytes.count - keptCount)
            )
        case let .headTail(headBytes, tailBytes):
            let headCount = min(headBytes, bytes.count)
            // The tail window starts after the head window; when the two
            // budgets cover the whole text nothing is omitted.
            let tailStart = max(headCount, bytes.count - min(tailBytes, bytes.count))
            if tailStart <= headCount {
                return RetainedText(
                    text: text,
                    truncated: false,
                    omittedBytes: .none
                )
            }
            let head = utf8SafePrefix(bytes, count: headCount)
            let tail = utf8SafeSuffix(bytes, count: bytes.count - tailStart)
            return RetainedText(
                text: head + tail,
                truncated: true,
                omittedBytes: omitted(tailStart - headCount)
            )
        }
    }

    /// Backs off up to 3 bytes so the cut never lands inside a multi-byte
    /// UTF-8 sequence (continuation bytes are 0b10xxxxxx).
    static func utf8SafePrefix(_ bytes: [UInt8], count: Int) -> String {
        var end = count
        while end > 0, end < bytes.count, isContinuation(bytes[end]) {
            end -= 1
        }
        return String(decoding: bytes[0..<end], as: UTF8.self)
    }

    static func utf8SafeSuffix(_ bytes: [UInt8], count: Int) -> String {
        var start = bytes.count - count
        while start < bytes.count, isContinuation(bytes[start]) {
            start += 1
        }
        return String(decoding: bytes[start..<bytes.count], as: UTF8.self)
    }

    /// UTF-8-boundary-safe prefix of a string, capped at `maxBytes`.
    static func safeHead(_ text: String, maxBytes: Int) -> String {
        utf8SafePrefix(Array(text.utf8), count: min(maxBytes, text.utf8.count))
    }

    /// UTF-8-boundary-safe suffix of a string, capped at `maxBytes`.
    static func safeTail(_ text: String, maxBytes: Int) -> String {
        utf8SafeSuffix(Array(text.utf8), count: min(maxBytes, text.utf8.count))
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0b1100_0000 == 0b1000_0000
    }

    private static func omitted(_ count: Int) -> Omitted {
        count == 0 ? .none : .exact(count: count)
    }
}

/// Mirrors upstream `compaction-tool-result-pruner`: before compaction runs,
/// tool results beyond the byte budget are replaced by a bounded head, a
/// short middle marker, and a bounded tail. The full original result stays in
/// the durable session log for exact replay; pruning itself makes no model
/// call and may relieve token pressure enough for compaction to be skipped.
enum ToolResultPruner {
    static let middleMarker = "\n[... 中间内容已修剪，完整原文保留在会话日志 ...]\n"
    /// Default per-result budget applied at compaction time.
    static let defaultMaxBytes = 8 * 1_024

    /// Prunes one tool result into head + middle marker + tail. Results
    /// within budget pass through untouched.
    static func prune(_ text: String, maxBytes: Int = ToolResultPruner.defaultMaxBytes) -> String {
        let byteCount = text.utf8.count
        guard byteCount > maxBytes else { return text }
        // Reserve room for the marker inside the overall budget.
        let markerBytes = middleMarker.utf8.count
        let windowBytes = max(0, maxBytes - markerBytes)
        let headBytes = windowBytes / 2
        let tailBytes = windowBytes - headBytes
        return OutputRetention.safeHead(text, maxBytes: headBytes)
            + middleMarker
            + OutputRetention.safeTail(text, maxBytes: tailBytes)
    }
}
