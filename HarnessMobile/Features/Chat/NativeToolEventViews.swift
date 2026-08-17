import SwiftUI

struct NativeToolEventRowSummary: Equatable {
    let text: String
    let suffix: String?
    let isError: Bool

    static func make(
        event: AgentToolEvent,
        presentation: NativeToolEventPresentation
    ) -> NativeToolEventRowSummary {
        if event.status == .failed || event.status == .denied || event.status == .interrupted,
           let error = firstLine(event.errorMessage),
           !error.isEmpty {
            return NativeToolEventRowSummary(text: error, suffix: nil, isError: true)
        }

        switch presentation {
        case let .workspaceRead(read):
            return NativeToolEventRowSummary(text: read.path, suffix: nil, isError: false)
        case let .workspaceWrite(write):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(write.byteCount),
                countStyle: .file
            )
            return NativeToolEventRowSummary(
                text: "\(write.path) · \(size)",
                suffix: nil,
                isError: false
            )
        case let .workspaceFiles(files):
            return NativeToolEventRowSummary(
                text: "\(files.files.count) 个路径",
                suffix: nil,
                isError: false
            )
        case let .workItems(workItems):
            let head = "\(workItems.completedCount)/\(workItems.items.count) 已完成"
            guard let active = workItems.activeItems.first else {
                return NativeToolEventRowSummary(text: head, suffix: nil, isError: false)
            }
            let extra = workItems.activeItems.count - 1
            return NativeToolEventRowSummary(
                text: "\(head) · \(active.title)",
                suffix: extra > 0 ? "+\(extra)" : nil,
                isError: false
            )
        case let .terminal(terminal):
            return NativeToolEventRowSummary(
                text: terminal.firstCommandLine,
                suffix: nil,
                isError: terminal.failedExit
            )
        case .generic:
            let summary = event.summary.isEmpty ? firstLine(event.arguments) ?? event.name : event.summary
            return NativeToolEventRowSummary(text: summary, suffix: nil, isError: false)
        }
    }

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \Character.isNewline).first.map(String.init)
    }
}

struct NativeToolEventBody: View {
    let presentation: NativeToolEventPresentation
    let event: AgentToolEvent

    var body: some View {
        switch presentation {
        case let .workspaceRead(read):
            WorkspaceReadToolCard(model: read)
        case let .workspaceWrite(write):
            WorkspaceWriteToolCard(model: write)
        case let .workspaceFiles(files):
            WorkspaceFilesToolCard(model: files)
        case let .workItems(workItems):
            WorkItemsToolCard(model: workItems)
        case let .terminal(terminal):
            TerminalToolCard(model: terminal)
        case .generic:
            GenericToolEventBody(event: event)
        }
    }
}

