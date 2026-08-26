import Foundation

private struct NativeMarkdownFenceMarker: Sendable, Equatable {
    let character: Character
    let count: Int
    let hasOnlyTrailingWhitespace: Bool
}

private func nativeMarkdownFenceMarker<S: StringProtocol>(
    in line: S
) -> NativeMarkdownFenceMarker? {
    let content = line.drop(while: { $0 == " " || $0 == "\t" })
    guard let character = content.first,
          character == "`" || character == "~" else { return nil }
    let markerCount = content.prefix(while: { $0 == character }).count
    guard markerCount >= 3 else { return nil }
    let remainder = content.dropFirst(markerCount)
    return NativeMarkdownFenceMarker(
        character: character,
        count: markerCount,
        hasOnlyTrailingWhitespace: remainder.allSatisfy(\.isWhitespace)
    )
}

/// Stable identity for conversation presentation nodes. These IDs are derived
/// from durable event/message/tool identities, never from a rendered array
/// offset. Markdown blocks use a content fingerprint plus an occurrence count
/// only to disambiguate identical sibling blocks.
enum ConversationPresentationItemID: Hashable, Sendable, CustomStringConvertible {
    case event(sequence: UInt64, kind: String)
    case message(UUID)
    case reasoning(messageID: UUID)
    case toolCall(messageID: UUID, callID: String)
    case toolEvent(eventID: UUID, callID: String)
    case markdownBlock(documentID: String, kind: String, fingerprint: String, occurrence: Int)
    case markdownSegment(documentID: String, fingerprint: String, occurrence: Int)
    case streaming(runID: String, kind: String)

    var description: String {
        switch self {
        case let .event(sequence, kind): "event:\(sequence):\(kind)"
        case let .message(id): "message:\(id.uuidString)"
        case let .reasoning(messageID): "reasoning:\(messageID.uuidString)"
        case let .toolCall(messageID, callID): "tool:\(messageID.uuidString):\(callID)"
        case let .toolEvent(eventID, callID): "tool-event:\(eventID.uuidString):\(callID)"
        case let .markdownBlock(documentID, kind, fingerprint, occurrence):
            "markdown:\(documentID):\(kind):\(fingerprint):\(occurrence)"
        case let .markdownSegment(documentID, fingerprint, occurrence):
            "markdown-segment:\(documentID):\(fingerprint):\(occurrence)"
        case let .streaming(runID, kind): "stream:\(runID):\(kind)"
        }
    }
}

struct ConversationPresentationItem: Identifiable, Hashable, Sendable {
    let id: ConversationPresentationItemID

    static func message(_ message: AgentMessage) -> Self {
        Self(id: .message(message.id))
    }

    static func reasoning(messageID: UUID) -> Self {
        Self(id: .reasoning(messageID: messageID))
    }

    static func toolCall(messageID: UUID, call: AgentToolCall) -> Self {
        Self(id: .toolCall(messageID: messageID, callID: call.id))
    }
}

enum NativeMarkdownTableAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

struct NativeMarkdownTable: Sendable, Equatable {
    let header: [String]
    let rows: [[String]]
    let alignments: [NativeMarkdownTableAlignment]
}

