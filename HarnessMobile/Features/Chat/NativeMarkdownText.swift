import Foundation
import SwiftUI
import UIKit

struct NativeMarkdownText: View {
    let source: String
    let documentID: String

    private let shortDocumentBlocks: [NativeMarkdownBlockItem]
    private let requiresSegmentation: Bool
    private let segmentationTaskID: String
    @State private var measuredWidth: CGFloat = 0
    @State private var segments: [NativeMarkdownSegmentItem]?

    init(source: String, documentID: String = "markdown-document") {
        self.source = source
        self.documentID = documentID
        let requiresSegmentation = NativeMarkdownSegmentation.requiresSegmentation(source)
        self.requiresSegmentation = requiresSegmentation
        segmentationTaskID = "\(documentID):\(source.utf8.count)"
        shortDocumentBlocks = requiresSegmentation
            ? []
            : NativeMarkdownBlockItem.makeItems(
                MarkdownRenderCache.shared.blocks(for: source),
                documentID: documentID
            )
    }

    var body: some View {
        Group {
            if requiresSegmentation {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        UIPasteboard.general.string = source
                    } label: {
                        Label("复制完整 Markdown", systemImage: "doc.on.doc")
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("copy-complete-markdown")
                    .accessibilityValue("\(source.utf8.count) 字节")

                    if let segments {
                        if let first = segments.first {
                            NativeMarkdownSegmentView(
                                segment: first,
                                documentID: documentID,
                                availableWidth: measuredWidth,
                                rendersImmediately: true
                            )
                        }

                        if segments.count > 2 {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(segments.dropFirst().dropLast()) { segment in
                                    NativeMarkdownSegmentView(
                                        segment: segment,
                                        documentID: documentID,
                                        availableWidth: measuredWidth,
                                        rendersImmediately: false
                                    )
                                }
                            }
                        }

                        if segments.count > 1, let last = segments.last {
                            NativeMarkdownSegmentView(
                                segment: last,
                                documentID: documentID,
                                availableWidth: measuredWidth,
                                rendersImmediately: true
                            )
                        }
                    } else {
                        LargeMarkdownPreparationView()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shortDocumentBlocks) { item in
                        NativeMarkdownBlockView(
                            item: item,
                            documentID: documentID,
                            availableWidth: measuredWidth
                        )
                    }
                }
            }
        }
        .textSelection(.enabled)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { nextWidth in
            if abs(nextWidth - measuredWidth) >= 0.5 {
                measuredWidth = nextWidth
            }
        }
        .task(id: segmentationTaskID) {
            guard requiresSegmentation else { return }
            segments = nil
            let source = source
            let documentID = documentID
            let generated = await Task.detached(priority: .userInitiated) {
                NativeMarkdownSegmentation.makeSegments(
                    source: source,
                    documentID: documentID
                )
            }.value
            guard !Task.isCancelled else { return }
            segments = generated
        }
    }
}

private struct LargeMarkdownPreparationView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在准备超长 Markdown…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("large-markdown-preparing")
    }
}

private struct NativeMarkdownSegmentView: View {
    let segment: NativeMarkdownSegmentItem
    let documentID: String
    let availableWidth: CGFloat
    let rendersImmediately: Bool

    @State private var blocks: [NativeMarkdownBlockItem]?
    @State private var shouldRender = false

    var body: some View {
        Group {
            if let blocks {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks) { item in
                        NativeMarkdownBlockView(
                            item: item,
                            documentID: segmentDocumentID,
                            availableWidth: availableWidth
                        )
                    }
                }
            } else {
                segmentPlaceholder
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            if visible {
                shouldRender = true
            }
        }
        .task(id: rendersImmediately || shouldRender) {
            guard (rendersImmediately || shouldRender), blocks == nil else { return }
            let source = segment.source
            let documentID = segmentDocumentID
            let renderedBlocks = await Task.detached(priority: .userInitiated) {
                NativeMarkdownBlockItem.makeItems(
                    MarkdownRenderCache.shared.blocks(for: source),
                    documentID: documentID
                )
            }.value
            guard !Task.isCancelled else { return }
            blocks = renderedBlocks
        }
    }

    private var segmentDocumentID: String {
        "\(documentID):\(segment.id.description)"
    }

    private var estimatedHeight: CGFloat {
        let width = max(availableWidth, 280)
        let estimatedCharactersPerLine = max(24, Int(width / 8))
        let estimatedLines = max(
            3,
            (segment.source.utf8.count + estimatedCharactersPerLine - 1)
                / estimatedCharactersPerLine
        )
        return min(12_000, CGFloat(estimatedLines) * 22)
    }

    private var segmentPlaceholder: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(height: estimatedHeight)
            ProgressView()
                .controlSize(.small)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("正在渲染 Markdown 分段")
    }
}

