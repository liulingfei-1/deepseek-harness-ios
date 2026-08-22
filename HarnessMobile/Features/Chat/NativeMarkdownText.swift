import Foundation
import SwiftUI

struct NativeMarkdownText: View {
    let source: String

    private let blocks: [NativeMarkdownBlock]

    init(source: String) {
        self.source = source
        blocks = NativeMarkdownBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Text(inlineMarkdown(text))
                        .font(headingFont(level: level))
                        .fontWeight(.semibold)
                case let .paragraph(text):
                    Text(inlineMarkdown(text))
                        .font(.body)
                case let .ordered(marker, text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(inlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .unordered(text):
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(inlineMarkdown(text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .quote(text):
                    HStack(alignment: .top, spacing: 10) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3)
                        Text(inlineMarkdown(text))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case let .code(text):
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(.rect(cornerRadius: 6))
                case let .table(table):
                    NativeMarkdownTableView(table: table)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct NativeMarkdownTableView: View {
    let table: NativeMarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.header, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                }
            }
            .padding(1)
        }
        .scrollIndicators(.visible)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.55))
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表格，\(table.rows.count + 1) 行，\(table.header.count) 列")
        .accessibilityIdentifier("markdown-table")
    }

    @ViewBuilder
    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, text in
                let alignment = table.alignments.indices.contains(column)
                    ? table.alignments[column].swiftUIAlignment
                    : Alignment.leading
                Text(inlineMarkdown(text))
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .frame(
                        minWidth: 96,
                        maxWidth: 240,
                        alignment: alignment
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        isHeader
                            ? Color.secondary.opacity(0.12)
                            : Color(uiColor: .systemBackground).opacity(0.72)
                    )
                    .overlay {
                        Rectangle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                    }
            }
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private extension NativeMarkdownTableAlignment {
    var swiftUIAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
