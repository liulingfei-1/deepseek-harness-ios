import Foundation
import CryptoKit

/// A bounded, local-only stdio transport boundary for an MCP server.
///
/// The transport deliberately exposes bytes rather than JSON so the client can
/// enforce one framing and size policy for every implementation (the real iSH
/// bridge and the in-memory test transport use the same contract).
protocol MCPStdioTransport: Sendable {
    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (MCPTransportExit) -> Void
    ) async throws -> Int32

    func write(_ data: Data) async throws
    func stop() async
}

struct MCPTransportExit: Sendable, Equatable {
    let exitCode: Int
    let errorCode: Int
}

enum MCPClientError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case invalidConfiguration(String)
    case invalidState(String)
    case malformedJSON
    case invalidJSONRPC(String)
    case frameTooLarge(maximumBytes: Int)
    case payloadTooLarge(kind: String, maximumBytes: Int)
    case transportEOF
    case transportFailure(String)
    case remote(code: Int, message: String, data: JSONValue?)
    case unauthorized(server: String, tool: String)
    case toolNotFound(String)
    case timedOut(method: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "本机构建不包含可用的 iSH MCP 边界。"
        case let .invalidConfiguration(reason):
            "MCP 配置无效：\(reason)"
        case let .invalidState(reason):
            "MCP 客户端状态无效：\(reason)"
        case .malformedJSON:
            "MCP 服务返回了无法解析的 JSON。"
        case let .invalidJSONRPC(reason):
            "MCP JSON-RPC 消息无效：\(reason)"
        case let .frameTooLarge(maximumBytes):
            "MCP 消息超过 \(maximumBytes) 字节上限。"
        case let .payloadTooLarge(kind, maximumBytes):
            "MCP \(kind) 超过 \(maximumBytes) 字节上限。"
        case .transportEOF:
            "MCP 本地 stdio 通道已结束。"
        case let .transportFailure(reason):
            "MCP 本地通道失败：\(reason)"
        case let .remote(code, message, _):
            "MCP 服务错误 \(code)：\(message)"
        case let .unauthorized(server, tool):
            "未获授权调用 MCP 服务 \(server) 的工具 \(tool)。"
        case let .toolNotFound(name):
            "MCP 工具不存在：\(name)"
        case let .timedOut(method):
            "MCP 请求超时：\(method)"
        case .cancelled:
            "MCP 请求已取消。"
        }
    }
}

struct MCPClientLimits: Sendable, Equatable {
    let maximumOutboundFrameBytes: Int
    let maximumInboundFrameBytes: Int
    let maximumToolCount: Int
    let maximumToolListPayloadBytes: Int
    let maximumArgumentsPayloadBytes: Int
    let maximumResultPayloadBytes: Int
    let maximumCursorBytes: Int

    init(
        maximumOutboundFrameBytes: Int = 1 * 1_024 * 1_024,
        maximumInboundFrameBytes: Int = 4 * 1_024 * 1_024,
        maximumToolCount: Int = 256,
        maximumToolListPayloadBytes: Int = 1 * 1_024 * 1_024,
        maximumArgumentsPayloadBytes: Int = 256 * 1_024,
        maximumResultPayloadBytes: Int = 4 * 1_024 * 1_024,
        maximumCursorBytes: Int = 4 * 1_024
    ) {
        self.maximumOutboundFrameBytes = max(1, maximumOutboundFrameBytes)
        self.maximumInboundFrameBytes = max(1, maximumInboundFrameBytes)
        self.maximumToolCount = max(1, maximumToolCount)
        self.maximumToolListPayloadBytes = max(1, maximumToolListPayloadBytes)
        self.maximumArgumentsPayloadBytes = max(1, maximumArgumentsPayloadBytes)
        self.maximumResultPayloadBytes = max(1, maximumResultPayloadBytes)
        self.maximumCursorBytes = max(1, maximumCursorBytes)
    }
}

