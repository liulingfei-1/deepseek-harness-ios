import SwiftUI

struct PluginManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var presentedSheet: PluginManagementSheet?

    var body: some View {
        List {
            Section {
                PluginRuntimeSummary(
                    installedCount: model.pluginSnapshots.count,
                    activeCount: activePluginCount,
                    hostCount: model.ishPluginHostInventory.count,
                    contributionSummary: "工具 \(model.pluginToolContributions.count) · 提示词 \(model.pluginPromptContributions.count) · 客户端 \(model.ishNativeClientPlugins.count)"
                )
                .accessibilityIdentifier("plugin-runtime-summary")
            } header: {
                Label("Cordis 运行时", systemImage: "cpu")
            } footer: {
                Text("原生插件可热启停和回滚；社区 JavaScript 插件由手机内 iSH Host 承载。")
            }

            ISHPluginHostSection()

            if !filteredHostInventory.isEmpty {
                Section {
                    ForEach(filteredHostInventory, id: \.pluginId) { entry in
                        NavigationLink {
                            ISHPluginDetailView(pluginID: entry.pluginId)
                        } label: {
                            ISHPluginInventoryRow(entry: entry)
                        }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let plan = entry.preferredActivationPlan {
                                    Button {
                                        Task {
                                            await model.runISHPlugin(
                                                pluginID: entry.pluginId,
                                                packageID: plan.packageID,
                                                mode: plan.mode
                                            )
                                        }
                                    } label: {
                                        Label(plan.title, systemImage: plan.iconName)
                                    }
                                    .tint(plan.tint)
                                }

                                if entry.activeRun != nil {
                                    Button {
                                        Task { await model.stopISHPlugin(pluginID: entry.pluginId) }
                                    } label: {
                                        Label("停止", systemImage: "stop.fill")
                                    }
                                    .tint(.orange)
                                }

                                Button(role: .destructive) {
                                    Task { await model.undefineISHPlugin(pluginID: entry.pluginId) }
                                } label: {
                                    Label("卸载", systemImage: "trash")
                                }
                            }
                            .harnessCardListRow()
                    }
                } header: { Label("iSH 动态插件", systemImage: "terminal") }
            }

            if filteredSnapshots.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Section {
                    ForEach(filteredSnapshots, id: \.id) { snapshot in
                        NavigationLink {
                            PluginDetailView(pluginID: snapshot.id)
                        } label: {
                            PluginInventoryRow(snapshot: snapshot)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                Task { await model.restartPlugin(id: snapshot.id) }
                            } label: {
                                Label("重启", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                        .harnessCardListRow()
                    }
                } header: { Label("插件", systemImage: "puzzlepiece.extension") }
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("插件")
        .searchable(text: $query, prompt: "搜索插件、依赖或服务")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        presentedSheet = .experimentalPrompt
                    } label: {
                        Label("提示词插件", systemImage: "text.badge.plus")
                    }
                    Button {
                        presentedSheet = .ishHostPlugin
                    } label: {
                        Label("iSH JavaScript 插件", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加插件")
                .accessibilityIdentifier("add-plugin-menu")
                .help("添加插件")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .experimentalPrompt:
                ExperimentalPromptPluginSheet()
            case .ishHostPlugin:
                ISHHostPluginSheet()
            }
        }
        .task {
            await model.refreshPluginInventory()
        }
        .refreshable {
            await model.refreshPluginInventory()
        }
    }

    private var activePluginCount: Int {
        model.pluginSnapshots.count { $0.state == .active }
    }

    private var filteredSnapshots: [CordisPluginSnapshot] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.pluginSnapshots }
        return model.pluginSnapshots.filter { snapshot in
            let searchable = [
                snapshot.id.rawValue,
                snapshot.version,
                snapshot.state.rawValue,
                snapshot.dependencies.joined(separator: " "),
                snapshot.provides.joined(separator: " "),
                snapshot.missingDependencies.joined(separator: " "),
                snapshot.error ?? ""
            ].joined(separator: " ").lowercased()
            return searchable.contains(normalized)
        }
    }

    private var filteredHostInventory: [ISHPluginHostInventoryEntry] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return model.ishPluginHostInventory }
        return model.ishPluginHostInventory.filter { entry in
            let searchable = [
                entry.pluginId,
                entry.agentId,
                entry.currentPackageId ?? "",
                entry.nextPackageId ?? "",
                entry.packages.map { [$0.packageId, $0.name, $0.purpose].joined(separator: " ") }
                    .joined(separator: " ")
            ].joined(separator: " ").lowercased()
            return searchable.contains(normalized)
        }
    }
}