enum NativeMarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case ordered(marker: String, text: String)
    case unordered(String)
    case quote(String)
    case code(String)
    case table(NativeMarkdownTable)

    var presentationKind: String {
        switch self {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .ordered: "ordered"
        case .unordered: "unordered"
        case .quote: "quote"
        case .code: "code"
        case .table: "table"
        }
    }

    /// Canonical visible content used only for a stable presentation key. The
    /// original source remains the durable value and is never replaced by this
    /// fingerprint or by a cached render.
    var presentationFingerprint: String {
        StablePresentationFingerprint.hex(of: presentationCacheSource)
    }

    /// Complete canonical content for exact cache derivation. It is never used
    /// as the durable model value; AgentMessage/SessionEvent remain authoritative.
    var presentationCacheSource: String {
        switch self {
        case let .heading(level, text): "h\(level):\(text)"
        case let .paragraph(text): "p:\(text)"
        case let .ordered(marker, text): "o:\(marker):\(text)"
        case let .unordered(text): "u:\(text)"
        case let .quote(text): "q:\(text)"
        case let .code(text): "c:\(text)"
        case let .table(table):
            "t:\(table.header.joined(separator: "\u{1f}")):\(table.alignments.map(String.init(describing:)).joined(separator: "\u{1f}")):\(table.rows.map { $0.joined(separator: "\u{1f}") }.joined(separator: "\u{1e}"))"
        }
    }

    func presentationItems(documentID: String) -> [NativeMarkdownBlockItem] {
        NativeMarkdownBlockItem.makeItems([self], documentID: documentID)
    }

    static func parse(_ source: String) -> [Self] {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [Self] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var activeCodeFence: NativeMarkdownFenceMarker?
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            blocks.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = nativeMarkdownFenceMarker(in: line) {
                if let openFence = activeCodeFence {
                    if marker.character == openFence.character,
                       marker.count >= openFence.count,
                       marker.hasOnlyTrailingWhitespace {
                        flushCode()
                        activeCodeFence = nil
                    } else {
                        codeLines.append(line)
                    }
                } else {
                    flushParagraph()
                    activeCodeFence = marker
                }
                index += 1
                continue
            }

            if activeCodeFence != nil {
                codeLines.append(line)
                index += 1
                continue
            }

            if let table = table(startingAt: index, lines: lines) {
                flushParagraph()
                blocks.append(.table(table.table))
                index = table.nextIndex
                continue
            }

            guard !trimmed.isEmpty else {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if let ordered = orderedItem(in: trimmed) {
                flushParagraph()
                blocks.append(.ordered(marker: ordered.marker, text: ordered.text))
            } else if let text = unorderedItem(in: trimmed) {
                flushParagraph()
                blocks.append(.unordered(text))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else {
                paragraphLines.append(trimmed)
            }
            index += 1
        }

        flushParagraph()
        if activeCodeFence != nil || !codeLines.isEmpty {
            flushCode()
        }
        return blocks
    }

    private static func table(
        startingAt index: Int,
        lines: [String]
    ) -> (table: NativeMarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let header = tableCells(in: lines[index]),
              header.count >= 2,
              let delimiter = tableCells(in: lines[index + 1]),
              delimiter.count == header.count else { return nil }
        let alignments = delimiter.compactMap(tableAlignment)
        guard alignments.count == header.count else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, var cells = tableCells(in: lines[cursor]) else { break }
            if cells.count < header.count {
                cells.append(contentsOf: repeatElement("", count: header.count - cells.count))
            } else if cells.count > header.count {
                cells = Array(cells.prefix(header.count))
            }
            rows.append(cells)
            cursor += 1
        }

        return (
            NativeMarkdownTable(header: header, rows: rows, alignments: alignments),
            cursor
        )
    }

    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var cells: [String] = []
        var buffer = ""
        var isEscaped = false
        var isInCode = false
        var foundSeparator = false

        for character in trimmed {
            if isEscaped {
                buffer.append(character)
                isEscaped = false
            } else if character == "\\" {
                buffer.append(character)
                isEscaped = true
            } else if character == "`" {
                buffer.append(character)
                isInCode.toggle()
            } else if character == "|", !isInCode {
                cells.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer.removeAll(keepingCapacity: true)
                foundSeparator = true
            } else {
                buffer.append(character)
            }
        }
        cells.append(buffer.trimmingCharacters(in: .whitespaces))
        guard foundSeparator else { return nil }
        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if trimmed.hasSuffix("|"), cells.last?.isEmpty == true {
            cells.removeLast()
        }
        return cells
    }

    private static func tableAlignment(_ cell: String) -> NativeMarkdownTableAlignment? {
        let marker = cell.trimmingCharacters(in: .whitespaces)
        let hasLeadingColon = marker.hasPrefix(":")
        let hasTrailingColon = marker.hasSuffix(":")
        let dashes = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if hasLeadingColon, hasTrailingColon { return .center }
        if hasTrailingColon { return .trailing }
        return .leading
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let markers = line.prefix { $0 == "#" }
        guard !markers.isEmpty,
              markers.count <= 6,
              line.dropFirst(markers.count).first == " " else { return nil }
        return (markers.count, String(line.dropFirst(markers.count + 1)))
    }

    private static func orderedItem(in line: String) -> (marker: String, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let suffix = line.dropFirst(digits.count)
        guard suffix.hasPrefix(". ") else { return nil }
        return (String(digits) + ".", String(suffix.dropFirst(2)))
    }

    private static func unorderedItem(in line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }
}

struct NativeMarkdownSegmentItem: Identifiable, Sendable, Equatable {
    let id: ConversationPresentationItemID
    let source: String
}