private struct NativeMarkdownBlockView: View {
    let item: NativeMarkdownBlockItem
    let documentID: String
    let availableWidth: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ConversationMeasuredBlock(
            itemID: item.id,
            kind: item.block.presentationKind,
            content: item.block.presentationCacheSource
        ) {
            blockContent
        }
    }

    @ViewBuilder
    private var blockContent: some View {
        switch item.block {
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
            .background(HarnessTheme.surface, in: RoundedRectangle(cornerRadius: HarnessTheme.Radius.small, style: .continuous))
        case let .table(table):
            NativeMarkdownTableView(
                table: table,
                documentID: "\(documentID)-\(item.id)"
            )
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        MarkdownRenderCache.shared.attributedString(
            source: text,
            width: availableWidth,
            dynamicType: String(describing: dynamicTypeSize)
        )
    }
}

/// Reuses only a prior real SwiftUI measurement for the exact presentation
/// item/content/width/Dynamic Type key. The cache never stores or substitutes
/// model content, and a changed key is remeasured before it can be reused.
struct ConversationMeasuredBlock<Content: View>: View {
    let itemID: ConversationPresentationItemID
    let kind: String
    let measurementContent: String
    private let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var cachedMinimumHeight: CGFloat?
    @State private var activeMeasurementKey: ConversationPresentationMeasurementKey?

    init(
        itemID: ConversationPresentationItemID,
        kind: String,
        content: String,
        @ViewBuilder contentBuilder: () -> Content
    ) {
        self.itemID = itemID
        self.kind = kind
        measurementContent = content
        self.content = contentBuilder()
    }

    var body: some View {
        content
            .frame(minHeight: cachedMinimumHeight, alignment: .top)
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                updateMeasurement(size)
            }
            .onChange(of: dynamicTypeSize) {
                cachedMinimumHeight = nil
                activeMeasurementKey = nil
            }
    }

    private func updateMeasurement(_ size: CGSize) {
        guard size.width > 0, size.height >= 0 else { return }
        let key = ConversationPresentationMeasurementKey(
            itemID: itemID,
            kind: kind,
            content: measurementContent,
            width: size.width,
            dynamicType: String(describing: dynamicTypeSize)
        )
        if activeMeasurementKey != key {
            let hadPreviousKey = activeMeasurementKey != nil
            activeMeasurementKey = key
            if let cached = MarkdownRenderCache.shared.measuredHeight(for: key) {
                cachedMinimumHeight = cached
            } else if hadPreviousKey {
                // The current geometry may still include the previous key's
                // minimum. Clear it and let the next layout report a clean size.
                cachedMinimumHeight = nil
            } else {
                MarkdownRenderCache.shared.recordMeasuredHeight(size.height, for: key)
                cachedMinimumHeight = size.height
            }
            return
        }

        let cached = MarkdownRenderCache.shared.measuredHeight(for: key)
        let nextHeight: CGFloat
        if let cached, abs(cached - size.height) < 1 {
            nextHeight = cached
        } else {
            MarkdownRenderCache.shared.recordMeasuredHeight(size.height, for: key)
            nextHeight = size.height
        }
        if cachedMinimumHeight.map({ abs($0 - nextHeight) >= 0.5 }) ?? true {
            cachedMinimumHeight = nextHeight
        }
    }
}

private struct NativeMarkdownTableView: View {
    let table: NativeMarkdownTable
    let documentID: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(table.header, isHeader: true, rowID: "header")
                ForEach(table.presentationRows) { row in
                    tableRow(row.cells, isHeader: false, rowID: row.id)
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { nextWidth in
            if abs(nextWidth - measuredWidth) >= 0.5 {
                measuredWidth = nextWidth
            }
        }
    }

    @ViewBuilder
    private func tableRow(_ cells: [String], isHeader: Bool, rowID: String) -> some View {
        GridRow {
            ForEach(tableCellItems(cells: cells, rowID: rowID)) { cell in
                let column = cell.column
                let text = cell.text
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

    private func tableCellItems(cells: [String], rowID: String) -> [NativeMarkdownTableCellItem] {
        var occurrences: [String: Int] = [:]
        let columnIDs = table.presentationColumnIDs
        return cells.indices.map { column in
            let text = cells[column]
            let columnID = columnIDs.indices.contains(column)
                ? columnIDs[column]
                : "column:\(StablePresentationFingerprint.hex(of: String(column)))"
            let fingerprint = StablePresentationFingerprint.hex(of: text)
            let occurrenceKey = "\(columnID):\(fingerprint)"
            let occurrence = occurrences[occurrenceKey, default: 0]
            occurrences[occurrenceKey] = occurrence + 1
            return NativeMarkdownTableCellItem(
                id: "\(rowID):\(columnID):\(fingerprint):\(occurrence)",
                column: column,
                text: text
            )
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        MarkdownRenderCache.shared.attributedString(
            source: text,
            width: measuredWidth,
            dynamicType: String(describing: dynamicTypeSize)
        )
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