/// Claude Desktop/OpenMinis-compatible stdio configuration. The command is
/// always started inside the guest selected by the iSH transport adapter.
struct MCPStdioServerConfiguration: Codable, Sendable, Equatable {
    let serverName: String
    let command: String
    let args: [String]
    let env: [String: String]
    let cwd: String?

    init(
        serverName: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        cwd: String? = nil
    ) {
        self.serverName = serverName
        self.command = command
        self.args = args
        self.env = env
        self.cwd = cwd
    }

    func validate() throws {
        guard !serverName.isEmpty, serverName.utf8.count <= 32,
              serverName.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 48 && value <= 57)
                      || (value >= 65 && value <= 90)
                      || (value >= 97 && value <= 122)
                      || value == 95 || value == 45
              }) else {
            throw MCPClientError.invalidConfiguration("serverName 必须匹配 [A-Za-z0-9_-]{1,32}")
        }
        guard !command.isEmpty, command.utf8.count <= 512,
              !command.contains("\0"), !command.contains("\n"), !command.contains("\r") else {
            throw MCPClientError.invalidConfiguration("command 为空或包含非法控制字符")
        }
        guard args.count <= 128,
              args.allSatisfy({ $0.utf8.count <= 8 * 1_024 && !$0.contains("\0") }) else {
            throw MCPClientError.invalidConfiguration("args 超出数量或单项大小上限")
        }
        guard env.count <= 128 else {
            throw MCPClientError.invalidConfiguration("env 超出数量上限")
        }
        for (key, value) in env {
            guard !key.isEmpty, key.utf8.count <= 256,
                  key.unicodeScalars.allSatisfy({ scalar in
                      let value = scalar.value
                      return (value >= 48 && value <= 57)
                          || (value >= 65 && value <= 90)
                          || (value >= 97 && value <= 122)
                          || value == 95 || value == 45
                  }),
                  value.utf8.count <= 8 * 1_024,
                  !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
                throw MCPClientError.invalidConfiguration("env 含有非法键或值")
            }
        }
        if let cwd {
            guard cwd.isEmpty || (cwd.utf8.count <= 4 * 1_024 && !cwd.contains("\0") && !cwd.contains("\n") && !cwd.contains("\r")) else {
                throw MCPClientError.invalidConfiguration("cwd 无效")
            }
        }
    }
}

struct MCPClientConfiguration: Sendable, Equatable {
    let server: MCPStdioServerConfiguration
    let toolCallTimeout: Duration
    let limits: MCPClientLimits

    init(
        server: MCPStdioServerConfiguration,
        toolCallTimeout: Duration = .seconds(60),
        limits: MCPClientLimits = MCPClientLimits()
    ) {
        self.server = server
        self.toolCallTimeout = toolCallTimeout
        self.limits = limits
    }

    func validate() throws {
        try server.validate()
        guard toolCallTimeout > .zero else {
            throw MCPClientError.invalidConfiguration("toolCallTimeout 必须大于 0")
        }
        guard limits.maximumOutboundFrameBytes <= limits.maximumInboundFrameBytes else {
            throw MCPClientError.invalidConfiguration("出站消息上限不能大于入站消息上限")
        }
    }
}

struct MCPInitializeParams: Codable, Sendable, Equatable {
    let protocolVersion: String
    let capabilities: JSONValue
    let clientInfo: JSONValue

    init(
        protocolVersion: String = "2025-06-18",
        capabilities: JSONValue = .object([:]),
        clientName: String = "harness-mobile",
        clientVersion: String = "0.1.0"
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = .object([
            "name": .string(clientName),
            "version": .string(clientVersion)
        ])
    }
}

struct MCPInitializeResult: Codable, Sendable, Equatable {
    let protocolVersion: String
    let capabilities: JSONValue
    let serverInfo: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case capabilities
        case serverInfo
    }

    init(protocolVersion: String, capabilities: JSONValue, serverInfo: JSONValue? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        capabilities = try container.decodeIfPresent(JSONValue.self, forKey: .capabilities) ?? .object([:])
        serverInfo = try container.decodeIfPresent(JSONValue.self, forKey: .serverInfo)
    }
}

