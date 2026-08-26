import Foundation

enum AgentRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
}

/// Why an assistant message ended before a normal model completion. The
/// existing `isIncomplete` flag is intentionally broad for compatibility; UI
/// must use this reason before attributing the interruption to a model limit.
enum AgentMessageIncompleteReason: String, Codable, Sendable, Equatable {
    /// The provider explicitly sent its canonical length finish reason.
    case modelOutputLength = "model_output_length"
    /// The local task or transport was cancelled after visible output arrived.
    case cancelled
}

/// Provider/model provenance plus adapter-private JSON needed to replay one
/// assistant response. This mirrors the upstream model message source while
/// keeping the envelope open for signed-thinking and future provider state.
struct AgentModelSource: Sendable, Equatable {
    let provider: String
    let model: String
    let replayState: JSONValue?

    init(provider: String, model: String, replayState: JSONValue? = nil) {
        self.provider = provider
        self.model = model
        self.replayState = replayState
    }

    init?(jsonValue: JSONValue?) {
        guard let object = jsonValue?.objectValue,
              object["kind"] == .string("model"),
              let provider = object["provider"]?.stringValue,
              !provider.isEmpty,
              let model = object["model"]?.stringValue,
              !model.isEmpty else {
            return nil
        }
        self.provider = provider
        self.model = model
        replayState = object["replayState"]
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string("model"),
            "provider": .string(provider),
            "model": .string(model)
        ]
        if let replayState {
            object["replayState"] = replayState
        }
        return .object(object)
    }
}

enum MessageFeedbackRating: String, Codable, Sendable, Equatable, CaseIterable {
    case positive
    case negative
}

struct MessageFeedback: Codable, Sendable, Equatable {
    static let maximumNoteUTF8Bytes = 4 * 1_024

    var rating: MessageFeedbackRating
    var note: String?
    var version: UUID
    let createdAt: Date
    var updatedAt: Date

    init(
        rating: MessageFeedbackRating,
        note: String? = nil,
        version: UUID = UUID(),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.rating = rating
        self.note = note
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AgentToolCall: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: String
}

enum AgentToolEventStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case awaitingApproval
    case running
    case succeeded
    case failed
    case denied
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .pending, .awaitingApproval, .running:
            false
        case .succeeded, .failed, .denied, .interrupted:
            true
        }
    }
}

enum AgentToolOutputChannel: String, Codable, Sendable, Equatable {
    case stdout
    case stderr
    case progress
    case system
}

struct AgentToolOutputChunk: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let channel: AgentToolOutputChannel
    var text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        channel: AgentToolOutputChannel,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.channel = channel
        self.text = text
        self.createdAt = createdAt
    }
}

struct AgentToolEvent: Identifiable, Codable, Sendable, Equatable {
    static let maximumPersistedOutputBytes = 64 * 1_024

    let id: UUID
    let callID: String
    let name: String
    let arguments: String
    var summary: String
    var status: AgentToolEventStatus
    var output: [AgentToolOutputChunk]
    var result: String?
    var errorMessage: String?
    let createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var children: [AgentToolEvent]

    init(
        id: UUID = UUID(),
        call: AgentToolCall,
        summary: String = "",
        status: AgentToolEventStatus = .pending,
        output: [AgentToolOutputChunk] = [],
        result: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date = .now,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        children: [AgentToolEvent] = []
    ) {
        self.id = id
        callID = call.id
        name = call.name
        arguments = call.arguments
        self.summary = summary
        self.status = status
        self.output = output
        self.result = result
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.children = children
    }

    var call: AgentToolCall {
        AgentToolCall(id: callID, name: name, arguments: arguments)
    }

    mutating func appendOutput(_ chunk: AgentToolOutputChunk) {
        Self.appendOutput(chunk, to: &output)
    }

    /// Shared bounded reducer for live presentation batches and durable tool
    /// events. Keeping one reducer prevents the throttled UI path from having
    /// different truncation or channel-merging semantics.
    static func appendOutput(
        _ chunk: AgentToolOutputChunk,
        to output: inout [AgentToolOutputChunk]
    ) {
        guard !chunk.text.isEmpty else { return }
        let usedBytes = output.reduce(into: 0) { total, item in
            total += item.text.utf8.count
        }
        guard usedBytes < Self.maximumPersistedOutputBytes else { return }

        let remainingBytes = Self.maximumPersistedOutputBytes - usedBytes
        let boundedText = Self.prefix(chunk.text, maximumUTF8Bytes: remainingBytes)
        guard !boundedText.isEmpty else { return }

        if let lastIndex = output.indices.last,
           output[lastIndex].channel == chunk.channel {
            output[lastIndex].text += boundedText
        } else {
            output.append(
                AgentToolOutputChunk(
                    id: chunk.id,
                    channel: chunk.channel,
                    text: boundedText,
                    createdAt: chunk.createdAt
                )
            )
        }

        if boundedText.utf8.count < chunk.text.utf8.count,
           !output.contains(where: { $0.channel == .system && $0.text.contains("output truncated") }) {
            output.append(
                AgentToolOutputChunk(
                    channel: .system,
                    text: "\n[output truncated for local session]\n"
                )
            )
        }
    }

