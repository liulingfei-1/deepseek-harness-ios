import Foundation

struct CredentialReference: RawRepresentable, Codable, Sendable, Equatable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func providerAPIKey(profileID: String) -> CredentialReference {
        CredentialReference(rawValue: "provider.\(profileID).api-key")
    }

    func validated() throws -> CredentialReference {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == rawValue,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 192,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && (CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "."
                          || scalar == "-"
                          || scalar == "_")
              }) else {
            throw ProviderProfileError.invalidCredentialReference
        }
        return self
    }
}

struct ProviderProfile: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var displayName: String
    var providerID: ModelProviderID
    var wireProtocol: ModelProviderWireProtocol
    var baseURL: String
    let credentialReference: CredentialReference
    var models: [ProviderModel]
    var defaultModel: String
    var reasoningMode: ReasoningMode
    var openAIWireProfile: OpenAICompatibleWireProfile?
    var openAICompatibility: OpenAICompletionsCompatibility?
    var retryPolicy: ProviderRetryPolicyConfiguration?
    var maxSteps: Int
    var maxOutputTokens: Int
    var isCustom: Bool

    init(
        id: String,
        displayName: String,
        providerID: ModelProviderID,
        wireProtocol: ModelProviderWireProtocol,
        baseURL: String,
        credentialReference: CredentialReference? = nil,
        models: [ProviderModel],
        defaultModel: String,
        reasoningMode: ReasoningMode,
        openAIWireProfile: OpenAICompatibleWireProfile? = nil,
        openAICompatibility: OpenAICompletionsCompatibility? = nil,
        retryPolicy: ProviderRetryPolicyConfiguration? = nil,
        maxSteps: Int = 8,
        maxOutputTokens: Int = 8_192,
        isCustom: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.wireProtocol = wireProtocol
        self.baseURL = baseURL
        self.credentialReference = credentialReference ?? .providerAPIKey(profileID: id)
        self.models = models
        self.defaultModel = defaultModel
        self.reasoningMode = reasoningMode
        self.openAIWireProfile = openAIWireProfile
        self.openAICompatibility = openAICompatibility
        self.retryPolicy = retryPolicy
        self.maxSteps = maxSteps
        self.maxOutputTokens = maxOutputTokens
        self.isCustom = isCustom
    }

    static func catalogDefault(
        for providerID: ModelProviderID,
        maxSteps: Int = 8,
        maxOutputTokens: Int = 8_192
    ) -> ProviderProfile {
        let descriptor = ModelProviderCatalog.descriptor(for: providerID)
        return ProviderProfile(
            id: providerID.rawValue,
            displayName: descriptor.displayName,
            providerID: providerID,
            wireProtocol: descriptor.wireProtocol,
            baseURL: descriptor.defaultBaseURL,
            models: descriptor.builtInModels,
            defaultModel: descriptor.defaultModel,
            reasoningMode: descriptor.defaultReasoningMode,
            openAIWireProfile: Self.defaultWireProfile(
                providerID: providerID,
                wireProtocol: descriptor.wireProtocol
            ),
            openAICompatibility: nil,
            retryPolicy: .upstreamDefault,
            maxSteps: maxSteps,
            maxOutputTokens: maxOutputTokens,
            isCustom: providerID == .customOpenAICompatible
        )
    }

    static func customDraft(
        id: String = "",
        displayName: String = "",
        maxSteps: Int = 8,
        maxOutputTokens: Int = 8_192
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            displayName: displayName,
            providerID: .customOpenAICompatible,
            wireProtocol: .openAIChatCompletions,
            baseURL: "",
            models: [],
            defaultModel: "",
            reasoningMode: .providerDefault,
            openAIWireProfile: .legacyGateway,
            openAICompatibility: nil,
            retryPolicy: .upstreamDefault,
            maxSteps: maxSteps,
            maxOutputTokens: maxOutputTokens,
            isCustom: true
        )
    }

    static func migrating(_ configuration: AgentConfiguration) -> ProviderProfile {
        let descriptor = ModelProviderCatalog.descriptor(for: configuration.providerID)
        let routeID = normalizedMigratedID(
            configuration.profileID ?? configuration.providerID.rawValue
        )
        var declaredModels = mergedModels(
            descriptor.builtInModels,
            ensuring: configuration.model
        )
        if let inputModalities = configuration.inputModalities,
           let index = declaredModels.firstIndex(where: { $0.id == configuration.model }) {
            let current = declaredModels[index]
            declaredModels[index] = ProviderModel(
                id: current.id,
                name: current.name,
                contextWindow: current.contextWindow,
                maxOutputTokens: current.maxOutputTokens,
                inputModalities: inputModalities,
                openAICompatibility: current.openAICompatibility
            )
        }
        return ProviderProfile(
            id: routeID,
            displayName: descriptor.displayName,
            providerID: configuration.providerID,
            wireProtocol: descriptor.wireProtocol,
            baseURL: configuration.baseURL,
            credentialReference: configuration.credentialReference
                ?? .providerAPIKey(profileID: routeID),
            models: declaredModels,
            defaultModel: configuration.model,
            reasoningMode: configuration.reasoningMode,
            openAIWireProfile: configuration.openAIWireProfile,
            openAICompatibility: configuration.openAICompatibility,
            retryPolicy: configuration.retryPolicy,
            maxSteps: configuration.maxSteps,
            maxOutputTokens: configuration.maxOutputTokens,
            isCustom: configuration.providerID == .customOpenAICompatible
        )
    }

    var descriptor: ModelProviderDescriptor {
        ModelProviderCatalog.descriptor(for: providerID)
    }

    func configuration(
        model: String? = nil,
        reasoningMode: ReasoningMode? = nil
    ) -> AgentConfiguration {
        let selectedModelID = model ?? defaultModel
        let selectedModel = models.first(where: { $0.id == selectedModelID })
        let modelCompatibility = selectedModel?.openAICompatibility
        let mergedCompatibility: OpenAICompletionsCompatibility?
        if openAICompatibility == nil, modelCompatibility == nil {
            mergedCompatibility = nil
        } else {
            mergedCompatibility = (openAICompatibility ?? .init())
                .overlaying(modelCompatibility)
        }
        return AgentConfiguration(
            providerID: providerID,
            profileID: id,
            credentialReference: credentialReference,
            baseURL: baseURL,
            model: selectedModelID,
            inputModalities: selectedModel?.inputModalities,
            reasoningMode: reasoningMode ?? self.reasoningMode,
            openAIWireProfile: openAIWireProfile,
            openAICompatibility: mergedCompatibility,
            retryPolicy: retryPolicy,
            maxSteps: maxSteps,
            maxOutputTokens: maxOutputTokens
        )
    }

    func validated() throws -> ProviderProfile {
        try Self.validateID(id)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDisplayName.isEmpty, normalizedDisplayName.utf8.count <= 96 else {
            throw ProviderProfileError.invalidDisplayName
        }
        _ = try credentialReference.validated()

        let normalizedDefaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDefaultModel.isEmpty else {
            throw ProviderProfileError.emptyDefaultModel
        }
        guard (128...65_536).contains(maxOutputTokens) else {
            throw AgentConfigurationError.invalidMaxOutputTokens
        }

        var endpointConfiguration = configuration(model: normalizedDefaultModel)
        endpointConfiguration.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try endpointConfiguration.validated()

        if providerID != .customOpenAICompatible,
           wireProtocol != descriptor.wireProtocol {
            throw ProviderProfileError.catalogProtocolMismatch
        }
        if isCustom, wireProtocol != .openAIChatCompletions {
            throw ProviderProfileError.unsupportedWireProtocol
        }
        if wireProtocol != .openAIChatCompletions,
           (openAIWireProfile != nil || openAICompatibility != nil
            || models.contains(where: { $0.openAICompatibility != nil })) {
            throw ProviderProfileError.unsupportedWireCompatibility
        }
        if let retryPolicy {
            _ = try ModelRetryPolicy.resolved(retryPolicy)
        }

        let normalizedModels = try Self.validatedModels(
            models,
            ensuring: normalizedDefaultModel,
            requireDeclaredModel: isCustom
        )
        var result = self
        result.displayName = normalizedDisplayName
        result.baseURL = endpointConfiguration.baseURL
        result.defaultModel = normalizedDefaultModel
        result.models = normalizedModels
        return result
    }

    private static func defaultWireProfile(
        providerID: ModelProviderID,
        wireProtocol: ModelProviderWireProtocol
    ) -> OpenAICompatibleWireProfile? {
        guard wireProtocol == .openAIChatCompletions else { return nil }
        switch providerID {
        case .deepSeekOfficial: return .deepSeek
        case .openAI, .openRouter: return .openAI
        case .customOpenAICompatible: return .legacyGateway
        case .anthropic: return nil
        }
    }

    static func validateID(_ id: String) throws {
        guard !id.isEmpty,
              id.utf8.count <= 64,
              let first = id.unicodeScalars.first,
              first.isASCII,
              CharacterSet.lowercaseLetters.contains(first),
              id.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII
                      && (CharacterSet.lowercaseLetters.contains(scalar)
                          || CharacterSet.decimalDigits.contains(scalar)
                          || scalar == "-")
              }),
              !id.hasSuffix("-") else {
            throw ProviderProfileError.invalidID
        }
    }

    private static func normalizedMigratedID(_ candidate: String) -> String {
        let lowered = candidate.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII,
               CharacterSet.lowercaseLetters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "-" {
                return Character(String(scalar))
            }
            return "-"
        }
        var value = String(scalars)
        while value.contains("--") {
            value = value.replacingOccurrences(of: "--", with: "-")
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if value.first?.isLetter != true {
            value = "provider-" + value
        }
        return String(value.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func validatedModels(
        _ models: [ProviderModel],
        ensuring defaultModel: String,
        requireDeclaredModel: Bool
    ) throws -> [ProviderModel] {
        var result: [ProviderModel] = []
        var seen: Set<String> = []
        for model in models {
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.utf8.count <= 256 else {
                throw ProviderProfileError.invalidModelID
            }
            guard seen.insert(id).inserted else {
                throw ProviderProfileError.duplicateModelID(id)
            }
            guard !model.inputModalities.isEmpty,
                  model.inputModalities.contains(.text),
                  Set(model.inputModalities).count == model.inputModalities.count else {
                throw ProviderProfileError.invalidModelInputModalities(id)
            }
            let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(
                ProviderModel(
                    id: id,
                    name: name?.isEmpty == true ? nil : name,
                    contextWindow: model.contextWindow,
                    maxOutputTokens: model.maxOutputTokens,
                    inputModalities: model.inputModalities,
                    openAICompatibility: model.openAICompatibility
                )
            )
        }
        let merged = mergedModels(result, ensuring: defaultModel)
        if requireDeclaredModel, merged.isEmpty {
            throw ProviderProfileError.customProviderRequiresModel
        }
        return merged
    }

    private static func mergedModels(
        _ models: [ProviderModel],
        ensuring modelID: String
    ) -> [ProviderModel] {
        guard !modelID.isEmpty, !models.contains(where: { $0.id == modelID }) else {
            return models
        }
        return models + [ProviderModel(id: modelID)]
    }
}

struct ProviderProfileDirectory: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var activeProfileID: String?
    var profiles: [ProviderProfile]

    init(
        schemaVersion: Int = ProviderProfileDirectory.schemaVersion,
        activeProfileID: String?,
        profiles: [ProviderProfile]
    ) {
        self.schemaVersion = schemaVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    static func initial() -> ProviderProfileDirectory {
        let profile = ProviderProfile.catalogDefault(for: .deepSeekOfficial)
        return ProviderProfileDirectory(activeProfileID: profile.id, profiles: [profile])
    }

    static func migrating(_ configuration: AgentConfiguration) -> ProviderProfileDirectory {
        let profile = ProviderProfile.migrating(configuration)
        return ProviderProfileDirectory(activeProfileID: profile.id, profiles: [profile])
    }

    var activeProfile: ProviderProfile? {
        guard let activeProfileID else { return nil }
        return profile(id: activeProfileID)
    }

    func profile(id: String) -> ProviderProfile? {
        profiles.first { $0.id == id }
    }

    func profile(matching configuration: AgentConfiguration) -> ProviderProfile? {
        if let profileID = configuration.profileID,
           let exact = profile(id: profileID) {
            return exact
        }
        if let credentialReference = configuration.credentialReference,
           let exact = profiles.first(where: { $0.credentialReference == credentialReference }) {
            return exact
        }
        let normalizedBaseURL = configuration.baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.first {
            $0.providerID == configuration.providerID
                && $0.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedBaseURL
        }
    }

    func validated() throws -> ProviderProfileDirectory {
        guard schemaVersion == Self.schemaVersion else {
            throw ProviderProfileError.unsupportedDirectorySchema(schemaVersion)
        }
        var seenIDs: Set<String> = []
        var seenCredentialReferences: Set<CredentialReference> = []
        let validatedProfiles = try profiles.map { profile in
            let validated = try profile.validated()
            guard seenIDs.insert(validated.id).inserted else {
                throw ProviderProfileError.duplicateID(validated.id)
            }
            guard seenCredentialReferences.insert(validated.credentialReference).inserted else {
                throw ProviderProfileError.duplicateCredentialReference(
                    validated.credentialReference
                )
            }
            return validated
        }
        if let activeProfileID,
           !validatedProfiles.contains(where: { $0.id == activeProfileID }) {
            throw ProviderProfileError.missingActiveProfile
        }
        var result = self
        result.profiles = validatedProfiles
        return result
    }

    mutating func upsert(_ profile: ProviderProfile, makeActive: Bool) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        if makeActive || activeProfileID == nil {
            activeProfileID = profile.id
        }
    }

    @discardableResult
    mutating func remove(id: String) -> ProviderProfile? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = profiles.remove(at: index)
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        return removed
    }
}