struct MCPToolDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String?
    let inputSchema: JSONValue
    let outputSchema: JSONValue?
    let title: String?
    let annotations: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema
        case outputSchema
        case title
        case annotations
    }

    init(
        name: String,
        description: String? = nil,
        inputSchema: JSONValue = .object(["type": .string("object")]),
        outputSchema: JSONValue? = nil,
        title: String? = nil,
        annotations: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.title = title
        self.annotations = annotations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
            ?? .object(["type": .string("object")])
        outputSchema = try container.decodeIfPresent(JSONValue.self, forKey: .outputSchema)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        annotations = try container.decodeIfPresent(JSONValue.self, forKey: .annotations)
    }
}

struct MCPToolsListResult: Codable, Sendable, Equatable {
    let tools: [MCPToolDefinition]
    let nextCursor: String?

    init(tools: [MCPToolDefinition], nextCursor: String? = nil) {
        self.tools = tools
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tools = try container.decodeIfPresent([MCPToolDefinition].self, forKey: .tools) ?? []
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }

    private enum CodingKeys: String, CodingKey {
        case tools
        case nextCursor
    }
}

struct MCPToolCallResult: Codable, Sendable, Equatable {
    let content: [JSONValue]
    let structuredContent: JSONValue?
    let isError: Bool?

    init(
        content: [JSONValue] = [],
        structuredContent: JSONValue? = nil,
        isError: Bool? = nil
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.isError = isError
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([JSONValue].self, forKey: .content) ?? []
        structuredContent = try container.decodeIfPresent(JSONValue.self, forKey: .structuredContent)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError)
    }

    private enum CodingKeys: String, CodingKey {
        case content
        case structuredContent
        case isError
    }
}

struct MCPRemoteError: Codable, Sendable, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}

enum MCPRequestID: Codable, Hashable, Sendable, Equatable {
    case string(String)
    case integer(Int)

    var stringValue: String {
        switch self {
        case let .string(value): return value
        case let .integer(value): return String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSON-RPC id must be a string or integer"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        }
    }
}

struct MCPClientEvent: Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case request
        case result
        case error
        case cancelled
    }

    let kind: Kind
    let serverName: String
    let requestID: String?
    let method: String?
    let toolName: String?
    let byteCount: Int?
    let error: MCPClientError?

    static func request(
        serverName: String,
        requestID: String,
        method: String,
        toolName: String?,
        byteCount: Int
    ) -> Self {
        Self(kind: .request, serverName: serverName, requestID: requestID, method: method, toolName: toolName, byteCount: byteCount, error: nil)
    }

    static func result(
        serverName: String,
        requestID: String,
        method: String,
        toolName: String?,
        byteCount: Int
    ) -> Self {
        Self(kind: .result, serverName: serverName, requestID: requestID, method: method, toolName: toolName, byteCount: byteCount, error: nil)
    }

    static func failure(
        serverName: String,
        requestID: String?,
        method: String?,
        toolName: String?,
        error: MCPClientError
    ) -> Self {
        Self(kind: .error, serverName: serverName, requestID: requestID, method: method, toolName: toolName, byteCount: nil, error: error)
    }

    static func cancellation(
        serverName: String,
        requestID: String?,
        method: String?,
        toolName: String?
    ) -> Self {
        Self(kind: .cancelled, serverName: serverName, requestID: requestID, method: method, toolName: toolName, byteCount: nil, error: .cancelled)
    }
}

typealias MCPEventSink = @Sendable (MCPClientEvent) async -> Void

protocol MCPAuthorizationChecking: Sendable {
    func authorize(
        serverName: String,
        tool: MCPToolDefinition,
        arguments: [String: JSONValue]
    ) async throws
}

