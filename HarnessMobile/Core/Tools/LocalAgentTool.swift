import Foundation

enum ToolRisk: String, Codable, Sendable {
    case pure
    case localState
    case sensitiveRead
    case sideEffect
    case destructive

    var requiresApproval: Bool {
        switch self {
        case .pure, .localState:
            false
        case .sensitiveRead, .sideEffect, .destructive:
            true
        }
    }

    var title: String {
        switch self {
        case .pure:
            "只读计算"
        case .localState:
            "本地状态"
        case .sensitiveRead:
            "敏感读取"
        case .sideEffect:
            "本机操作"
        case .destructive:
            "危险操作"
        }
    }
}

enum ToolPermissionDecision: Sendable, Equatable {
    case allow
    case ask
    case deny
}

extension ToolPermissionMode {
    func decision(for risk: ToolRisk) -> ToolPermissionDecision {
        switch self {
        case .readOnly:
            switch risk {
            case .pure, .localState:
                .allow
            case .sensitiveRead:
                .ask
            case .sideEffect, .destructive:
                .deny
            }
        case .workspaceWrite:
            switch risk {
            case .pure, .localState:
                .allow
            case .sensitiveRead, .sideEffect, .destructive:
                .ask
            }
        case .dangerFullAccess:
            .allow
        }
    }
}

protocol LocalAgentTool: Sendable {
    var definition: ModelToolDefinition { get }
    var risk: ToolRisk { get }
    func validate(arguments: [String: JSONValue]) throws
    func summary(arguments: [String: JSONValue]) -> String
    /// Matches DSH's fail-closed `isConcurrencySafe` tool metadata.
    /// Only an explicit `true` lets sibling calls overlap.
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool
    /// Stable, tool-owned resource identities used to prevent conflicting calls
    /// from overlapping even when both are otherwise concurrency-safe.
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String>
    /// Stable resource identities used to scope a durable user approval. Tools
    /// should omit command contents and secrets while retaining the boundary
    /// the user is trusting, such as one workspace path or one sandbox.
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String>
    func execute(arguments: [String: JSONValue]) async throws -> String
    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String
}

extension LocalAgentTool {
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        false
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        []
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let resources = try concurrencyResources(arguments: arguments)
        return resources.isEmpty ? ["tool"] : resources
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try await execute(arguments: arguments)
    }
}

enum ToolApprovalScopeError: LocalizedError, Sendable, Equatable {
    case invalidToolName
    case invalidModelDestination
    case invalidResource
    case tooManyResources
    case tooManyGrants

    var errorDescription: String? {
        switch self {
        case .invalidToolName:
            "工具授权包含无效的工具名称。"
        case .invalidModelDestination:
            "工具授权包含无效的模型 API 来源。"
        case .invalidResource:
            "工具授权包含无效的资源范围。"
        case .tooManyResources:
            "单个工具授权的资源范围过多。"
        case .tooManyGrants:
            "已记住的工具授权数量超过上限。"
        }
    }
}

struct ToolApprovalScope: Codable, Hashable, Sendable {
    static let maximumResources = 16
    /// Stable marker used by the device-wide local execution policy. It is
    /// never accepted from a tool or plugin; AppModel creates this scope when
    /// the personal-device policy records a grant.
    static let allLocalToolsMarker = "*"
    static let allLocalToolsResource = "device:local-tools"

    let toolName: String
    let risk: ToolRisk
    let modelDestination: String
    let resources: [String]