private struct PluginRuntimeSummary: View {
    let installedCount: Int
    let activeCount: Int
    let hostCount: Int
    let contributionSummary: String

    var body: some View {
        VStack(alignment: .leading, spacing: HarnessTheme.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HarnessTheme.Spacing.small) {
                    summaryItem("已安装", value: installedCount, icon: "puzzlepiece.extension", tint: .accentColor)
                    summaryItem("运行中", value: activeCount, icon: "bolt.fill", tint: .green)
                    summaryItem("Host 插件", value: hostCount, icon: "terminal.fill", tint: .orange)
                }

                VStack(alignment: .leading, spacing: HarnessTheme.Spacing.small) {
                    HStack(spacing: HarnessTheme.Spacing.small) {
                        summaryItem("已安装", value: installedCount, icon: "puzzlepiece.extension", tint: .accentColor)
                        summaryItem("运行中", value: activeCount, icon: "bolt.fill", tint: .green)
                    }
                    summaryItem("Host 插件", value: hostCount, icon: "terminal.fill", tint: .orange)
                }
            }
            Text(contributionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, HarnessTheme.Spacing.xSmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("插件运行时摘要：已安装 \(installedCount) 个，运行中 \(activeCount) 个，Host 插件 \(hostCount) 个。\(contributionSummary)")
    }

