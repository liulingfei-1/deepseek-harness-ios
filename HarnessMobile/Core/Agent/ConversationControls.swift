import Foundation

enum ConversationInteractionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case agent
    case plan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent:
            "Agent"
        case .plan:
            "Plan"
        }
    }
}

enum ToolPermissionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readOnly:
            "只读"
        case .workspaceWrite:
            "工作区写入"
        case .dangerFullAccess:
            "完全访问"
        }
    }

    var compactTitle: String {
        switch self {
        case .readOnly:
            "只读"
        case .workspaceWrite:
            "写入"
        case .dangerFullAccess:
            "完全"
        }
    }

    var systemImage: String {
        switch self {
        case .readOnly:
            "lock"
        case .workspaceWrite:
            "lock.open"
        case .dangerFullAccess:
            "exclamationmark.shield"
        }
    }
}

enum QueuedInputDisposition: String, Codable, Sendable {
    case queued
    case steer
}

struct QueuedAgentInput: Identifiable, Codable, Sendable, Equatable {
    static let maximumTextUTF8Bytes = 64 * 1_024

    let id: UUID
    var text: String
    var disposition: QueuedInputDisposition
    let createdAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        disposition: QueuedInputDisposition = .queued,
        createdAt: Date = .now
    ) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= Self.maximumTextUTF8Bytes else {
            throw ConversationControlError.invalidQueuedInput
        }
        self.id = id
        self.text = normalized
        self.disposition = disposition
        self.createdAt = createdAt
    }
}

struct ConversationControlState: Codable, Sendable, Equatable {
    static let maximumQueuedInputs = 32

    var interactionMode: ConversationInteractionMode
    var permissionMode: ToolPermissionMode
    var agentPresetID: String
    private(set) var isAgentPresetLocked: Bool
    var modelConfiguration: AgentConfiguration?
    var contextLimitUTF8Bytes: Int?
    private(set) var queuedInputs: [QueuedAgentInput]

    init(
        interactionMode: ConversationInteractionMode = .agent,
        permissionMode: ToolPermissionMode = .workspaceWrite,
        agentPresetID: String = AgentPresetRegistry.defaultID,
        isAgentPresetLocked: Bool = false,
        modelConfiguration: AgentConfiguration? = nil,
        contextLimitUTF8Bytes: Int? = nil,
        queuedInputs: [QueuedAgentInput] = []
    ) {
        self.interactionMode = interactionMode
        self.permissionMode = permissionMode
        self.agentPresetID = AgentPresetIdentifier.isValid(agentPresetID)
            ? agentPresetID
            : AgentPresetRegistry.defaultID
        self.isAgentPresetLocked = isAgentPresetLocked
        self.modelConfiguration = modelConfiguration
        self.contextLimitUTF8Bytes = contextLimitUTF8Bytes
        self.queuedInputs = Array(queuedInputs.prefix(Self.maximumQueuedInputs))
    }

    private enum CodingKeys: String, CodingKey {
        case interactionMode
        case permissionMode
        case agentPresetID
        case isAgentPresetLocked
        case modelConfiguration
        case contextLimitUTF8Bytes
        case queuedInputs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interactionMode = try container.decodeIfPresent(
            ConversationInteractionMode.self,
            forKey: .interactionMode
        ) ?? .agent
        permissionMode = try container.decodeIfPresent(
            ToolPermissionMode.self,
            forKey: .permissionMode
        ) ?? .workspaceWrite
        let decodedPresetID = try container.decodeIfPresent(
            String.self,
            forKey: .agentPresetID
        ) ?? AgentPresetRegistry.defaultID
        agentPresetID = AgentPresetIdentifier.isValid(decodedPresetID)
            ? decodedPresetID
            : AgentPresetRegistry.defaultID
        isAgentPresetLocked = try container.decodeIfPresent(
            Bool.self,
            forKey: .isAgentPresetLocked
        ) ?? false
        modelConfiguration = try container.decodeIfPresent(
            AgentConfiguration.self,
            forKey: .modelConfiguration
        )
        contextLimitUTF8Bytes = try container.decodeIfPresent(
            Int.self,
            forKey: .contextLimitUTF8Bytes
        )
        let decodedQueue = try container.decodeIfPresent(
            [QueuedAgentInput].self,
            forKey: .queuedInputs
        ) ?? []
        queuedInputs = Array(decodedQueue.prefix(Self.maximumQueuedInputs))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encode(permissionMode, forKey: .permissionMode)
        try container.encode(agentPresetID, forKey: .agentPresetID)
        try container.encode(isAgentPresetLocked, forKey: .isAgentPresetLocked)
        try container.encodeIfPresent(modelConfiguration, forKey: .modelConfiguration)
        try container.encodeIfPresent(contextLimitUTF8Bytes, forKey: .contextLimitUTF8Bytes)
        try container.encode(queuedInputs, forKey: .queuedInputs)
    }

