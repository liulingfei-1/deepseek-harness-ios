import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class TrajectoryViewState {
    var mode: TrajectoryLedgerMode = .duration
    var query = ""
    var collapsedTurnIDs = Set<String>()
    var collapsedCallIDs = Set<String>()
    var selectedEvent: SessionEvent?
    var isHarnessInspectorPresented = false
    var isRefreshing = false
}

struct TrajectoryView: View {
    @Environment(AppModel.self) private var model
    let navigationTitle: String
    @State private var state: TrajectoryViewState

    init(
        navigationTitle: String = "轨迹",
        state: TrajectoryViewState? = nil
    ) {
        self.navigationTitle = navigationTitle
        _state = State(initialValue: state ?? TrajectoryViewState())
    }

    var body: some View {
        let projection = TrajectoryProjection(
            events: model.trajectoryVisibleEvents,
            query: state.query,
            mode: state.mode
        )
        let summary = TrajectoryMetricSummary(
            metrics: model.trajectoryMetrics,
            events: projection.visibleEvents
        )

        VStack(spacing: 0) {
            TrajectoryMetricsHeader(summary: summary)

            if !model.harnessTraceEvents.isEmpty {
                HarnessTraceStrip(
                    events: model.harnessTraceEvents,
                    summary: model.harnessTraceSummary,
                    action: { state.isHarnessInspectorPresented = true }
                )
            }

            Picker("轨迹视图", selection: $state.mode) {
                ForEach(TrajectoryLedgerMode.allCases) { candidate in
                    Label(candidate.title, systemImage: candidate.systemImage)
                        .tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            trajectoryLedger(projection)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $state.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索类型、内容、工具或 Call ID"
        )
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                collapseMenu(projection)

                Button(action: refresh) {
                    ZStack {
                        Image(systemName: "arrow.clockwise")
                            .opacity(state.isRefreshing ? 0 : 1)
                        if state.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .disabled(state.isRefreshing)
                .accessibilityLabel("刷新轨迹")
                .help("刷新轨迹")
            }
        }
        .sheet(item: $state.selectedEvent) { event in
            TrajectoryEventInspectorView(event: event)
        }
        .sheet(isPresented: $state.isHarnessInspectorPresented) {
            HarnessTraceInspectorView(
                events: model.harnessTraceEvents,
                summary: model.harnessTraceSummary
            )
        }
        .task {
            await refreshNow()
        }
    }

    @ViewBuilder
    private func trajectoryLedger(_ projection: TrajectoryProjection) -> some View {
        if projection.isEmpty(for: state.mode) {
            ContentUnavailableView(
                state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "暂无轨迹"
                    : "没有匹配的轨迹",
                systemImage: state.query.isEmpty
                    ? "point.3.connected.trianglepath.dotted"
                    : "magnifyingglass",
                description: Text(
                    state.query.isEmpty
                        ? "会话运行后，请求、消息和本机工具事件会显示在这里。"
                        : "尝试搜索事件类型、模型、工具名或 Call ID。"
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if model.canLoadOlderTrajectory {
                        Button {
                            Task { await model.loadOlderTrajectory() }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isLoadingOlderTrajectory {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                                }
                                Text(model.isLoadingOlderTrajectory ? "正在加载" : "加载更早轨迹")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingOlderTrajectory)
                        Divider()
                    }

                    switch state.mode {
                    case .duration:
                        ForEach(projection.filteredEvents) { event in
                            TrajectoryEventRow(
                                event: event,
                                elapsedMilliseconds: projection.elapsedMilliseconds(for: event),
                                action: { state.selectedEvent = event }
                            )
                            Divider()
                                .padding(.leading, 52)
                        }

                    case .turns:
                        ForEach(projection.turns) { turn in
                            Section {
                                if !isTurnCollapsed(turn) {
                                    ForEach(turn.events) { event in
                                        TrajectoryEventRow(
                                            event: event,
                                            elapsedMilliseconds: projection.elapsedMilliseconds(for: event),
                                            action: { state.selectedEvent = event }
                                        )
                                        Divider()
                                            .padding(.leading, 52)
                                    }
                                }
                            } header: {
                                TrajectorySectionHeader(
                                    title: turn.title,
                                    detail: turn.detail,
                                    systemImage: "arrow.triangle.branch",
                                    isCollapsed: isTurnCollapsed(turn),
                                    action: { toggleTurn(turn) }
                                )
                            }
                        }

                    case .calls:
                        ForEach(projection.calls) { call in
                            Section {
                                if !isCallCollapsed(call) {
                                    ForEach(call.events) { event in
                                        TrajectoryEventRow(
                                            event: event,
                                            elapsedMilliseconds: projection.elapsedMilliseconds(for: event),
                                            action: { state.selectedEvent = event }
                                        )
                                        Divider()
                                            .padding(.leading, 52)
                                    }
                                }
                            } header: {
                                TrajectorySectionHeader(
                                    title: call.title,
                                    detail: call.detail,
                                    systemImage: call.isError ? "xmark.circle" : "wrench.and.screwdriver",
                                    tint: call.isError ? .red : .secondary,
                                    isCollapsed: isCallCollapsed(call),
                                    action: { toggleCall(call) }
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(HarnessTheme.pageBackground)
            .refreshable {
                await refreshNow()
            }
            .accessibilityLabel("轨迹时间线")
        }
    }

    @ViewBuilder
    private func collapseMenu(_ projection: TrajectoryProjection) -> some View {
        if state.mode != .duration {
            Menu {
                switch state.mode {
                case .duration:
                    EmptyView()
                case .turns:
                    Button {
                        state.collapsedTurnIDs.formUnion(projection.turns.map(\.id))
                    } label: {
                        Label("折叠所有回合", systemImage: "rectangle.compress.vertical")
                    }
                    Button {
                        state.collapsedTurnIDs.subtract(projection.turns.map(\.id))
                    } label: {
                        Label("展开所有回合", systemImage: "rectangle.expand.vertical")
                    }
                case .calls:
                    Button {
                        state.collapsedCallIDs.formUnion(projection.calls.map(\.id))
                    } label: {
                        Label("折叠所有调用", systemImage: "rectangle.compress.vertical")
                    }
                    Button {
                        state.collapsedCallIDs.subtract(projection.calls.map(\.id))
                    } label: {
                        Label("展开所有调用", systemImage: "rectangle.expand.vertical")
                    }
                }
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .accessibilityLabel("折叠选项")
            .help("折叠选项")
        }
    }

    private func isTurnCollapsed(_ turn: TrajectoryTurnSection) -> Bool {
        state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.collapsedTurnIDs.contains(turn.id)
    }

    private func isCallCollapsed(_ call: TrajectoryCallSection) -> Bool {
        state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && state.collapsedCallIDs.contains(call.id)
    }

    private func toggleTurn(_ turn: TrajectoryTurnSection) {
        if !state.collapsedTurnIDs.insert(turn.id).inserted {
            state.collapsedTurnIDs.remove(turn.id)
        }
    }

    private func toggleCall(_ call: TrajectoryCallSection) {
        if !state.collapsedCallIDs.insert(call.id).inserted {
            state.collapsedCallIDs.remove(call.id)
        }
    }

    private func refresh() {
        Task { await refreshNow() }
    }

    @MainActor
    private func refreshNow() async {
        guard !state.isRefreshing else { return }
        state.isRefreshing = true
        defer { state.isRefreshing = false }
        await model.refreshTrajectory()
    }
}

enum TrajectoryLedgerMode: String, CaseIterable, Identifiable {
    case duration
    case turns
    case calls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duration: "耗时"
        case .turns: "回合"
        case .calls: "调用"
        }
    }

    var systemImage: String {
        switch self {
        case .duration: "clock"
        case .turns: "arrow.triangle.branch"
        case .calls: "wrench.and.screwdriver"
        }
    }
}

/// Mirrors upstream `session-stats`: whole-log counts plus model, tool,
/// first-token and decode wall times. Every figure folds from the complete
/// durable log, not from the paged-in window.
///
private struct TrajectoryMetricSummary {
    let durationMilliseconds: Double
    let turns: Int
    let steps: Int
    let calls: Int
    let modelMilliseconds: Double
    let toolMilliseconds: Double
    let averageTTFTMilliseconds: Double?
    let ttftSamples: Int
    let decodeMilliseconds: Double
    let decodeTokens: Int
    let outputTokens: Int
    let cacheHitRate: Double?

    init(metrics: SessionTrajectoryMetrics?, events: [SessionEvent]) {
        if let metrics {
            durationMilliseconds = metrics.durationMilliseconds
            turns = metrics.turns
            steps = metrics.steps
            calls = metrics.calls
            modelMilliseconds = metrics.modelDurationMilliseconds
            toolMilliseconds = metrics.toolDurationMilliseconds
            averageTTFTMilliseconds = metrics.averageTTFTMilliseconds
            ttftSamples = metrics.ttftSamples
            decodeMilliseconds = metrics.decodeDurationMilliseconds
            decodeTokens = metrics.decodeTokens
            outputTokens = metrics.outputTokens
            cacheHitRate = metrics.cacheHitRate
            return
        }

        let firstTime = events.first?.time
        let lastTime = events.last?.time
        durationMilliseconds = if let firstTime, let lastTime {
            Double(max(0, lastTime - firstTime))
        } else {
            0
        }
        turns = Set(events.compactMap(\.trajectoryTurn)).count
        steps = events.count { $0.type == SessionEventVocabulary.stepEnd }
        calls = events.count { $0.type == SessionEventVocabulary.toolCall }
        modelMilliseconds = 0
        toolMilliseconds = 0
        averageTTFTMilliseconds = nil
        ttftSamples = 0
        decodeMilliseconds = 0
        decodeTokens = 0
        outputTokens = 0
        cacheHitRate = nil
    }

    /// Decode throughput over the steps that reported both a decode span and
    /// output tokens. Nil until at least one such step lands.
    var tokensPerSecond: Double? {
        guard decodeMilliseconds > 0, decodeTokens > 0 else { return nil }
        return Double(decodeTokens) / (decodeMilliseconds / 1_000)
    }
}

private struct HarnessTraceStrip: View {
    let events: [HarnessTraceEvent]
    let summary: HarnessTraceSummary?
    let action: () -> Void

    private var checkpointCount: Int {
        events.count { event in
            event.kind == .checkpointFinished
                || event.kind == .checkpointFailed
        }
    }

    private var pluginCount: Int {
        events.count { event in
            event.kind == .pluginStateChanged
                || event.kind == .pluginCleanupFailed
        }
    }

    private var failureCount: Int {
        events.count { event in
            event.kind == .checkpointFailed
                || event.kind == .pluginCleanupFailed
                || event.kind == .error
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HarnessIconTile(
                    systemImage: failureCount == 0
                        ? "point.3.connected.trianglepath.dotted"
                        : "exclamationmark.triangle.fill",
                    tint: failureCount == 0 ? .teal : .red
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Harness 运行时")
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(HarnessTheme.secondarySurface)
        .accessibilityIdentifier("harness-trace-strip")
        .accessibilityLabel("Harness 运行时轨迹")
        .accessibilityValue(detail)
    }

    private var detail: String {
        let base = "\(checkpointCount) 个检查点 · \(pluginCount) 个插件"
        if failureCount > 0 {
            return base + " · \(failureCount) 个错误"
        }
        if let summary {
            return base + " · " + TrajectoryFormat.duration(summary.durationMilliseconds)
        }
        return base
    }
}

private struct TrajectoryMetricsHeader: View {
    let summary: TrajectoryMetricSummary

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    primaryMetrics
                }

                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        durationMetric
                        Divider().frame(height: 36)
                        TrajectoryPrimaryMetric(title: "回合", value: String(summary.turns))
                    }
                    HStack(spacing: 0) {
                        TrajectoryPrimaryMetric(title: "调用", value: String(summary.calls))
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    secondaryMetrics
                }
                VStack(spacing: 6) {
                    HStack(spacing: 14) {
                        TrajectorySecondaryMetric(
                            title: "模型",
                            value: TrajectoryFormat.duration(summary.modelMilliseconds)
                        )
                        TrajectorySecondaryMetric(
                            title: "工具",
                            value: TrajectoryFormat.duration(summary.toolMilliseconds)
                        )
                        TrajectorySecondaryMetric(
                            title: "首字延迟",
                            value: summary.averageTTFTMilliseconds.map(TrajectoryFormat.duration) ?? "—"
                        )
                        TrajectorySecondaryMetric(
                            title: "解码",
                            value: TrajectoryFormat.duration(summary.decodeMilliseconds)
                                + " · " + TrajectoryFormat.count(summary.decodeTokens) + " tok"
                        )
                    }
                    HStack(spacing: 14) {
                        TrajectorySecondaryMetric(
                            title: "吞吐",
                            value: summary.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—"
                        )
                        TrajectorySecondaryMetric(
                            title: "输出",
                            value: TrajectoryFormat.count(summary.outputTokens) + " tok"
                        )
                        TrajectorySecondaryMetric(
                            title: "缓存",
                            value: summary.cacheHitRate.map(TrajectoryFormat.percent) ?? "—"
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 10)
        .background(HarnessTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("轨迹统计")
    }

    @ViewBuilder private var secondaryMetrics: some View {
        TrajectorySecondaryMetric(
            title: "模型",
            value: TrajectoryFormat.duration(summary.modelMilliseconds)
        )
        TrajectorySecondaryMetric(
            title: "工具",
            value: TrajectoryFormat.duration(summary.toolMilliseconds)
        )
        TrajectorySecondaryMetric(
            title: "首字延迟",
            value: summary.averageTTFTMilliseconds.map(TrajectoryFormat.duration) ?? "—"
        )
        // Upstream session-stats also folds decode wall time and the tokens
        // that arrived during it, which is what makes throughput derivable.
        TrajectorySecondaryMetric(
            title: "解码",
            value: TrajectoryFormat.duration(summary.decodeMilliseconds)
                + " · " + TrajectoryFormat.count(summary.decodeTokens) + " tok"
        )
        TrajectorySecondaryMetric(
            title: "吞吐",
            value: summary.tokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "—"
        )
        TrajectorySecondaryMetric(
            title: "输出",
            value: TrajectoryFormat.count(summary.outputTokens) + " tok"
        )
        TrajectorySecondaryMetric(
            title: "缓存",
            value: summary.cacheHitRate.map(TrajectoryFormat.percent) ?? "—"
        )
    }

    private var primaryMetrics: some View {
        HStack(spacing: 0) {
            durationMetric
            Divider().frame(height: 36)
            TrajectoryPrimaryMetric(title: "回合", value: String(summary.turns))
            Divider().frame(height: 36)
            TrajectoryPrimaryMetric(title: "调用", value: String(summary.calls))
        }
    }

    private var durationMetric: some View {
        TrajectoryPrimaryMetric(
            title: "耗时",
            value: TrajectoryFormat.duration(summary.durationMilliseconds)
        )
    }
}

private struct TrajectoryPrimaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct TrajectorySecondaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption2)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct TrajectoryProjection {
    let visibleEvents: [SessionEvent]
    let filteredEvents: [SessionEvent]
    let turns: [TrajectoryTurnSection]
    let calls: [TrajectoryCallSection]
    private let firstTimestamp: Int64?

    init(events: [SessionEvent], query: String, mode: TrajectoryLedgerMode) {
        visibleEvents = events
        firstTimestamp = events.first?.time

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredEvents = normalizedQuery.isEmpty
            ? events
            : events.filter { $0.trajectorySearchText.contains(normalizedQuery) }

        switch mode {
        case .duration:
            turns = []
            calls = []
        case .turns:
            let allTurns = Self.groupTurns(events)
            turns = normalizedQuery.isEmpty
                ? allTurns
                : allTurns.compactMap { section in
                    let matches = section.events.filter { $0.trajectorySearchText.contains(normalizedQuery) }
                    return matches.isEmpty ? nil : section.replacingEvents(matches)
                }
            calls = []
        case .calls:
            turns = []
            let allCalls = Self.groupCalls(events)
            calls = normalizedQuery.isEmpty
                ? allCalls
                : allCalls.filter { $0.searchText.contains(normalizedQuery) }
        }
    }

    func elapsedMilliseconds(for event: SessionEvent) -> Double? {
        guard let firstTimestamp else { return nil }
        return Double(max(0, event.time - firstTimestamp))
    }

    func isEmpty(for mode: TrajectoryLedgerMode) -> Bool {
        switch mode {
        case .duration: filteredEvents.isEmpty
        case .turns: turns.isEmpty
        case .calls: calls.isEmpty
        }
    }

    private static func groupTurns(_ events: [SessionEvent]) -> [TrajectoryTurnSection] {
        var order: [String] = []
        var grouped: [String: [SessionEvent]] = [:]
        var currentTurn: Int?

        for event in events {
            if let start = event.turnStartData?.turn {
                currentTurn = start
            }
            let turn = event.trajectoryTurn ?? currentTurn
            let id = turn.map { "turn:" + String($0) } ?? "between-turns"
            if grouped[id] == nil {
                order.append(id)
                grouped[id] = []
            }
            grouped[id, default: []].append(event)
            if event.turnEndData != nil {
                currentTurn = nil
            }
        }

        return order.compactMap { id in
            guard let groupedEvents = grouped[id], !groupedEvents.isEmpty else { return nil }
            return TrajectoryTurnSection(
                id: id,
                turn: groupedEvents.compactMap(\.trajectoryTurn).first,
                events: groupedEvents
            )
        }
    }

    private static func groupCalls(_ events: [SessionEvent]) -> [TrajectoryCallSection] {
        var order: [String] = []
        var grouped: [String: [SessionEvent]] = [:]

        for event in events {
            let callID: String?
            if let call = event.toolCallData {
                callID = call.callID
            } else if let result = event.toolResultData {
                callID = result.callID
            } else {
                callID = nil
            }
            guard let callID, !callID.isEmpty else { continue }
            if grouped[callID] == nil {
                order.append(callID)
                grouped[callID] = []
            }
            grouped[callID, default: []].append(event)
        }

        return order.compactMap { callID in
            guard let groupedEvents = grouped[callID], !groupedEvents.isEmpty else { return nil }
            return TrajectoryCallSection(callID: callID, events: groupedEvents)
        }
    }
}

private struct TrajectoryTurnSection: Identifiable {
    let id: String
    let turn: Int?
    let events: [SessionEvent]

    var title: String {
        turn.map { "回合 " + String($0) } ?? "回合之间"
    }

    var detail: String {
        String(events.count) + " 个事件 · " + TrajectoryFormat.duration(durationMilliseconds)
    }

    private var durationMilliseconds: Double {
        guard let first = events.first?.time, let last = events.last?.time else { return 0 }
        return Double(max(0, last - first))
    }

    func replacingEvents(_ events: [SessionEvent]) -> Self {
        Self(id: id, turn: turn, events: events)
    }
}

private struct TrajectoryCallSection: Identifiable {
    let callID: String
    let events: [SessionEvent]

    var id: String { callID }

    var title: String {
        events.compactMap(\.toolCallData).first?.name ?? "工具调用"
    }

    var detail: String {
        let status = isError ? "错误" : events.contains { $0.toolResultData != nil } ? "已完成" : "运行中"
        return status + " · " + TrajectoryFormat.duration(durationMilliseconds) + " · " + callID
    }

    private var durationMilliseconds: Double {
        guard let start = events.first(where: { $0.toolCallData != nil })?.time else { return 0 }
        let end = events.last(where: { $0.toolResultData != nil })?.time ?? events.last?.time ?? start
        return Double(max(0, end - start))
    }

    var isError: Bool {
        events.contains { $0.toolResultData?.trajectoryIsError == true }
    }

    var searchText: String {
        ([callID, title] + events.map(\.trajectorySearchText))
            .joined(separator: " ")
            .lowercased()
    }
}

private struct TrajectorySectionHeader: View {
    let title: String
    let detail: String
    let systemImage: String
    var tint: Color = .secondary
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HarnessIconTile(systemImage: systemImage, tint: tint, size: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .background(.bar)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed ? "已折叠" : "已展开")
        .accessibilityHint(isCollapsed ? "展开事件" : "折叠事件")
    }
}

private struct TrajectoryEventRow: View {
    let event: SessionEvent
    let elapsedMilliseconds: Double?
    let action: () -> Void

    var body: some View {
        let presentation = TrajectoryEventPresentation(event: event)

        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                HarnessIconTile(systemImage: presentation.systemImage, tint: presentation.tint, size: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(presentation.kind)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(presentation.tint)
                            .lineLimit(1)
                        Text("#" + String(event.seq))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                        Text(elapsedMilliseconds.map(TrajectoryFormat.offset) ?? "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    Text(presentation.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let subtitle = presentation.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.kind + "，" + presentation.title)
        .accessibilityValue("事件 " + String(event.seq))
        .accessibilityHint("查看事件详情")
    }
}

private struct TrajectoryEventPresentation {
    let kind: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    init(event: SessionEvent) {
        switch event.type {
        case SessionEventVocabulary.requestHeader:
            kind = "系统"
            title = "请求头"
            subtitle = event.requestHeaderData.map { "原因: " + $0.reason.rawValue }
            systemImage = "slider.horizontal.3"
            tint = .indigo

        case SessionEventVocabulary.requestContext:
            kind = "上下文"
            if let context = event.requestContextData {
                title = context.provider + " / " + context.model
                subtitle = context.contextWindow.map { "上下文: " + TrajectoryFormat.count($0) }
            } else {
                title = "请求上下文"
                subtitle = nil
            }
            systemImage = "brain.head.profile"
            tint = .teal

        case SessionEventVocabulary.questionRequested:
            kind = "提问"
            if let request = event.questionRequestedData {
                title = request.questions.first?.question ?? "Agent 请求用户输入"
                subtitle = String(request.questionCount) + " 个问题 · 等待回答"
            } else {
                title = "Agent 请求用户输入"
                subtitle = nil
            }
            systemImage = "questionmark.bubble.fill"
            tint = .orange

        case SessionEventVocabulary.questionResolved:
            kind = "提问"
            if let resolved = event.questionResolvedData {
                title = resolved.outcome == "answered" ? "用户已回答" : "问题已取消"
                let skipped = resolved.skippedIDs.isEmpty
                    ? nil
                    : "已跳过: " + resolved.skippedIDs.joined(separator: ", ")
                subtitle = [resolved.requestID, skipped].compactMap { $0 }.joined(separator: " · ")
            } else {
                title = "问题已处理"
                subtitle = nil
            }
            systemImage = "checkmark.bubble.fill"
            tint = .green

        case SessionEventVocabulary.userMessage:
            kind = "用户"
            title = event.data.trajectoryPreview(fallback: "用户消息")
            subtitle = event.surfaceOp?.trajectoryDescription
            systemImage = "person.fill"
            tint = .blue

        case SessionEventVocabulary.assistantMessage:
            kind = "助手"
            if let assistant = event.assistantMessageData {
                title = assistant.message.trajectoryPreview(fallback: "助手消息")
                subtitle = "回合 " + String(assistant.turn) + " · 步骤 " + String(assistant.step)
            } else {
                title = "助手消息"
                subtitle = nil
            }
            systemImage = "sparkles"
            tint = .purple

        case SessionEventVocabulary.toolCall:
            kind = "工具调用"
            if let call = event.toolCallData {
                title = call.name
                subtitle = call.callID + " · " + call.arguments.trajectorySingleLine(limit: 160)
            } else {
                title = "工具调用"
                subtitle = nil
            }
            systemImage = "wrench.and.screwdriver.fill"
            tint = .orange

        case SessionEventVocabulary.toolResult:
            let result = event.toolResultData
            kind = result?.trajectoryIsError == true ? "工具错误" : "工具结果"
            title = result?.message.trajectoryPreview(fallback: "工具结果") ?? "工具结果"
            subtitle = result?.callID
            systemImage = result?.trajectoryIsError == true ? "xmark.circle.fill" : "checkmark.circle.fill"
            tint = result?.trajectoryIsError == true ? .red : .green

        case SessionEventVocabulary.turnStart:
            kind = "回合"
            title = "回合 " + String(event.turnStartData?.turn ?? 0) + " 开始"
            subtitle = nil
            systemImage = "play.circle"
            tint = .secondary

        case SessionEventVocabulary.turnEnd:
            kind = "回合"
            title = "回合 " + String(event.turnEndData?.turn ?? 0) + " 结束"
            subtitle = event.turnEndData?.reason.trajectoryPreview(fallback: nil)
            systemImage = "stop.circle"
            tint = .secondary

        case SessionEventVocabulary.modelSelection:
            let route = event.data.objectValue
            let provider = route?["provider"]?.stringValue
            let model = route?["model"]?.stringValue
            kind = "模型"
            let joinedRoute = [provider, model].compactMap { $0 }.joined(separator: " / ")
            title = joinedRoute.isEmpty ? "模型选择" : joinedRoute.trajectorySingleLine(limit: 240)
            subtitle = route?["reasoningEffort"]?.stringValue.map { "推理强度 \($0)" }
            systemImage = "cpu"
            tint = .purple

        case SessionEventVocabulary.stepStart, SessionEventVocabulary.stepEnd:
            kind = "步骤"
            if let step = event.stepData {
                title = "回合 " + String(step.turn) + " · 步骤 " + String(step.step)
            } else {
                title = event.type
            }
            subtitle = event.type == SessionEventVocabulary.stepStart ? "开始" : "结束"
            systemImage = event.type == SessionEventVocabulary.stepStart ? "arrow.right.circle" : "checkmark.circle"
            tint = .secondary

        default:
            kind = "事件"
            title = event.type
            subtitle = event.data.trajectoryPreview(fallback: nil)
            systemImage = "point.3.connected.trianglepath.dotted"
            tint = .secondary
        }
    }
}

private struct HarnessTraceInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedEvent: HarnessTraceEvent?

    let events: [HarnessTraceEvent]
    let summary: HarnessTraceSummary?

    var body: some View {
        NavigationStack {
            List {
                if let summary {
                    Section {
                        LabeledContent("耗时", value: TrajectoryFormat.duration(summary.durationMilliseconds))
                        LabeledContent("回合", value: String(summary.turns))
                        LabeledContent("调用", value: String(summary.calls))
                        LabeledContent(
                            "首字延迟",
                            value: summary.averageFirstTokenMilliseconds.map(TrajectoryFormat.duration) ?? "—"
                        )
                        LabeledContent(
                            "缓存",
                            value: summary.cacheHitRate.map(TrajectoryFormat.percent) ?? "—"
                        )
                    } header: {
                        Label("运行", systemImage: "chart.bar.xaxis")
                    }
                }

                Section {
                    if filteredEvents.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ForEach(filteredEvents) { event in
                            Button {
                                selectedEvent = event
                            } label: {
                                HarnessTraceEventRow(event: event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Label("Harness 事件", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            .navigationTitle("Harness F12")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索 checkpoint、插件或 handler")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $selectedEvent) { event in
                HarnessTraceEventInspectorView(event: event)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredEvents: [HarnessTraceEvent] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return events }
        return events.filter { $0.harnessSearchText.contains(normalized) }
    }
}

private struct HarnessTraceEventRow: View {
    let event: HarnessTraceEvent

    var body: some View {
        let presentation = HarnessTracePresentation(event: event)
        HStack(alignment: .top, spacing: 10) {
            HarnessIconTile(
                systemImage: presentation.systemImage,
                tint: presentation.tint,
                size: 32
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(presentation.kind)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(presentation.tint)
                    Text("#" + String(event.sequence))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    if let duration = event.durationMilliseconds {
                        Text(TrajectoryFormat.duration(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(presentation.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = presentation.subtitle {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.kind + "，" + presentation.title)
        .accessibilityValue(presentation.subtitle ?? "")
    }
}

private struct HarnessTracePresentation {
    let kind: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color

    init(event: HarnessTraceEvent) {
        title = event.name ?? event.kind.rawValue
        let handlers = event.harnessHandlerDescriptions
        switch event.kind {
        case .checkpointStarted:
            kind = "检查点"
            subtitle = handlers.isEmpty ? "默认 Handler" : handlers.joined(separator: " → ")
            systemImage = "arrow.right.circle"
            tint = .teal
        case .checkpointFinished:
            kind = "检查点"
            subtitle = handlers.isEmpty ? "已完成" : handlers.joined(separator: " → ")
            systemImage = "checkmark.circle.fill"
            tint = .green
        case .checkpointFailed:
            kind = "检查点错误"
            subtitle = event.error ?? handlers.joined(separator: " → ")
            systemImage = "xmark.circle.fill"
            tint = .red
        case .pluginStateChanged:
            kind = "插件"
            subtitle = [event.pluginID, event.attributes["previousState"]?.stringValue]
                .compactMap { $0 }
                .joined(separator: " · ")
            systemImage = "shippingbox.fill"
            tint = .indigo
        case .pluginCleanupFailed:
            kind = "插件错误"
            subtitle = event.error ?? event.pluginID
            systemImage = "exclamationmark.triangle.fill"
            tint = .red
        case .settingsRead:
            kind = "设置"
            subtitle = event.error ?? event.attributes["namespace"]?.stringValue ?? "配置已加载"
            systemImage = "slider.horizontal.3"
            tint = event.error == nil ? .blue : .red
        case .settingsWrite:
            kind = "设置"
            subtitle = event.error
                ?? event.attributes["namespace"]?.stringValue
                ?? event.attributes["status"]?.stringValue
                ?? "配置已更新"
            systemImage = "slider.horizontal.3"
            tint = event.error == nil ? .blue : .red
        case .settingsConflict:
            kind = "设置冲突"
            subtitle = event.error ?? event.attributes["namespace"]?.stringValue
            systemImage = "arrow.trianglehead.2.clockwise.rotate.90"
            tint = .orange
        case .modelRequest, .modelFirstToken, .modelCompleted:
            kind = "模型"
            subtitle = event.modelStepDescription
            systemImage = "brain.head.profile"
            tint = .purple
        case .toolStarted, .toolFinished:
            kind = "工具"
            subtitle = event.callID
            systemImage = "wrench.and.screwdriver.fill"
            tint = .orange
        case .runStarted, .runFinished, .turnStarted, .turnFinished, .stepStarted, .stepFinished:
            kind = "运行时"
            subtitle = event.modelStepDescription
            systemImage = "point.3.connected.trianglepath.dotted"
            tint = .secondary
        case .backgroundTask:
            kind = "后台"
            subtitle = event.name ?? event.modelStepDescription
            systemImage = "clock.arrow.trianglehead.counterclockwise.rotate.90"
            tint = .teal
        case .error:
            kind = "错误"
            subtitle = event.error
            systemImage = "exclamationmark.triangle.fill"
            tint = .red
        }
    }
}

private struct HarnessTraceEventInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var formattedEvent: String?

    let event: HarnessTraceEvent

    var body: some View {
        let presentation = HarnessTracePresentation(event: event)
        NavigationStack {
            List {
                Section {
                    LabeledContent("序号", value: String(event.sequence))
                    LabeledContent("类型", value: event.kind.rawValue)
                    LabeledContent("名称", value: event.name ?? "—")
                    LabeledContent("时间") {
                        Text(event.timestamp, format: .dateTime.year().month().day().hour().minute().second())
                            .monospacedDigit()
                    }
                    if let duration = event.durationMilliseconds {
                        LabeledContent("耗时", value: TrajectoryFormat.duration(duration))
                    }
                    if let turn = event.turn {
                        LabeledContent("回合", value: String(turn))
                    }
                    if let step = event.step {
                        LabeledContent("步骤", value: String(step))
                    }
                    if let pluginID = event.pluginID {
                        LabeledContent("插件") {
                            Text(pluginID).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                    }
                } header: {
                    Label("事件", systemImage: presentation.systemImage)
                }

                if !event.harnessHandlerDescriptions.isEmpty {
                    Section {
                        ForEach(
                            Array(event.harnessHandlerDescriptions.enumerated()),
                            id: \.element
                        ) { index, handler in
                            LabeledContent(String(index + 1)) {
                                Text(handler)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    } header: {
                        Label("Handler 链", systemImage: "link")
                    }
                }

                if let input = event.attributes["input"] {
                    Section {
                        ScrollView(.horizontal) {
                            Text(input.displayText)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } header: {
                        Label("输入", systemImage: "arrow.down.doc")
                    }
                }

                if let output = event.attributes["output"] {
                    Section {
                        ScrollView(.horizontal) {
                            Text(output.displayText)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } header: {
                        Label("输出", systemImage: "arrow.up.doc")
                    }
                }

                if let error = event.error, !error.isEmpty {
                    Section {
                        Text(error)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } header: {
                        Label("错误", systemImage: "exclamationmark.triangle")
                    }
                }

                Section {
                    if let formattedEvent {
                        ScrollView(.horizontal) {
                            Text(formattedEvent)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } header: {
                    Label("原始 JSON", systemImage: "curlybraces.square")
                }
            }
            .navigationTitle(presentation.kind)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: event.id) {
            let event = event
            formattedEvent = await Task.detached(priority: .userInitiated) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(event) else { return "无法编码事件。" }
                return String(decoding: data, as: UTF8.self)
            }.value
        }
    }
}

private struct TrajectoryEventInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var formattedEnvelope: String?
    @State private var formattedArguments: String?
    @State private var formattedRequestHeader: String?
    @State private var formattedUserMessage: String?
    @State private var formattedAssistantMessage: String?
    @State private var formattedToolResult: String?

    let event: SessionEvent

    var body: some View {
        let presentation = TrajectoryEventPresentation(event: event)

        NavigationStack {
            List {
                Section {
                    LabeledContent("序号", value: String(event.seq))
                    LabeledContent("类型", value: event.type)
                    LabeledContent("时间") {
                        Text(event.trajectoryDate.formatted(
                            .dateTime.year().month().day().hour().minute().second()
                                .locale(Locale(identifier: "zh_CN"))
                        ))
                            .monospacedDigit()
                    }
                    if event.isIgnorable {
                        LabeledContent("策略", value: "Ignorable")
                    }
                    if let sourceEventSeqs = event.sourceEventSeqs, !sourceEventSeqs.isEmpty {
                        LabeledContent("来源序号") {
                            Text(sourceEventSeqs.map(String.init).joined(separator: ", "))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Label("事件", systemImage: presentation.systemImage)
                }

                typedDetailSections

                Section {
                    if let formattedEnvelope {
                        ScrollView(.horizontal) {
                            Text(formattedEnvelope)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在格式化…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("原始 JSON", systemImage: "curlybraces.square")
                }
            }
            .navigationTitle(presentation.kind)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .task(id: event.seq) {
            await formatJSON()
        }
    }

    @ViewBuilder
    private var typedDetailSections: some View {
        if let header = event.requestHeaderData {
            Section {
                LabeledContent("原因", value: header.reason.rawValue)
                if let formattedRequestHeader {
                    inspectorPayload(formattedRequestHeader)
                }
            } header: {
                Label("请求头", systemImage: "arrow.up.doc")
            }
        }

        if event.type == SessionEventVocabulary.userMessage,
           let formattedUserMessage {
            Section {
                inspectorPayload(formattedUserMessage)
            } header: {
                Label("用户", systemImage: "person")
            }
        }

        if let context = event.requestContextData {
            Section {
                LabeledContent("服务商", value: context.provider)
                LabeledContent("模型", value: context.model)
                if let contextWindow = context.contextWindow {
                    LabeledContent("上下文窗口", value: TrajectoryFormat.count(contextWindow))
                }
            } header: {
                Label("请求上下文", systemImage: "contextualmenu.and.cursorarrow")
            }
        }

        if let assistant = event.assistantMessageData {
            Section {
                LabeledContent("回合", value: String(assistant.turn))
                LabeledContent("步骤", value: String(assistant.step))
                if let usage = assistant.usage {
                    usageDetails(usage)
                }
                if let formattedAssistantMessage {
                    inspectorPayload(formattedAssistantMessage)
                }
            } header: {
                Label("助手", systemImage: "sparkles")
            }
        }

        if let usage = event.assistantChunkData?.usage {
            Section {
                usageDetails(usage)
            } header: {
                Label("用量", systemImage: "chart.bar")
            }
        }

        if let call = event.toolCallData {
            Section {
                LabeledContent("名称", value: call.name)
                LabeledContent("Call ID") {
                    Text(call.callID)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                if let formattedArguments {
                    ScrollView(.horizontal) {
                        Text(formattedArguments)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Label("工具调用", systemImage: "wrench.and.screwdriver")
            }
        }

        if let result = event.toolResultData {
            Section(result.trajectoryIsError ? "工具错误" : "工具结果") {
                if let callID = result.callID {
                    LabeledContent("Call ID") {
                        Text(callID)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                }
                if result.trajectoryIsError {
                    Label("工具返回错误", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if let formattedToolResult {
                    inspectorPayload(formattedToolResult)
                }
            }
        }
    }

    @ViewBuilder
    private func usageDetails(_ usage: SessionTokenUsage) -> some View {
        LabeledContent("未缓存输入", value: TrajectoryFormat.count(usage.inputTokens))
        LabeledContent("输出", value: TrajectoryFormat.count(usage.outputTokens))
        if let cacheRead = usage.cacheReadTokens {
            LabeledContent("缓存读取", value: TrajectoryFormat.count(cacheRead))
        }
        if let cacheWrite = usage.cacheWriteTokens {
            LabeledContent("缓存写入", value: TrajectoryFormat.count(cacheWrite))
        }
        LabeledContent("缓存命中", value: TrajectoryFormat.cachePercent(usage) ?? "—")
        if let reasoning = usage.reasoningTokens {
            LabeledContent("思考", value: TrajectoryFormat.count(reasoning))
        }
    }

    private func inspectorPayload(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func formatJSON() async {
        let event = event
        let callArguments = event.toolCallData?.arguments
        let result = await Task.detached(priority: .userInitiated) {
            (
                TrajectoryJSONFormatter.event(event),
                callArguments.map(TrajectoryJSONFormatter.embeddedJSON),
                event.requestHeaderData.map { TrajectoryJSONFormatter.value($0.header) },
                event.type == SessionEventVocabulary.userMessage
                    ? TrajectoryJSONFormatter.value(event.data)
                    : nil,
                event.assistantMessageData.map { TrajectoryJSONFormatter.value($0.message) },
                event.toolResultData.map { TrajectoryJSONFormatter.value($0.message) }
            )
        }.value
        guard !Task.isCancelled else { return }
        formattedEnvelope = result.0
        formattedArguments = result.1
        formattedRequestHeader = result.2
        formattedUserMessage = result.3
        formattedAssistantMessage = result.4
        formattedToolResult = result.5
    }
}

private enum TrajectoryJSONFormatter {
    static func event(_ event: SessionEvent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event) else { return "无法编码事件。" }
        return String(decoding: data, as: UTF8.self)
    }

    static func embeddedJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else {
            return raw
        }
        return String(decoding: formatted, as: UTF8.self)
    }

    static func value(_ value: JSONValue) -> String {
        if case let .string(text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value.displayText }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum TrajectoryFormat {
    static func duration(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        if milliseconds < 1_000 {
            return String(Int(milliseconds.rounded())) + " ms"
        }
        if milliseconds < 60_000 {
            let decimals = milliseconds < 10_000 ? 2 : 1
            return String(format: "%.*f s", decimals, milliseconds / 1_000)
        }
        let minutes = Int(milliseconds / 60_000)
        let seconds = Int((milliseconds.truncatingRemainder(dividingBy: 60_000)) / 1_000)
        return String(minutes) + "m " + String(seconds) + "s"
    }

    static func offset(_ milliseconds: Double) -> String {
        "+" + duration(milliseconds)
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func percent(_ value: Double) -> String {
        CacheHitRateFormat.percent(value)
    }

    static func cachePercent(_ usage: SessionTokenUsage) -> String? {
        let result = CacheHitRateFormat.percent(
            inputTokens: usage.inputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens
        )
        return result == CacheHitRateFormat.unavailable ? nil : result
    }
}

private extension SessionEvent {
    var trajectoryDate: Date {
        Date(timeIntervalSince1970: Double(time) / 1_000)
    }

    var trajectoryTurn: Int? {
        turnStartData?.turn
            ?? turnEndData?.turn
            ?? stepData?.turn
            ?? assistantChunkData?.turn
            ?? assistantMessageData?.turn
            ?? toolCallData?.turn
            ?? toolResultData?.turn
    }

    var trajectorySearchText: String {
        let presentation = TrajectoryEventPresentation(event: self)
        return [
            type,
            presentation.kind,
            presentation.title,
            presentation.subtitle ?? "",
            String(seq),
            toolCallData?.callID ?? "",
            toolResultData?.callID ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
    }
}

private extension HarnessTraceEvent {
    var harnessHandlerDescriptions: [String] {
        guard case let .array(values)? = attributes["handlers"] else { return [] }
        return values.compactMap { value in
            guard case let .object(object) = value,
                  let pluginID = object["pluginId"]?.stringValue else { return nil }
            let generation: String
            if case let .number(rawGeneration)? = object["generation"] {
                generation = "g" + String(Int(rawGeneration))
            } else {
                generation = "g?"
            }
            let label = object["label"]?.stringValue
            return [pluginID + "@" + generation, label]
                .compactMap { $0 }
                .joined(separator: ":")
        }
    }

    var modelStepDescription: String? {
        let values = [
            turn.map { "Turn " + String($0) },
            step.map { "Step " + String($0) },
            callID
        ].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var harnessSearchText: String {
        [
            kind.rawValue,
            name ?? "",
            pluginID ?? "",
            callID ?? "",
            error ?? "",
            harnessHandlerDescriptions.joined(separator: " "),
            attributes["inputType"]?.stringValue ?? "",
            attributes["outputType"]?.stringValue ?? "",
            String(sequence)
        ]
        .joined(separator: " ")
        .lowercased()
    }
}

private extension SessionSurfaceOperation {
    var trajectoryDescription: String {
        switch self {
        case .append:
            "append"
        case let .replace(start, end):
            "replace #" + String(start) + "…#" + String(end)
        }
    }
}

private extension SessionToolResultData {
    var trajectoryIsError: Bool {
        guard let error else { return false }
        if case .null = error { return false }
        return true
    }
}

private extension JSONValue {
    func trajectoryPreview(fallback: String?) -> String {
        if let direct = stringValue {
            return direct.trajectorySingleLine(limit: 240)
        }
        if let object = objectValue {
            for key in ["text", "content", "message", "summary", "title"] {
                if let text = object[key]?.trajectoryFirstText() {
                    return text.trajectorySingleLine(limit: 240)
                }
            }
        }
        return fallback ?? ""
    }

    func trajectoryFirstText() -> String? {
        switch self {
        case let .string(value):
            return value
        case let .array(values):
            return values.lazy.compactMap { $0.trajectoryFirstText() }.first
        case let .object(object):
            for key in ["text", "content", "message", "summary", "title"] {
                if let text = object[key]?.trajectoryFirstText() { return text }
            }
            return nil
        case .number, .bool, .null:
            return nil
        }
    }
}

private extension String {
    func trajectorySingleLine(limit: Int) -> String {
        let normalized = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }
}
