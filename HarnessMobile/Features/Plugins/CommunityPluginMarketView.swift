import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum CommunityPluginMarketMode: String, CaseIterable, Identifiable {
    case catalog
    case installed

    var id: Self { self }

    var title: String {
        switch self {
        case .catalog: "市场"
        case .installed: "已安装"
        }
    }
}

private enum CommunityPluginMarketSheet: String, Identifiable {
    case github

    var id: String { rawValue }
}

struct CommunityPluginMarketView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = CommunityPluginMarketMode.catalog
    @State private var query = ""
    @State private var presentedSheet: CommunityPluginMarketSheet?
    @State private var isFileImporterPresented = false
    @State private var isActionsPresented = false

    var body: some View {
        List {
            Picker("插件视图", selection: $mode) {
                ForEach(CommunityPluginMarketMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("community-plugin-market-mode")
            .controlSize(.small)
            .padding(.vertical, 0)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)

            CommunityPluginMarketHeader {
                isActionsPresented = true
            }
            CommunityPluginMarketplaceStateSections()
            if let trace = model.nativePluginCompilationTrace {
                CommunityPluginCompilationTraceSection(trace: trace)
            }

            switch mode {
            case .catalog:
                catalogContent
            case .installed:
                installedContent
            }
        }
        .communityPluginListChrome()
        .navigationTitle("社区插件")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            prompt: Text("搜索插件、分类或仓库")
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.refreshISHPluginMarketplace(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("community-plugin-market-refresh")
                .accessibilityLabel("刷新插件目录")
                .disabled(model.isISHPluginMarketplaceWorking)
            }
        }
        .confirmationDialog(
            "插件操作",
            isPresented: $isActionsPresented,
            titleVisibility: .visible
        ) {
            Button("刷新目录") {
                Task { await model.refreshISHPluginMarketplace(forceRefresh: true) }
            }
            Button("GitHub 仓库") {
                model.clearISHPluginMarketplaceFailure()
                presentedSheet = .github
            }
            Button("导入 ZIP") {
                isFileImporterPresented = true
            }
            Button("清理下载缓存") {
                Task { await model.clearISHPluginMarketplaceCache() }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .github:
                CommunityPluginGitHubInstallSheet()
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result {
                    model.reportISHPluginMarketplaceError(error)
                }
                return
            }
            Task {
                _ = await model.importISHMarketplacePluginArchive(from: url)
            }
        }
        .task {
            if model.ishPluginMarketplaceCatalog == nil, !isUITestingMarketplaceFixtureRequested {
                await model.refreshISHPluginMarketplace()
            }
        }
        .refreshable {
            await model.refreshISHPluginMarketplace(forceRefresh: true)
        }
    }

    private var isUITestingMarketplaceFixtureRequested: Bool {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-present-plugin-market-for-ui-testing")
            || arguments.contains("-present-plugin-compilation-failure-for-ui-testing")
#else
        false
#endif
    }

    @ViewBuilder
    private var catalogContent: some View {
        if model.ishPluginMarketplaceCatalog == nil {
            if !model.isISHPluginMarketplaceWorking,
               model.ishPluginMarketplaceFailure == nil {
                CommunityPluginEmptyRow(
                    title: "尚未载入插件目录",
                    detail: "可以重新读取社区目录，或从 GitHub 和本地 ZIP 安装。",
                    systemImage: "shippingbox"
                ) {
                    Button {
                        Task { await model.refreshISHPluginMarketplace(forceRefresh: true) }
                    } label: {
                        Label("重新载入", systemImage: "arrow.clockwise")
                    }
                }
            }
        } else if filteredCatalogItems.isEmpty {
            CommunityPluginEmptyRow(
                title: query.isEmpty ? "目录里没有插件" : "没有匹配的插件",
                detail: query.isEmpty ? "稍后刷新目录，或使用右上角从 GitHub、ZIP 安装。" : "换一个名称、分类或仓库关键词。",
                systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass"
            )
        } else {
            Section {
                ForEach(filteredCatalogItems) { item in
                    NavigationLink {
                        CommunityPluginCatalogDetailView(itemID: item.id)
                    } label: {
                        CommunityPluginCatalogRow(item: item)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                }
            } header: {
                HStack {
                    Text("社区目录")
                    Spacer()
                    if let catalog = model.ishPluginMarketplaceCatalog, catalog.stale {
                        Label("缓存", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(filteredCatalogItems.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var installedContent: some View {
        if filteredInstalledPlugins.isEmpty {
            CommunityPluginEmptyRow(
                title: query.isEmpty ? "还没有社区插件" : "没有匹配的插件",
                detail: query.isEmpty
                    ? "从市场、GitHub 或 ZIP 安装后会显示在这里。"
                    : "换一个插件名称、版本或来源关键词。",
                systemImage: query.isEmpty ? "shippingbox" : "magnifyingglass"
            )
        } else {
            Section("已安装") {
                ForEach(filteredInstalledPlugins) { plugin in
                    NavigationLink {
                        CommunityInstalledPluginDetailView(pluginID: plugin.id)
                    } label: {
                        CommunityInstalledPluginRow(plugin: plugin)
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 12))
                }
            }
        }
    }

    private var filteredCatalogItems: [ISHMarketplaceCatalogItem] {
        let items = model.ishPluginMarketplaceCatalog?.items ?? []
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return items }
        return items.filter { item in
            [
                item.name,
                item.description,
                item.category,
                item.repositoryKey
            ].joined(separator: " ").lowercased().contains(normalized)
        }
    }

    private var filteredInstalledPlugins: [ISHMarketplacePlugin] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.ishMarketplacePlugins }
        return model.ishMarketplacePlugins.filter { plugin in
            [
                plugin.id,
                plugin.name,
                plugin.version,
                plugin.description ?? "",
                plugin.source.location,
                plugin.state.rawValue
            ].joined(separator: " ").lowercased().contains(normalized)
        }
    }
}

private struct CommunityPluginMarketplaceStateSections: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let operation = model.ishPluginMarketplaceOperation {
            HStack(alignment: .top, spacing: 11) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title(hostState: model.ishPluginHostState))
                        .font(.subheadline.weight(.semibold))
                    Text(operation.detail(hostState: model.ishPluginHostState))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowBackground(Color.accentColor.opacity(0.07))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("community-plugin-market-status")
        }

        if let failure = model.ishPluginMarketplaceFailure {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("操作失败")
                            .font(.subheadline.weight(.semibold))
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 18) {
                    if failure.canRetry {
                        Button {
                            Task { await model.retryISHPluginMarketplaceOperation() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("community-plugin-market-retry")
                    }
                    Button {
                        model.clearISHPluginMarketplaceFailure()
                    } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.orange.opacity(0.08))
            .accessibilityIdentifier("community-plugin-market-error")
        }
    }
}

private struct CommunityPluginCompilationTraceSection: View {
    let trace: NativePluginCompilationTrace
    @State private var isExpanded = true
    @State private var areLogsExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(trace.steps) { step in
                        CommunityPluginCompilationStepRow(step: step)
                    }
                }

                if !trace.logs.isEmpty {
                    DisclosureGroup(isExpanded: $areLogsExpanded) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(trace.logs) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(.tertiary)
                                    Text(entry.stage.title)
                                        .foregroundStyle(entry.state.tint)
                                    Text(entry.message)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 6)
                        .accessibilityIdentifier("community-plugin-compilation-logs")
                    } label: {
                        HStack {
                            Text("详细日志")
                        }
                        .accessibilityIdentifier("community-plugin-compilation-logs-toggle")
                    }
                    .font(.caption)
                    .padding(.top, 8)
                }

                if let diagnostic = trace.diagnostic {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Image(systemName: diagnostic.retryable ? "arrow.triangle.2.circlepath" : "hand.raised.fill")
                                .foregroundStyle(diagnostic.retryable ? .orange : .red)
                            Text("结构化诊断 · \(diagnostic.code)")
                                .font(.caption.weight(.semibold))
                        }
                        Text(diagnostic.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(diagnostic.suggestedAction)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 10)
                    .accessibilityIdentifier("community-plugin-compilation-diagnostic")
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: trace.isFinished ? "checklist.checked" : "hammer.fill")
                        .foregroundStyle(trace.isFinished ? Color.green : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trace.isFinished ? "最近一次编译结果" : "手机 Agent 编译中")
                            .font(.subheadline.weight(.semibold))
                        Text(trace.outcome ?? currentSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }
                .accessibilityIdentifier("community-plugin-compilation-summary")
            }
        } header: {
            Text("Agent 原生编译")
        } footer: {
            Text(trace.source)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
                .accessibilityIdentifier("community-plugin-compilation-source")
        }
        .onChange(of: trace.id) {
            isExpanded = true
            areLogsExpanded = false
        }
    }

    private var currentSummary: String {
        trace.steps.last(where: { $0.state == .running })?.detail
            ?? trace.steps.last(where: { $0.state == .failed })?.detail
            ?? "等待开始"
    }
}