/// A conservative adapter for callers that already have the app's permission
/// mode. `.ask` never falls through to allow; the caller must perform the
/// normal checkpoint/approval flow and inject a gate that returns `.allow`.
struct MCPToolPermissionAuthorization: MCPAuthorizationChecking {
    let permissionMode: ToolPermissionMode
    let modelDestination: String
    let risk: ToolRisk
    let resources: @Sendable (String, [String: JSONValue]) -> Set<String>

    init(
        permissionMode: ToolPermissionMode,
        modelDestination: String = "local-mcp",
        risk: ToolRisk = .sideEffect,
        resources: @escaping @Sendable (String, [String: JSONValue]) -> Set<String> = { toolName, _ in ["mcp-tool:\(toolName)"] }
    ) {
        self.permissionMode = permissionMode
        self.modelDestination = modelDestination
        self.risk = risk
        self.resources = resources
    }

    func authorize(
        serverName: String,
        tool: MCPToolDefinition,
        arguments: [String: JSONValue]
    ) async throws {
        let decision = permissionMode.decision(for: risk)
        guard decision == .allow else {
            throw MCPClientError.unauthorized(server: serverName, tool: tool.name)
        }
        _ = try? ToolApprovalScope(
            toolName: MCPToolNames.publicName(serverName: serverName, rawName: tool.name),
            risk: risk,
            modelDestination: modelDestination,
            resources: resources(tool.name, arguments)
        )
    }
}

struct MCPDenyAllAuthorization: MCPAuthorizationChecking {
    func authorize(
        serverName: String,
        tool: MCPToolDefinition,
        arguments: [String: JSONValue]
    ) async throws {
        _ = arguments
        throw MCPClientError.unauthorized(server: serverName, tool: tool.name)
    }
}

enum MCPToolNames {
    static let maximumPublicNameLength = 64

    static func publicName(serverName: String, rawName: String) -> String {
        let joined = "mcp__\(serverName)__\(rawName)"
        let normalized = joined.map { character -> Character in
            if character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-") {
                return character
            }
            return "_"
        }
        let normalizedString = String(normalized)
        if normalizedString == joined, normalizedString.count <= maximumPublicNameLength {
            return normalizedString
        }
        let digest = SHA256.hash(data: Data("\(serverName)\0\(rawName)".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(12)
        let prefixLength = max(1, maximumPublicNameLength - hash.count - 1)
        return "\(normalizedString.prefix(prefixLength))_\(hash)"
    }
}

extension MCPToolDefinition {
    func modelDefinition(serverName: String) -> ModelToolDefinition {
        ModelToolDefinition(
            name: MCPToolNames.publicName(serverName: serverName, rawName: name),
            description: description ?? "",
            parameters: inputSchema
        )
    }
}

/// Newline-delimited framing with an explicit memory bound.
struct MCPNDJSONFramer: Sendable {
    private(set) var bufferedByteCount = 0
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = max(1, maximumLineBytes)
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard line.count <= maximumLineBytes else {
                throw MCPClientError.frameTooLarge(maximumBytes: maximumLineBytes)
            }
            if !line.isEmpty { lines.append(line) }
        }
        bufferedByteCount = buffer.count
        guard buffer.count <= maximumLineBytes else {
            throw MCPClientError.frameTooLarge(maximumBytes: maximumLineBytes)
        }
        return lines
    }

    mutating func finish() throws -> [Data] {
        defer {
            buffer.removeAll(keepingCapacity: false)
            bufferedByteCount = 0
        }
        guard !buffer.isEmpty else { return [] }
        guard buffer.count <= maximumLineBytes else {
            throw MCPClientError.frameTooLarge(maximumBytes: maximumLineBytes)
        }
        if buffer.last == 0x0D { buffer.removeLast() }
        return buffer.isEmpty ? [] : [buffer]
    }
}

private extension Character {
    var isASCII: Bool {
        unicodeScalars.allSatisfy { $0.value < 128 }
    }
}
