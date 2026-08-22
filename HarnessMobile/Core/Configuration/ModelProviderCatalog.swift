import Foundation

enum ModelProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case deepSeekOfficial = "deepseek-official"
    case openAI = "openai"
    case anthropic = "anthropic"
    case openRouter = "openrouter"
    case customOpenAICompatible = "openai-compatible"

    var id: String { rawValue }
}

enum ModelProviderWireProtocol: String, Codable, Sendable {
    case openAIChatCompletions = "openai-chat-completions"
    case anthropicMessages = "anthropic-messages"
}

enum ModelProviderInferenceSupport: String, Codable, Sendable {
    case supported
    case adapterRequired
}

enum ModelProviderDiscoverySupport: String, Codable, Sendable {
    case openAICompatibleModels
    case builtInCatalogOnly
}

enum ModelInputModality: String, Codable, Sendable, Equatable, Hashable {
    case text
    case image
}

struct ProviderModel: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String?
    let contextWindow: Int?
    let maxOutputTokens: Int?
    let inputModalities: [ModelInputModality]
    let openAICompatibility: OpenAICompletionsCompatibility?

    init(
        id: String,
        name: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        inputModalities: [ModelInputModality] = [.text],
        openAICompatibility: OpenAICompletionsCompatibility? = nil
    ) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.inputModalities = inputModalities
        self.openAICompatibility = openAICompatibility
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, contextWindow, maxOutputTokens, inputModalities, openAICompatibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        maxOutputTokens = try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        inputModalities = try container.decodeIfPresent(
            [ModelInputModality].self,
            forKey: .inputModalities
        ) ?? [.text]
        openAICompatibility = try container.decodeIfPresent(
            OpenAICompletionsCompatibility.self,
            forKey: .openAICompatibility
        )
    }
}

enum ModelCatalogSource: String, Codable, Sendable {
    case builtIn
    case remote
    case cache
}

struct ModelCatalogSnapshot: Codable, Sendable, Equatable {
    let providerID: ModelProviderID
    let source: ModelCatalogSource
    let catalogVersion: String
    let fetchedAt: Date?
    let models: [ProviderModel]
}

struct ModelProviderDescriptor: Sendable, Equatable, Identifiable {
    let id: ModelProviderID
    let displayName: String
    let detail: String
    let wireProtocol: ModelProviderWireProtocol
    let inferenceSupport: ModelProviderInferenceSupport
    let discoverySupport: ModelProviderDiscoverySupport
    let defaultBaseURL: String
    let defaultModel: String
    let defaultReasoningMode: ReasoningMode
    let builtInModels: [ProviderModel]
    let compatibilityNotice: String?

    var supportsCurrentInferenceWire: Bool {
        inferenceSupport == .supported
    }

    var supportsRemoteModelDiscovery: Bool {
        discoverySupport == .openAICompatibleModels
    }
}

enum ModelProviderCatalog {
    static let schemaVersion = 1
    static let revision = 2
    static let version = "provider-catalog-v\(schemaVersion).r\(revision)"