    init(
        toolName: String,
        risk: ToolRisk,
        modelDestination: String,
        resources: some Sequence<String>
    ) throws {
        let normalizedToolName = Self.normalize(toolName)
        guard !normalizedToolName.isEmpty,
              normalizedToolName.utf8.count <= 128 else {
            throw ToolApprovalScopeError.invalidToolName
        }

        let normalizedDestination = Self.normalize(modelDestination).lowercased()
        guard !normalizedDestination.isEmpty,
              normalizedDestination.utf8.count <= 512 else {
            throw ToolApprovalScopeError.invalidModelDestination
        }

        let normalizedResources = Array(
            Set(resources.map(Self.normalize))
        ).sorted()
        guard !normalizedResources.isEmpty,
              normalizedResources.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 1_024
              }) else {
            throw ToolApprovalScopeError.invalidResource
        }
        guard normalizedResources.count <= Self.maximumResources else {
            throw ToolApprovalScopeError.tooManyResources
        }

        self.toolName = normalizedToolName
        self.risk = risk
        self.modelDestination = normalizedDestination
        self.resources = normalizedResources
    }

    func validated() throws -> Self {
        try Self(
            toolName: toolName,
            risk: risk,
            modelDestination: modelDestination,
            resources: resources
        )
    }

    private static func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ToolApprovalGrant: Identifiable, Codable, Sendable, Equatable {
    static let maximumStoredGrants = 256

    let id: UUID
    let scope: ToolApprovalScope
    let grantedAt: Date

    init(
        id: UUID = UUID(),
        scope: ToolApprovalScope,
        grantedAt: Date = .now
    ) {
        self.id = id
        self.scope = scope
        self.grantedAt = grantedAt
    }

    func validated() throws -> Self {
        Self(
            id: id,
            scope: try scope.validated(),
            grantedAt: grantedAt
        )
    }

    func allows(_ request: ToolApprovalRequest) -> Bool {
        if scope.toolName == ToolApprovalScope.allLocalToolsMarker,
           scope.modelDestination == request.scope.modelDestination,
           scope.resources == [ToolApprovalScope.allLocalToolsResource] {
            // This is an explicit personal-device choice. It covers every
            // local risk level, including destructive calls; the iOS system
            // still owns privacy prompts and the Cordis plugin chain may
            // independently reject a call.
            return true
        }
        return scope == request.scope
    }
}

enum ToolApprovalResolution: Sendable, Equatable {
    case deny
    case trustScope
    case trustDevice
}

struct ToolApprovalRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let runID: UUID
    let call: AgentToolCall
    let risk: ToolRisk
    let summary: String
    let modelHost: String
    let scope: ToolApprovalScope

    init(
        id: UUID = UUID(),
        runID: UUID,
        call: AgentToolCall,
        risk: ToolRisk,
        summary: String,
        modelHost: String,
        approvalResources: some Sequence<String>
    ) throws {
        self.id = id
        self.runID = runID
        self.call = call
        self.risk = risk
        self.summary = summary
        self.modelHost = modelHost
        scope = try ToolApprovalScope(
            toolName: call.name,
            risk: risk,
            modelDestination: modelHost,
            resources: approvalResources
        )
    }
}

enum LocalToolError: LocalizedError, Sendable {
    case unknownTool(String)
    case invalidArguments
    case missingArgument(String)
    case argumentsTooLarge
    case resultTooLarge
    case userDenied
    case permissionModeDenied(ToolPermissionMode)
    case pluginDenied(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "未注册的本地工具：\(name)。"
        case .invalidArguments:
            return "工具参数不是有效的 JSON 对象。"
        case let .missingArgument(name):
            return "缺少工具参数：\(name)。"
        case .argumentsTooLarge:
            return "工具参数超过 64 KiB 上限。"
        case .resultTooLarge:
            return "工具结果超过 128 KiB 上限。"
        case .userDenied:
            return "用户拒绝了这次工具调用。"
        case let .permissionModeDenied(mode):
            return "当前“\(mode.title)”权限模式不允许这次工具调用。"
        case let .pluginDenied(reason):
            return "Cordis 插件拒绝了这次工具调用：\(reason)"
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw LocalToolError.missingArgument(key)
        }
        return value
    }

    func requiredString(
        _ key: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool = false
    ) throws -> String {
        guard let value = self[key]?.stringValue,
              (allowEmpty || !value.isEmpty),
              value.utf8.count <= maximumUTF8Bytes else {
            throw LocalToolError.invalidArguments
        }
        return value
    }

    func requireOnlyKeys(_ allowed: Set<String>) throws {
        guard Set(keys).isSubset(of: allowed) else {
            throw LocalToolError.invalidArguments
        }
    }
}
