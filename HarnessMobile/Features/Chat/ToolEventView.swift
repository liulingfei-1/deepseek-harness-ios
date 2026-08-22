import SwiftUI

struct ToolEventTreeView: View {
    let events: [AgentToolEvent]
    let isLive: Bool

    @State private var showsAllEvents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hiddenEventCount > 0 {
                Button {
                    showsAllEvents = true
                } label: {
                    Label("显示前面的 \(hiddenEventCount) 个工具调用", systemImage: "ellipsis")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(visibleEvents) { event in
                ToolEventNodeView(event: event, isLive: isLive)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isLive ? "正在执行的工具" : "工具调用")
    }

    private var visibleEvents: ArraySlice<AgentToolEvent> {
        showsAllEvents ? events[...] : events.suffix(isLive ? 5 : 4)
    }

    private var hiddenEventCount: Int {
        showsAllEvents ? 0 : max(0, events.count - visibleEvents.count)
    }
}

private struct ToolEventNodeView: View {
    let event: AgentToolEvent
    let isLive: Bool

    @State private var selectedEvent: AgentToolEvent?
    @State private var showsAllChildren = false

    var body: some View {
        let displayEvent = presentedEvent
        VStack(alignment: .leading, spacing: 8) {
            ToolEventCard(event: displayEvent, isLive: isLive) {
                selectedEvent = displayEvent
            }

            if !displayEvent.children.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if hiddenChildCount > 0 {
                        Button {
                            showsAllChildren = true
                        } label: {
                            Text("显示前面的 \(hiddenChildCount) 个子工具")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(visibleChildren) { child in
                        ToolEventNodeView(event: child, isLive: isLive)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1)
                        .accessibilityHidden(true)
                }
            }
        }
        .sheet(item: $selectedEvent) { selectedEvent in
            ToolEventInspectorView(event: selectedEvent)
        }
    }

    private var presentedEvent: AgentToolEvent {
        guard !isLive else { return event }
        var presented = event
        presented.finishNonterminalRecursively(
            status: .interrupted,
            message: "任务结束前工具未返回最终状态。",
            at: event.finishedAt ?? .now
        )
        return presented
    }

    private var visibleChildren: ArraySlice<AgentToolEvent> {
        showsAllChildren
            ? presentedEvent.children[...]
            : presentedEvent.children.suffix(3)
    }

    private var hiddenChildCount: Int {
        showsAllChildren ? 0 : max(0, presentedEvent.children.count - visibleChildren.count)
    }
}

/// Shared compact tool row for durable events and legacy orphaned results.
struct ToolEventCard: View {
    let event: AgentToolEvent
    let isLive: Bool
    let onInspect: () -> Void

    @State private var isExpanded = false