    static let providers: [ModelProviderDescriptor] = [
        ModelProviderDescriptor(
            id: .deepSeekOfficial,
            displayName: "DeepSeek",
            detail: "DeepSeek 官方 OpenAI-compatible Chat Completions API",
            wireProtocol: .openAIChatCompletions,
            inferenceSupport: .supported,
            discoverySupport: .openAICompatibleModels,
            defaultBaseURL: AgentConfiguration.defaultBaseURL,
            defaultModel: AgentConfiguration.defaultModel,
            defaultReasoningMode: .high,
            builtInModels: [
                ProviderModel(
                    id: "deepseek-v4-flash",
                    name: "DeepSeek-V4-Flash",
                    contextWindow: 1_000_000,
                    maxOutputTokens: 256_000
                ),
                ProviderModel(
                    id: "deepseek-v4-pro",
                    name: "DeepSeek-V4-Pro",
                    contextWindow: 1_000_000,
                    maxOutputTokens: 256_000
                ),
                ProviderModel(
                    id: "deepseek-v4-flash-vision-exp",
                    name: "DeepSeek-V4-Flash-Vision-Exp",
                    contextWindow: 1_000_000,
                    maxOutputTokens: 256_000,
                    inputModalities: [.text, .image]
                )
            ],
            compatibilityNotice: nil
        ),
        ModelProviderDescriptor(
            id: .openAI,
            displayName: "OpenAI",
            detail: "OpenAI Chat Completions API",
            wireProtocol: .openAIChatCompletions,
            inferenceSupport: .supported,
            discoverySupport: .openAICompatibleModels,
            defaultBaseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-5",
            defaultReasoningMode: .providerDefault,
            builtInModels: [
                ProviderModel(id: "gpt-5", name: "GPT-5"),
                ProviderModel(id: "gpt-5-mini", name: "GPT-5 mini")
            ],
            compatibilityNotice: nil
        ),
        ModelProviderDescriptor(
            id: .anthropic,
            displayName: "Anthropic",
            detail: "Anthropic Messages API",
            wireProtocol: .anthropicMessages,
            inferenceSupport: .supported,
            discoverySupport: .builtInCatalogOnly,
            defaultBaseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-sonnet-4-5",
            defaultReasoningMode: .providerDefault,
            builtInModels: [
                ProviderModel(
                    id: "claude-sonnet-4-5",
                    name: "Claude Sonnet 4.5",
                    inputModalities: [.text, .image]
                ),
                ProviderModel(
                    id: "claude-opus-4-1",
                    name: "Claude Opus 4.1",
                    inputModalities: [.text, .image]
                )
            ],
            compatibilityNotice: "Anthropic Messages 已支持流式文本、工具调用、用量和错误解析；官方 API 没有统一模型目录，因此使用内建目录或手动模型 ID。"
        ),
        ModelProviderDescriptor(
            id: .openRouter,
            displayName: "OpenRouter",
            detail: "聚合多个厂商的 OpenAI-compatible Chat Completions API",
            wireProtocol: .openAIChatCompletions,
            inferenceSupport: .supported,
            discoverySupport: .openAICompatibleModels,
            defaultBaseURL: "https://openrouter.ai/api/v1",
            defaultModel: "openrouter/auto",
            defaultReasoningMode: .providerDefault,
            builtInModels: [
                ProviderModel(id: "openrouter/auto", name: "OpenRouter Auto")
            ],
            compatibilityNotice: nil
        ),
        ModelProviderDescriptor(
            id: .customOpenAICompatible,
            displayName: "自定义 OpenAI-compatible",
            detail: "自定义 HTTPS endpoint，必须兼容流式 chat/completions；/models 可选",
            wireProtocol: .openAIChatCompletions,
            inferenceSupport: .supported,
            discoverySupport: .openAICompatibleModels,
            defaultBaseURL: "",
            defaultModel: "",
            defaultReasoningMode: .providerDefault,
            builtInModels: [],
            compatibilityNotice: "仅支持 OpenAI-compatible Chat Completions wire，不会自动兼容 Anthropic、Gemini 或其他协议。"
        )
    ]

    static func descriptor(for id: ModelProviderID) -> ModelProviderDescriptor {
        providers.first(where: { $0.id == id }) ?? providers[0]
    }

    static func inferredProviderID(baseURL: String) -> ModelProviderID {
        guard let host = URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )?.host?.lowercased() else {
            return .customOpenAICompatible
        }
        switch host {
        case "api.deepseek.com":
            return .deepSeekOfficial
        case "api.openai.com":
            return .openAI
        case "api.anthropic.com":
            return .anthropic
        case "openrouter.ai":
            return .openRouter
        default:
            return .customOpenAICompatible
        }
    }

    static func applying(
        _ providerID: ModelProviderID,
        to configuration: AgentConfiguration
    ) -> AgentConfiguration {
        let descriptor = descriptor(for: providerID)
        var result = configuration
        result.providerID = providerID
        result.baseURL = descriptor.defaultBaseURL
        result.model = descriptor.defaultModel
        result.inputModalities = descriptor.builtInModels.first(
            where: { $0.id == descriptor.defaultModel }
        )?.inputModalities
        result.reasoningMode = descriptor.defaultReasoningMode
        return result
    }

    static func builtInSnapshot(for providerID: ModelProviderID) -> ModelCatalogSnapshot {
        let descriptor = descriptor(for: providerID)
        return ModelCatalogSnapshot(
            providerID: providerID,
            source: .builtIn,
            catalogVersion: version,
            fetchedAt: nil,
            models: descriptor.builtInModels
        )
    }

    static func supportsImageInput(_ configuration: AgentConfiguration) -> Bool {
        if let inputModalities = configuration.inputModalities {
            return inputModalities.contains(.image)
        }
        let normalized = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let models = descriptor(for: configuration.providerID).builtInModels
        return models.first(where: { $0.id.lowercased() == normalized })?
            .inputModalities.contains(.image) == true
    }
}
