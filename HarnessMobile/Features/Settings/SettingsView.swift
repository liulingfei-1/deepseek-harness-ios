import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var isResetConfirmationPresented = false
    @State private var isRemoveConfirmationPresented = false

    var body: some View {
        Form {
            Section("模型") {
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
                    Label("模型与服务商", systemImage: "server.rack")
                }
            }

            Section("执行边界") {
                LabeledContent("模型推理", value: "你配置的 API")
                LabeledContent("Agent Loop", value: "本机")
                LabeledContent("工具与文件", value: "本机")
                LabeledContent("命令执行", value: "手机 iSH / Alpine")
                LabeledContent("Linux 网络", value: "默认开启")
                Text("模型 provider 只负责推理。shell_execute、文件和 Agent Loop 都在 iPhone 内执行；Linux 网络默认可用，也可在“命令”页主动关闭。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("系统能力") {
                NavigationLink {
                    PhonePermissionsView()
                } label: {
                    Label("手机权限", systemImage: "hand.raised")
                }
                NavigationLink {
                    BackgroundSettingsView(runtimeStatus: model.backgroundRuntimeStatus)
                } label: {
                    Label("后台任务", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }
                NavigationLink {
                    PluginManagementView()
                } label: {
                    Label("Cordis 插件", systemImage: "puzzlepiece.extension")
                }
                NavigationLink {
                    ToolApprovalSettingsView()
                } label: {
                    HStack {
                        Label("工具授权", systemImage: "checkmark.shield")
                        Spacer()
                        Text("\(model.trustedToolApprovals.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                LabeledContent("本机工具", value: "\(ProductionToolCatalog.approvedNames.count) 项")
                LabeledContent("快捷指令", value: "已启用")
            }

            if let usage = model.latestUsage {
                Section("最近一次用量") {
                    LabeledContent("输入", value: "\(usage.promptTokens)")
                    LabeledContent("输出", value: "\(usage.completionTokens)")
                    if let reasoning = usage.reasoningTokens {
                        LabeledContent("思考", value: "\(reasoning)")
                    }
                }
            }

            Section("诊断") {
                NavigationLink {
                    DiagnosticLogView()
                } label: {
                    Label("详细日志", systemImage: "doc.text.magnifyingglass")
                }
            }

            Section("本地数据") {
                Button("清空当前会话", role: .destructive) {
                    isResetConfirmationPresented = true
                }
                Button("重置全部模型连接", role: .destructive) {
                    isRemoveConfirmationPresented = true
                }
            }
        }
        .harnessCompactListChrome()
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
}

private struct DiagnosticLogView: View {
    @Environment(AppModel.self) private var model

    @State private var isRefreshing = false
    @State private var isPreparingExport = false
    @State private var isFileExporterPresented = false
    @State private var exportDocument: ConversationExportFileDocument?
    @State private var exportFilename = "Harness-Diagnostics"

    var body: some View {
        Form {
            Section("当前运行") {
                LabeledContent("Agent", value: model.isRunning ? "运行中" : "空闲")
                LabeledContent("当前步骤", value: "\(model.currentStep)")
                LabeledContent("会话轨迹", value: "\(model.trajectoryEvents.count) 条")
                LabeledContent("Harness Trace", value: "\(model.harnessTraceEvents.count) 条")
            }

            Section("Cordis Host") {
                Text(model.diagnosticHostStateDescription)
                    .font(.footnote)
                    .textSelection(.enabled)

                if let diagnostics = model.ishPluginHostDiagnostics {
                    LabeledContent("等待中的 RPC", value: "\(diagnostics.pendingRequestCount)")
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
            } footer: {
                Text("导出包含设备与运行状态、Cordis 插件、Plugin Host stderr、Harness Trace 和当前会话完整轨迹。API Key、Authorization 及常见密码/Secret 字段会在手机上脱敏后再写入文件。")
            }
        }
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
                let data = try await model.diagnosticReportData()
                exportDocument = ConversationExportFileDocument(data: data)
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
                    ContentUnavailableView(
                        "尚未记录设备授权",
                        systemImage: "checkmark.shield",
                        description: Text("本机工具首次运行会自动记录当前模型 API 的设备级授权；系统隐私权限和 Cordis 检查仍独立生效。")
                    )
                }
            } else {
                Section {
                    ForEach(model.trustedToolApprovals) { grant in
                        ToolApprovalGrantRow(grant: grant) {
                            model.revokeToolApproval(id: grant.id)
                        }
                    }
                } header: {
                    Text("已记住")
                } footer: {
                    Text("“本机工具”授权会覆盖当前模型 API 下的所有本机工具和风险级别。系统隐私权限、目标 App 是否存在以及 Cordis 检查仍由系统或插件决定。")
                }

                Section {
                    Button("撤销全部授权", role: .destructive) {
                        isRevokeAllConfirmationPresented = true
                    }
                }
            }
        }
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
            Text("之后的匹配工具调用会按当前无拦截策略自动记录新的设备授权。")
        }
    }
}

private struct ToolApprovalGrantRow: View {
    let grant: ToolApprovalGrant
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: grant.scope.risk.systemImage)
                .foregroundStyle(grant.scope.risk.tint)
                .accessibilityHidden(true)

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
