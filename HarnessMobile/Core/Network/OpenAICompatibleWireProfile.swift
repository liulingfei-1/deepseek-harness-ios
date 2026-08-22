import Foundation

/// Route-owned OpenAI chat-completions compatibility contract.
///
/// An unknown private gateway must not inherit OpenAI or DeepSeek extensions
/// merely because its endpoint uses `/chat/completions`. This mirrors the
/// upstream pi-ai profile rule: compatibility is explicit and conservative.
enum OpenAICompatibleWireProfile: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case deepSeek
    case openAI
    case legacyGateway

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek 原生"
        case .openAI: return "OpenAI 标准"
        case .legacyGateway: return "保守兼容网关"
        }
    }

    static func resolve(_ configuration: AgentConfiguration) -> Self {
        if let configured = configuration.openAIWireProfile {
            return configured
        }
        let host = (try? configuration.chatCompletionsURL().host?.lowercased()) ?? nil
        if configuration.providerID == .deepSeekOfficial || host == "api.deepseek.com" {
            return .deepSeek
        }
        switch configuration.providerID {
        case .openAI, .openRouter:
            return .openAI
        case .customOpenAICompatible:
            return .legacyGateway
        case .deepSeekOfficial:
            return .deepSeek
        case .anthropic:
            return .legacyGateway
        }
    }
}

