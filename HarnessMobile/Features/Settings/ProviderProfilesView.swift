import SwiftUI

struct ProviderProfilesView: View {
    @Environment(AppModel.self) private var model

    @State private var presentedEditor: ProviderEditorRoute?
    @State private var pendingDeletion: ProviderProfile?
    @State private var workingProfileID: String?
    @State private var operationError: String?

    var body: some View {
        List {
            Section {
                if model.providerProfiles.isEmpty {
                    ContentUnavailableView(
                        "没有服务商",
                        systemImage: "server.rack",
                        description: Text("添加目录服务商或自定义 OpenAI-compatible 服务商。")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(model.providerProfiles) { profile in
                        ProviderProfileListRow(
                            profile: profile,
                            credentialStatus: model.credentialStatus(for: profile),
                            isActive: model.providerDirectory.activeProfileID == profile.id,
                            isWorking: workingProfileID == profile.id,
                            onEdit: { presentedEditor = .edit(profile.id) },
                            onActivate: { activate(profile) }
                        )
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if model.providerDirectory.activeProfileID != profile.id {
                                Button {
                                    activate(profile)
                                } label: {
                                    Label("设为默认", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                                .disabled(!canActivate(profile))
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeletion = profile
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                presentedEditor = .edit(profile.id)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            if model.providerDirectory.activeProfileID != profile.id {
                                Button("设为默认", systemImage: "checkmark.circle") {
                                    activate(profile)
                                }
                                .disabled(!canActivate(profile))
                            }
                            Button("编辑", systemImage: "pencil") {
                                presentedEditor = .edit(profile.id)
                            }
                            Button("删除", systemImage: "trash", role: .destructive) {
                                pendingDeletion = profile
                            }
                        }
                    }
                }
            } header: {
                Text("Provider Profiles")
            } footer: {
                Text("默认 Profile 用于新请求；当前正在运行的请求不会在中途切换。API Key 只保存在各自的本机 Keychain 项中。")
            }

            Section {
                Picker("摘要模型", selection: compactionSummaryRouteBinding) {
                    Text("跟随当前会话")
                        .tag(nil as CompactionSummaryRoute?)
                    ForEach(compactionSummaryRouteOptions) { option in
                        Text("\(option.profileName) / \(option.route.model)")
                            .tag(Optional(option.route))
                    }
                }
                .disabled(model.isRunning)
            } header: {
                Text("上下文压缩")
            } footer: {
                Text("可让压缩摘要使用独立 Profile 和模型。独立路由在尚未输出摘要时失败，会记录诊断并回退到当前会话模型；半截输出、取消、截断或工具调用不会静默重试。")
            }

            Section {
                Toggle("向 Agent 提供当前时间", isOn: timeContextEnabledBinding)
                    .disabled(model.isRunning)
                if model.timeContextSettings.isEnabled {
                    Picker("显示时区", selection: timeContextTimeZoneBinding) {
                        Text("跟随 iPhone（\(TimeZone.current.identifier)）")
                            .tag(nil as String?)
                        Text("UTC")
                            .tag(Optional("UTC"))
                    }
                    Picker("刷新间隔", selection: timeContextRefreshBinding) {
                        Text("每个模型步骤").tag(0)
                        Text("1 分钟").tag(60_000)
                        Text("5 分钟").tag(300_000)
                        Text("15 分钟").tag(900_000)
                    }
                }
            } header: {
                Text("时间上下文")
            } footer: {
                Text("默认关闭。开启后时间会作为带来源的持久快照追加到消息尾部，而不是修改系统提示；刷新间隔内不会重复注入，因此稳定前缀和模型缓存不会被每秒时间变化破坏。")
            }

            Section {
                Picker("自动标题", selection: sessionTitleModeBinding) {
                    ForEach(SessionTitleAutomaticMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(model.isRunning)
                if model.sessionTitleSettings.automaticMode != .disabled {
                    Picker("标题模型", selection: sessionTitleRouteBinding) {
                        Text("跟随会话模型")
                            .tag(nil as CompactionSummaryRoute?)
                        ForEach(compactionSummaryRouteOptions) { option in
                            Text("\(option.profileName) / \(option.route.model)")
                                .tag(Optional(option.route))
                        }
                    }
                    .disabled(model.isRunning)
                }
            } header: {
                Text("会话标题")
            } footer: {
                Text("模型标题使用独立的受限请求，不带工具，API Key 仍只由本机 Keychain 解析。生成失败会保留首条提问的本机标题；手动重命名会固定标题，除非从会话菜单选择重新生成。")
            }

            Section("添加") {
                ForEach(catalogProviders) { descriptor in
                    Button {
                        presentedEditor = .addCatalog(descriptor.id)
                    } label: {
                        LabeledContent {
                            if hasCatalogProfile(descriptor.id) {
                                Text("已添加")
                                    .foregroundStyle(.secondary)
                            } else if !descriptor.supportsCurrentInferenceWire {
                                Text("协议待接入")
                                    .foregroundStyle(.orange)
                            }
                        } label: {
                            Label(descriptor.displayName, systemImage: descriptor.systemImage)
                        }
                    }
                    .disabled(
                        hasCatalogProfile(descriptor.id)
                            || !descriptor.supportsCurrentInferenceWire
                    )
                }

                Button {
                    presentedEditor = .addCustom
                } label: {
                    Label("自定义 OpenAI-compatible", systemImage: "plus.rectangle.on.rectangle")
                }
            }
        }
        .navigationTitle("模型与服务商")
        .task {
            await model.refreshProviderCredentialStatuses()
        }
        .sheet(item: $presentedEditor) { route in
            SetupView(mode: route.setupMode)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPresented,
            titleVisibility: .visible
        ) {
            Button("删除 Profile 与 API Key", role: .destructive) {
                deletePendingProfile()
            }
            Button("取消", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("本地会话和工作区文件会保留。引用该 Profile 的旧会话需要重新选择模型后才能继续请求。")
        }
        .alert("服务商操作失败", isPresented: operationErrorPresented) {
            Button("好") {
                operationError = nil
            }
        } message: {
            Text(operationError ?? "")
        }
    }

    private var catalogProviders: [ModelProviderDescriptor] {
        ModelProviderCatalog.providers.filter { $0.id != .customOpenAICompatible }
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "删除 Provider Profile？" }
        return "删除“\(pendingDeletion.displayName)”？"
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var operationErrorPresented: Binding<Bool> {
        Binding(
            get: { operationError != nil },
            set: { presented in
                if !presented {
                    operationError = nil
                }
            }
        )
    }

    private var compactionSummaryRouteOptions: [CompactionSummaryRouteOption] {
        model.providerProfiles.flatMap { profile in
            profile.models.map { providerModel in
                CompactionSummaryRouteOption(
                    profileName: profile.displayName,
                    route: CompactionSummaryRoute(
                        profileID: profile.id,
                        model: providerModel.id
                    )
                )
            }
        }
    }

    private var compactionSummaryRouteBinding: Binding<CompactionSummaryRoute?> {
        Binding(
            get: { model.compactionSummaryRoute },
            set: { route in
                do {
                    try model.setCompactionSummaryRoute(route)
                    operationError = nil
                } catch {
                    operationError = error.localizedDescription
                }
            }
        )
    }

    private var timeContextEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.timeContextSettings.isEnabled },
            set: { enabled in
                updateTimeContextSettings { $0.isEnabled = enabled }
            }
        )
    }

    private var timeContextTimeZoneBinding: Binding<String?> {
        Binding(
            get: { model.timeContextSettings.timeZoneIdentifier },
            set: { identifier in
                updateTimeContextSettings { $0.timeZoneIdentifier = identifier }
            }
        )
    }

    private var timeContextRefreshBinding: Binding<Int> {
        Binding(
            get: { model.timeContextSettings.refreshIntervalMilliseconds },
            set: { interval in
                updateTimeContextSettings { $0.refreshIntervalMilliseconds = interval }
            }
        )
    }

    private func updateTimeContextSettings(
        _ update: (inout TimeContextSettings) -> Void
    ) {
        var settings = model.timeContextSettings
        update(&settings)
        do {
            try model.setTimeContextSettings(settings)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private var sessionTitleModeBinding: Binding<SessionTitleAutomaticMode> {
        Binding(
            get: { model.sessionTitleSettings.automaticMode },
            set: { mode in
                updateSessionTitleSettings { $0.automaticMode = mode }
            }
        )
    }

    private var sessionTitleRouteBinding: Binding<CompactionSummaryRoute?> {
        Binding(
            get: { model.sessionTitleSettings.route },
            set: { route in
                updateSessionTitleSettings { $0.route = route }
            }
        )
    }

    private func updateSessionTitleSettings(
        _ update: (inout SessionTitleSettings) -> Void
    ) {
        var settings = model.sessionTitleSettings
        update(&settings)
        do {
            try model.setSessionTitleSettings(settings)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func hasCatalogProfile(_ providerID: ModelProviderID) -> Bool {
        model.providerProfiles.contains { profile in
            !profile.isCustom && profile.providerID == providerID
        }
    }

    private func canActivate(_ profile: ProviderProfile) -> Bool {
        profile.descriptor.supportsCurrentInferenceWire
            && model.credentialStatus(for: profile) == .configured
            && workingProfileID == nil
            && !model.isRunning
    }

    private func activate(_ profile: ProviderProfile) {
        guard canActivate(profile) else { return }
        workingProfileID = profile.id
        operationError = nil
        Task {
            do {
                try await model.activateProviderProfile(id: profile.id)
            } catch {
                operationError = error.localizedDescription
            }
            workingProfileID = nil
        }
    }

    private func deletePendingProfile() {
        guard let profile = pendingDeletion else { return }
        pendingDeletion = nil
        workingProfileID = profile.id
        operationError = nil
        Task {
            do {
                try await model.removeProviderProfile(id: profile.id)
            } catch {
                operationError = error.localizedDescription
            }
            workingProfileID = nil
        }
    }
}

private struct CompactionSummaryRouteOption: Identifiable {
    let profileName: String
    let route: CompactionSummaryRoute

    var id: String { route.profileID + "\u{0}" + route.model }
}

private enum ProviderEditorRoute: Identifiable {
    case edit(String)
    case addCatalog(ModelProviderID)
    case addCustom

    var id: String {
        switch self {
        case let .edit(profileID):
            return "edit-\(profileID)"
        case let .addCatalog(providerID):
            return "add-\(providerID.rawValue)"
        case .addCustom:
            return "add-custom"
        }
    }

    var setupMode: SetupMode {
        switch self {
        case let .edit(profileID):
            return .profile(profileID)
        case let .addCatalog(providerID):
            return .addingCatalog(providerID)
        case .addCustom:
            return .addingCustom
        }
    }
}

private struct ProviderProfileListRow: View {
    let profile: ProviderProfile
    let credentialStatus: ProviderCredentialStatus
    let isActive: Bool
    let isWorking: Bool
    let onEdit: () -> Void
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    Image(systemName: profile.descriptor.systemImage)
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(profile.displayName)
                                .font(.body.weight(.medium))
                            if profile.isCustom {
                                Text("自定义")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(profile.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(profile.defaultModel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            VStack(alignment: .trailing, spacing: 5) {
                ProviderCredentialStatusLabel(
                    status: credentialStatus,
                    supportsInference: profile.descriptor.supportsCurrentInferenceWire
                )

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel("默认服务商")
                } else {
                    Button(action: onActivate) {
                        Image(systemName: "circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(
                        credentialStatus != .configured
                            || !profile.descriptor.supportsCurrentInferenceWire
                    )
                    .accessibilityLabel("设为默认服务商")
                    .help("设为默认服务商")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderCredentialStatusLabel: View {
    let status: ProviderCredentialStatus
    let supportsInference: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(foregroundStyle)
            .labelStyle(.titleAndIcon)
    }

    private var title: String {
        guard supportsInference else { return "协议待接入" }
        switch status {
        case .unknown:
            return "检查中"
        case .configured:
            return "已配置"
        case .missing:
            return "缺少 Key"
        case .originMismatch:
            return "需更新 Key"
        }
    }

    private var systemImage: String {
        guard supportsInference else { return "exclamationmark.triangle.fill" }
        switch status {
        case .unknown:
            return "ellipsis.circle"
        case .configured:
            return "checkmark.circle.fill"
        case .missing:
            return "key.slash"
        case .originMismatch:
            return "arrow.trianglehead.2.clockwise.rotate.90.circle"
        }
    }

    private var foregroundStyle: AnyShapeStyle {
        guard supportsInference else { return AnyShapeStyle(.orange) }
        switch status {
        case .unknown:
            return AnyShapeStyle(.secondary)
        case .configured:
            return AnyShapeStyle(.green)
        case .missing:
            return AnyShapeStyle(.red)
        case .originMismatch:
            return AnyShapeStyle(.orange)
        }
    }
}

private extension ModelProviderDescriptor {
    var systemImage: String {
        switch id {
        case .deepSeekOfficial:
            return "brain.head.profile"
        case .openAI:
            return "sparkles"
        case .anthropic:
            return "text.bubble"
        case .openRouter:
            return "arrow.triangle.branch"
        case .customOpenAICompatible:
            return "server.rack"
        }
    }
}