private struct WorkspaceReadToolCard: View {
    let model: NativeWorkspaceReadPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let languageHint = model.languageHint {
                    Text(languageHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(lineCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.totalLines == 0 {
                Text("空文件")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ToolTextRows(
                    lines: model.lines,
                    totalLines: model.totalLines,
                    style: .read
                )
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("读取文件 \(model.path)，\(lineCountLabel)")
    }

    private var lineCountLabel: String {
        if model.previewTruncated || model.lines.count < model.totalLines {
            return "预览 \(model.lines.count) / \(model.totalLines) 行"
        }
        return "\(model.totalLines) 行"
    }
}

private struct WorkspaceWriteToolCard: View {
    let model: NativeWorkspaceWritePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text(model.path)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let languageHint = model.languageHint {
                    Text(languageHint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.totalLines == 0 {
                Text("写入空文件")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ToolTextRows(
                    lines: model.lines,
                    totalLines: model.totalLines,
                    style: .added
                )
            }

            Divider()
            Text(footer)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("写入文件 \(model.path)，\(model.totalLines) 行")
    }

    private var footer: String {
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(model.byteCount),
            countStyle: .file
        )
        let preview = model.previewTruncated ? " · 界面预览已截断" : ""
        return "└ 写入 \(model.totalLines) 行 · \(size)\(preview)"
    }
}

private enum ToolTextRowStyle {
    case read
    case added
}

private struct ToolTextDisplayRow: Identifiable {
    enum Content {
        case line(NativeToolTextLine)
        case gap(Int)
    }

    let id: String
    let content: Content
}

private struct ToolTextRows: View {
    let lines: [NativeToolTextLine]
    let totalLines: Int
    let style: ToolTextRowStyle

    @State private var isExpanded = false

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(headRows) { row in
                    rowView(row)
                }
                if hiddenCount > 0 {
                    expandButton
                }
                ForEach(tailRows) { row in
                    rowView(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 230)
    }

    private var displayRows: [ToolTextDisplayRow] {
        var rows: [ToolTextDisplayRow] = []
        rows.reserveCapacity(lines.count + 1)
        var previousNumber: Int?
        for line in lines {
            if let previousNumber, line.number > previousNumber + 1 {
                let omitted = line.number - previousNumber - 1
                rows.append(
                    ToolTextDisplayRow(
                        id: "gap-\(previousNumber)-\(line.number)",
                        content: .gap(omitted)
                    )
                )
            }
            rows.append(
                ToolTextDisplayRow(id: "line-\(line.number)", content: .line(line))
            )
            previousNumber = line.number
        }
        return rows
    }

    private var slice: ToolHeadTailSlice<ToolTextDisplayRow> {
        ToolHeadTailSlice(items: displayRows, maximumVisible: 8, expanded: isExpanded)
    }

    private var headRows: [ToolTextDisplayRow] { slice.head }
    private var tailRows: [ToolTextDisplayRow] { slice.tail }
    private var hiddenCount: Int { slice.hidden }

    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(isExpanded ? "收起" : "… 其余 \(hiddenCount) 行")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "收起内容" : "展开其余 \(hiddenCount) 行")
    }

    @ViewBuilder
    private func rowView(_ row: ToolTextDisplayRow) -> some View {
        switch row.content {
        case let .gap(omitted):
            Text("… 省略 \(omitted) 行界面预览")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        case let .line(line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if style == .read {
                    Text("\(line.number)")
                        .frame(width: 36, alignment: .trailing)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("+")
                        .frame(width: 12, alignment: .trailing)
                        .foregroundStyle(.green)
                }
                Text(line.text + (line.isTruncated ? " …" : ""))
                    .foregroundStyle(style == .added ? .green : .primary)
            }
            .font(.caption.monospaced())
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
    }
}

private struct WorkspaceFilesToolCard: View {
    let model: NativeWorkspaceFilesPresentation

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.files.count) 个路径")
                    .font(.caption.weight(.semibold))
                Spacer()
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.files.isEmpty {
                Text("工作区中没有文本文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(slice.head) { file in
                    fileRow(file)
                }
                if slice.hidden > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "收起" : "… 其余 \(slice.hidden) 个路径")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起路径" : "展开其余 \(slice.hidden) 个路径")
                }
                ForEach(slice.tail) { file in
                    fileRow(file)
                }
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文件列表，\(model.files.count) 个路径")
    }

    private var slice: ToolHeadTailSlice<NativeWorkspaceFilePresentation> {
        ToolHeadTailSlice(items: model.files, maximumVisible: 8, expanded: isExpanded)
    }

    private func fileRow(_ file: NativeWorkspaceFilePresentation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(file.path)
                .font(.caption.monospaced())
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct WorkItemsToolCard: View {
    let model: NativeWorkItemsPresentation

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(model.kind == .todos ? "任务清单" : "执行计划")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(model.completedCount)/\(model.items.count) 已完成")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.items.isEmpty {
                Text("清单为空")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ForEach(slice.head) { item in
                    itemRow(item)
                }
                if slice.hidden > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "收起" : "… 其余 \(slice.hidden) 项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起清单" : "展开其余 \(slice.hidden) 项")
                }
                ForEach(slice.tail) { item in
                    itemRow(item)
                }
            }
        }
        .toolSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.kind == .todos ? "任务清单" : "执行计划")，\(model.completedCount) 项已完成，共 \(model.items.count) 项")
    }

    private var slice: ToolHeadTailSlice<NativeWorkItemPresentation> {
        ToolHeadTailSlice(items: model.items, maximumVisible: 8, expanded: isExpanded)
    }

    private func itemRow(_ item: NativeWorkItemPresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: statusIcon(item.status))
                .font(.caption)
                .foregroundStyle(statusTint(item.status))
                .accessibilityHidden(true)
            Text(item.title)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusTitle(item.status))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func statusIcon(_ status: ConversationItemStatus) -> String {
        switch status {
        case .pending: "circle"
        case .active: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .blocked: "exclamationmark.octagon.fill"
        }
    }

    private func statusTint(_ status: ConversationItemStatus) -> Color {
        switch status {
        case .pending, .paused: .secondary
        case .active: .blue
        case .completed: .green
        case .blocked: .red
        }
    }

    private func statusTitle(_ status: ConversationItemStatus) -> String {
        switch status {
        case .pending: "待处理"
        case .active: "进行中"
        case .paused: "已暂停"
        case .completed: "已完成"
        case .blocked: "受阻"
        }
    }
}