private struct CommunityPluginCompilationStepRow: View {
    let step: NativePluginCompilationStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if step.state == .running {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: step.state.iconName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(step.state.tint)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.stage.title)
                    .font(.subheadline.weight(.medium))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

private extension NativePluginCompilationStageState {
    var iconName: String {
        switch self {
        case .pending: "clock"
        case .running: "circle.dotted"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .pending, .skipped: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        }
    }
}

/// A compact, Minis-style summary sits above the catalog so the page remains
/// useful while the Host is starting or the remote catalog is unavailable.
private struct CommunityPluginMarketHeader: View {
    @Environment(AppModel.self) private var model
    let onOpenActions: () -> Void

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("手机插件生态")
                        .font(.headline)
                    Text("Host 插件在 iSH 内运行，模型密钥留在原生层")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)
                hostStatus
            }

            HStack(spacing: 8) {
                summaryPill(
                    title: "目录",
                    value: model.ishPluginMarketplaceCatalog.map { "\($0.items.count)" } ?? "-",
                    tint: .blue
                )
                summaryPill(
                    title: "已安装",
                    value: "\(model.ishMarketplacePlugins.count)",
                    tint: .green
                )
                summaryPill(
                    title: "原生扩展",
                    value: "\(model.ishNativeClientPlugins.count)",
                    tint: .orange
                )
            }

            Button(action: onOpenActions) {
                Label("插件操作", systemImage: "ellipsis.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isISHPluginMarketplaceWorking)
            .accessibilityIdentifier("community-plugin-market-actions")
            .accessibilityLabel("插件操作")
        } header: {
            Text("插件中心")
        } footer: {
            Text("支持市场目录、GitHub 仓库和本地 ZIP；不兼容的桌面 Client 插件会在安装前标记。")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("community-plugin-market-summary")
    }

    private var hostStatus: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Image(systemName: model.ishPluginHostState.iconName)
                .foregroundStyle(model.ishPluginHostState.tint)
            Text(model.ishPluginHostState.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 54)
    }

    private func summaryPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct CommunityPluginEmptyRow<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let actions: Actions

    init(
        title: String,
        detail: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

private extension CommunityPluginEmptyRow where Actions == EmptyView {
    init(title: String, detail: String, systemImage: String) {
        self.init(title: title, detail: detail, systemImage: systemImage) {
            EmptyView()
        }
    }
}

private extension ISHPluginMarketplaceOperation {
    func title(hostState: ISHPluginHostRuntimeState) -> String {
        switch self {
        case .preparingHost:
            switch hostState {
            case .installing: "正在安装 iSH 插件 Host"
            case .starting: "正在启动 iSH 插件 Host"
            case .running: "正在检查 iSH 插件 Host"
            case .stopped, .failed: "正在准备 iSH 插件 Host"
            }
        case .loadingCatalog: "正在读取社区插件目录"
        case .preparingNativePlugin: "正在下载并分析插件源码"
        case .installingPlugin: "正在下载并安装插件"
        case .updatingPlugin: "正在下载并更新插件"
        case .compilingNativePlugin: "手机 Agent 正在编译原生插件"
        case .enablingPlugin: "正在启用插件"
        case .disablingPlugin: "正在停用插件"
        case .uninstallingPlugin: "正在卸载插件"
        case .clearingCache: "正在清理插件缓存"
        }
    }

    func detail(hostState: ISHPluginHostRuntimeState) -> String {
        switch self {
        case .preparingHost:
            switch hostState {
            case .installing:
                "首次安装 Node 和 Cordis 依赖通常需要 40–60 秒，请保持 App 在前台。"
            case .starting:
                "依赖已经就绪，正在启动手机内的本地 Host。"
            case .running:
                "正在确认 Host 版本与已安装插件。"
            case .stopped, .failed:
                "正在检查手机内的 iSH 环境和 Host 依赖。"
            }
        case .loadingCatalog:
            "iSH guest 网络默认开启；目录读取仍完全在手机内完成，也可在命令页主动关闭。"
        case .preparingNativePlugin:
            "先在手机上准备受限源码快照，优先尝试编译为签名内置引擎可执行的原生工具。"
        case .installingPlugin, .updatingPlugin:
            "原生适配未达标，正在回退 iSH；校验和依赖安装仍全部在手机内完成。"
        case .compilingNativePlugin:
            "源码已从隔离环境交给手机 Agent；生成结果会由 Swift 校验并注册，不加载新二进制。"
        case .enablingPlugin, .disablingPlugin:
            "正在同步 Host 与原生工具贡献状态。"
        case .uninstallingPlugin:
            "正在移除插件、依赖和运行时贡献。"
        case .clearingCache:
            "只清理插件下载缓存，不会删除工作区文件。"
        }
    }
}

private struct CommunityPluginCatalogRow: View {
    let item: ISHMarketplaceCatalogItem

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.compatibility.iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(item.compatibility.tint, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(item.category)
                    Text("·")
                        .accessibilityHidden(true)
                    Text(item.repositoryKey)
                        .fontDesign(.monospaced)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
            if item.installed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("已安装")
            }
        }
        .contentShape(Rectangle())
    }
}