/// Sparse route/model overrides matching the OpenAI Completions compatibility
/// surface exposed by the upstream pi-ai adapter. The preset above remains a
/// convenient UI baseline; these independent fields are the persisted
/// contract because real gateways rarely match one all-or-nothing preset.
struct OpenAICompletionsCompatibility: Codable, Sendable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case supportsStore
        case supportsDeveloperRole
        case supportsReasoningEffort
        case supportsUsageInStreaming
        case maxTokensField
        case requiresToolResultName
        case requiresAssistantAfterToolResult
        case requiresThinkingAsText
        case requiresReasoningContentOnAssistantMessages
        case thinkingFormat
        case chatTemplateKwargs
        case supportsStrictMode
        case cacheControlFormat
        case supportsLongCacheRetention
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    enum MaxTokensField: String, Codable, Sendable, Hashable {
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
    }

    enum ThinkingFormat: String, Codable, Sendable, Hashable {
        case openAI = "openai"
        case deepSeek = "deepseek"
        case openRouter = "openrouter"
        case together
        case zai
        case qwen
        case chatTemplate = "chat-template"
        case qwenChatTemplate = "qwen-chat-template"
        case stringThinking = "string-thinking"
        case antLing = "ant-ling"
    }

    enum CacheControlFormat: String, Codable, Sendable, Hashable {
        case anthropic
    }

    enum ChatTemplateKwarg: Codable, Sendable, Equatable, Hashable {
        enum Variable: String, Codable, Sendable, Hashable {
            case thinkingEnabled = "thinking.enabled"
            case thinkingEffort = "thinking.effort"
        }

        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case variable(Variable, omitWhenOff: Bool?)

        private enum VariableKeys: String, CodingKey {
            case variable = "$var"
            case omitWhenOff
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            let object = try decoder.container(keyedBy: VariableKeys.self)
            self = .variable(
                try object.decode(Variable.self, forKey: .variable),
                omitWhenOff: try object.decodeIfPresent(Bool.self, forKey: .omitWhenOff)
            )
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .string(value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case let .number(value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case let .bool(value):
                var container = encoder.singleValueContainer()
                try container.encode(value)
            case .null:
                var container = encoder.singleValueContainer()
                try container.encodeNil()
            case let .variable(variable, omitWhenOff):
                var container = encoder.container(keyedBy: VariableKeys.self)
                try container.encode(variable, forKey: .variable)
                try container.encodeIfPresent(omitWhenOff, forKey: .omitWhenOff)
            }
        }
    }

    var supportsStore: Bool?
    var supportsDeveloperRole: Bool?
    var supportsReasoningEffort: Bool?
    var supportsUsageInStreaming: Bool?
    var maxTokensField: MaxTokensField?
    var requiresToolResultName: Bool?
    var requiresAssistantAfterToolResult: Bool?
    var requiresThinkingAsText: Bool?
    var requiresReasoningContentOnAssistantMessages: Bool?
    var thinkingFormat: ThinkingFormat?
    var chatTemplateKwargs: [String: ChatTemplateKwarg]?
    var supportsStrictMode: Bool?
    var cacheControlFormat: CacheControlFormat?
    var supportsLongCacheRetention: Bool?

    init(
        supportsStore: Bool? = nil,
        supportsDeveloperRole: Bool? = nil,
        supportsReasoningEffort: Bool? = nil,
        supportsUsageInStreaming: Bool? = nil,
        maxTokensField: MaxTokensField? = nil,
        requiresToolResultName: Bool? = nil,
        requiresAssistantAfterToolResult: Bool? = nil,
        requiresThinkingAsText: Bool? = nil,
        requiresReasoningContentOnAssistantMessages: Bool? = nil,
        thinkingFormat: ThinkingFormat? = nil,
        chatTemplateKwargs: [String: ChatTemplateKwarg]? = nil,
        supportsStrictMode: Bool? = nil,
        cacheControlFormat: CacheControlFormat? = nil,
        supportsLongCacheRetention: Bool? = nil
    ) {
        self.supportsStore = supportsStore
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsUsageInStreaming = supportsUsageInStreaming
        self.maxTokensField = maxTokensField
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.requiresThinkingAsText = requiresThinkingAsText
        self.requiresReasoningContentOnAssistantMessages = requiresReasoningContentOnAssistantMessages
        self.thinkingFormat = thinkingFormat
        self.chatTemplateKwargs = chatTemplateKwargs
        self.supportsStrictMode = supportsStrictMode
        self.cacheControlFormat = cacheControlFormat
        self.supportsLongCacheRetention = supportsLongCacheRetention
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath + [unknown],
                    debugDescription: "Unknown OpenAI compatibility field \(unknown.stringValue)"
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            guard container.contains(key) else { return nil }
            guard try !container.decodeNil(forKey: key) else {
                throw DecodingError.valueNotFound(
                    T.self,
                    .init(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "Explicit null is not a compatibility override"
                    )
                )
            }
            return try container.decode(T.self, forKey: key)
        }
        supportsStore = try value(Bool.self, .supportsStore)
        supportsDeveloperRole = try value(Bool.self, .supportsDeveloperRole)
        supportsReasoningEffort = try value(Bool.self, .supportsReasoningEffort)
        supportsUsageInStreaming = try value(Bool.self, .supportsUsageInStreaming)
        maxTokensField = try value(MaxTokensField.self, .maxTokensField)
        requiresToolResultName = try value(Bool.self, .requiresToolResultName)
        requiresAssistantAfterToolResult = try value(
            Bool.self,
            .requiresAssistantAfterToolResult
        )
        requiresThinkingAsText = try value(Bool.self, .requiresThinkingAsText)
        requiresReasoningContentOnAssistantMessages = try value(
            Bool.self,
            .requiresReasoningContentOnAssistantMessages
        )
        thinkingFormat = try value(ThinkingFormat.self, .thinkingFormat)
        chatTemplateKwargs = try value(
            [String: ChatTemplateKwarg].self,
            .chatTemplateKwargs
        )
        supportsStrictMode = try value(Bool.self, .supportsStrictMode)
        cacheControlFormat = try value(CacheControlFormat.self, .cacheControlFormat)
        supportsLongCacheRetention = try value(Bool.self, .supportsLongCacheRetention)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(supportsStore, forKey: .supportsStore)
        try container.encodeIfPresent(supportsDeveloperRole, forKey: .supportsDeveloperRole)
        try container.encodeIfPresent(supportsReasoningEffort, forKey: .supportsReasoningEffort)
        try container.encodeIfPresent(supportsUsageInStreaming, forKey: .supportsUsageInStreaming)
        try container.encodeIfPresent(maxTokensField, forKey: .maxTokensField)
        try container.encodeIfPresent(requiresToolResultName, forKey: .requiresToolResultName)
        try container.encodeIfPresent(
            requiresAssistantAfterToolResult,
            forKey: .requiresAssistantAfterToolResult
        )
        try container.encodeIfPresent(requiresThinkingAsText, forKey: .requiresThinkingAsText)
        try container.encodeIfPresent(
            requiresReasoningContentOnAssistantMessages,
            forKey: .requiresReasoningContentOnAssistantMessages
        )
        try container.encodeIfPresent(thinkingFormat, forKey: .thinkingFormat)
        try container.encodeIfPresent(chatTemplateKwargs, forKey: .chatTemplateKwargs)
        try container.encodeIfPresent(supportsStrictMode, forKey: .supportsStrictMode)
        try container.encodeIfPresent(cacheControlFormat, forKey: .cacheControlFormat)
        try container.encodeIfPresent(
            supportsLongCacheRetention,
            forKey: .supportsLongCacheRetention
        )
    }

    func overlaying(_ override: Self?) -> Self {
        guard let override else { return self }
        return Self(
            supportsStore: override.supportsStore ?? supportsStore,
            supportsDeveloperRole: override.supportsDeveloperRole ?? supportsDeveloperRole,
            supportsReasoningEffort: override.supportsReasoningEffort ?? supportsReasoningEffort,
            supportsUsageInStreaming: override.supportsUsageInStreaming ?? supportsUsageInStreaming,
            maxTokensField: override.maxTokensField ?? maxTokensField,
            requiresToolResultName: override.requiresToolResultName ?? requiresToolResultName,
            requiresAssistantAfterToolResult: override.requiresAssistantAfterToolResult ?? requiresAssistantAfterToolResult,
            requiresThinkingAsText: override.requiresThinkingAsText ?? requiresThinkingAsText,
            requiresReasoningContentOnAssistantMessages: override.requiresReasoningContentOnAssistantMessages ?? requiresReasoningContentOnAssistantMessages,
            thinkingFormat: override.thinkingFormat ?? thinkingFormat,
            chatTemplateKwargs: override.chatTemplateKwargs ?? chatTemplateKwargs,
            supportsStrictMode: override.supportsStrictMode ?? supportsStrictMode,
            cacheControlFormat: override.cacheControlFormat ?? cacheControlFormat,
            supportsLongCacheRetention: override.supportsLongCacheRetention ?? supportsLongCacheRetention
        )
    }
}

