import Foundation

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

    static func parse(_ source: String) -> [Self] {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [Self] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeFence = false
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

            if trimmed.hasPrefix("```") {
                if isInCodeFence {
                    flushCode()
                } else {
                    flushParagraph()
                }
                isInCodeFence.toggle()
                index += 1
                continue
            }

            if isInCodeFence {
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
        if isInCodeFence || !codeLines.isEmpty {
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