private struct TerminalToolCard: View {
    let model: NativeTerminalPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                runState
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.commandLines.prefix(3)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.number == 1 ? "workspace" : "$")
                                .foregroundStyle(.green.opacity(0.9))
                            Text(line.text + (line.isTruncated ? " …" : ""))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.monospaced())
                    }
                    if model.commandPreviewTruncated || model.commandLines.count > 3 {
                        Text("命令预览 \(min(3, model.commandLines.count)) / \(model.commandTotalLines) 行")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                if let statusLabel {
                    Text(statusLabel)
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: .capsule)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(10)

            if !model.outputLines.isEmpty {
                Divider()
                    .overlay(.white.opacity(0.12))
                TerminalOutputRows(model: model)
            } else if !model.isRunning {
                Divider()
                    .overlay(.white.opacity(0.12))
                Text("无输出")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(10)
            }

            if let metadataLabel {
                Divider()
                    .overlay(.white.opacity(0.12))
                Text(metadataLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("iSH 终端，\(terminalStatusTitle)")
    }

    @ViewBuilder
    private var runState: some View {
        if model.isRunning {
            ProgressView()
                .controlSize(.mini)
                .tint(.blue)
                .accessibilityLabel("运行中")
        } else {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusTint)
                .accessibilityLabel(terminalStatusTitle)
        }
    }

    private var statusLabel: String? {
        if model.isRunning { return "运行中" }
        if model.status == .interrupted { return "已取消" }
        if let exitCode = model.exitCode, exitCode != 0 { return "退出码 \(exitCode)" }
        return nil
    }

    private var terminalStatusTitle: String {
        if model.isRunning { return "运行中" }
        if model.status == .interrupted { return "已取消" }
        return model.failedExit ? "失败" : "已完成"
    }

    private var statusIcon: String {
        if model.status == .interrupted { return "stop.circle.fill" }
        return model.failedExit ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if model.status == .interrupted { return .white.opacity(0.7) }
        return model.failedExit ? .red : .green
    }

    private var metadataLabel: String? {
        var parts: [String] = []
        if let duration = model.durationMilliseconds {
            parts.append(duration >= 1_000
                ? String(format: "%.2f s", Double(duration) / 1_000)
                : "\(duration) ms")
        }
        if let processID = model.processID {
            parts.append("PID \(processID)")
        }
        if let timeout = model.timeoutSeconds {
            parts.append("超时 \(timeout) s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct TerminalOutputRows: View {
    let model: NativeTerminalPresentation

    @State private var isExpanded = false

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(slice.head) { line in
                    terminalLine(line)
                }
                if slice.hidden > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Text(isExpanded ? "收起" : "… 其余 \(slice.hidden) 行")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "收起输出" : "展开其余 \(slice.hidden) 行输出")
                }
                ForEach(slice.tail) { line in
                    terminalLine(line)
                }
                if model.outputPreviewTruncated {
                    Text("界面预览 \(model.outputLines.count) / \(model.totalOutputLines) 行")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.yellow.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: 230)
    }

    private var slice: ToolHeadTailSlice<NativeTerminalLine> {
        ToolHeadTailSlice(items: model.outputLines, maximumVisible: 8, expanded: isExpanded)
    }

    private func terminalLine(_ line: NativeTerminalLine) -> some View {
        HStack(spacing: 0) {
            ForEach(line.segments) { segment in
                Text(segment.text)
                    .foregroundStyle(outputTint(segment.channel))
            }
            if line.isTruncated {
                Text(" …")
                    .foregroundStyle(.yellow)
            }
        }
        .font(.caption.monospaced())
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private func outputTint(_ channel: AgentToolOutputChannel) -> Color {
        switch channel {
        case .stdout: Color(white: 0.92)
        case .stderr: .red.opacity(0.92)
        case .progress: .cyan.opacity(0.92)
        case .system: .yellow.opacity(0.92)
        }
    }
}

private struct GenericToolEventBody: View {
    let event: AgentToolEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !event.arguments.isEmpty {
                genericSection(label: "IN") {
                    Text(limited(event.arguments))
                        .foregroundStyle(.secondary)
                }
            }

            if !event.arguments.isEmpty, hasOutput {
                Divider()
            }

            if hasOutput {
                genericSection(label: "OUT") {
                    if !event.output.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(event.output) { chunk in
                                Text(limited(chunk.text))
                                    .foregroundStyle(outputTint(chunk.channel))
                            }
                        }
                    } else if let result = event.result, !result.isEmpty {
                        Text(limited(result))
                            .foregroundStyle(.secondary)
                    } else if let error = event.errorMessage, !error.isEmpty {
                        Text(limited(error))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .font(.caption.monospaced())
        .textSelection(.enabled)
        .toolSurface()
    }

    private var hasOutput: Bool {
        !event.output.isEmpty
            || !(event.result?.isEmpty ?? true)
            || !(event.errorMessage?.isEmpty ?? true)
    }

    private func genericSection<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)
            ScrollView(.horizontal) {
                content()
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .frame(maxHeight: 170)
    }

    private func limited(_ text: String) -> String {
        guard text.utf8.count > 64 * 1_024 else { return text }
        var result = ""
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= 64 * 1_024 else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result + "\n[UI output truncated]"
    }

    private func outputTint(_ channel: AgentToolOutputChannel) -> Color {
        switch channel {
        case .stdout: .secondary
        case .stderr: .red
        case .progress: .blue
        case .system: .orange
        }
    }
}

private struct ToolHeadTailSlice<Item> {
    let head: [Item]
    let tail: [Item]
    let hidden: Int

    init(items: [Item], maximumVisible: Int, expanded: Bool) {
        hidden = max(0, items.count - maximumVisible)
        guard hidden > 0, !expanded else {
            head = items
            tail = []
            return
        }
        let headCount = (maximumVisible + 1) / 2
        let tailCount = maximumVisible - headCount
        head = Array(items.prefix(headCount))
        tail = Array(items.suffix(tailCount))
    }
}

private struct ToolSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

private extension View {
    func toolSurface() -> some View {
        modifier(ToolSurfaceModifier())
    }
}