    mutating func selectAgentPreset(
        id: String,
        defaultPermissionMode: ToolPermissionMode
    ) throws {
        guard AgentPresetIdentifier.isValid(id) else {
            throw AgentPresetError.invalidID(id)
        }
        agentPresetID = id
        permissionMode = defaultPermissionMode
        interactionMode = .agent
    }

    mutating func lockAgentPreset() {
        isAgentPresetLocked = true
    }

    mutating func unlockAgentPresetForBlankConversation() {
        isAgentPresetLocked = false
    }

    mutating func enqueue(
        _ text: String,
        disposition: QueuedInputDisposition = .queued
    ) throws -> QueuedAgentInput {
        guard queuedInputs.count < Self.maximumQueuedInputs else {
            throw ConversationControlError.queueFull
        }
        let input = try QueuedAgentInput(text: text, disposition: disposition)
        if disposition == .steer {
            let firstNormalIndex = queuedInputs.firstIndex { $0.disposition == .queued }
                ?? queuedInputs.endIndex
            queuedInputs.insert(input, at: firstNormalIndex)
        } else {
            queuedInputs.append(input)
        }
        return input
    }

    mutating func update(id: UUID, text: String) throws {
        guard let index = queuedInputs.firstIndex(where: { $0.id == id }) else {
            throw ConversationControlError.queuedInputNotFound
        }
        let replacement = try QueuedAgentInput(
            id: queuedInputs[index].id,
            text: text,
            disposition: queuedInputs[index].disposition,
            createdAt: queuedInputs[index].createdAt
        )
        queuedInputs[index] = replacement
    }

    mutating func setDisposition(
        id: UUID,
        disposition: QueuedInputDisposition
    ) throws {
        guard let index = queuedInputs.firstIndex(where: { $0.id == id }) else {
            throw ConversationControlError.queuedInputNotFound
        }
        guard queuedInputs[index].disposition != disposition else { return }

        var input = queuedInputs.remove(at: index)
        input.disposition = disposition
        if disposition == .steer {
            let firstNormalIndex = queuedInputs.firstIndex { $0.disposition == .queued }
                ?? queuedInputs.endIndex
            queuedInputs.insert(input, at: firstNormalIndex)
        } else {
            queuedInputs.append(input)
        }
    }

    mutating func steerAll() {
        for index in queuedInputs.indices {
            queuedInputs[index].disposition = .steer
        }
    }

    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        guard let index = queuedInputs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        queuedInputs.remove(at: index)
        return true
    }

    mutating func popNext() -> QueuedAgentInput? {
        guard !queuedInputs.isEmpty else { return nil }
        return queuedInputs.removeFirst()
    }

    mutating func removeAllQueuedInputs() {
        queuedInputs.removeAll(keepingCapacity: false)
    }
}

enum ConversationControlError: LocalizedError, Sendable, Equatable {
    case invalidQueuedInput
    case queueFull
    case queuedInputNotFound

    var errorDescription: String? {
        switch self {
        case .invalidQueuedInput:
            "排队输入不能为空或超过 64 KiB。"
        case .queueFull:
            "当前会话最多排队 32 条输入。"
        case .queuedInputNotFound:
            "找不到要编辑的排队输入。"
        }
    }
}
