import SwiftUI

enum SetupMode: Equatable {
    case onboarding
    case editing
    case profile(String)
    case addingCatalog(ModelProviderID)
    case addingCustom
}

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let mode: SetupMode

    @State private var draft = AgentConfiguration()
    @State private var profileID = ""
    @State private var displayName = ""
    @State private var isCustomProfile = false
    @State private var apiKey = ""
    @State private var catalog = SetupModelCatalog.builtIn(for: AgentConfiguration())
    @State private var isDiscoveringModels = false
    @State private var isSaving = false
    @State private var modelDiscoveryError: String?
    @State private var inlineError: String?
    @State private var didLoad = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case profileID
        case displayName
        case baseURL
        case apiKey
        case model
    }

    private var provider: ModelProviderDescriptor {
        ModelProviderCatalog.descriptor(for: draft.providerID)
    }

    private var visibleCatalog: SetupModelCatalog {
        guard catalog.identity == ModelCatalogIdentity(configuration: draft) else {
            return .builtIn(for: draft)
        }
        return catalog
    }

    private var providerSelection: Binding<ModelProviderID> {
        Binding(
            get: { draft.providerID },
            set: { selectProvider($0) }
        )
    }

    private var existingProfile: ProviderProfile? {
        guard let existingProfileID else { return nil }
        return model.providerDirectory.profile(id: existingProfileID)
    }

    private var existingProfileID: String? {
        switch mode {
        case .onboarding:
            return model.providerDirectory.profile(id: profileID)?.id
        case .editing:
            return model.activeProviderProfile?.id
        case let .profile(id):
            return id
        case .addingCatalog, .addingCustom:
            return nil
        }
    }

    private var canChangeCatalogProvider: Bool {
        mode == .onboarding
    }

    private var isCreatingProfile: Bool {
        switch mode {
        case .addingCatalog, .addingCustom:
            true
        case .onboarding, .editing, .profile:
            false
        }
    }

    private var makeActiveAfterSave: Bool {
        switch mode {
        case .onboarding, .editing, .addingCatalog, .addingCustom:
            return true
        case let .profile(id):
            return model.providerDirectory.activeProfileID == id
        }
    }

    private var navigationTitle: String {
        switch mode {
        case .onboarding:
            "配置 Harness"
        case .editing, .profile:
            "编辑服务商"
        case .addingCatalog:
            "添加服务商"
        case .addingCustom:
            "自定义服务商"
        }
    }

    private var keyPlaceholder: String {
        guard let existingProfile else { return "API Key" }
        return model.credentialStatus(for: existingProfile) == .configured
            ? "API Key（留空则保留）"
            : "API Key"
    }

    private var canRefreshModels: Bool {
        provider.supportsRemoteModelDiscovery
            && !isDiscoveringModels
            && (try? draft.modelsURL()) != nil
    }

    private var selectedModelLabel: String {
        guard !draft.model.isEmpty else { return "未选择" }
        return visibleCatalog.models.first(where: { $0.id == draft.model })?.name
            ?? draft.model
    }

    private var compatibilityForegroundStyle: AnyShapeStyle {
        provider.supportsCurrentInferenceWire
            ? AnyShapeStyle(.secondary)
            : AnyShapeStyle(.orange)
    }

    private var effectiveRetryPolicy: ProviderRetryPolicyConfiguration {
        draft.retryPolicy ?? .upstreamDefault
    }

    private var retryModeBinding: Binding<ProviderRetryPolicyConfiguration.Mode> {
        Binding(
            get: { effectiveRetryPolicy.mode },
            set: { mode in
                var policy = effectiveRetryPolicy
                policy.mode = mode
                draft.retryPolicy = policy
            }
        )
    }

    private var retryCountBinding: Binding<Int> {
        Binding(
            get: { effectiveRetryPolicy.maxRetries ?? 5 },
            set: { value in
                var policy = effectiveRetryPolicy
                policy.maxRetries = value
                draft.retryPolicy = policy
            }
        )
    }

    private var wireProfileBinding: Binding<OpenAICompatibleWireProfile> {
        Binding(
            get: { draft.openAIWireProfile ?? OpenAICompatibleWireProfile.resolve(draft) },
            set: { draft.openAIWireProfile = $0 }
        )
    }

    private var effectiveOpenAICompatibility: OpenAICompletionsCompatibility {
        (draft.openAIWireProfile ?? OpenAICompatibleWireProfile.resolve(draft))
            .compatibilityBaseline
            .overlaying(draft.openAICompatibility)
    }

    private func compatibilityBoolBinding(
        _ keyPath: WritableKeyPath<OpenAICompletionsCompatibility, Bool?>
    ) -> Binding<Bool> {
        Binding(
            get: { effectiveOpenAICompatibility[keyPath: keyPath] ?? false },
            set: { value in
                var compatibility = draft.openAICompatibility ?? .init()
                compatibility[keyPath: keyPath] = value
                draft.openAICompatibility = compatibility
            }
        )
    }

    private var maxTokensFieldBinding: Binding<OpenAICompletionsCompatibility.MaxTokensField> {
        Binding(
            get: { effectiveOpenAICompatibility.maxTokensField ?? .maxTokens },
            set: { value in
                var compatibility = draft.openAICompatibility ?? .init()
                compatibility.maxTokensField = value
                draft.openAICompatibility = compatibility
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                connectionSection
                modelSection
                inferenceSection
                securitySection

                if let inlineError {
                    Section {
                        Text(inlineError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveActionBar
            }
            .toolbar {
                if mode != .onboarding {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            dismiss()
                        }
                    }
                }
            }
            .task {
                guard !didLoad else { return }
                loadDraft()
                didLoad = true

                if existingProfile != nil,
                   existingProfile.map(model.credentialStatus(for:)) == .configured,
                   provider.supportsRemoteModelDiscovery {
                    await discoverModels(forceRefresh: false)
                }
            }
        }
    }

    private var saveActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                save()
            } label: {
                Group {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text(mode == .onboarding ? "保存并开始" : "保存")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                isSaving
                    || isDiscoveringModels
                    || !provider.supportsCurrentInferenceWire
            )
            .accessibilityIdentifier("save-configuration")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var identitySection: some View {
        Section {
            if canChangeCatalogProvider {
                Picker("服务商", selection: providerSelection) {
                    ForEach(ModelProviderCatalog.providers) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isDiscoveringModels)
                .accessibilityIdentifier("provider-picker")
            } else {
                LabeledContent("Provider ID", value: profileID.isEmpty ? "未填写" : profileID)
            }

            if mode == .addingCustom || (mode == .onboarding && isCustomProfile) {
                TextField("例如 acme-gateway", text: $profileID)
                    .accessibilityIdentifier("provider-id-field")
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .profileID)
            }

            if mode != .onboarding || isCustomProfile {
                TextField("显示名称", text: $displayName)
                    .accessibilityIdentifier("provider-display-name-field")
                    .focused($focusedField, equals: .displayName)
            }

            if isCustomProfile {
                LabeledContent("API 协议", value: "OpenAI Chat Completions")
            } else {
                Text(provider.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("服务商")
        } footer: {
            if mode == .onboarding {
                Text("稍后可以在设置中修改名称、地址、密钥和模型。")
            } else {
                Text("Provider ID 会写入会话和凭据引用，保存后不能改名；显示名称、地址、密钥和模型目录仍可编辑。")
            }
        }
    }

    private var connectionSection: some View {
        Section {
            TextField("API Base URL", text: $draft.baseURL)
                .accessibilityIdentifier("base-url-field")
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .baseURL)
                .disabled(isDiscoveringModels)

            SecureField(keyPlaceholder, text: $apiKey)
            .accessibilityIdentifier("api-key-field")
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .apiKey)
            .disabled(isDiscoveringModels)
        } header: {
            Text("连接")
        } footer: {
            Text(
                "API Key 只写入该 Provider ID 的本机 Keychain 项，并绑定当前 HTTPS 域名和端口。模型推理走所选服务商，Agent Loop 和工具仍在这台 iPhone 内执行。"
            )
        }
    }

    private var modelSection: some View {
        Section {
            if visibleCatalog.models.isEmpty {
                Label("当前目录没有内建模型", systemImage: "tray")
                    .foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    ModelSelectionView(
                        models: visibleCatalog.models,
                        selection: $draft.model
                    )
                } label: {
                    LabeledContent("目录选择", value: selectedModelLabel)
                }
                .accessibilityIdentifier("model-catalog-link")
            }

            TextField("手动模型 ID", text: $draft.model)
                .accessibilityIdentifier("model-field")
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .model)

            ModelCatalogStatusView(
                catalog: visibleCatalog,
                isLoading: isDiscoveringModels
            )

            Button("刷新模型", systemImage: "arrow.clockwise") {
                Task {
                    await discoverModels(forceRefresh: true)
                }
            }
            .disabled(!canRefreshModels)
            .accessibilityIdentifier("refresh-models")

            if let compatibilityNotice = provider.compatibilityNotice {
                Label(
                    compatibilityNotice,
                    systemImage: provider.supportsCurrentInferenceWire
                        ? "info.circle"
                        : "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(compatibilityForegroundStyle)
            }

            if let modelDiscoveryError {
                Text(modelDiscoveryError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("模型")
        } footer: {
            Text(
                "目录之外的模型可直接填写。刷新时，当前输入的 Key 只用于本次同源 /models 请求；请求完成后该字段会清空，保存前需要重新输入。"
            )
        }
    }

    private var inferenceSection: some View {
        Section {
            Picker("思考模式", selection: $draft.reasoningMode) {
                ForEach(ReasoningMode.supportedModes(for: draft.providerID)) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            if provider.wireProtocol == .openAIChatCompletions {
                Picker("兼容协议", selection: wireProfileBinding) {
                    ForEach(OpenAICompatibleWireProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                Text("私有网关默认使用保守模式；只有网关明确支持时才开启 OpenAI 或 DeepSeek 扩展字段。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                DisclosureGroup("高级网关兼容") {
                    Toggle(
                        "发送 reasoning_effort",
                        isOn: compatibilityBoolBinding(\.supportsReasoningEffort)
                    )
                    Toggle(
                        "流式返回用量",
                        isOn: compatibilityBoolBinding(\.supportsUsageInStreaming)
                    )
                    Toggle(
                        "使用 developer 角色",
                        isOn: compatibilityBoolBinding(\.supportsDeveloperRole)
                    )
                    Picker("输出 Token 字段", selection: maxTokensFieldBinding) {
                        Text("max_tokens").tag(
                            OpenAICompletionsCompatibility.MaxTokensField.maxTokens
                        )
                        Text("max_completion_tokens").tag(
                            OpenAICompletionsCompatibility.MaxTokensField.maxCompletionTokens
                        )
                    }
                    Toggle(
                        "工具结果附带 name",
                        isOn: compatibilityBoolBinding(\.requiresToolResultName)
                    )
                    Toggle(
                        "工具结果后补 assistant",
                        isOn: compatibilityBoolBinding(\.requiresAssistantAfterToolResult)
                    )
                    Toggle(
                        "思考内容转为文本标签",
                        isOn: compatibilityBoolBinding(\.requiresThinkingAsText)
                    )
                    Toggle(
                        "回放 reasoning_content",
                        isOn: compatibilityBoolBinding(
                            \.requiresReasoningContentOnAssistantMessages
                        )
                    )
                    Button("恢复预设兼容项") {
                        draft.openAICompatibility = nil
                    }
                }
            }

            Picker("失败重试", selection: retryModeBinding) {
                ForEach(ProviderRetryPolicyConfiguration.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if effectiveRetryPolicy.mode == .normal {
                TextField("最大重试次数", value: retryCountBinding, format: .number)
                    .keyboardType(.numberPad)
            } else {
                Text("持续重试会在每次失败后有界退避，直到成功、手动停止或 App 终止；每次重试仍写入轨迹。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            LabeledContent("Agent 循环", value: "无 App 总步数限制")
            Text("单次模型响应建议最多调用 8 个工具，手机同时执行最多 2 个并发安全工具，其余自动排队。Anthropic 扩展思考需保存签名块，当前仅开放服务默认和关闭。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Label("推理", systemImage: "cpu")
        }
    }

    private var securitySection: some View {
        Section {
            Label(
                "Key 仅保存在本机 Keychain，不进入会话、日志或工具环境。",
                systemImage: "lock.shield"
            )
            Label(
                "移动端 BYOK 无法像自有后端那样完全隐藏 Key；建议使用独立、限额、可撤销的密钥。",
                systemImage: "exclamationmark.shield"
            )
        } header: {
            Text("安全边界")
        }
    }

    private func selectProvider(_ providerID: ModelProviderID) {
        guard providerID != draft.providerID else { return }
        let profile: ProviderProfile
        if providerID != .customOpenAICompatible,
           let stored = model.providerDirectory.profile(id: providerID.rawValue) {
            profile = stored
        } else if providerID == .customOpenAICompatible {
            profile = ProviderProfile.customDraft(
                maxSteps: draft.maxSteps,
                maxOutputTokens: draft.maxOutputTokens
            )
        } else {
            profile = ProviderProfile.catalogDefault(
                for: providerID,
                maxSteps: draft.maxSteps,
                maxOutputTokens: draft.maxOutputTokens
            )
        }
        profileID = profile.id
        displayName = profile.displayName
        isCustomProfile = providerID == .customOpenAICompatible
        draft = profile.configuration()
        draft.profileID = nil
        draft.credentialReference = nil
        apiKey = ""
        catalog = .stored(for: profile)
        modelDiscoveryError = nil
        inlineError = nil
    }

    private func discoverModels(forceRefresh: Bool) async {
        guard canRefreshModels else { return }
        let requestConfiguration = draft
        let requestIdentity = ModelCatalogIdentity(configuration: requestConfiguration)
        let temporaryKey = normalizedAPIKey(apiKey)

        isDiscoveringModels = true
        modelDiscoveryError = nil
        defer {
            if let temporaryKey, normalizedAPIKey(apiKey) == temporaryKey {
                apiKey = ""
            }
            isDiscoveringModels = false
        }

        do {
            let snapshot = try await model.discoverModels(
                for: requestConfiguration,
                temporaryAPIKey: temporaryKey,
                forceRefresh: forceRefresh
            )
            guard requestIdentity == ModelCatalogIdentity(configuration: draft) else { return }
            let refreshedCatalog = SetupModelCatalog.merging(
                snapshot,
                existing: visibleCatalog.models,
                for: requestConfiguration
            )
            catalog = refreshedCatalog
            if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let firstModel = refreshedCatalog.models.first {
                draft.model = firstModel.id
            }
            draft.inputModalities = refreshedCatalog.models.first(
                where: { $0.id == draft.model }
            )?.inputModalities
        } catch is CancellationError {
            return
        } catch {
            guard requestIdentity == ModelCatalogIdentity(configuration: draft) else { return }
            modelDiscoveryError = error.localizedDescription
        }
    }

    private func normalizedAPIKey(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        inlineError = nil
        Task {
            do {
                let routeID = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
                let credentialReference = existingProfile?.id == routeID
                    ? existingProfile?.credentialReference
                    : .providerAPIKey(profileID: routeID)
                let profile = ProviderProfile(
                    id: routeID,
                    displayName: displayName,
                    providerID: draft.providerID,
                    wireProtocol: isCustomProfile
                        ? .openAIChatCompletions
                        : provider.wireProtocol,
                    baseURL: draft.baseURL,
                    credentialReference: credentialReference,
                    models: modelsEnsuringSelection(visibleCatalog.models),
                    defaultModel: draft.model,
                    reasoningMode: draft.reasoningMode,
                    openAIWireProfile: draft.openAIWireProfile,
                    openAICompatibility: draft.openAICompatibility,
                    retryPolicy: draft.retryPolicy ?? .upstreamDefault,
                    maxSteps: draft.maxSteps,
                    maxOutputTokens: draft.maxOutputTokens,
                    isCustom: isCustomProfile
                )
                try await model.saveProviderProfile(
                    profile,
                    apiKey: apiKey,
                    makeActive: makeActiveAfterSave,
                    existingProfileID: existingProfile?.id == routeID
                        ? existingProfile?.id
                        : nil
                )
                apiKey = ""
                if mode != .onboarding {
                    dismiss()
                }
            } catch {
                inlineError = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func loadDraft() {
        let profile: ProviderProfile
        switch mode {
        case .onboarding, .editing:
            profile = model.activeProviderProfile ?? .catalogDefault(for: .deepSeekOfficial)
        case let .profile(id):
            profile = model.providerDirectory.profile(id: id)
                ?? .catalogDefault(for: .deepSeekOfficial)
        case let .addingCatalog(providerID):
            profile = .catalogDefault(
                for: providerID,
                maxSteps: model.configuration.maxSteps,
                maxOutputTokens: model.configuration.maxOutputTokens
            )
        case .addingCustom:
            profile = .customDraft(
                maxSteps: model.configuration.maxSteps,
                maxOutputTokens: model.configuration.maxOutputTokens
            )
        }

        profileID = profile.id
        displayName = profile.displayName
        isCustomProfile = profile.isCustom
        draft = profile.configuration()
        if isCreatingProfile {
            draft.profileID = nil
            draft.credentialReference = nil
        }
        catalog = .stored(for: profile)
    }

    private func modelsEnsuringSelection(_ models: [ProviderModel]) -> [ProviderModel] {
        let selected = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty, !models.contains(where: { $0.id == selected }) else {
            return models
        }
        return models + [ProviderModel(id: selected)]
    }
}

private struct ModelCatalogIdentity: Equatable {
    let providerID: ModelProviderID
    let baseURL: String

    init(configuration: AgentConfiguration) {
        providerID = configuration.providerID
        baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SetupModelCatalog {
    let identity: ModelCatalogIdentity
    let source: ModelCatalogSource
    let fetchedAt: Date?
    let models: [ProviderModel]

    static func builtIn(for configuration: AgentConfiguration) -> SetupModelCatalog {
        let snapshot = ModelProviderCatalog.builtInSnapshot(for: configuration.providerID)
        return SetupModelCatalog(
            identity: ModelCatalogIdentity(configuration: configuration),
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            models: snapshot.models
        )
    }

    static func stored(for profile: ProviderProfile) -> SetupModelCatalog {
        SetupModelCatalog(
            identity: ModelCatalogIdentity(configuration: profile.configuration()),
            source: .builtIn,
            fetchedAt: nil,
            models: profile.models
        )
    }

    static func merging(
        _ snapshot: ModelCatalogSnapshot,
        existing: [ProviderModel],
        for configuration: AgentConfiguration
    ) -> SetupModelCatalog {
        guard snapshot.providerID == configuration.providerID else {
            return .builtIn(for: configuration)
        }

        let builtIn = ModelProviderCatalog.builtInSnapshot(for: configuration.providerID).models
        var models = existing.isEmpty ? builtIn : existing
        var positions = Dictionary(
            uniqueKeysWithValues: models.enumerated().map { ($0.element.id, $0.offset) }
        )
        for discoveredModel in snapshot.models {
            if let position = positions[discoveredModel.id] {
                let existing = models[position]
                let builtIn = ModelProviderCatalog.descriptor(for: configuration.providerID)
                    .builtInModels
                    .first(where: { $0.id == discoveredModel.id })
                let refreshedModalities = discoveredModel.inputModalities == [.text]
                    && builtIn?.inputModalities.contains(.image) == true
                    ? builtIn?.inputModalities ?? discoveredModel.inputModalities
                    : discoveredModel.inputModalities
                models[position] = ProviderModel(
                    id: discoveredModel.id,
                    name: discoveredModel.name ?? existing.name,
                    contextWindow: discoveredModel.contextWindow ?? existing.contextWindow,
                    maxOutputTokens: discoveredModel.maxOutputTokens ?? existing.maxOutputTokens,
                    // A refreshed provider catalog is authoritative for model
                    // capabilities. Keeping the cached value can leave a
                    // vision model marked as text-only after discovery.
                    inputModalities: refreshedModalities,
                    openAICompatibility: existing.openAICompatibility
                )
            } else {
                positions[discoveredModel.id] = models.count
                models.append(discoveredModel)
            }
        }

        return SetupModelCatalog(
            identity: ModelCatalogIdentity(configuration: configuration),
            source: snapshot.source,
            fetchedAt: snapshot.fetchedAt,
            models: models
        )
    }
}

private struct ModelCatalogStatusView: View {
    let catalog: SetupModelCatalog
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在获取模型…")
            } else {
                Label("\(sourceTitle) · \(catalog.models.count) 项", systemImage: sourceIcon)
            }
            Spacer()
            if let fetchedAt = catalog.fetchedAt, !isLoading {
                Text(fetchedAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var sourceTitle: String {
        switch catalog.source {
        case .builtIn:
            return "内建目录"
        case .remote:
            return "服务商返回"
        case .cache:
            return "本机缓存"
        }
    }

    private var sourceIcon: String {
        switch catalog.source {
        case .builtIn:
            return "shippingbox"
        case .remote:
            return "network"
        case .cache:
            return "internaldrive"
        }
    }
}

private struct ModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss

    let models: [ProviderModel]
    @Binding var selection: String

    @State private var searchText = ""

    private var filteredModels: [ProviderModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        return models.filter { model in
            model.id.localizedCaseInsensitiveContains(query)
                || model.name?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        List(filteredModels) { model in
            Button {
                selection = model.id
                dismiss()
            } label: {
                ModelSelectionRow(model: model, isSelected: model.id == selection)
            }
            .buttonStyle(.plain)
        }
        .harnessCompactListChrome()
        .overlay {
            if filteredModels.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索模型 ID 或名称")
    }
}

private struct ModelSelectionRow: View {
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
                if let capacity = capacityDescription {
                    Text(capacity)
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
