import Foundation

struct AnthropicMessagesRequest: Encodable, Sendable {
    let model: String
    let system: String
    let messages: [Message]
    let tools: [Tool]?
    let maxTokens: Int
    let stream = true

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case tools
        case maxTokens = "max_tokens"
        case stream
    }

    struct Message: Encodable, Sendable {
        let role: String
        let content: [ContentBlock]
    }

    struct Tool: Encodable, Sendable {
        let name: String
        let description: String
        let inputSchema: JSONValue

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case inputSchema = "input_schema"
        }
    }

    enum ContentBlock: Encodable, Sendable {
        case text(String)
        case image(mediaType: String, data: String)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(toolUseID: String, content: String, isError: Bool?)

        private struct ImageSource: Encodable, Sendable {
            let type = "base64"
            let mediaType: String
            let data: String

            private enum CodingKeys: String, CodingKey {
                case type
                case mediaType = "media_type"
                case data
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case source
            case id
            case name
            case input
            case toolUseID = "tool_use_id"
            case content
            case isError = "is_error"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .image(mediaType, data):
                try container.encode("image", forKey: .type)
                try container.encode(
                    ImageSource(mediaType: mediaType, data: data),
                    forKey: .source
                )
            case let .toolUse(id, name, input):
                try container.encode("tool_use", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(input, forKey: .input)
            case let .toolResult(toolUseID, content, isError):
                try container.encode("tool_result", forKey: .type)
                try container.encode(toolUseID, forKey: .toolUseID)
                try container.encode(content, forKey: .content)
                try container.encodeIfPresent(isError, forKey: .isError)
            }
        }
    }
}

enum AnthropicMessagesWireError: LocalizedError, Sendable, Equatable {
    case invalidToolArguments(String)
    case missingToolCallID
    case unsupportedImageRole(String)
    case unsupportedImageMIME(String)

    var errorDescription: String? {
        switch self {
        case let .invalidToolArguments(toolName):
            return "工具 \(toolName) 的参数不是 Anthropic Messages 可接受的 JSON 对象。"
        case .missingToolCallID:
            return "工具结果缺少对应的 Tool Use ID。"
        case let .unsupportedImageRole(role):
            return "Anthropic Messages 不能在 \(role) 历史消息中携带图片。"
        case let .unsupportedImageMIME(mimeType):
            return "Anthropic Messages 不支持图片类型 \(mimeType)。"
        }
    }
}

enum AnthropicWireSerializer {
    static func encodeRequest(_ request: ModelRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(makeRequest(request))
    }

    static func makeRequest(_ request: ModelRequest) throws -> AnthropicMessagesRequest {
        AnthropicMessagesRequest(
            model: request.configuration.model,
            system: request.systemPrompt,
            messages: try makeMessages(
                request.messages,
                imagePayloads: request.imagePayloads
            ),
            tools: request.tools.isEmpty ? nil : request.tools.map {
                AnthropicMessagesRequest.Tool(
                    name: $0.name,
                    description: $0.description,
                    inputSchema: $0.parameters
                )
            },
            maxTokens: request.configuration.maxOutputTokens
        )
    }