    func containsRecursively(callID candidate: String) -> Bool {
        callID == candidate || children.contains { $0.containsRecursively(callID: candidate) }
    }

    mutating func replaceRecursively(_ replacement: AgentToolEvent) -> Bool {
        if callID == replacement.callID {
            self = replacement
            return true
        }
        for index in children.indices {
            if children[index].replaceRecursively(replacement) {
                return true
            }
        }
        return false
    }

    mutating func appendOutputRecursively(
        callID: String,
        chunk: AgentToolOutputChunk
    ) -> Bool {
        if self.callID == callID {
            appendOutput(chunk)
            return true
        }
        for index in children.indices {
            if children[index].appendOutputRecursively(callID: callID, chunk: chunk) {
                return true
            }
        }
        return false
    }

    mutating func finishNonterminalRecursively(
        status: AgentToolEventStatus,
        message: String,
        at date: Date
    ) {
        if !self.status.isTerminal {
            self.status = status
            errorMessage = message
            finishedAt = date
        }
        for index in children.indices {
            children[index].finishNonterminalRecursively(
                status: status,
                message: message,
                at: date
            )
        }
    }

    private static func prefix(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0, text.utf8.count > maximumUTF8Bytes else {
            return maximumUTF8Bytes > 0 ? text : ""
        }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result
    }
}

struct AgentImageAttachmentRef: Codable, Sendable, Equatable, Hashable {
    let id: UUID
    let path: String
    let mimeType: String
    let byteCount: Int

