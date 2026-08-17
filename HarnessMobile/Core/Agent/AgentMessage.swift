import Foundation

enum AgentRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
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

struct AgentMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let role: AgentRole
    var content: String
    var reasoning: String?
    var toolCalls: [AgentToolCall]
    var toolCallID: String?
    var toolName: String?
    var isToolError: Bool?
    var isIncomplete: Bool
    var toolEvents: [AgentToolEvent]
    var feedback: MessageFeedback?
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
        case toolEvents
        case feedback
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
        toolEvents: [AgentToolEvent] = [],
        feedback: MessageFeedback? = nil,
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
        self.toolEvents = toolEvents
        self.feedback = feedback
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
        toolEvents = try container.decodeIfPresent([AgentToolEvent].self, forKey: .toolEvents) ?? []
        feedback = try container.decodeIfPresent(MessageFeedback.self, forKey: .feedback)
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
        try container.encode(toolEvents, forKey: .toolEvents)
        try container.encodeIfPresent(feedback, forKey: .feedback)
        try container.encode(createdAt, forKey: .createdAt)
    }

    static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, content: text)
    }

    static func assistant(
        _ text: String,
        reasoning: String? = nil,
        toolCalls: [AgentToolCall] = [],
        toolEvents: [AgentToolEvent] = [],
        isIncomplete: Bool = false
    ) -> AgentMessage {
        AgentMessage(
            role: .assistant,
            content: text,
            reasoning: reasoning,
            toolCalls: toolCalls,
            isIncomplete: isIncomplete,
            toolEvents: toolEvents
        )
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