    static func makeMessages(
        _ messages: [AgentMessage],
        imagePayloads: [ModelImagePayload] = []
    ) throws -> [AnthropicMessagesRequest.Message] {
        var result: [AnthropicMessagesRequest.Message] = []
        var pendingToolResults: [AnthropicMessagesRequest.ContentBlock] = []
        let payloads = Dictionary(uniqueKeysWithValues: imagePayloads.map { ($0.id, $0) })

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            result.append(.init(role: "user", content: pendingToolResults))
            pendingToolResults.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if message.role != .user, !message.imageAttachments.isEmpty {
                throw AnthropicMessagesWireError.unsupportedImageRole(message.role.rawValue)
            }
            switch message.role {
            case .tool:
                guard let toolCallID = message.toolCallID, !toolCallID.isEmpty else {
                    throw AnthropicMessagesWireError.missingToolCallID
                }
                pendingToolResults.append(
                    .toolResult(
                        toolUseID: toolCallID,
                        content: message.content.isEmpty ? "(no output)" : message.content,
                        isError: message.isToolError
                    )
                )
            case .user:
                flushToolResults()
                var blocks: [AnthropicMessagesRequest.ContentBlock] = []
                if !message.content.isEmpty || message.imageAttachments.isEmpty {
                    blocks.append(.text(message.content))
                }
                var omittedImages = 0
                for reference in message.imageAttachments {
                    guard let payload = payloads[reference.id], !payload.data.isEmpty else {
                        omittedImages += 1
                        continue
                    }
                    let mimeType = payload.mimeType.lowercased()
                    guard Self.supportedImageMIMETypes.contains(mimeType) else {
                        throw AnthropicMessagesWireError.unsupportedImageMIME(payload.mimeType)
                    }
                    blocks.append(
                        .image(
                            mediaType: mimeType,
                            data: payload.data.base64EncodedString()
                        )
                    )
                }
                if omittedImages > 0 {
                    blocks.append(
                        .text(
                            "[\(omittedImages) earlier image(s) omitted because the request image limit was reached.]"
                        )
                    )
                }
                result.append(
                    .init(
                        role: "user",
                        content: blocks
                    )
                )
            case .assistant:
                flushToolResults()
                var blocks: [AnthropicMessagesRequest.ContentBlock] = []
                if !message.content.isEmpty {
                    blocks.append(.text(message.content))
                }
                for call in message.toolCalls {
                    blocks.append(
                        .toolUse(
                            id: call.id,
                            name: call.name,
                            input: try toolInput(call)
                        )
                    )
                }
                if !blocks.isEmpty {
                    result.append(.init(role: "assistant", content: blocks))
                }
            }
        }
        flushToolResults()
        return result
    }

    private static let supportedImageMIMETypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp"
    ]

    private static func toolInput(_ call: AgentToolCall) throws -> JSONValue {
        guard let data = call.arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else {
            throw AnthropicMessagesWireError.invalidToolArguments(call.name)
        }
        return value
    }
}

struct AnthropicStreamDecoder: Sendable {
    private static let maximumReportedTokenCount = 100_000_000

    private var inputTokens = 0
    private var outputTokens = 0
    private var cacheCreationInputTokens = 0
    private var cacheReadInputTokens = 0
    private var thinkingTokens: Int?
    private var emittedUsage = false

