import Foundation

protocol ModelProviderAdapter: Sendable {
    var wireProtocol: ModelProviderWireProtocol { get }
    var modelListSchemaVersion: Int { get }

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL
    func modelListURL(for configuration: AgentConfiguration) throws -> URL
    func decodeModelList(_ data: Data) throws -> [ProviderModel]
}

enum ModelProviderAdapterRegistry {
    static func adapter(for providerID: ModelProviderID) throws -> any ModelProviderAdapter {
        let descriptor = ModelProviderCatalog.descriptor(for: providerID)
        guard descriptor.supportsCurrentInferenceWire else {
            throw AgentConfigurationError.unsupportedProviderWire(providerID)
        }
        switch descriptor.wireProtocol {
        case .openAIChatCompletions:
            return OpenAIChatCompletionsAdapter()
        case .anthropicMessages:
            return AnthropicMessagesAdapter()
        }
    }
}

struct OpenAIChatCompletionsAdapter: ModelProviderAdapter {
    let wireProtocol = ModelProviderWireProtocol.openAIChatCompletions
    let modelListSchemaVersion = 1

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(appending: "chat/completions")
    }

    func modelListURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(
            appending: "models",
            replacingTrailingPath: "chat/completions"
        )
    }

    func decodeModelList(_ data: Data) throws -> [ProviderModel] {
        let envelope: OpenAIModelListEnvelope
        do {
            envelope = try JSONDecoder().decode(OpenAIModelListEnvelope.self, from: data)
        } catch {
            throw ModelDiscoveryError.malformedResponse
        }

        var seen = Set<String>()
        var models: [ProviderModel] = []
        models.reserveCapacity(min(envelope.data.count, 1_024))
        for lossyItem in envelope.data {
            guard let item = lossyItem.value,
                  let id = Self.normalizedLabel(item.id),
                  id.utf8.count <= 512,
                  seen.insert(id).inserted else {
                continue
            }
            guard models.count < 10_000 else {
                throw ModelDiscoveryError.tooManyModels
            }
            models.append(
                ProviderModel(
                    id: id,
                    name: Self.normalizedLabel(item.name, item.displayName),
                    contextWindow: Self.positiveCapacity(
                        item.contextWindow,
                        item.contextLength
                    ),
                    maxOutputTokens: Self.positiveCapacity(
                        item.maxOutputTokens,
                        item.maxTokens
                    )
                )
            )
        }
        return models
    }

    private static func normalizedLabel(_ candidates: String?...) -> String? {
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  value.utf8.count <= 512 else {
                continue
            }
            return value
        }
        return nil
    }

    private static func positiveCapacity(_ candidates: Int?...) -> Int? {
        candidates.compactMap { $0 }.first(where: { $0 > 0 })
    }
}

struct AnthropicMessagesAdapter: ModelProviderAdapter {
    let wireProtocol = ModelProviderWireProtocol.anthropicMessages
    let modelListSchemaVersion = 1

    func chatCompletionsURL(for configuration: AgentConfiguration) throws -> URL {
        try configuration.apiEndpointURL(appending: "messages")
    }

    func modelListURL(for configuration: AgentConfiguration) throws -> URL {
        throw AgentConfigurationError.unsupportedModelDiscovery(configuration.providerID)
    }

    func decodeModelList(_ data: Data) throws -> [ProviderModel] {
        throw ModelDiscoveryError.unsupportedProvider(.anthropic)
    }
}

private struct OpenAIModelListEnvelope: Decodable {
    let data: [LossyOpenAIModelListItem]
}

private struct LossyOpenAIModelListItem: Decodable {
    let value: OpenAIModelListItem?

    init(from decoder: Decoder) throws {
        value = try? OpenAIModelListItem(from: decoder)
    }
}

private struct OpenAIModelListItem: Decodable {
    let id: String?
    let name: String?
    let displayName: String?
    let contextWindow: Int?
    let contextLength: Int?
    let maxTokens: Int?
    let maxOutputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case displayName = "display_name"
        case contextWindow = "context_window"
        case contextLength = "context_length"
        case maxTokens = "max_tokens"
        case maxOutputTokens = "max_output_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        displayName = try? container.decode(String.self, forKey: .displayName)
        contextWindow = try? container.decode(Int.self, forKey: .contextWindow)
        contextLength = try? container.decode(Int.self, forKey: .contextLength)
        maxTokens = try? container.decode(Int.self, forKey: .maxTokens)
        maxOutputTokens = try? container.decode(Int.self, forKey: .maxOutputTokens)
    }
}