/// Lossless, fence-aware segmentation for oversized Markdown. Boundaries are
/// emitted only after blank lines outside a fenced code block, which is also a
/// block boundary for this renderer. The original source is never normalized:
/// concatenating every returned segment reproduces it byte for byte.
enum NativeMarkdownSegmentation {
    static let paginationThreshold = 50_000
    static let segmentTargetSize = 10_000

    static func requiresSegmentation(_ source: String) -> Bool {
        source.utf8.count >= paginationThreshold
    }

    static func makeSegments(
        source: String,
        documentID: String,
        targetSize: Int = segmentTargetSize
    ) -> [NativeMarkdownSegmentItem] {
        var occurrences: [String: Int] = [:]
        return split(source: source, targetSize: targetSize).map { segment in
            let fingerprint = StablePresentationFingerprint.hex(of: segment)
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            return NativeMarkdownSegmentItem(
                id: .markdownSegment(
                    documentID: documentID,
                    fingerprint: fingerprint,
                    occurrence: occurrence
                ),
                source: segment
            )
        }
    }

    private static func split(source: String, targetSize: Int) -> [String] {
        let targetSize = max(1, targetSize)
        guard source.utf8.count > targetSize else { return [source] }

        var segments: [String] = []
        var segmentStart = source.startIndex
        var lineStart = source.startIndex
        var segmentSize = 0
        var segmentHasContent = false
        var activeFence: NativeMarkdownFenceMarker?

        func consumeLine(
            contentEnd: String.Index,
            lineEnd: String.Index
        ) {
            let line = source[lineStart..<contentEnd]
            let trimmed = line.drop(while: \.isWhitespace)
            let isBlank = trimmed.isEmpty

            if let marker = nativeMarkdownFenceMarker(in: line) {
                if let openFence = activeFence {
                    if marker.character == openFence.character,
                       marker.count >= openFence.count,
                       marker.hasOnlyTrailingWhitespace {
                        activeFence = nil
                    }
                } else {
                    activeFence = marker
                }
            }

            if !isBlank {
                segmentHasContent = true
            }
            segmentSize += source[lineStart..<lineEnd].utf8.count

            guard isBlank,
                  activeFence == nil,
                  segmentHasContent,
                  segmentSize >= targetSize else {
                lineStart = lineEnd
                return
            }

            segments.append(String(source[segmentStart..<lineEnd]))
            segmentStart = lineEnd
            lineStart = lineEnd
            segmentSize = 0
            segmentHasContent = false
        }

        while let newline = source[lineStart...].firstIndex(of: "\n") {
            let nextLine = source.index(after: newline)
            consumeLine(contentEnd: newline, lineEnd: nextLine)
        }

        if lineStart < source.endIndex {
            consumeLine(contentEnd: source.endIndex, lineEnd: source.endIndex)
        }
        if segmentStart < source.endIndex {
            segments.append(String(source[segmentStart..<source.endIndex]))
        }
        if segments.isEmpty {
            segments.append(source)
        }
        return segments
    }
}

struct NativeMarkdownBlockItem: Identifiable, Sendable, Equatable {
    let id: ConversationPresentationItemID
    let block: NativeMarkdownBlock

    static func makeItems(
        _ blocks: [NativeMarkdownBlock],
        documentID: String
    ) -> [Self] {
        var occurrences: [String: Int] = [:]
        return parseItems(from: blocks, documentID: documentID, occurrences: &occurrences)
    }

    private static func parseItems(
        from blocks: [NativeMarkdownBlock],
        documentID: String,
        occurrences: inout [String: Int]
    ) -> [Self] {
        blocks.map { block in
            let key = "\(block.presentationKind):\(block.presentationFingerprint)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return Self(
                id: .markdownBlock(
                    documentID: documentID,
                    kind: block.presentationKind,
                    fingerprint: block.presentationFingerprint,
                    occurrence: occurrence
                ),
                block: block
            )
        }
    }
}