    static func isMessageStop(_ payload: String) -> Bool {
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AnthropicEventType.self, from: data) else {
            return false
        }
        return envelope.type == "message_stop"
    }

    mutating func decodeEvents(_ payload: String) throws -> [LLMStreamEvent] {
        guard payload.utf8.count <= 1_048_576 else {
            throw ModelClientError.eventTooLarge
        }
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AnthropicStreamEnvelope.self, from: data) else {
            throw ModelClientError.malformedEvent
        }

        switch envelope.type {
        case "message_start":
            if let usage = envelope.message?.usage {
                try merge(usage)
            }
            return []
        case "content_block_start":
            guard let index = envelope.index,
                  let block = envelope.contentBlock else {
                throw ModelClientError.malformedEvent
            }
            switch block.type {
            case "text":
                return block.text.map { $0.isEmpty ? [] : [.text($0)] } ?? []
            case "thinking":
                return block.thinking.map { $0.isEmpty ? [] : [.reasoning($0)] } ?? []
            case "tool_use":
                guard let id = block.id, let name = block.name else {
                    throw ModelClientError.malformedEvent
                }
                return [
                    .toolCallDelta(
                        index: index,
                        id: id,
                        type: "function",
                        name: name,
                        arguments: try initialToolInput(block.input)
                    )
                ]
            default:
                return []
            }
        case "content_block_delta":
            guard let index = envelope.index,
                  let delta = envelope.delta else {
                throw ModelClientError.malformedEvent
            }
            switch delta.type {
            case "text_delta":
                return delta.text.map { $0.isEmpty ? [] : [.text($0)] } ?? []
            case "thinking_delta":
                return delta.thinking.map { $0.isEmpty ? [] : [.reasoning($0)] } ?? []
            case "input_json_delta":
                return [
                    .toolCallDelta(
                        index: index,
                        id: nil,
                        type: nil,
                        name: nil,
                        arguments: delta.partialJSON ?? ""
                    )
                ]
            case "signature_delta", "citations_delta":
                return []
            default:
                return []
            }
        case "message_delta":
            if let usage = envelope.usage {
                try merge(usage)
            }
            var events: [LLMStreamEvent] = []
            if let usageEvent = try currentUsageEvent() {
                emittedUsage = true
                events.append(usageEvent)
            }
            if let stopReason = envelope.delta?.stopReason {
                events.append(.finish(Self.finishReason(stopReason)))
            }
            return events
        case "message_stop":
            guard !emittedUsage, let usage = try currentUsageEvent() else { return [] }
            emittedUsage = true
            return [usage]
        case "error":
            throw ModelClientError.providerStreamFailure(
                code: envelope.error?.type,
                message: envelope.error?.message ?? "Anthropic 流式响应失败。"
            )
        case "ping", "content_block_stop":
            return []
        default:
            return []
        }
    }

    private mutating func merge(_ usage: AnthropicStreamEnvelope.Usage) throws {
        if let value = usage.inputTokens {
            inputTokens = value
        }
        if let value = usage.outputTokens {
            outputTokens = value
        }
        if let value = usage.cacheCreationInputTokens {
            cacheCreationInputTokens = value
        }
        if let value = usage.cacheReadInputTokens {
            cacheReadInputTokens = value
        }
        if let value = usage.thinkingTokens {
            thinkingTokens = value
        }
        let values = [
            inputTokens,
            outputTokens,
            cacheCreationInputTokens,
            cacheReadInputTokens,
            thinkingTokens ?? 0,
        ]
        guard values.allSatisfy({ (0...Self.maximumReportedTokenCount).contains($0) }) else {
            throw ModelClientError.invalidUsage
        }
    }

    private func currentUsageEvent() throws -> LLMStreamEvent? {
        guard inputTokens > 0 || outputTokens > 0
                || cacheCreationInputTokens > 0 || cacheReadInputTokens > 0 else {
            return nil
        }
        let prompt = try checkedSum(
            inputTokens,
            cacheCreationInputTokens,
            cacheReadInputTokens
        )
        let total = try checkedSum(prompt, outputTokens)
        return .usage(
            ModelTokenUsage(
                promptTokens: prompt,
                completionTokens: outputTokens,
                totalTokens: total,
                cachedPromptTokens: cacheReadInputTokens > 0 ? cacheReadInputTokens : nil,
                reasoningTokens: thinkingTokens
            )
        )
    }

    private func checkedSum(_ values: Int...) throws -> Int {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow, next <= Self.maximumReportedTokenCount else {
                throw ModelClientError.invalidUsage
            }
            total = next
        }
        return total
    }

    private func initialToolInput(_ input: JSONValue?) throws -> String {
        guard let input else { return "" }
        if case let .object(values) = input, values.isEmpty {
            return ""
        }
        let data = try JSONEncoder().encode(input)
        return String(decoding: data, as: UTF8.self)
    }

    private static func finishReason(_ value: String) -> ModelFinishReason {
        switch value {
        case "end_turn", "stop_sequence", "pause_turn", "refusal":
            return .stop
        case "tool_use":
            return .toolCalls
        case "max_tokens", "model_context_window_exceeded":
            return .length
        default:
            return .unknown
        }
    }
}

private struct AnthropicEventType: Decodable {
    let type: String
}

private struct AnthropicStreamEnvelope: Decodable {
    let type: String
    let index: Int?
    let contentBlock: ContentBlock?
    let delta: Delta?
    let message: Message?
    let usage: Usage?
    let error: APIError?

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case contentBlock = "content_block"
        case delta
        case message
        case usage
        case error
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let thinking: String?
        let id: String?
        let name: String?
        let input: JSONValue?
    }

    struct Delta: Decodable {
        let type: String?
        let text: String?
        let thinking: String?
        let partialJSON: String?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case thinking
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    struct Message: Decodable {
        let usage: Usage?
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?
        let thinkingTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case thinkingTokens = "thinking_tokens"
        }
    }

    struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}