private struct CommunityInstalledPluginRow: View {
    let plugin: ISHMarketplacePlugin

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: plugin.state.iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(plugin.state.tint, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if let description = plugin.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(plugin.state.title)
                    Text("·")
                        .accessibilityHidden(true)
                    Text("v\(plugin.version)")
                    Text("·")
                        .accessibilityHidden(true)
                    Text("\(plugin.entryCount) 个入口")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

private struct CommunityPluginCatalogDetailView: View {
    @Environment(AppModel.self) private var model
    let itemID: String
    @State private var isConfirmationPresented = false

    var body: some View {
        Group {
            if let item {
                List {
                    CommunityPluginMarketplaceStateSections()

                    Section("插件") {
                        LabeledContent("名称", value: item.name)
                        LabeledContent("分类", value: item.category)
                        LabeledContent("兼容性", value: item.compatibility.title)
                        if let installedVersion = item.installedVersion {
                            LabeledContent("已安装", value: installedVersion)
                        }
                    }

                    if !item.description.isEmpty {
                        Section("说明") {
                            Text(item.description)
                                .textSelection(.enabled)
                        }
                    }

                    Section("来源") {
                        Text(item.repositoryURL)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }

                    if let reason = item.unsupportedReason {
                        Section("手机兼容性") {
                            Label(reason, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(item.compatibility == .unsupported ? .orange : .secondary)
                        }
                    }

                    Section {
                        Button {
                            isConfirmationPresented = true
                        } label: {
                            Label(
                                item.installed ? "重新安装" : "安装到 iSH",
                                systemImage: "arrow.down.app"
                            )
                        }
                        .disabled(
                            model.isISHPluginMarketplaceWorking
                        )
                    } footer: {
                        Text("插件分类不会阻止安装；源码、依赖下载和执行均留在手机 iSH 内完成。")
                    }
                }
                .communityPluginListChrome()
                .confirmationDialog(
                    item.installed ? "重新安装插件？" : "安装社区插件？",
                    isPresented: $isConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button(item.installed ? "更新并保留启停状态" : "安装") {
                        Task {
                            _ = await model.installISHMarketplacePlugin(
                                source: ISHMarketplacePluginSource(
                                    kind: .market,
                                    location: item.repositoryURL
                                ),
                                replace: item.installed
                            )
                        }
                    }
                } message: {
                    Text("第三方插件会在 iSH 沙箱中读写工作区，但无法获取原生模型 API Key。")
                }
            } else {
                ContentUnavailableView("插件不可用", systemImage: "shippingbox")
            }
        }
        .navigationTitle(item?.name ?? "插件")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var item: ISHMarketplaceCatalogItem? {
        model.ishPluginMarketplaceCatalog?.items.first { $0.id == itemID }
    }
}

private enum CommunityInstalledPluginAction: String {
    case enable
    case reinstall
    case uninstall
}

private struct CommunityInstalledPluginDetailView: View {
    @Environment(AppModel.self) private var model
    let pluginID: String
    @State private var pendingAction: CommunityInstalledPluginAction?

    var body: some View {
        Group {
            if let plugin {
                List {
                    CommunityPluginMarketplaceStateSections()

                    Section("运行状态") {
                        LabeledContent("状态", value: plugin.state.title)
                        LabeledContent("版本", value: plugin.version)
                        LabeledContent("Loader entries", value: "\(plugin.entryCount)")
                        Toggle(
                            "启用插件",
                            isOn: Binding(
                                get: { plugin.enabled },
                                set: { enabled in
                                    if enabled {
                                        pendingAction = .enable
                                    } else {
                                        Task {
                                            await model.setISHMarketplacePluginEnabled(
                                                id: pluginID,
                                                enabled: false
                                            )
                                        }
                                    }
                                }
                            )
                        )
                        .disabled(model.isISHPluginMarketplaceWorking)
                    }

                    if let nativeClient {
                        Section("原生扩展") {
                            NavigationLink {
                                NativeClientContributionsView(pluginID: pluginID)
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Native Client")
                                        Text(
                                            "\(nativeClient.contributions.inspectors.count) inspectors · "
                                                + "\(nativeClient.contributions.settings.count) settings · "
                                                + "\(nativeClient.contributions.commands.count) commands"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "puzzlepiece.extension")
                                }
                            }
                            .accessibilityIdentifier("native-client-open-\(pluginID)")
                        }
                    }

                    if nativeAgentPlugin?.settings != nil {
                        Section("原生插件") {
                            NavigationLink {
                                NativeAgentPluginSettingsView(pluginID: pluginID)
                            } label: {
                                Label("插件设置", systemImage: "slider.horizontal.3")
                            }
                            .accessibilityIdentifier("native-agent-settings-\(pluginID)")
                        }
                    }

                    if !nativeClientFailures.isEmpty {
                        Section("原生扩展加载失败") {
                            ForEach(nativeClientFailures) { failure in
                                Text(failure.message)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if let description = plugin.description, !description.isEmpty {
                        Section("说明") {
                            Text(description)
                                .textSelection(.enabled)
                        }
                    }

                    if let notes = nativeAgentPlugin?.compatibilityNotes,
                       !notes.isEmpty {
                        Section("兼容性说明") {
                            ForEach(notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    Section("来源") {
                        LabeledContent("类型", value: plugin.source.kind.title)
                        Text(plugin.source.location)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        if let license = plugin.license {
                            LabeledContent("许可证", value: license)
                        }
                    }

                    if let error = plugin.lastError {
                        Section("加载失败") {
                            Text(error)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }

                    Section("管理") {
                        if plugin.source.kind != .localZip {
                            Button {
                                pendingAction = .reinstall
                            } label: {
                                Label("重新下载并更新", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(model.isISHPluginMarketplaceWorking)
                        }
                        Button(role: .destructive) {
                            pendingAction = .uninstall
                        } label: {
                            Label("卸载插件", systemImage: "trash")
                        }
                        .disabled(model.isISHPluginMarketplaceWorking)
                    }
                }
                .communityPluginListChrome()
                .confirmationDialog(
                    "确认插件操作",
                    isPresented: Binding(
                        get: { pendingAction != nil },
                        set: { presented in
                            if !presented { pendingAction = nil }
                        }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingAction
                ) { action in
                    switch action {
                    case .enable:
                        Button("启用第三方代码") {
                            Task {
                                await model.setISHMarketplacePluginEnabled(
                                    id: pluginID,
                                    enabled: true
                                )
                            }
                        }
                    case .reinstall:
                        Button("更新并保留启停状态") {
                            Task {
                                _ = await model.installISHMarketplacePlugin(
                                    source: ISHMarketplacePluginSource(
                                        kind: plugin.source.kind,
                                        location: plugin.source.location
                                    ),
                                    replace: true
                                )
                            }
                        }
                    case .uninstall:
                        Button("卸载", role: .destructive) {
                            Task { await model.uninstallISHMarketplacePlugin(id: pluginID) }
                        }
                    }
                } message: { action in
                    switch action {
                    case .enable:
                        Text(
                            nativeAgentPlugin == nil
                                ? "插件将在本机 iSH Host 内执行，并可以访问 App 私有工作区。"
                                : "插件将由 App 的签名 Swift 运行时加载，只获得清单中声明并通过校验的手机能力。"
                        )
                    case .reinstall:
                        Text("新版加载失败时会回滚到当前已安装版本。")
                    case .uninstall:
                        Text("卸载会删除该插件与它在 iSH 中安装的依赖。")
                    }
                }
            } else {
                ContentUnavailableView("插件已卸载", systemImage: "shippingbox")
            }
        }
        .navigationTitle(plugin?.name ?? pluginID)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var plugin: ISHMarketplacePlugin? {
        model.ishMarketplacePlugins.first { $0.id == pluginID }
    }

    private var nativeClient: ISHNativeClientPlugin? {
        model.ishNativeClientPlugins.first { $0.pluginId == pluginID }
    }

    private var nativeAgentPlugin: NativeAgentCompiledPlugin? {
        model.nativeAgentPlugins.first { $0.id == pluginID }
    }

    private var nativeClientFailures: [ISHNativeClientSynchronizationFailure] {
        model.ishNativeClientFailures.filter { $0.pluginID == pluginID }
    }
}

private struct CommunityPluginGitHubInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var location = ""
    @State private var replaceExisting = false

    var body: some View {
        NavigationStack {
            List {
                CommunityPluginMarketplaceStateSections()

                Section("GitHub") {
                    TextField("https://github.com/owner/repository", text: $location)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("覆盖同名插件", isOn: $replaceExisting)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("安装仓库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("安装") {
                        Task {
                            let installed = await model.installISHMarketplacePlugin(
                                source: ISHMarketplacePluginSource(
                                    kind: .github,
                                    location: normalizedLocation
                                ),
                                replace: replaceExisting
                            )
                            if installed { dismiss() }
                        }
                    }
                    .disabled(
                        model.isISHPluginMarketplaceWorking
                            || normalizedLocation.isEmpty
                    )
                }
            }
            .interactiveDismissDisabled(model.isISHPluginMarketplaceWorking)
        }
        .presentationDetents([.medium, .large])
    }

    private var normalizedLocation: String {
        location.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension View {
    func communityPluginListChrome() -> some View {
        listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 52)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

private extension ISHMarketplaceCompatibility {
    var title: String {
        switch self {
        case .supported: "Host 兼容"
        case .review: "需安装校验"
        case .unsupported: "仅桌面 Client"
        }
    }

    var iconName: String {
        switch self {
        case .supported: "checkmark.shield.fill"
        case .review: "shield.lefthalf.filled"
        case .unsupported: "desktopcomputer.trianglebadge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .supported: .green
        case .review: .orange
        case .unsupported: .secondary
        }
    }
}

private extension ISHMarketplacePluginState {
    var title: String {
        switch self {
        case .enabled: "运行中"
        case .disabled: "已关闭"
        case .failed: "加载失败"
        }
    }

    var iconName: String {
        switch self {
        case .enabled: "checkmark.circle.fill"
        case .disabled: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .enabled: .green
        case .disabled: .secondary
        case .failed: .red
        }
    }
}

private extension ISHMarketplacePluginSourceKind {
    var title: String {
        switch self {
        case .market: "社区市场"
        case .github: "GitHub"
        case .localZip: "本地 ZIP"
        }
    }
}

private extension ISHPluginHostRuntimeState {
    var title: String {
        switch self {
        case .installing: "安装中"
        case .starting: "启动中"
        case .running(_, _): "运行中"
        case .stopped: "未启动"
        case .failed(_): "异常"
        }
    }

    var iconName: String {
        switch self {
        case .installing, .starting: "hourglass"
        case .running(_, _): "checkmark.circle.fill"
        case .stopped: "pause.circle"
        case .failed(_): "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .installing, .starting: .orange
        case .running(_, _): .green
        case .stopped: .secondary
        case .failed(_): .red
        }
    }
}
