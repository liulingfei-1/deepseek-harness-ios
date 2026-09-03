import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isResetConfirmationPresented = false
    @State private var isRemoveConfirmationPresented = false

    var body: some View {
        Form {
            Section {
                LabeledContent("服务商", value: activeProfileName)
                LabeledContent("API", value: endpointHost)
                LabeledContent("模型", value: model.configuration.model)
                LabeledContent("思考", value: model.configuration.reasoningMode.title)
                if let compatibilityNotice = provider.compatibilityNotice {
                    Label(compatibilityNotice, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    ProviderProfilesView()
                } label: {
                    SettingsLinkLabel(title: "模型与服务商", systemImage: "server.rack", tint: .blue)
                }
                .accessibilityIdentifier("settings-model-providers")
            } header: { Label("模型", systemImage: "server.rack") }

            Section {
                NavigationLink {
                    BackgroundSettingsView(
                        runtimeStatus: model.backgroundRuntimeStatus,
                        locationSnapshot: model.backgroundLocationKeepAliveSnapshot,
                        systemProjection: model.backgroundSystemProjection,
                        requestLocationAuthorization: model.requestBackgroundLocationAuthorization
                    )
                } label: {
                    SettingsLinkLabel(title: "后台任务与恢复", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90", tint: .orange)
                }
                .accessibilityIdentifier("settings-background-tasks")
                LabeledContent("当前状态", value: backgroundStatusLabel)
                LabeledContent("活动任务", value: "\(model.backgroundSystemProjection.activeRunCount) 个")
            } header: { Label("后台", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }

            Section {
                NavigationLink {
                    WebSearchSettingsView()
                } label: {
                    SettingsLinkLabel(title: "联网搜索", systemImage: "magnifyingglass", tint: .cyan)
                }
                .accessibilityIdentifier("settings-web-search")
            } header: { Label("搜索", systemImage: "magnifyingglass") }

            Section {
                NavigationLink {
                    AgentProviderBundlesView()
                } label: {
                    SettingsLinkLabel(title: "Agent 编排 Bundle", systemImage: "arrow.triangle.branch", tint: .indigo)
                }
                .accessibilityIdentifier("settings-agent-bundles")
                NavigationLink {
                    PhonePermissionsView()
                } label: {
                    SettingsLinkLabel(title: "手机权限", systemImage: "hand.raised", tint: .green)
                }
                .accessibilityIdentifier("settings-phone-permissions")
            } header: { Label("Agent 与权限", systemImage: "person.crop.circle.badge.checkmark") }

            Section {
                NavigationLink {
                    PluginManagementView()
                } label: {
                    SettingsLinkLabel(title: "Cordis 插件", systemImage: "puzzlepiece.extension", tint: .purple)
                }
                NavigationLink {
                    ToolApprovalSettingsView()
                } label: {
                    HStack {
                        SettingsLinkLabel(title: "工具授权", systemImage: "checkmark.shield", tint: .teal)
                        Spacer()
                        Text("仅本次")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("settings-tool-approvals")
                LabeledContent("本机工具", value: "\(ProductionToolCatalog.approvedNames.count) 项")
            } header: { Label("工具与插件", systemImage: "puzzlepiece.extension") }

            Section {
                NavigationLink {
                    WorkspaceView()
                } label: {
                    SettingsLinkLabel(title: "本机工作区", systemImage: "folder", tint: .orange)
                }
                .accessibilityIdentifier("settings-workspace")
                NavigationLink {
                    MemoryManagementView()
                } label: {
                    SettingsLinkLabel(title: "记忆", systemImage: "brain", tint: .purple)
                }
                .accessibilityIdentifier("settings-memory")
                LabeledContent("会话存储", value: "本机持久化")
                LabeledContent("同步", value: "未启用")
                Text("会话、轨迹和工作区文件保存在此 iPhone。当前版本不会把凭据或会话正文上传到同步服务。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Label("存储与同步", systemImage: "externaldrive") }

            Section {
                Button {
                    isResetConfirmationPresented = true
                } label: {
                    Label("清空当前会话", systemImage: "trash")
                }
                .foregroundStyle(.red)

                Button {
                    isRemoveConfirmationPresented = true
                } label: {
                    Label("重置全部模型连接", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(.red)
            } header: {
                Label("危险操作", systemImage: "exclamationmark.triangle")
            } footer: {
                Text("这些操作只影响本机配置或当前会话；工作区文件不会被删除。")
            }

            Section {
                DisclosureGroup("执行边界") {
                    LabeledContent("模型推理", value: "你配置的 API")
                    LabeledContent("Agent Loop", value: "本机")
                    LabeledContent("工具与文件", value: "本机")
                    LabeledContent("命令执行", value: "手机 iSH / Alpine")
                    LabeledContent("Linux 网络", value: "默认开启")
                    Text("模型 provider 只负责推理。shell_execute、文件和 Agent Loop 都在 iPhone 内执行；Linux 网络默认可用，也可在“命令”页主动关闭。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    SettingsLinkLabel(title: "详细日志", systemImage: "doc.text.magnifyingglass", tint: .gray)
                }
                .accessibilityIdentifier("settings-diagnostics")
                if let usage = model.latestUsage {
                    LabeledContent("最近用量", value: "输入 \(usage.promptTokens) · 输出 \(usage.completionTokens)")
                }
                Text("诊断导出会在本机先脱敏；默认不包含 API Key、Authorization、命令正文或模型提示词。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: { Label("隐私与诊断", systemImage: "checkmark.shield") }
        }
        .harnessCompactListChrome()
        .scrollContentBackground(.hidden)
        .navigationTitle("设置")
        .confirmationDialog(
            "清空当前会话？",
            isPresented: $isResetConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) {
                Task {
                    await model.resetConversation()
                }
            }
        } message: {
            Text("这会删除本机保存的当前对话，不会删除工作区文件。")
        }
        .confirmationDialog(
            "重置全部模型连接？",
            isPresented: $isRemoveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                Task {
                    await model.removeConfiguration()
                }
            }
        } message: {
            Text("所有 Provider Profile 和 API Key 会被移除，本地会话和工作区文件保留。")
        }
    }

    private var provider: ModelProviderDescriptor {
        ModelProviderCatalog.descriptor(for: model.configuration.providerID)
    }

    private var activeProfileName: String {
        model.activeProviderProfile?.displayName ?? provider.displayName
    }

    private var endpointHost: String {
        URLComponents(string: model.configuration.baseURL)?.host ?? "无效地址"
    }

    private var backgroundStatusLabel: String {
        switch model.backgroundSystemProjection.survivalTier {
        case .foreground: "前台"
        case .finiteBackgroundTask: "短时后台"
        case .continuedProcessing: "Continued Processing"
        case .extendedAudio: "音频延展"
        case .extendedLocation: "定位延展"
        case .degraded: "降级"
        }
    }
}

private struct SettingsLinkLabel: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 11) {
            HarnessIconTile(systemImage: systemImage, tint: tint, size: 30)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

private struct WebSearchSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProvider = "none"
    @State private var apiKey = ""
    @State private var credentialStatus: ProviderCredentialStatus = .unknown
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let providers = [
        (id: "none", name: "关闭搜索", detail: "不注册联网搜索工具"),
        (id: DeepSeekSearchProvider.identifierValue, name: "DeepSeek", detail: "使用当前模型服务商的搜索能力"),
        (id: ExaSearchProvider.identifierValue, name: "Exa", detail: "Exa Search API"),
        (id: PerplexitySearchProvider.identifierValue, name: "Perplexity", detail: "Perplexity Sonar API")
    ]

    var body: some View {
        Form {
            Section {
                Picker("搜索服务商", selection: $selectedProvider) {
                    ForEach(providers, id: \.id) { provider in
                        VStack(alignment: .leading) {
                            Text(provider.name)
                            Text(provider.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .disabled(provider.id == DeepSeekSearchProvider.identifierValue && model.effectiveConfiguration.providerID != .deepSeekOfficial)
                        .tag(provider.id)
                    }
                }
                .accessibilityIdentifier("web-search-provider-picker")
                .onChange(of: selectedProvider) { _, newValue in
                    model.setWebSearchProvider(newValue == "none" ? nil : newValue)
                    Task { await refreshCredentialStatus(for: newValue) }
                }
            } header: {
                Text("联网搜索")
            } footer: {
                Text("搜索结果会携带服务商返回的 URL、标题和摘要。DeepSeek 仅在当前模型服务商为官方 DeepSeek 时可用。")
            }

            if selectedProvider == ExaSearchProvider.identifierValue || selectedProvider == PerplexitySearchProvider.identifierValue {
                Section {
                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)
                        .accessibilityIdentifier("web-search-api-key")
                    LabeledContent("凭据状态", value: credentialStatusLabel)
                    HStack {
                        Button("保存") { saveKey() }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        if credentialStatus == .configured {
                            Button("删除 Key", role: .destructive) { deleteKey() }
                                .disabled(isSaving)
                        }
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                } header: {
                    Text("\(selectedProvider.capitalized) 凭据")
                } footer: {
                    Text("Key 仅保存到本机 Keychain；未配置 Key 时搜索工具会返回明确错误。")
                }
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("联网搜索")
        .task {
            let saved = UserDefaults.standard.string(forKey: "harness.web-search-provider")
            selectedProvider = saved ?? (model.effectiveConfiguration.providerID == .deepSeekOfficial ? DeepSeekSearchProvider.identifierValue : "none")
            await refreshCredentialStatus(for: selectedProvider)
        }
        .alert("搜索设置失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var credentialStatusLabel: String {
        switch credentialStatus {
        case .unknown: "检查中"
        case .configured: "已配置"
        case .missing: "缺少 Key"
        case .originMismatch: "来源不匹配"
        }
    }

    private func refreshCredentialStatus(for providerID: String) async {
        guard providerID == ExaSearchProvider.identifierValue || providerID == PerplexitySearchProvider.identifierValue else {
            credentialStatus = .unknown
            return
        }
        credentialStatus = await model.searchProviderCredentialStatus(for: providerID)
    }

    private func saveKey() {
        isSaving = true
        Task {
            do {
                try await model.saveSearchProviderAPIKey(apiKey, providerID: selectedProvider)
                model.setWebSearchProvider(selectedProvider)
                apiKey = ""
                await refreshCredentialStatus(for: selectedProvider)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func deleteKey() {
        isSaving = true
        Task {
            do {
                try await model.deleteSearchProviderAPIKey(providerID: selectedProvider)
                credentialStatus = .missing
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct DiagnosticLogView: View {
    @Environment(AppModel.self) private var model

    @State private var isRefreshing = false
    @State private var isPreparingExport = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportFilename = "Harness-Diagnostics"
    @State private var workspaceExportPath: String?

    var body: some View {
        @Bindable var preferences = model.backgroundPreferences

        Form {
            Section {
                LabeledContent("Agent", value: model.isRunning ? "运行中" : "空闲")
                LabeledContent("当前步骤", value: "\(model.currentStep)")
                LabeledContent("会话轨迹", value: "\(model.trajectoryEvents.count) 条")
                LabeledContent("Harness Trace", value: "\(model.harnessTraceEvents.count) 条")
            } header: {
                Label("当前运行", systemImage: "waveform.path.ecg")
            }

            Section {
                Text(model.diagnosticHostStateDescription)
                    .font(.footnote)
                    .textSelection(.enabled)

                if let diagnostics = model.ishPluginHostDiagnostics {
                    LabeledContent("等待中的 RPC", value: "\(diagnostics.pendingRequestCount)")
                    LabeledContent(
                        "待写入 stdin",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(diagnostics.outboundQueuedBytes),
                            countStyle: .memory
                        )
                    )
                    LabeledContent(
                        "stdin 写入",
                        value: diagnostics.outboundWriteInFlight ? "进行中" : "空闲"
                    )
                    LabeledContent("stdin 拒绝次数", value: "\(diagnostics.rejectedWriteCount)")
                    if let failure = diagnostics.lastTransportFailure {
                        LabeledContent("最近传输错误") {
                            Text(failure)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if !diagnostics.stderrTail.isEmpty {
                        DisclosureGroup("stderr 最近输出") {
                            Text(diagnostics.stderrTail)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if let failure = model.ishPluginMarketplaceFailure {
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } header: {
                Label("Cordis Host", systemImage: "terminal")
            }

            Section {
                Button("刷新日志", systemImage: "arrow.clockwise") {
                    refresh()
                }
                .disabled(isRefreshing || isPreparingExport)

                Button("导出详细日志", systemImage: "square.and.arrow.up") {
                    prepareExport()
                }
                .disabled(isRefreshing || isPreparingExport)

                if isRefreshing || isPreparingExport {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(isPreparingExport ? "正在生成脱敏日志…" : "正在刷新本机状态…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("导出内容与脱敏") {
                    Text("导出包含设备与运行状态、Cordis 插件、Plugin Host stderr、有限 runtime telemetry、Harness Trace 和当前会话完整轨迹。API Key、Authorization 及常见密码/Secret 字段会在手机上脱敏后再写入文件；同时会写入当前会话的本地 Downloads 工作区。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("导出前在本机脱敏，并保存到当前会话 Downloads。")
            }

            Section {
                Toggle("记录有限性能/资源样本", isOn: $preferences.isPerformanceResourceSamplingEnabled)
                    .onChange(of: preferences.isPerformanceResourceSamplingEnabled) { _, _ in
                        Task { await model.configureRuntimePerformanceSampling() }
                    }

                DisclosureGroup("采样内容与隐私") {
                    Text("开启后仅记录有界的热状态、低电量和前后台数值标记；不记录提示词、工具参数或输出、URL、请求头、Cookie、环境变量和调用栈。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("性能与资源采样")
            } footer: {
                Text("默认关闭，仅记录有界的系统数值标记。")
            }

            if let workspaceExportPath {
                Section {
                    Text(workspaceExportPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("本地副本")
                } footer: {
                    Text("这是当前会话哈希隔离的工作区相对路径，不包含会话原始 ID。")
                }
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("详细日志")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: exportDocument,
            contentType: ConversationExportFileDocument.logContentType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case let .failure(error) = result {
                model.presentError(error)
            }
        }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            await model.refreshDiagnostics()
            isRefreshing = false
        }
    }

    private func prepareExport() {
        guard !isPreparingExport else { return }
        isPreparingExport = true
        Task { @MainActor in
            defer { isPreparingExport = false }
            do {
                let export = try await model.diagnosticReportExport()
                exportDocument = ConversationExportFileDocument(data: export.data)
                workspaceExportPath = export.workspacePath
                exportFilename = "Harness-Diagnostics-\(Self.filenameTimestamp())"
                isFileExporterPresented = true
            } catch {
                model.presentError(error)
            }
        }
    }

    private static func filenameTimestamp(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct ToolApprovalSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isRevokeAllConfirmationPresented = false

    var body: some View {
        Form {
            if model.trustedToolApprovals.isEmpty {
                Section {
                    Label("暂无长期工具授权", systemImage: "checkmark.shield")
                } footer: {
                    Text("只有在首次弹窗中选择“始终允许”才会保存；iOS 系统隐私权限仍由系统单独管理。")
                }
            } else {
                Section {
                    ForEach(model.trustedToolApprovals) { grant in
                        ToolApprovalGrantRow(grant: grant) {
                            model.revokeToolApproval(id: grant.id)
                        }
                    }
                    Button("撤销全部工具授权", role: .destructive) {
                        isRevokeAllConfirmationPresented = true
                    }
                } header: {
                    Text("长期授权")
                } footer: {
                    Text("iOS 系统隐私权限仍由系统单独管理。")
                }
            }
        }
        .harnessCompactListChrome()
        .navigationTitle("工具授权")
        .confirmationDialog(
            "撤销全部工具授权？",
            isPresented: $isRevokeAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("全部撤销", role: .destructive) {
                model.revokeAllToolApprovals()
            }
        } message: {
            Text("删除后，下次命中相同范围的工具调用会再次询问。")
        }
    }
}

private struct ToolApprovalGrantRow: View {
    let grant: ToolApprovalGrant
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HarnessIconTile(
                systemImage: grant.scope.risk.systemImage,
                tint: grant.scope.risk.tint,
                size: 30
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(grant.scope.toolName)
                    .font(.headline)
                Text(grant.scope.risk.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(grant.scope.resourceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(grant.scope.modelDestination)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(role: .destructive, action: onRevoke) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("撤销 \(grant.scope.toolName) 授权")
        }
        .accessibilityElement(children: .contain)
    }
}

private extension ToolRisk {
    var systemImage: String {
        switch self {
        case .pure:
            "equal.circle"
        case .localState:
            "iphone"
        case .sensitiveRead:
            "eye"
        case .sideEffect:
            "hammer"
        case .destructive:
            "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .pure, .localState:
            .secondary
        case .sensitiveRead:
            .blue
        case .sideEffect:
            .orange
        case .destructive:
            .red
        }
    }
}

private extension ToolApprovalScope {
    var resourceSummary: String {
        if toolName == Self.allLocalToolsMarker,
           resources == [Self.allLocalToolsResource] {
            return "本机工具（全部风险级别）"
        }
        return resources.map { resource in
            switch resource {
            case "tool":
                "整个工具"
            case "workspace:root":
                "App 工作区"
            case "ish-sandbox:/workspace":
                "iSH /workspace 沙箱"
            default:
                resource.replacingOccurrences(of: "workspace:file:", with: "工作区文件：")
            }
        }
        .joined(separator: "，")
    }
}
