import SwiftUI

/// Selects a saved Provider Profile and model for the current conversation.
/// Credentials remain write-only and are resolved by AppModel from Keychain.
struct SessionModelPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft = AgentConfiguration()
    @State private var selectedProfileID = ""
    @State private var catalog = SessionModelCatalog.builtIn(for: AgentConfiguration())
    @State private var searchText = ""
    @State private var isFollowingGlobal = true
    @State private var isDiscoveringModels = false
    @State private var isSaving = false
    @State private var modelDiscoveryError: String?
    @State private var saveError: String?
    @State private var didLoad = false

    private var selectedProfile: ProviderProfile? {
        model.providerDirectory.profile(id: selectedProfileID)
    }

    private var provider: ModelProviderDescriptor {
        selectedProfile?.descriptor
            ?? ModelProviderCatalog.descriptor(for: draft.providerID)
    }

    private var visibleCatalog: SessionModelCatalog {
        guard catalog.identity == SessionModelCatalogIdentity(configuration: draft) else {
            if let selectedProfile {
                return .stored(for: selectedProfile, configuration: draft)
            }
            return .builtIn(for: draft)
        }
        return catalog
    }

    private var filteredModels: [ProviderModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleCatalog.models }
        return visibleCatalog.models.filter { candidate in
            candidate.id.localizedCaseInsensitiveContains(query)
                || candidate.name?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var canRefreshModels: Bool {
        guard let selectedProfile else { return false }
        return selectedProfile.descriptor.supportsRemoteModelDiscovery
            && model.credentialStatus(for: selectedProfile) == .configured
            && !isDiscoveringModels
            && (try? draft.modelsURL()) != nil
    }

    private var selectedModelIsInCatalog: Bool {
        visibleCatalog.models.contains { $0.id == draft.model }
    }

    private var selectedProfileIsUsable: Bool {
        guard let selectedProfile else { return false }
        return selectedProfile.descriptor.supportsCurrentInferenceWire
            && model.credentialStatus(for: selectedProfile) == .configured
    }

    private var saveIsDisabled: Bool {
        isSaving
            || isDiscoveringModels
            || model.isRunning
            || (!isFollowingGlobal && (
                !selectedProfileIsUsable
                    || draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ))
    }

    var body: some View {
        NavigationStack {
            List {
                scopeSection
                if !isFollowingGlobal {
                    providerSection
                    modelSection
                    inferenceSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle("本会话模型")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索模型 ID 或名称")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("完成")
                        }
                    }
                    .disabled(saveIsDisabled)
                    .accessibilityIdentifier("session-model-save")
                }
            }
            .task {
                await loadIfNeeded()
            }
            .onChange(of: model.providerDirectory) { _, _ in
                reconcileSelectedProfile()
            }
            .alert("无法保存本会话模型", isPresented: saveErrorPresented) {
                Button("好") {
                    saveError = nil
                }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Toggle("跟随默认模型设置", isOn: followingGlobalBinding)
                .accessibilityIdentifier("session-model-follow-global")

            if isFollowingGlobal {
                LabeledContent("当前模型", value: model.configuration.model)
                LabeledContent(
                    "Provider Profile",
                    value: model.activeProviderProfile?.displayName ?? "未配置"
                )
            } else {
                Label("该选择只覆盖当前会话，不改变默认 Profile。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("应用范围")
        } footer: {
            Text("切换会在下一次模型请求时生效；正在进行的请求不会中途更换服务商。")
        }
    }

    private var providerSection: some View {
        Section {
            if model.providerProfiles.isEmpty {
                ContentUnavailableView(
                    "没有 Provider Profile",
                    systemImage: "server.rack",
                    description: Text("请先在模型与服务商中添加连接。")
                )
                .listRowBackground(Color.clear)
            } else {
                Picker("Provider Profile", selection: profileSelection) {
                    ForEach(model.providerProfiles) { profile in
                        Text(profile.displayName)
                            .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isDiscoveringModels || isSaving || model.isRunning)
                .accessibilityIdentifier("session-model-provider-picker")
            }

            if let selectedProfile {
                LabeledContent("Provider ID", value: selectedProfile.id)
                LabeledContent("API", value: endpointHost(selectedProfile.baseURL))
                SessionProviderStatusView(
                    credentialStatus: model.credentialStatus(for: selectedProfile),
                    supportsInference: selectedProfile.descriptor.supportsCurrentInferenceWire
                )

                Text(selectedProfile.descriptor.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let compatibilityNotice = selectedProfile.descriptor.compatibilityNotice {
                    Label(
                        compatibilityNotice,
                        systemImage: selectedProfile.descriptor.supportsCurrentInferenceWire
                            ? "info.circle"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(
                        selectedProfile.descriptor.supportsCurrentInferenceWire
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.orange)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            NavigationLink {
                ProviderProfilesView()
            } label: {
                Label("管理模型与服务商", systemImage: "slider.horizontal.3")
            }
        } header: {
            Text("服务商")
        } footer: {
            Text("这里只能选择已保存的 Profile；API Key 不会显示，也不能在会话页修改。")
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        Section {
            TextField("手动模型 ID", text: modelIDBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(isSaving || model.isRunning || selectedProfile == nil)
                .accessibilityIdentifier("session-model-field")

            if isDiscoveringModels {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在获取模型目录…")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if filteredModels.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "没有可用模型"
                            : "没有匹配的模型",
                        systemImage: "tray"
                    )
                } description: {
                    Text(
                        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "可在上方手动输入模型 ID。"
                            : "可修改搜索词，或直接输入模型 ID。"
                    )
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredModels) { candidate in
                    Button {
                        draft.model = candidate.id
                        draft.inputModalities = candidate.inputModalities
                    } label: {
                        SessionModelRow(
                            model: candidate,
                            isSelected: candidate.id == draft.model
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving || model.isRunning)
                    .accessibilityIdentifier("session-model-option-\(candidate.id)")
                }
            }

            if !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !selectedModelIsInCatalog {
                Label("使用手动模型 ID：\(draft.model)", systemImage: "keyboard")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Label(catalogSourceTitle, systemImage: catalogSourceIcon)
                Spacer()
                if let fetchedAt = visibleCatalog.fetchedAt {
                    Text(fetchedAt, format: .dateTime.month().day().hour().minute())
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            if let modelDiscoveryError {
                Label(modelDiscoveryError, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("刷新模型目录", systemImage: "arrow.clockwise") {
                Task {
                    await discoverModels(forceRefresh: true)
                }
            }
            .disabled(!canRefreshModels || isSaving || model.isRunning)
            .accessibilityIdentifier("session-model-refresh")
        } header: {
            Text("模型")
        } footer: {
            Text("刷新只使用该 Profile 已保存在 Keychain 中的同源 API Key。目录之外的模型可直接填写 ID。")
        }
    }

    private var modelIDBinding: Binding<String> {
        Binding(
            get: { draft.model },
            set: { value in
                draft.model = value
                draft.inputModalities = visibleCatalog.models.first(
                    where: { $0.id == value }
                )?.inputModalities
            }
        )
    }

    private var inferenceSection: some View {
        Section {
            Picker("思考模式", selection: $draft.reasoningMode) {
                ForEach(ReasoningMode.supportedModes(for: draft.providerID)) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } header: {
            Text("推理")
        } footer: {
            Text("可选模式会按当前服务商协议过滤；Anthropic 扩展思考暂不用于需要工具续轮的会话。")
        }
    }

    private var followingGlobalBinding: Binding<Bool> {
        Binding(
            get: { isFollowingGlobal },
            set: { followsGlobal in
                isFollowingGlobal = followsGlobal
                saveError = nil
                modelDiscoveryError = nil
                if followsGlobal {
                    let configuration = model.configuration
                    draft = configuration
                    selectedProfileID = model.activeProviderProfile?.id ?? ""
                    if let profile = model.activeProviderProfile {
                        catalog = .stored(for: profile, configuration: configuration)
                    } else {
                        catalog = .builtIn(for: configuration)
                    }
                } else if let profile = model.activeProviderProfile {
                    selectProfile(profile.id)
                }
            }
        )
    }

    private var profileSelection: Binding<String> {
        Binding(
            get: { selectedProfileID },
            set: { selectProfile($0) }
        )
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { presented in
                if !presented {
                    saveError = nil
                }
            }
        )
    }

    private var catalogSourceTitle: String {
        switch visibleCatalog.source {
        case .builtIn:
            return "Profile 目录 · \(visibleCatalog.models.count) 项"
        case .remote:
            return "服务商目录 · \(visibleCatalog.models.count) 项"
        case .cache:
            return "本机缓存 · \(visibleCatalog.models.count) 项"
        }
    }

    private var catalogSourceIcon: String {
        switch visibleCatalog.source {
        case .builtIn:
            return "shippingbox"
        case .remote:
            return "network"
        case .cache:
            return "internaldrive"
        }
    }

    private func loadIfNeeded() async {
        guard !didLoad else { return }
        let configuration = model.effectiveConfiguration
        let profile = model.providerDirectory.profile(matching: configuration)
            ?? model.activeProviderProfile
        draft = configuration
        selectedProfileID = profile?.id ?? ""
        isFollowingGlobal = model.controlState.modelConfiguration == nil
        if let profile {
            catalog = .stored(for: profile, configuration: configuration)
        } else {
            catalog = .builtIn(for: configuration)
        }
        didLoad = true

        guard !isFollowingGlobal, canRefreshModels else { return }
        await discoverModels(forceRefresh: false)
    }

    private func selectProfile(_ profileID: String) {
        guard let profile = model.providerDirectory.profile(id: profileID) else { return }
        selectedProfileID = profile.id
        draft = profile.configuration()
        catalog = .stored(for: profile)
        modelDiscoveryError = nil
        saveError = nil
    }

    private func reconcileSelectedProfile() {
        guard didLoad else { return }
        guard let profile = model.providerDirectory.profile(id: selectedProfileID) else {
            if let activeProfile = model.activeProviderProfile {
                selectProfile(activeProfile.id)
            } else {
                selectedProfileID = ""
            }
            return
        }

        let selectedModel = draft.model
        let reasoningMode = draft.reasoningMode
        draft = profile.configuration(model: selectedModel, reasoningMode: reasoningMode)
        catalog = .stored(for: profile, configuration: draft)
        modelDiscoveryError = nil
    }

    private func discoverModels(forceRefresh: Bool) async {
        guard !isFollowingGlobal, canRefreshModels else { return }
        let requestConfiguration = draft
        let requestIdentity = SessionModelCatalogIdentity(configuration: requestConfiguration)
        isDiscoveringModels = true
        modelDiscoveryError = nil
        defer {
            isDiscoveringModels = false
        }

        do {
            let snapshot = try await model.discoverModels(
                for: requestConfiguration,
                forceRefresh: forceRefresh
            )
            guard requestIdentity == SessionModelCatalogIdentity(configuration: draft) else {
                return
            }
            let refreshedCatalog = SessionModelCatalog.merging(
                snapshot,
                existing: visibleCatalog.models,
                for: requestConfiguration
            )
            catalog = refreshedCatalog
            // Keep the request configuration in sync with the refreshed
            // capability metadata. Without this, an already-selected vision
            // model can remain explicitly cached as `.text` and fail the
            // runtime image-input guard even though the catalog is correct.
            draft.inputModalities = refreshedCatalog.models.first(
                where: { $0.id == draft.model }
            )?.inputModalities
        } catch is CancellationError {
            return
        } catch {
            guard requestIdentity == SessionModelCatalogIdentity(configuration: draft) else {
                return
            }
            modelDiscoveryError = error.localizedDescription
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                if isFollowingGlobal {
                    try await model.setSessionModelConfiguration(nil)
                } else {
                    try await model.setSessionModelConfiguration(draft)
                }
                dismiss()
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func endpointHost(_ baseURL: String) -> String {
        URLComponents(string: baseURL)?.host ?? "无效地址"
    }
}

struct SessionModelCatalogIdentity: Equatable {
    let profileID: String
    let providerID: ModelProviderID
    let baseURL: String

    init(configuration: AgentConfiguration) {
        profileID = configuration.profileID ?? configuration.providerID.rawValue
        providerID = configuration.providerID
        baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionModelCatalog {
    let identity: SessionModelCatalogIdentity
    let source: ModelCatalogSource
    let fetchedAt: Date?
    let models: [ProviderModel]

    static func builtIn(for configuration: AgentConfiguration) -> SessionModelCatalog {
        let snapshot = ModelProviderCatalog.builtInSnapshot(for: configuration.providerID)
        return SessionModelCatalog(
            identity: SessionModelCatalogIdentity(configuration: configuration),
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            models: snapshot.models
        )
    }

    static func stored(
        for profile: ProviderProfile,
        configuration: AgentConfiguration? = nil
    ) -> SessionModelCatalog {
        SessionModelCatalog(
            identity: SessionModelCatalogIdentity(
                configuration: configuration ?? profile.configuration()
            ),
            source: .builtIn,
            fetchedAt: nil,
            models: profile.models
        )
    }

    static func merging(
        _ snapshot: ModelCatalogSnapshot,
        existing: [ProviderModel],
        for configuration: AgentConfiguration
    ) -> SessionModelCatalog {
        guard snapshot.providerID == configuration.providerID else {
            return .builtIn(for: configuration)
        }

        var models = existing
        var positions = Dictionary(
            uniqueKeysWithValues: models.enumerated().map { ($0.element.id, $0.offset) }
        )
        for discoveredModel in snapshot.models {
            if let position = positions[discoveredModel.id] {
                let current = models[position]
                let builtIn = ModelProviderCatalog.descriptor(for: configuration.providerID)
                    .builtInModels
                    .first(where: { $0.id == discoveredModel.id })
                let refreshedModalities = discoveredModel.inputModalities == [.text]
                    && builtIn?.inputModalities.contains(.image) == true
                    ? builtIn?.inputModalities ?? discoveredModel.inputModalities
                    : discoveredModel.inputModalities
                models[position] = ProviderModel(
                    id: discoveredModel.id,
                    name: discoveredModel.name ?? current.name,
                    contextWindow: discoveredModel.contextWindow ?? current.contextWindow,
                    maxOutputTokens: discoveredModel.maxOutputTokens ?? current.maxOutputTokens,
                    // The refreshed catalog is authoritative for capabilities.
                    // Keeping `current.inputModalities` here preserves stale
                    // `.text` metadata from an older profile and makes
                    // `deepseek-v4-flash-vision-exp` fail the vision guard.
                    inputModalities: refreshedModalities,
                    openAICompatibility: current.openAICompatibility
                )
            } else {
                positions[discoveredModel.id] = models.count
                models.append(discoveredModel)
            }
        }

        return SessionModelCatalog(
            identity: SessionModelCatalogIdentity(configuration: configuration),
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            models: models
        )
    }
}

private struct SessionProviderStatusView: View {
    let credentialStatus: ProviderCredentialStatus
    let supportsInference: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(foregroundStyle)
    }

    private var title: String {
        guard supportsInference else { return "当前协议尚未接入原生推理客户端" }
        switch credentialStatus {
        case .unknown:
            return "正在检查 API Key"
        case .configured:
            return "API Key 已配置"
        case .missing:
            return "缺少 API Key，请先编辑该 Profile"
        case .originMismatch:
            return "API 地址已变化，需要重新输入 API Key"
        }
    }

    private var systemImage: String {
        guard supportsInference else { return "exclamationmark.triangle.fill" }
        switch credentialStatus {
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
        switch credentialStatus {
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

private struct SessionModelRow: View {
    let model: ProviderModel
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name ?? model.id)
                    .foregroundStyle(.primary)
                if model.name != nil {
                    Text(model.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let capacityDescription {
                    Text(capacityDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .fontWeight(.semibold)
                .foregroundStyle(.tint)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var capacityDescription: String? {
        var parts: [String] = []
        if let contextWindow = model.contextWindow {
            parts.append("上下文 \(contextWindow.formatted())")
        }
        if let maxOutputTokens = model.maxOutputTokens {
            parts.append("最大输出 \(maxOutputTokens.formatted())")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