enum ProviderCredentialStatus: String, Codable, Sendable, Equatable {
    case unknown
    case configured
    case missing
    case originMismatch
}

enum ProviderProfileError: LocalizedError, Sendable, Equatable {
    case invalidID
    case duplicateID(String)
    case duplicateCredentialReference(CredentialReference)
    case invalidDisplayName
    case invalidCredentialReference
    case invalidModelID
    case invalidModelInputModalities(String)
    case duplicateModelID(String)
    case emptyDefaultModel
    case customProviderRequiresModel
    case catalogProtocolMismatch
    case unsupportedWireProtocol
    case unsupportedWireCompatibility
    case missingActiveProfile
    case missingProfile(String)
    case profileIdentityChanged
    case profileBusy
    case profileRemovalRollbackFailed
    case unsupportedDirectorySchema(Int)

    var errorDescription: String? {
        switch self {
        case .invalidID:
            return "Provider ID 必须以小写字母开头，只能包含小写字母、数字和连字符，且保存后不可修改。"
        case let .duplicateID(id):
            return "Provider ID“\(id)”已经存在。"
        case let .duplicateCredentialReference(reference):
            return "凭据引用“\(reference.rawValue)”已经被另一个 Provider Profile 使用。"
        case .invalidDisplayName:
            return "服务商显示名称不能为空，且不能超过 96 字节。"
        case .invalidCredentialReference:
            return "服务商凭据引用无效。"
        case .invalidModelID:
            return "模型 ID 不能为空，且不能超过 256 字节。"
        case let .invalidModelInputModalities(id):
            return "模型 ID“\(id)”的输入类型必须包含 text，且不能重复。"
        case let .duplicateModelID(id):
            return "模型 ID“\(id)”重复。"
        case .emptyDefaultModel:
            return "默认模型不能为空。"
        case .customProviderRequiresModel:
            return "自定义服务商至少需要声明一个模型。"
        case .catalogProtocolMismatch:
            return "目录服务商不能改成与其内建适配器不同的 API 协议。"
        case .unsupportedWireProtocol:
            return "当前原生客户端只支持 OpenAI-compatible Chat Completions 协议。"
        case .unsupportedWireCompatibility:
            return "只有 OpenAI Chat Completions Profile 可以设置兼容协议。"
        case .missingActiveProfile:
            return "默认服务商指向了不存在的 Provider Profile。"
        case let .missingProfile(id):
            return "Provider Profile“\(id)”不存在。"
        case .profileIdentityChanged:
            return "Provider ID 和凭据引用是永久标识，编辑时不能修改。"
        case .profileBusy:
            return "当前任务仍在运行，停止任务后才能移除这个 Provider Profile。"
        case .profileRemovalRollbackFailed:
            return "Provider Profile 删除失败，且无法恢复原目录。请重新启动 App 后检查服务商配置。"
        case let .unsupportedDirectorySchema(version):
            return "不支持 Provider Profile 目录版本 \(version)。"
        }
    }
}
