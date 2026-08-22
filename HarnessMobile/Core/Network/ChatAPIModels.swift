import Foundation

struct ChatCompletionsRequest: Encodable, Sendable {
    let model: String
    let messages: [ChatRequestMessage]
    let tools: [ChatRequestTool]?
    let stream = true
    let streamOptions = StreamOptions(includeUsage: true)
    let thinking: Thinking?
    let reasoningEffort: String?
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case stream
        case streamOptions = "stream_options"
        case thinking
        case reasoningEffort = "reasoning_effort"
        case maxTokens = "max_tokens"
    }

    struct StreamOptions: Encodable, Sendable {
        let includeUsage: Bool

        enum CodingKeys: String, CodingKey {
            case includeUsage = "include_usage"
        }
    }

    struct Thinking: Encodable, Sendable {
        let type: String
    }
}

struct ChatRequestMessage: Encodable, Sendable {
    let role: String
    let content: String?
    let imageParts: [ImagePart]?
    let reasoningContent: String?
    let toolCalls: [ChatRequestToolCall]?
    let toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    struct ImagePart: Encodable, Sendable {
        let type: String
        let text: String?
        let imageURL: ImageURL?
        let fileID: String?

        struct ImageURL: Encodable, Sendable {
            let url: String
        }

        static func text(_ value: String) -> ImagePart {
            ImagePart(type: "text", text: value, imageURL: nil, fileID: nil)
        }

        static func image(url: String) -> ImagePart {
            ImagePart(type: "image_url", text: nil, imageURL: .init(url: url), fileID: nil)
        }

        static func file(id: String) -> ImagePart {
            ImagePart(type: "file", text: nil, imageURL: nil, fileID: id)
        }

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
            case fileID = "file_id"
        }
    }

    init(
        role: String,
        content: String?,
        reasoningContent: String?,
        toolCalls: [ChatRequestToolCall]?,
        toolCallID: String?,
        imageParts: [ImagePart]? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.imageParts = imageParts
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let imageParts, !imageParts.isEmpty {
            try container.encode(imageParts, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

struct ChatRequestToolCall: Encodable, Sendable {
    let id: String
    let type = "function"
    let function: Function

    struct Function: Encodable, Sendable {
        let name: String
        let arguments: String
    }
}

struct ChatRequestTool: Encodable, Sendable {
    let type = "function"
    let function: Function

    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: JSONValue
    }
}

struct ChatStreamChunk: Decodable, Sendable {
    let choices: [Choice]?
    let usage: Usage?

    struct Choice: Decodable, Sendable {
        let index: Int
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable, Sendable {
        let content: String?
        let reasoningContent: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable, Sendable {
        let index: Int
        let id: String?
        let type: String?
        let function: Function?

        struct Function: Decodable, Sendable {
            let name: String?
            let arguments: String?
        }
    }

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let completionTokens: Int?
        let totalTokens: Int?
        let promptCacheHitTokens: Int?
        let promptCacheMissTokens: Int?
        let promptTokensDetails: PromptTokensDetails?
        let completionTokensDetails: CompletionTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
            case promptTokensDetails = "prompt_tokens_details"
            case completionTokensDetails = "completion_tokens_details"
        }

        struct PromptTokensDetails: Decodable, Sendable {
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        struct CompletionTokensDetails: Decodable, Sendable {
            let reasoningTokens: Int?

            enum CodingKeys: String, CodingKey {
                case reasoningTokens = "reasoning_tokens"
            }
        }
    }
}

struct ChatAPIErrorEnvelope: Decodable, Sendable {
    let error: APIError

    struct APIError: Decodable, Sendable {
        let message: String
        let type: String?
        let code: JSONValue?
    }
}

enum ChatWireSerializer {
    static func makeRequest(_ request: ModelRequest) -> ChatCompletionsRequest {
        let configuration = request.configuration
        return ChatCompletionsRequest(
            model: configuration.model,
            messages: makeMessages(
                systemPrompt: request.systemPrompt,
                messages: request.messages,
                imagePayloads: request.imagePayloads,
                replayEmptyReasoningForToolCalls: configuration.requiresDeepSeekReasoningReplay
            ),
            tools: request.tools.isEmpty ? nil : request.tools.map {
                ChatRequestTool(
                    function: .init(
                        name: $0.name,
                        description: $0.description,
                        parameters: $0.parameters
                    )
                )
            },
            thinking: makeThinking(configuration.reasoningMode),
            reasoningEffort: makeReasoningEffort(configuration.reasoningMode),
            maxTokens: configuration.maxOutputTokens
        )
    }

    static func makeMessages(
        systemPrompt: String,
        messages: [AgentMessage],
        imagePayloads: [ModelImagePayload] = [],
        replayEmptyReasoningForToolCalls: Bool = false
    ) -> [ChatRequestMessage] {
        var result = [
            ChatRequestMessage(
                role: "system",
                content: systemPrompt,
                reasoningContent: nil,
                toolCalls: nil,
                toolCallID: nil
            )
        ]
        result.reserveCapacity(messages.count + 1)
        let payloads = Dictionary(uniqueKeysWithValues: imagePayloads.map { ($0.id, $0) })

        for message in messages {
            switch message.role {
            case .user:
                let attachments = message.imageAttachments.compactMap { ref -> ChatRequestMessage.ImagePart? in
                    guard let payload = payloads[ref.id] else { return nil }
                    if let fileID = payload.fileID, !fileID.isEmpty {
                        return .file(id: fileID)
                    }
                    return .image(url: "data:\(payload.mimeType);base64,\(payload.data.base64EncodedString())")
                }
                let omittedCount = max(0, message.imageAttachments.count - attachments.count)
                let parts: [ChatRequestMessage.ImagePart]?
                if message.imageAttachments.isEmpty {
                    parts = nil
                } else {
                    parts = [.text(message.content)]
                        + attachments
                        + (omittedCount > 0
                            ? [.text("[\(omittedCount) earlier image(s) omitted because the request image limit was reached.]")]
                            : [])
                }
                result.append(
                    ChatRequestMessage(
                        role: "user",
                        content: message.content,
                        reasoningContent: nil,
                        toolCalls: nil,
                        toolCallID: nil,
                        imageParts: parts
                    )
                )
            case .assistant:
                let toolCalls = message.toolCalls.isEmpty ? nil : message.toolCalls.map {
                    ChatRequestToolCall(
                        id: $0.id,
                        function: .init(name: $0.name, arguments: $0.arguments)
                    )
                }
                result.append(
                    ChatRequestMessage(
                        role: "assistant",
                        content: message.content,
                        reasoningContent: message.reasoning.flatMap { reasoning in
                            reasoning.isEmpty ? nil : reasoning
                        } ?? (!message.toolCalls.isEmpty && replayEmptyReasoningForToolCalls
                            ? ""
                            : nil),
                        toolCalls: toolCalls,
                        toolCallID: nil
                    )
                )
            case .tool:
                result.append(
                    ChatRequestMessage(
                        role: "tool",
                        content: message.content.isEmpty ? "(no output)" : message.content,
                        reasoningContent: nil,
                        toolCalls: nil,
                        toolCallID: message.toolCallID
                    )
                )
            }
        }
        return result
    }

    private static func makeThinking(
        _ mode: ReasoningMode
    ) -> ChatCompletionsRequest.Thinking? {
        switch mode {
        case .providerDefault:
            return nil
        case .off:
            return .init(type: "disabled")
        case .low, .high, .max:
            return .init(type: "enabled")
        }
    }

    private static func makeReasoningEffort(_ mode: ReasoningMode) -> String? {
        switch mode {
        case .low:
            return "low"
        case .high:
            return "high"
        case .max:
            return "max"
        case .providerDefault, .off:
            return nil
        }
    }
}