    private func summaryItem(_ title: String, value: Int, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HarnessIconTile(systemImage: icon, tint: tint, size: 28)
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum PluginManagementSheet: String, Identifiable {
    case experimentalPrompt
    case ishHostPlugin

    var id: String { rawValue }
}

private struct ISHPluginHostSection: View {
    @Environment(AppModel.self) private var model
    @State private var isWorking = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: model.ishPluginHostState.iconName)
                    .font(.title3)
                    .foregroundStyle(model.ishPluginHostState.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("iSH Cordis Host")
                        .font(.headline)
                    Text(model.ishPluginHostState.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let processID = model.ishPluginHostState.processID {
                    Text("PID \(processID)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("ish-plugin-host-status")

            HStack(spacing: 10) {
                Button {
                    runHostAction(.start)
                } label: {
                    Label("启动", systemImage: "play.fill")
                }
                .disabled(isWorking || model.ishPluginHostState.isRunning)
                .accessibilityIdentifier("ish-plugin-host-start")

                Button {
                    runHostAction(.refresh)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(isWorking || !model.ishPluginHostState.isRunning)
                .accessibilityIdentifier("ish-plugin-host-refresh")

                Button(role: .destructive) {
                    runHostAction(.stop)
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .disabled(isWorking || !model.ishPluginHostState.isRunning)
                .accessibilityIdentifier("ish-plugin-host-stop")
            }
            .buttonStyle(.bordered)

            if !model.ishPluginHostPackages.isEmpty {
                ForEach(model.ishPluginHostPackages.keys.sorted(), id: \.self) { packageName in
                    LabeledContent(
                        packageName,
                        value: model.ishPluginHostPackages[packageName] ?? "-"
                    )
                    .font(.caption)
                }
            }

            NavigationLink {
                CommunityPluginMarketView()
            } label: {
                Label {
                    HStack {
                        Text("社区插件市场")
                        Spacer()
                        if !model.ishMarketplacePlugins.isEmpty {
                            Text("\(model.ishMarketplacePlugins.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "shippingbox.and.arrow.backward")
                }
            }
            .accessibilityIdentifier("community-plugin-market")

            NavigationLink {
                PluginSettingsView()
            } label: {
                Label {
                    HStack {
                        Text("插件设置")
                        Spacer()
                        if let count = model.ishPluginSettingsSnapshot?.namespaces.count,
                           count > 0 {
                            Text("\(count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
            .accessibilityIdentifier("ish-plugin-settings")

            if let diagnostics = model.ishPluginHostDiagnostics,
               !diagnostics.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Host stderr", systemImage: "waveform.path.ecg")
                        .font(.caption.weight(.semibold))
                    Text(diagnostics.stderrTail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("iSH Host")
        } footer: {
            Text("动态定义随 Host 停止释放；从社区市场安装的 Host 插件会持久保存在手机 iSH 工作区。")
        }
    }

    private func runHostAction(_ action: HostAction) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            switch action {
            case .start:
                _ = await model.startISHPluginHost()
            case .refresh:
                await model.refreshISHPluginHost()
            case .stop:
                await model.stopISHPluginHost()
            }
            isWorking = false
        }
    }

    private enum HostAction {
        case start
        case refresh
        case stop
    }
}

private struct ISHPluginInventoryRow: View {
    let entry: ISHPluginHostInventoryEntry

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(
                systemImage: entry.activeRun == nil ? "shippingbox" : "shippingbox.fill",
                tint: entry.activeRun == nil ? .secondary : .green
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.pluginId)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Text(entry.packages.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let activeRun = entry.activeRun {
                    Text("运行中 · \(activeRun.packageId)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if let currentPackageID = entry.currentPackageId {
                    Text("已定义 · \(currentPackageID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if entry.nextPackageId != nil {
                HarnessStatusPill(title: "待切换", systemImage: "arrow.triangle.2.circlepath", tint: .orange)
                    .accessibilityLabel("有待切换版本")
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ISHPluginDetailView: View {
    @Environment(AppModel.self) private var model
    let pluginID: String
    @State private var isWorking = false

    var body: some View {
        Group {
            if let entry {
                Form {
                    Section {
                        LabeledContent("插件", value: entry.pluginId)
                        LabeledContent("会话 Agent", value: entry.agentId)
                        HStack {
                            Text("状态")
                            Spacer(minLength: 8)
                            HarnessStatusPill(
                                title: entry.activeRun == nil ? "已停止" : "运行中",
                                systemImage: entry.activeRun == nil ? "pause.circle" : "bolt.fill",
                                tint: entry.activeRun == nil ? .secondary : .green
                            )
                        }
                        if let packageID = entry.currentPackageId {
                            LabeledContent("当前版本", value: packageID)
                        }
                        if let packageID = entry.nextPackageId,
                           packageID != entry.currentPackageId {
                            LabeledContent("待切换版本", value: packageID)
                        }
                        if let activeRun = entry.activeRun {
                            LabeledContent("Run ID", value: activeRun.pluginRunId)
                        }

                        if let plan = entry.preferredActivationPlan {
                            Button {
                                run(.activate(plan))
                            } label: {
                                Label(plan.title, systemImage: plan.iconName)
                            }
                            .disabled(isWorking)
                        }

                        if entry.activeRun != nil {
                            Button {
                                run(.stop)
                            } label: {
                                Label("停止", systemImage: "stop.fill")
                            }
                            .disabled(isWorking)
                        }

                        NavigationLink {
                            PluginSettingsView()
                        } label: {
                            Label("Host 设置命名空间", systemImage: "slider.horizontal.3")
                        }
                    } header: { Label("生命周期", systemImage: "arrow.clockwise") }

                    Section {
                        ForEach(entry.packages, id: \.packageId) { package in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(package.name)
                                        .font(.headline)
                                    Spacer(minLength: 8)
                                    Text(package.packageId)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text(package.purpose)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) {
                                        packageCapabilityLabels(for: package)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        packageCapabilityLabels(for: package)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let plan = entry.activationPlan(for: package.packageId) {
                                    Button {
                                        run(.activate(plan))
                                    } label: {
                                        Label(plan.title, systemImage: plan.iconName)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isWorking || package.hasClientHalf)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    } header: { Label("Packages", systemImage: "shippingbox") }

                    if let latestRun = entry.latestRun {
                        Section {
                            Text(latestRun.displayText)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } header: { Label("最近一次运行", systemImage: "clock.arrow.circlepath") }
                    }

                    Section {
                        Button("卸载插件", role: .destructive) {
                            run(.undefine)
                        }
                        .disabled(isWorking)
                    } footer: {
                        Text("卸载会移除该插件的全部内存 Package；iSH Host 重启后动态定义也会消失。")
                    }
                }
            } else {
                ContentUnavailableView(
                    "插件不可用",
                    systemImage: "shippingbox",
                    description: Text("它可能已卸载，或 iSH Host 已经重启。")
                )
            }
        }
        .navigationTitle(pluginID)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshPluginInventory()
        }
    }

    private var entry: ISHPluginHostInventoryEntry? {
        model.ishPluginHostInventory.first { $0.pluginId == pluginID }
    }

    private func run(_ action: Action) {
        guard !isWorking else { return }
        isWorking = true
        Task { @MainActor in
            switch action {
            case let .activate(plan):
                await model.runISHPlugin(
                    pluginID: pluginID,
                    packageID: plan.packageID,
                    mode: plan.mode
                )
            case .stop:
                await model.stopISHPlugin(pluginID: pluginID)
            case .undefine:
                await model.undefineISHPlugin(pluginID: pluginID)
            }
            isWorking = false
        }
    }

    private enum Action {
        case activate(ISHPluginHostActivationPlan)
        case stop
        case undefine
    }

    @ViewBuilder
    private func packageCapabilityLabels(
        for package: ISHPluginHostPackageSummary
    ) -> some View {
        Label(
            package.hasHostHalf ? "Host" : "无 Host",
            systemImage: package.hasHostHalf ? "terminal.fill" : "terminal"
        )
        Label(
            package.hasClientHalf ? "Client" : "无 Client",
            systemImage: package.hasClientHalf ? "rectangle.on.rectangle" : "iphone"
        )
    }
}

private struct PluginInventoryRow: View {
    let snapshot: CordisPluginSnapshot

    var body: some View {
        HStack(spacing: 12) {
            HarnessIconTile(systemImage: snapshot.state.iconName, tint: snapshot.state.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.id.rawValue)
                    .font(.body.monospaced())
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(snapshot.state.title)
                    Text("v\(snapshot.version)")
                    if snapshot.generation > 0 {
                        Text("gen \(snapshot.generation)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !snapshot.isEnabled {
                HarnessStatusPill(title: "已停用", systemImage: "pause.circle.fill", tint: .secondary)
            } else if !snapshot.missingDependencies.isEmpty {
                HarnessStatusPill(title: "等待依赖", systemImage: "link.badge.plus", tint: .orange)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    let pluginID: CordisPluginID

    var body: some View {
        Group {
            if let snapshot {
                Form {
                    Section {
                        LabeledContent("状态", value: snapshot.state.title)
                        LabeledContent("版本", value: snapshot.version)
                        LabeledContent("代次", value: "\(snapshot.generation)")
                        Toggle(
                            "启用插件",
                            isOn: Binding(
                                get: { snapshot.isEnabled },
                                set: { enabled in
                                    Task {
                                        await model.setPluginEnabled(enabled, id: pluginID)
                                    }
                                }
                            )
                        )
                        Button {
                            Task { await model.restartPlugin(id: pluginID) }
                        } label: {
                            Label("重启 Fiber", systemImage: "arrow.clockwise")
                        }
                    } header: { Label("生命周期", systemImage: "arrow.clockwise") }

                    if !snapshot.dependencies.isEmpty {
                        StringListSection(title: "依赖", values: snapshot.dependencies)
                    }
                    if !snapshot.provides.isEmpty {
                        StringListSection(title: "提供服务", values: snapshot.provides)
                    }
                    if !snapshot.missingDependencies.isEmpty {
                        StringListSection(
                            title: "等待重连",
                            values: snapshot.missingDependencies,
                            tint: .orange
                        )
                    }

                    let tools = model.pluginToolContributions.filter { $0.pluginID == pluginID }
                    if !tools.isEmpty {
                        Section {
                            ForEach(tools, id: \.definition.name) { contribution in
                                LabeledContent(
                                    contribution.definition.name,
                                    value: contribution.risk.rawValue
                                )
                            }
                        } header: { Label("工具", systemImage: "wrench.and.screwdriver") }
                    }

                    let prompts = model.pluginPromptContributions.filter { $0.pluginID == pluginID }
                    if !prompts.isEmpty {
                        Section {
                            ForEach(prompts, id: \.stableID) { contribution in
                                LabeledContent(
                                    contribution.name,
                                    value: contribution.kind.rawValue
                                )
                            }
                        } header: { Label("提示词", systemImage: "text.quote") }
                    }

                    if let error = snapshot.error {
                        Section {
                            Text(error)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } header: { Label("故障隔离", systemImage: "exclamationmark.triangle") }
                    }

                    if pluginID.rawValue.hasPrefix("memory.") || pluginID.rawValue.hasPrefix("ish.") {
                        Section {
                            Button("卸载插件", role: .destructive) {
                                Task { await model.uninstallPlugin(id: pluginID) }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "插件已卸载",
                    systemImage: "shippingbox",
                    description: Text("返回插件列表查看当前运行时库存。")
                )
            }
        }
        .navigationTitle(pluginID.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshPluginInventory()
        }
    }

    private var snapshot: CordisPluginSnapshot? {
        model.pluginSnapshots.first { $0.id == pluginID }
    }
}

private struct StringListSection: View {
    let title: String
    let values: [String]
    var tint: Color = .secondary

    var body: some View {
        Section {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.body.monospaced())
                    .foregroundStyle(tint)
            }
        } header: { Label(title, systemImage: "list.bullet.rectangle") }
    }
}

private struct ExperimentalPromptPluginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pluginName = ""
    @State private var instruction = ""
    @State private var isInstalling = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $pluginName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextEditor(text: $instruction)
                        .frame(minHeight: 160)
                } header: {
                    Label("内存插件", systemImage: "text.badge.plus")
                } footer: {
                    Text("插件只存在于当前 App 进程，重启后消失；启用后会在下一步请求中加入提示词。")
                }
            }
            .navigationTitle("实验插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("安装") {
                        isInstalling = true
                        Task {
                            let installed = await model.installExperimentalPromptPlugin(
                                id: pluginName,
                                instruction: instruction
                            )
                            isInstalling = false
                            if installed { dismiss() }
                        }
                    }
                    .disabled(
                        isInstalling
                            || pluginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

private struct ISHHostPluginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pluginName = ""
    @State private var purpose = ""
    @State private var hostCode = Self.defaultHostCode
    @State private var isInstalling = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $pluginName)
                        .accessibilityIdentifier("ish-plugin-name")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("用途", text: $purpose, axis: .vertical)
                        .accessibilityIdentifier("ish-plugin-purpose")
                        .lineLimit(2...4)
                    TextEditor(text: $hostCode)
                        .accessibilityIdentifier("ish-plugin-host-code")
                        .font(.footnote.monospaced())
                        .frame(minHeight: 260)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Label("Host-half JavaScript", systemImage: "terminal")
                } footer: {
                    Text("代码只在本机 iSH Cordis Host 的内存中定义和运行。")
                }
            }
            .navigationTitle("iSH 插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("定义并运行") {
                        isInstalling = true
                        Task { @MainActor in
                            let installed = await model.defineAndRunISHPlugin(
                                name: pluginName,
                                purpose: purpose,
                                hostCode: hostCode
                            )
                            isInstalling = false
                            if installed { dismiss() }
                        }
                    }
                    .disabled(
                        isInstalling
                            || pluginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || hostCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .interactiveDismissDisabled(isInstalling)
        }
        .presentationDetents([.medium, .large])
    }

    private static let defaultHostCode = """
    return {
      name: 'mobile-echo',
      inject: ['tools'],
      apply(ctx) {
        harness.registerTool(ctx, harness.defineTool({
          name: 'mobile_echo',
          description: 'Return the supplied text.',
          parameters: { text: { type: 'string', required: true } },
          output: {
            schema: { type: 'string' },
            render(_args, value) { return [{ type: 'text', text: value }] },
          },
          async execute(args) { return String(args.text ?? '') },
        }))
      },
    }
    """
}

private extension ISHPluginHostActivationPlan {
    var title: String {
        switch mode {
        case .run: "运行"
        case .update: "更新"
        }
    }

    var iconName: String {
        switch mode {
        case .run: "play.fill"
        case .update: "arrow.triangle.2.circlepath"
        }
    }

    var tint: Color {
        switch mode {
        case .run: .green
        case .update: .blue
        }
    }
}

private extension CordisPluginState {
    var title: String {
        switch self {
        case .pending: "等待"
        case .loading: "加载中"
        case .active: "运行中"
        case .failed: "失败"
        case .unloading: "卸载中"
        case .disposed: "已释放"
        }
    }

    var iconName: String {
        switch self {
        case .pending: "clock"
        case .loading, .unloading: "arrow.trianglehead.2.clockwise.rotate.90"
        case .active: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .disposed: "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .active: .green
        case .failed: .red
        case .pending: .orange
        case .loading, .unloading: .blue
        case .disposed: .secondary
        }
    }
}

private extension ISHPluginHostRuntimeState {
    var title: String {
        switch self {
        case .stopped: "未启动"
        case .installing: "安装依赖中"
        case .starting: "启动中"
        case .running: "运行中"
        case .failed: "故障隔离"
        }
    }

    var iconName: String {
        switch self {
        case .stopped: "pause.circle"
        case .installing, .starting: "arrow.triangle.2.circlepath"
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: .secondary
        case .installing, .starting: .orange
        case .running: .green
        case .failed: .red
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var processID: Int32? {
        guard case let .running(_, processID) = self else { return nil }
        return processID
    }
}

private extension CordisPromptContributionSnapshot {
    var stableID: String {
        "\(kind.rawValue):\(name)"
    }
}