    var body: some View {
        let presentation = NativeToolEventPresentation.derive(for: event)
        let summary = NativeToolEventRowSummary.make(
            event: event,
            presentation: presentation
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    ToolEventSummaryRow(
                        event: event,
                        isLive: isLive,
                        isExpanded: isExpanded,
                        summary: summary,
                        terminalExitCode: presentation.terminalExitCode
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(ToolEventPresentation.title(for: event.name))，\(summary.text)，\(ToolEventPresentation.statusTitle(event.status))"
                )
                .accessibilityHint(isExpanded ? "收起工具内容" : "展开工具内容")

                Button(action: onInspect) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看工具详情")
            }

            if isExpanded {
                NativeToolEventBody(presentation: presentation, event: event)
                    .padding(.leading, 22)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct ToolEventSummaryRow: View {
    let event: AgentToolEvent
    let isLive: Bool
    let isExpanded: Bool
    let summary: NativeToolEventRowSummary
    let terminalExitCode: Int?

    var body: some View {
        HStack(spacing: 6) {
            Image(
                systemName: isExpanded
                    ? "chevron.down"
                    : ToolEventPresentation.icon(for: event.name)
            )
            .font(.caption.weight(.medium))
            .frame(width: 16, height: 24)
            .foregroundStyle(summary.isError ? .red : ToolEventPresentation.tint(for: event.status))
            .accessibilityHidden(true)

            Text(ToolEventPresentation.title(for: event.name))
                .font(.footnote.weight(.medium))
                .lineLimit(1)

            if !summary.text.isEmpty {
                Circle()
                    .fill(.tertiary)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)

                Text(summary.text)
                    .font(.caption)
                    .foregroundStyle(summary.isError ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let suffix = summary.suffix {
                    Text(suffix)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 6)
            ToolEventStatusView(
                status: event.status,
                isLive: isLive,
                terminalExitCode: terminalExitCode
            )
        }
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolEventStatusView: View {
    let status: AgentToolEventStatus
    let isLive: Bool
    let terminalExitCode: Int?

    var body: some View {
        HStack(spacing: 5) {
            if isLive, status == .pending || status == .awaitingApproval || status == .running {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusTint)
            }
            Text(statusTitle)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var hasFailingExit: Bool {
        status == .succeeded && (terminalExitCode ?? 0) != 0
    }

    private var statusTitle: String {
        if hasFailingExit, let terminalExitCode {
            return "退出 \(terminalExitCode)"
        }
        return ToolEventPresentation.statusTitle(status)
    }

    private var statusIcon: String {
        hasFailingExit ? "xmark.circle.fill" : ToolEventPresentation.statusIcon(status)
    }

    private var statusTint: Color {
        hasFailingExit ? .red : ToolEventPresentation.tint(for: status)
    }
}

private struct ToolEventOutputView: View {
    let event: AgentToolEvent
    let maximumCharacters: Int

    var body: some View {
        if !event.output.isEmpty {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(event.output) { chunk in
                        Text(limited(chunk.text))
                            .font(.caption.monospaced())
                            .foregroundStyle(ToolEventPresentation.outputTint(chunk.channel))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 180)
            .padding(8)
            .background(.black.opacity(0.86), in: .rect(cornerRadius: 6))
            .accessibilityLabel("工具输出")
        } else if let result = event.result, !result.isEmpty {
            Text(limited(result))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func limited(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "\n[UI output truncated]"
    }
}

private struct ToolEventInspectorView: View {
    @Environment(\.dismiss) private var dismiss

    let event: AgentToolEvent

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    LabeledContent("工具", value: ToolEventPresentation.title(for: event.name))
                    LabeledContent("状态", value: ToolEventPresentation.statusTitle(event.status))
                    if !event.summary.isEmpty {
                        Text(event.summary)
                            .textSelection(.enabled)
                    }
                    if let startedAt = event.startedAt {
                        LabeledContent("开始") {
                            Text(startedAt, format: .dateTime.hour().minute().second())
                        }
                    }
                    if let finishedAt = event.finishedAt {
                        LabeledContent("结束") {
                            Text(finishedAt, format: .dateTime.hour().minute().second())
                        }
                    }
                }

                Section("参数") {
                    Text(event.arguments)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                if !event.output.isEmpty {
                    Section("输出") {
                        ToolEventOutputView(event: event, maximumCharacters: 64 * 1_024)
                    }
                }

                if let result = event.result, !result.isEmpty {
                    Section("返回值") {
                        Text(result)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage = event.errorMessage, !errorMessage.isEmpty {
                    Section("错误") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if !event.children.isEmpty {
                    Section("子工具") {
                        ForEach(event.children) { child in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ToolEventPresentation.title(for: child.name))
                                    .font(.headline)
                                Text(child.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("工具详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

enum ToolEventPresentation {
    static func title(for name: String) -> String {
        switch name {
        case "shell_execute": "iSH 终端"
        case "run_code": "Code Mode"
        case "code_execute": "本机代码"
        case "read": "读取文件"
        case "write": "写入文件"
        case "edit": "编辑文件"
        case "job_output": "后台任务输出"
        case "job_list": "后台任务列表"
        case "job_kill": "停止后台任务"
        case "schedule_create": "创建定时任务"
        case "schedule_list": "定时任务列表"
        case "schedule_delete": "取消定时任务"
        case "workspace_list_files": "文件列表"
        case "workspace_read_text": "读取文件"
        case "workspace_write_text": "写入文件"
        case "camera_ocr": "相机 OCR"
        case "ask_user_question": "询问用户"
        case "exit_plan_mode": "计划审核"
        case "work_state_set_goal": "更新目标"
        case "work_state_replace_plan": "更新计划"
        case "work_state_replace_todos": "更新待办"
        case "contacts_search": "搜索联系人"
        case "location_current": "当前位置"
        case "motion_activity": "运动活动"
        case "notification_schedule": "本地通知"
        case "secure_authenticate": "设备验证"
        case "device_time": "设备时间"
        case "device_capabilities": "设备能力"
        case "ios_native": "iOS 原生"
        case "web_fetch": "网页读取"
        case "plugin_marketplace": "插件市场"
        case "cordis_inspect_list": "检查 Cordis 插件"
        case "cordis_inspect_query": "查询 Cordis 能力"
        case "cordis_inspect_self": "检查当前 Cordis 插件"
        case "cordis_define": "定义 Cordis 插件"
        case "cordis_run": "运行 Cordis 插件"
        case "cordis_stop": "停止 Cordis 插件"
        case "cordis_undefine": "移除 Cordis 插件"
        default: name.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "shell_execute": "terminal"
        case "run_code": "curlybraces.square"
        case "code_execute": "chevron.left.forwardslash.chevron.right"
        case "read": "doc.text.magnifyingglass"
        case "write": "doc.badge.plus"
        case "edit": "square.and.pencil"
        case "job_output": "text.append"
        case "job_list": "list.bullet.rectangle"
        case "job_kill": "stop.circle"
        case "schedule_create": "calendar.badge.plus"
        case "schedule_list": "calendar"
        case "schedule_delete": "calendar.badge.minus"
        case "workspace_list_files": "folder"
        case "workspace_read_text": "doc.text.magnifyingglass"
        case "workspace_write_text": "square.and.pencil"
        case "camera_ocr": "text.viewfinder"
        case "ask_user_question": "questionmark.bubble"
        case "exit_plan_mode": "checkmark.rectangle.stack"
        case "work_state_set_goal": "scope"
        case "work_state_replace_plan": "list.bullet.clipboard"
        case "work_state_replace_todos": "checklist"
        case "contacts_search": "person.crop.circle.badge.magnifyingglass"
        case "location_current": "location"
        case "motion_activity": "figure.walk.motion"
        case "notification_schedule": "bell.badge"
        case "secure_authenticate": "faceid"
        case "device_time": "clock"
        case "device_capabilities": "iphone.gen3"
        case "ios_native": "apps.iphone"
        case "web_fetch": "network"
        case "plugin_marketplace": "puzzlepiece.extension"
        case "cordis_inspect_list", "cordis_inspect_query", "cordis_inspect_self":
            "point.3.connected.trianglepath.dotted"
        case "cordis_define": "plus.square.dashed"
        case "cordis_run": "play.circle"
        case "cordis_stop": "stop.circle"
        case "cordis_undefine": "arrow.uturn.backward.circle"
        default: "wrench.and.screwdriver"
        }
    }

    static func statusTitle(_ status: AgentToolEventStatus) -> String {
        switch status {
        case .pending: "等待"
        case .awaitingApproval: "待授权"
        case .running: "运行中"
        case .succeeded: "完成"
        case .failed: "失败"
        case .denied: "已拒绝"
        case .interrupted: "已中断"
        }
    }

    static func statusIcon(_ status: AgentToolEventStatus) -> String {
        switch status {
        case .pending: "clock"
        case .awaitingApproval: "hand.raised"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .denied: "hand.raised.slash.fill"
        case .interrupted: "stop.circle.fill"
        }
    }

    static func tint(for status: AgentToolEventStatus) -> Color {
        switch status {
        case .pending: .secondary
        case .awaitingApproval: .orange
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .denied: .orange
        case .interrupted: .secondary
        }
    }

    static func background(for status: AgentToolEventStatus) -> Color {
        switch status {
        case .pending, .interrupted: Color(uiColor: .tertiarySystemBackground)
        case .awaitingApproval, .denied: .orange.opacity(0.10)
        case .running: .blue.opacity(0.08)
        case .succeeded: .green.opacity(0.07)
        case .failed: .red.opacity(0.08)
        }
    }

    static func outputTint(_ channel: AgentToolOutputChannel) -> Color {
        switch channel {
        case .stdout: Color(white: 0.92)
        case .stderr: .red.opacity(0.92)
        case .progress: .cyan.opacity(0.92)
        case .system: .yellow.opacity(0.92)
        }
    }
}