extension OpenAICompatibleWireProfile {
    var compatibilityBaseline: OpenAICompletionsCompatibility {
        switch self {
        case .deepSeek:
            return .init(
                supportsDeveloperRole: false,
                supportsReasoningEffort: true,
                supportsUsageInStreaming: true,
                maxTokensField: .maxTokens,
                requiresToolResultName: false,
                requiresAssistantAfterToolResult: false,
                requiresThinkingAsText: false,
                requiresReasoningContentOnAssistantMessages: true,
                thinkingFormat: .deepSeek
            )
        case .openAI:
            return .init(
                supportsDeveloperRole: true,
                supportsReasoningEffort: true,
                supportsUsageInStreaming: true,
                maxTokensField: .maxTokens,
                requiresToolResultName: false,
                requiresAssistantAfterToolResult: false,
                requiresThinkingAsText: false,
                requiresReasoningContentOnAssistantMessages: false,
                thinkingFormat: .openAI
            )
        case .legacyGateway:
            return .init(
                supportsDeveloperRole: false,
                supportsReasoningEffort: false,
                supportsUsageInStreaming: false,
                maxTokensField: .maxTokens,
                requiresToolResultName: false,
                requiresAssistantAfterToolResult: false,
                requiresThinkingAsText: false,
                requiresReasoningContentOnAssistantMessages: false
            )
        }
    }
}

