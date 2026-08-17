import Foundation

struct AgentConfiguration: Codable, Sendable, Equatable {
    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModel = "deepseek-v4-flash"

    var providerID: ModelProviderID = .deepSeekOfficial
    var profileID: String?
    var credentialReference: CredentialReference?
    var baseURL: String = defaultBaseURL
    var model: String = defaultModel
    var reasoningMode: ReasoningMode = .high
    var maxSteps: Int = 8
    var maxOutputTokens: Int = 4_096

    init(
        providerID: ModelProviderID = .deepSeekOfficial,
        profileID: String? = nil,
        credentialReference: CredentialReference? = nil,
        baseURL: String = defaultBaseURL,
        model: String = defaultModel,
        reasoningMode: ReasoningMode = .high,
        maxSteps: Int = 8,
        maxOutputTokens: Int = 4_096
    ) {
        self.providerID = providerID
        self.profileID = profileID
        self.credentialReference = credentialReference
        self.baseURL = baseURL
        self.model = model
        self.reasoningMode = reasoningMode
        self.maxSteps = maxSteps
        self.maxOutputTokens = maxOutputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case profileID
        case credentialReference
        case baseURL
        case model
        case reasoningMode
        case maxSteps
        case maxOutputTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
            ?? Self.defaultBaseURL
        model = try container.decodeIfPresent(String.self, forKey: .model)
            ?? Self.defaultModel
        reasoningMode = try container.decodeIfPresent(ReasoningMode.self, forKey: .reasoningMode)
            ?? .high
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 8
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
            ?? 4_096
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        credentialReference = try container.decodeIfPresent(
            CredentialReference.self,
            forKey: .credentialReference
        )
        if let rawProvider = try container.decodeIfPresent(String.self, forKey: .providerID),
           let decodedProvider = ModelProviderID(rawValue: rawProvider) {
            providerID = decodedProvider
        } else {
            providerID = ModelProviderCatalog.inferredProviderID(baseURL: baseURL)
        }
    }

    func chatCompletionsURL() throws -> URL {
        try ModelProviderAdapterRegistry.adapter(for: providerID)
            .chatCompletionsURL(for: self)
    }

    func modelsURL() throws -> URL {
        let descriptor = ModelProviderCatalog.descriptor(for: providerID)
        guard descriptor.supportsRemoteModelDiscovery else {
            throw AgentConfigurationError.unsupportedModelDiscovery(providerID)
        }
        return try ModelProviderAdapterRegistry.adapter(for: providerID)
            .modelListURL(for: self)
    }

    func apiEndpointURL(
        appending endpointPath: String,
        replacingTrailingPath trailingPath: String? = nil
    ) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw AgentConfigurationError.invalidHTTPSURL
        }

        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        if let trailingPath {
            let normalizedTrailingPath = "/" + trailingPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.hasSuffix(normalizedTrailingPath) {
                path.removeLast(normalizedTrailingPath.count)
            }
        }
        let normalizedEndpointPath = "/" + endpointPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.hasSuffix(normalizedEndpointPath) {
            path += normalizedEndpointPath
        }
        components.path = path

        guard let url = components.url else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        return url
    }

    func validated() throws -> AgentConfiguration {
        guard ModelProviderCatalog.descriptor(for: providerID).supportsCurrentInferenceWire else {
            throw AgentConfigurationError.unsupportedProviderWire(providerID)
        }
        _ = try chatCompletionsURL()
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentConfigurationError.emptyModel
        }
        guard (128...65_536).contains(maxOutputTokens) else {
            throw AgentConfigurationError.invalidMaxOutputTokens
        }
        guard ReasoningMode.supportedModes(for: providerID).contains(reasoningMode) else {
            throw AgentConfigurationError.unsupportedReasoningMode(providerID, reasoningMode)
        }
        return self
    }

    func credentialOrigin() throws -> String {
        let endpoint = try chatCompletionsURL()
        guard let host = endpoint.host?.lowercased() else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = endpoint.port ?? 443
        guard let value = origin.string else {
            throw AgentConfigurationError.invalidHTTPSURL
        }
        return value
    }

    var requiresDeepSeekReasoningReplay: Bool {
        guard reasoningMode == .high || reasoningMode == .max,
              let host = try? chatCompletionsURL().host?.lowercased() else {
            return false
        }
        return providerID == .deepSeekOfficial || host == "api.deepseek.com"
    }
}

enum ReasoningMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case providerDefault
    case off
    case high
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providerDefault:
            return "服务默认"
        case .off:
            return "关闭"
        case .high:
            return "High"
        case .max:
            return "Max"
        }
    }

    static func supportedModes(for providerID: ModelProviderID) -> [ReasoningMode] {
        switch ModelProviderCatalog.descriptor(for: providerID).wireProtocol {
        case .anthropicMessages:
            // Extended thinking requires replaying signed thinking blocks across
            // tool turns. Keep it off until that durable wire contract is stored.
            return [.providerDefault, .off]
        case .openAIChatCompletions:
            return allCases
        }
    }
}

enum AgentConfigurationError: LocalizedError, Sendable {
    case invalidHTTPSURL
    case emptyModel
    case invalidMaxOutputTokens
    case unsupportedProviderWire(ModelProviderID)
    case unsupportedModelDiscovery(ModelProviderID)
    case unsupportedReasoningMode(ModelProviderID, ReasoningMode)

    var errorDescription: String? {
        switch self {
        case .invalidHTTPSURL:
            return "API 地址必须是有效的 HTTPS URL。"
        case .emptyModel:
            return "模型名称不能为空。"
        case .invalidMaxOutputTokens:
            return "最大输出 Token 必须在 128 到 65536 之间。"
        case let .unsupportedProviderWire(providerID):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return provider.compatibilityNotice
                ?? "当前版本尚未实现 \(provider.displayName) 的推理协议。"
        case let .unsupportedModelDiscovery(providerID):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return "当前版本不能从 \(provider.displayName) 远端获取模型列表，请使用内建目录或手动输入模型。"
        case let .unsupportedReasoningMode(providerID, mode):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return "\(provider.displayName) 当前不能使用 \(mode.title) 思考模式；请选“服务默认”或“关闭”。"
        }
    }
}