    init(id: UUID = UUID(), path: String, mimeType: String, byteCount: Int) {
        self.id = id
        self.path = path
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

/// A durable reference to a non-image file copied into private workspace
/// storage. File contents intentionally never enter conversation persistence,
/// trajectories, or a provider request without an explicit provider contract.
struct AgentFileAttachmentRef: Codable, Sendable, Equatable, Hashable {
    let id: UUID
    let path: String
    let mimeType: String
    let byteCount: Int
    let displayName: String
    let expiresAt: Date

    init(
        id: UUID = UUID(),
        path: String,
        mimeType: String,
        byteCount: Int,
        displayName: String,
        expiresAt: Date
    ) {
        self.id = id
        self.path = path
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.displayName = displayName
        self.expiresAt = expiresAt
    }
}

/// Request-local image bytes. This is intentionally not part of AgentMessage
/// persistence or trace payloads; the durable message stores only a workspace
/// attachment reference.
struct ModelImagePayload: Sendable, Equatable {
    let id: UUID
    let mimeType: String
    let data: Data
    /// Provider-owned file reference, when the request was prepared through a
    /// provider Files API. It is intentionally request-local and never
    /// persisted in AgentMessage or trace state.
    let fileID: String?

    init(
        id: UUID,
        mimeType: String,
        data: Data,
        fileID: String? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.data = data
        self.fileID = fileID
    }
}

struct AgentMessage: Identifiable, Codable, Sendable, Equatable {
    static let runtimeContextPluginID = "@deepseek-ai/dsh-system-prompt"

    let id: UUID
    let role: AgentRole
    var content: String
    var reasoning: String?
    var toolCalls: [AgentToolCall]
    var toolCallID: String?
    var toolName: String?
    var isToolError: Bool?
    var isIncomplete: Bool
    var incompleteReason: AgentMessageIncompleteReason?
    var toolEvents: [AgentToolEvent]
    var feedback: MessageFeedback?
    var source: JSONValue?
    var imageAttachments: [AgentImageAttachmentRef]
    var fileAttachments: [AgentFileAttachmentRef]
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case reasoning
        case toolCalls
        case toolCallID
        case toolName
        case isToolError
        case isIncomplete
        case incompleteReason
        case toolEvents
        case feedback
        case source
        case imageAttachments
        case fileAttachments
        case createdAt
    }

    init(
        id: UUID = UUID(),
        role: AgentRole,
        content: String,
        reasoning: String? = nil,
        toolCalls: [AgentToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        isToolError: Bool? = nil,
        isIncomplete: Bool = false,
        incompleteReason: AgentMessageIncompleteReason? = nil,
        toolEvents: [AgentToolEvent] = [],
        feedback: MessageFeedback? = nil,
        source: JSONValue? = nil,
        imageAttachments: [AgentImageAttachmentRef] = [],
        fileAttachments: [AgentFileAttachmentRef] = [],
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.isToolError = isToolError
        self.isIncomplete = isIncomplete
        self.incompleteReason = incompleteReason
        self.toolEvents = toolEvents
        self.feedback = feedback
        self.source = source
        self.imageAttachments = imageAttachments
        self.fileAttachments = fileAttachments
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(AgentRole.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        toolCalls = try container.decodeIfPresent([AgentToolCall].self, forKey: .toolCalls) ?? []
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        isToolError = try container.decodeIfPresent(Bool.self, forKey: .isToolError)
        isIncomplete = try container.decodeIfPresent(Bool.self, forKey: .isIncomplete) ?? false
        incompleteReason = try container.decodeIfPresent(
            AgentMessageIncompleteReason.self,
            forKey: .incompleteReason
        )
        toolEvents = try container.decodeIfPresent([AgentToolEvent].self, forKey: .toolEvents) ?? []
        feedback = try container.decodeIfPresent(MessageFeedback.self, forKey: .feedback)
        source = try container.decodeIfPresent(JSONValue.self, forKey: .source)
        imageAttachments = try container.decodeIfPresent(
            [AgentImageAttachmentRef].self,
            forKey: .imageAttachments
        ) ?? []
        fileAttachments = try container.decodeIfPresent(
            [AgentFileAttachmentRef].self,
            forKey: .fileAttachments
        ) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(isToolError, forKey: .isToolError)
        try container.encode(isIncomplete, forKey: .isIncomplete)
        try container.encodeIfPresent(incompleteReason, forKey: .incompleteReason)
        try container.encode(toolEvents, forKey: .toolEvents)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(imageAttachments, forKey: .imageAttachments)
        try container.encode(fileAttachments, forKey: .fileAttachments)
        try container.encode(createdAt, forKey: .createdAt)
    }

    var isRuntimeContextSnapshot: Bool {
        guard role == .user,
              let envelope = source?.objectValue else { return false }
        return envelope["kind"] == .string("plugin")
            && envelope["plugin"] == .string(Self.runtimeContextPluginID)
    }

    /// Context messages are durable and model-visible but must not masquerade
    /// as chat rows written by the user. Direct user messages either have no
    /// source (legacy/local snapshot) or the canonical `{ kind: "user" }`
    /// source emitted by the trajectory.
    var isHiddenContextMessage: Bool {
        guard role == .user, let envelope = source?.objectValue else { return false }
        return envelope["kind"] != .string("user")
    }

    var isChatVisible: Bool { !isHiddenContextMessage }

    static func user(
        _ text: String,
        imageAttachments: [AgentImageAttachmentRef] = [],
        fileAttachments: [AgentFileAttachmentRef] = []
    ) -> AgentMessage {
        AgentMessage(
            role: .user,
            content: text,
            imageAttachments: imageAttachments,
            fileAttachments: fileAttachments
        )
    }

    static func assistant(
        _ text: String,
        reasoning: String? = nil,
        toolCalls: [AgentToolCall] = [],
        toolEvents: [AgentToolEvent] = [],
        isIncomplete: Bool = false,
        incompleteReason: AgentMessageIncompleteReason? = nil,
        source: JSONValue? = nil
    ) -> AgentMessage {
        AgentMessage(
            role: .assistant,
            content: text,
            reasoning: reasoning,
            toolCalls: toolCalls,
            isIncomplete: isIncomplete,
            incompleteReason: incompleteReason,
            toolEvents: toolEvents,
            source: source
        )
    }

    var modelSource: AgentModelSource? {
        AgentModelSource(jsonValue: source)
    }

    /// Only this reason is evidence that a provider, rather than the app UI,
    /// diagnostics exporter, tool preview, or a local cancellation, truncated
    /// the model response.
    var isModelOutputLengthTruncated: Bool {
        incompleteReason == .modelOutputLength
    }

    static func tool(
        callID: String,
        name: String? = nil,
        content: String,
        isError: Bool? = nil
    ) -> AgentMessage {
        AgentMessage(
            role: .tool,
            content: content,
            toolCallID: callID,
            toolName: name,
            isToolError: isError
        )
    }
}

struct ConversationRerunPreparation: Sendable, Equatable {
    let messages: [AgentMessage]
    let initialUserMessage: AgentMessage
    let removedMessageCount: Int
}

enum ConversationRerunError: LocalizedError, Sendable, Equatable {
    case messageNotFound
    case notUserMessage
    case emptyReplacement

    var errorDescription: String? {
        switch self {
        case .messageNotFound:
            "找不到要重新运行的消息。"
        case .notUserMessage:
            "只能从用户消息重新运行。"
        case .emptyReplacement:
            "编辑后的消息不能为空。"
        }
    }
}

enum ConversationRerunPlanner {
    static func prepare(
        messages: [AgentMessage],
        messageID: UUID,
        replacementText: String? = nil
    ) throws -> ConversationRerunPreparation {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw ConversationRerunError.messageNotFound
        }
        guard messages[index].role == .user else {
            throw ConversationRerunError.notUserMessage
        }

        var selected = messages[index]
        if let replacementText {
            let trimmed = replacementText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ConversationRerunError.emptyReplacement
            }
            selected.content = trimmed
        }
        var branch = Array(messages.prefix(index + 1))
        branch[index] = selected
        return ConversationRerunPreparation(
            messages: branch,
            initialUserMessage: selected,
            removedMessageCount: messages.count - branch.count
        )
    }
}