/// Small, process-local FNV-1a fingerprint. It is used for identity only, not
/// as an integrity check or a replacement for the complete Markdown source.
enum StablePresentationFingerprint {
    static func hex(of value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

struct NativeMarkdownTableRowItem: Identifiable, Sendable, Equatable {
    let id: String
    let cells: [String]
}

struct NativeMarkdownTableCellItem: Identifiable, Sendable, Equatable {
    let id: String
    let column: Int
    let text: String
}

extension NativeMarkdownTable {
    var presentationRows: [NativeMarkdownTableRowItem] {
        var occurrences: [String: Int] = [:]
        return rows.map { cells in
            let fingerprint = StablePresentationFingerprint.hex(of: cells.joined(separator: "\u{1f}"))
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            return NativeMarkdownTableRowItem(
                id: "row:\(fingerprint):\(occurrence)",
                cells: cells
            )
        }
    }

    var presentationColumnIDs: [String] {
        var occurrences: [String: Int] = [:]
        return header.map { value in
            let fingerprint = StablePresentationFingerprint.hex(of: value)
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            return "column:\(fingerprint):\(occurrence)"
        }
    }
}

struct MarkdownRenderCacheKey: Hashable, Sendable {
    let source: String
    let width: Int
    let dynamicType: String

    init(source: String, width: CGFloat, dynamicType: String) {
        self.source = source
        self.width = max(0, Int(width.rounded()))
        self.dynamicType = dynamicType
    }
}

struct ConversationPresentationMeasurementKey: Hashable, Sendable {
    let itemID: ConversationPresentationItemID
    let kind: String
    let content: String
    let width: Int
    let dynamicType: String

    init(
        itemID: ConversationPresentationItemID,
        kind: String,
        content: String,
        width: CGFloat,
        dynamicType: String
    ) {
        self.itemID = itemID
        self.kind = kind
        self.content = content
        self.width = max(0, Int(width.rounded()))
        self.dynamicType = dynamicType
    }
}

/// Bounded memoization for derived Markdown parsing and inline rendering.
/// Cache eviction is deliberately conservative: canonical message text stays
/// in AgentMessage/SessionEvent and is never evicted or truncated here.
final class MarkdownRenderCache: @unchecked Sendable {
    static let shared = MarkdownRenderCache(capacity: 512)

    private let capacity: Int
    private var parsed: [String: [NativeMarkdownBlock]] = [:]
    private var parsedOrder: [String] = []
    private var attributed: [MarkdownRenderCacheKey: AttributedString] = [:]
    private var attributedOrder: [MarkdownRenderCacheKey] = []
    private var measurements: [ConversationPresentationMeasurementKey: CGFloat] = [:]
    private var measurementOrder: [ConversationPresentationMeasurementKey] = []
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func blocks(for source: String) -> [NativeMarkdownBlock] {
        lock.lock()
        if let value = parsed[source] {
            touch(source, in: &parsedOrder)
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = NativeMarkdownBlock.parse(source)
        lock.lock()
        parsed[source] = value
        touch(source, in: &parsedOrder)
        trim(&parsed, order: &parsedOrder)
        lock.unlock()
        return value
    }

    func attributedString(
        source: String,
        width: CGFloat,
        dynamicType: String
    ) -> AttributedString {
        let key = MarkdownRenderCacheKey(source: source, width: width, dynamicType: dynamicType)
        lock.lock()
        if let value = attributed[key] {
            touch(key, in: &attributedOrder)
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = (try? AttributedString(markdown: source)) ?? AttributedString(source)
        lock.lock()
        attributed[key] = value
        touch(key, in: &attributedOrder)
        trim(&attributed, order: &attributedOrder)
        lock.unlock()
        return value
    }

    func removeAll() {
        lock.lock()
        parsed.removeAll(keepingCapacity: true)
        parsedOrder.removeAll(keepingCapacity: true)
        attributed.removeAll(keepingCapacity: true)
        attributedOrder.removeAll(keepingCapacity: true)
        measurements.removeAll(keepingCapacity: true)
        measurementOrder.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func measuredHeight(for key: ConversationPresentationMeasurementKey) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = measurements[key] else { return nil }
        touch(key, in: &measurementOrder)
        return value
    }

    func recordMeasuredHeight(
        _ height: CGFloat,
        for key: ConversationPresentationMeasurementKey
    ) {
        guard height >= 0, key.width > 0 else { return }
        lock.lock()
        measurements[key] = height
        touch(key, in: &measurementOrder)
        trim(&measurements, order: &measurementOrder)
        lock.unlock()
    }

    func counts() -> (parsed: Int, attributed: Int, measurements: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (parsed.count, attributed.count, measurements.count)
    }

    private func touch<Key: Hashable>(_ key: Key, in order: inout [Key]) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trim<Key: Hashable, Value>(
        _ values: inout [Key: Value],
        order: inout [Key]
    ) {
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}