enum OpenAICompatibleWireSerializer {
    static func encode(
        _ request: ModelRequest,
        profile: OpenAICompatibleWireProfile? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(ChatWireSerializer.makeRequest(request))
        let resolved = profile ?? OpenAICompatibleWireProfile.resolve(request.configuration)
        guard var object = try JSONSerialization.jsonObject(with: canonical) as? [String: Any] else {
            throw ModelClientError.invalidResponse
        }
        let compatibility = resolved.compatibilityBaseline.overlaying(
            request.configuration.openAICompatibility
        )
        // `thinking` is a DeepSeek extension. OpenAI uses reasoning_effort;
        // unknown legacy gateways get neither extension by default.
        if compatibility.thinkingFormat != .deepSeek {
            object.removeValue(forKey: "thinking")
        }
        if compatibility.supportsReasoningEffort == false {
            object.removeValue(forKey: "reasoning_effort")
        }
        if compatibility.supportsUsageInStreaming == false {
            object.removeValue(forKey: "stream_options")
        }
        if compatibility.maxTokensField == .maxCompletionTokens,
           let maxTokens = object.removeValue(forKey: "max_tokens") {
            object["max_completion_tokens"] = maxTokens
        }
        if let kwargs = compatibility.chatTemplateKwargs,
           compatibility.thinkingFormat == .chatTemplate
            || compatibility.thinkingFormat == .qwenChatTemplate {
            object["chat_template_kwargs"] = kwargs.mapValues { value -> Any in
                switch value {
                case let .string(value): return value
                case let .number(value): return value
                case let .bool(value): return value
                case .null: return NSNull()
                case let .variable(variable, omitWhenOff):
                    switch variable {
                    case .thinkingEnabled:
                        return request.configuration.reasoningMode != .off
                    case .thinkingEffort:
                        if omitWhenOff == true, request.configuration.reasoningMode == .off {
                            return NSNull()
                        }
                        return request.configuration.reasoningMode.rawValue
                    }
                }
            }
        }
        if var messages = object["messages"] as? [[String: Any]] {
            var toolNames: [String: String] = [:]
            for message in messages {
                guard let calls = message["tool_calls"] as? [[String: Any]] else { continue }
                for call in calls {
                    guard let id = call["id"] as? String,
                          let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String else { continue }
                    toolNames[id] = name
                }
            }
            for index in messages.indices {
                if messages[index]["role"] as? String == "system",
                   compatibility.supportsDeveloperRole == true,
                   request.configuration.reasoningMode != .off,
                   request.configuration.reasoningMode != .providerDefault {
                    messages[index]["role"] = "developer"
                }
                if compatibility.requiresThinkingAsText == true,
                   let reasoning = messages[index].removeValue(forKey: "reasoning_content") as? String,
                   !reasoning.isEmpty {
                    let content = messages[index]["content"] as? String ?? ""
                    messages[index]["content"] = "<thinking>\(reasoning)</thinking>\(content)"
                } else if compatibility.requiresReasoningContentOnAssistantMessages == true,
                          messages[index]["role"] as? String == "assistant",
                          messages[index]["reasoning_content"] == nil {
                    messages[index]["reasoning_content"] = ""
                } else if compatibility.requiresReasoningContentOnAssistantMessages != true {
                    messages[index].removeValue(forKey: "reasoning_content")
                }
                if compatibility.requiresToolResultName == true,
                   messages[index]["role"] as? String == "tool",
                   let callID = messages[index]["tool_call_id"] as? String,
                   let name = toolNames[callID] {
                    messages[index]["name"] = name
                }
                messages[index] = removingNullsFromObject(messages[index])
            }
            if compatibility.requiresAssistantAfterToolResult == true {
                var expanded: [[String: Any]] = []
                expanded.reserveCapacity(messages.count + 2)
                for message in messages {
                    if message["role"] as? String == "user",
                       expanded.last?["role"] as? String == "tool" {
                        expanded.append(["role": "assistant", "content": ""])
                    }
                    expanded.append(message)
                }
                messages = expanded
            }
            object["messages"] = messages
        }
        object = removingNullsFromObject(object)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Tolerate the two legacy spellings used by compatible gateways while
    /// retaining `reasoning_content` as the canonical DeepSeek spelling.
    static func alternateReasoningDelta(in payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first(where: { ($0["index"] as? Int) == 0 })?["delta"] as? [String: Any] else {
            return nil
        }
        for key in ["reasoning", "reasoningContent"] {
            if let value = delta[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func removingNullsFromObject(_ object: [String: Any]) -> [String: Any] {
        object.compactMapValues(removingNullsFromValue)
    }

    private static func removingNullsFromValue(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let object = value as? [String: Any] { return removingNullsFromObject(object) }
        if let array = value as? [Any] { return array.compactMap(removingNullsFromValue) }
        return value
    }
}
