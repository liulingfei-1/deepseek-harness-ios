import Foundation

/// Owns on-device MCP server lifetimes. A server is always started through an
/// injected local transport; there is no host Process/fork fallback.
actor MCPClientRegistry {
    struct ServerSnapshot: Sendable, Equatable {
        let serverName: String
        let state: MCPClientDiagnostics.State
        let toolCount: Int
        let processID: Int32?
        let stderrTail: String
    }

    private struct Entry {
        let configuration: MCPClientConfiguration
        let client: MCPStdioClient
    }

    private let workspaceURLProvider: @Sendable () async throws -> URL
    private let transportFactory: @Sendable (MCPClientConfiguration, URL) -> any MCPStdioTransport
    private let authorization: any MCPAuthorizationChecking
    private var entries: [String: Entry] = [:]

    init(
        workspaceURLProvider: @escaping @Sendable () async throws -> URL,
        // The model-facing `mcp_call` LocalAgentTool is the authoritative
        // approval checkpoint. This inner gate still validates a stable MCP
        // scope, but must not independently deny a call that already passed
        // the normal Harness permission pipeline.
        authorization: any MCPAuthorizationChecking = MCPToolPermissionAuthorization(
            permissionMode: .dangerFullAccess
        ),
        transportFactory: @escaping @Sendable (MCPClientConfiguration, URL) -> any MCPStdioTransport = { configuration, workspaceURL in
            ISHMCPStdioTransport(configuration: configuration.server, workspaceURL: workspaceURL)
        }
    ) {
        self.workspaceURLProvider = workspaceURLProvider
        self.authorization = authorization
        self.transportFactory = transportFactory
    }

    func connect(_ configuration: MCPClientConfiguration) async throws -> MCPInitializeResult {
        try configuration.validate()
        if let existing = entries[configuration.server.serverName] {
            return try await existing.client.start()
        }
        let workspaceURL = try await workspaceURLProvider()
        let client = MCPStdioClient(
            configuration: configuration,
            transport: transportFactory(configuration, workspaceURL),
            authorization: authorization
        )
        do {
            let result = try await client.start()
            entries[configuration.server.serverName] = Entry(configuration: configuration, client: client)
            return result
        } catch {
            await client.stop()
            throw error
        }
    }

    func disconnect(serverName: String) async {
        guard let entry = entries.removeValue(forKey: serverName) else { return }
        await entry.client.stop()
    }

    func snapshots() async -> [ServerSnapshot] {
        var snapshots: [ServerSnapshot] = []
        for name in entries.keys.sorted() {
            guard let entry = entries[name] else { continue }
            let diagnostics = await entry.client.diagnostics()
            snapshots.append(ServerSnapshot(
                serverName: name,
                state: diagnostics.state,
                toolCount: diagnostics.toolCount,
                processID: diagnostics.processID,
                stderrTail: diagnostics.stderrTail
            ))
        }
        return snapshots
    }

    func tools(serverName: String?) async throws -> [(serverName: String, definition: MCPToolDefinition)] {
        let names = serverName.map { [$0] } ?? entries.keys.sorted()
        var result: [(String, MCPToolDefinition)] = []
        for name in names {
            guard let entry = entries[name] else {
                throw MCPClientError.invalidState("MCP 服务未连接：\(name)")
            }
            for definition in await entry.client.discoveredTools() {
                result.append((name, definition))
            }
        }
        return result
    }

    func call(serverName: String, toolName: String, arguments: [String: JSONValue]) async throws -> MCPToolCallResult {
        guard let entry = entries[serverName] else {
            throw MCPClientError.invalidState("MCP 服务未连接：\(serverName)")
        }
        return try await entry.client.callTool(rawName: toolName, arguments: arguments)
    }
}

enum MCPToolSuite {
    static let toolNames: Set<String> = [
        "mcp_connect",
        "mcp_list_tools",
        "mcp_call",
        "mcp_disconnect"
    ]

    static let promptSection = CordisPromptSection(
        name: "core.mobile-mcp",
        order: 64,
        text: "MCP 在本机 iSH 中运行。先用 mcp_connect 连接受信任的本地 stdio server，再用 mcp_list_tools 查看工具，最后用 mcp_call 调用。不要把 API key 放进 server args/env；MCP 结果仍受工具输出上限和轨迹记录约束。"
    )

    static func makeTools(
        workspaceStore: WorkspaceStore,
        registry: MCPClientRegistry = MCPClientRegistry(workspaceURLProvider: { throw MCPClientError.unavailable })
    ) -> [any LocalAgentTool] {
        [
            MCPConnectTool(store: workspaceStore, registry: registry),
            MCPListToolsTool(registry: registry),
            MCPCallTool(registry: registry),
            MCPDisconnectTool(registry: registry)
        ]
    }
}

private struct MCPConnectTool: LocalAgentTool {
    let store: WorkspaceStore
    let registry: MCPClientRegistry
    let risk: ToolRisk = .sideEffect
    let definition = ModelToolDefinition(
        name: "mcp_connect",
        description: "Connect to one local MCP stdio server inside iSH and discover its tools. The command is never executed by the host process.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "server_name": .object(["type": .string("string"), "maxLength": .number(32)]),
                "command": .object(["type": .string("string"), "maxLength": .number(512)]),
                "args": .object(["type": .string("array"), "items": .object(["type": .string("string")]), "maxItems": .number(128)]),
                "env": .object(["type": .string("object")]),
                "cwd": .object(["type": .string("string"), "maxLength": .number(4_096)])
            ]),
            "required": .array([.string("server_name"), .string("command")]),
            "additionalProperties": .bool(false)
        ])
    )

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["server_name", "command", "args", "env", "cwd"])
        _ = try serverName(arguments)
        _ = try command(arguments)
        _ = try parsedArgs(arguments)
        _ = try parsedEnv(arguments)
        _ = try parsedCWD(arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "连接本机 MCP 服务 \((try? serverName(arguments)) ?? "未知")"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["mcp-server:\(try serverName(arguments))"]
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try approvalResources(arguments: arguments)
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let config = MCPClientConfiguration(server: MCPStdioServerConfiguration(
            serverName: try serverName(arguments),
            command: try command(arguments),
            args: try parsedArgs(arguments),
            env: try parsedEnv(arguments),
            cwd: try parsedCWD(arguments)
        ))
        // The default registry used by the catalog is replaced with a workspace
        // bound registry by the caller; this fallback keeps invalid wiring loud.
        _ = store
        let initialized = try await registry.connect(config)
        let tools = try await registry.tools(serverName: config.server.serverName)
        return JSONValue.object([
            "server_name": .string(config.server.serverName),
            "protocol_version": .string(initialized.protocolVersion),
            "tool_count": .number(Double(tools.count)),
            "tools": .array(tools.map { .string(MCPToolNames.publicName(serverName: $0.serverName, rawName: $0.definition.name)) })
        ]).displayText
    }

    private func serverName(_ arguments: [String: JSONValue]) throws -> String { try arguments.requiredString("server_name", maximumUTF8Bytes: 32) }
    private func command(_ arguments: [String: JSONValue]) throws -> String { try arguments.requiredString("command", maximumUTF8Bytes: 512) }
    private func parsedArgs(_ arguments: [String: JSONValue]) throws -> [String] {
        guard let value = arguments["args"] else { return [] }
        guard case let .array(values) = value else { throw LocalToolError.invalidArguments }
        return try values.map { value in
            guard case let .string(text) = value else { throw LocalToolError.invalidArguments }
            return text
        }
    }
    private func parsedEnv(_ arguments: [String: JSONValue]) throws -> [String: String] {
        guard let value = arguments["env"] else { return [:] }
        guard let object = value.objectValue else { throw LocalToolError.invalidArguments }
        var env: [String: String] = [:]
        for (key, value) in object {
            guard let text = value.stringValue else { throw LocalToolError.invalidArguments }
            env[key] = text
        }
        try ISHPluginHostCredentialFirewall.validate(
            .object(env.mapValues(JSONValue.string))
        )
        return env
    }
    private func parsedCWD(_ arguments: [String: JSONValue]) throws -> String? {
        guard let value = arguments["cwd"] else { return nil }
        guard let text = value.stringValue else { throw LocalToolError.invalidArguments }
        return text
    }
}

private struct MCPListToolsTool: LocalAgentTool {
    let registry: MCPClientRegistry
    let risk: ToolRisk = .localState
    let definition = ModelToolDefinition(
        name: "mcp_list_tools",
        description: "List tools discovered from connected local MCP servers.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["server_name": .object(["type": .string("string")])]),
            "additionalProperties": .bool(false)
        ])
    )
    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys(["server_name"]) }
    func summary(arguments: [String: JSONValue]) -> String { "查看本机 MCP 工具" }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let server = arguments["server_name"]?.stringValue
        let tools = try await registry.tools(serverName: server)
        return JSONValue.array(tools.map { serverName, definition in
            .object([
                "server_name": .string(serverName),
                "name": .string(definition.name),
                "public_name": .string(MCPToolNames.publicName(serverName: serverName, rawName: definition.name)),
                "description": .string(definition.description ?? ""),
                "input_schema": definition.inputSchema
            ])
        }).displayText
    }
}

private struct MCPCallTool: LocalAgentTool {
    let registry: MCPClientRegistry
    let risk: ToolRisk = .sideEffect
    let definition = ModelToolDefinition(
        name: "mcp_call",
        description: "Call one discovered tool on a connected local MCP server. Pass only JSON arguments required by its input schema.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "server_name": .object(["type": .string("string")]),
                "tool_name": .object(["type": .string("string")]),
                "arguments": .object(["type": .string("object")])
            ]),
            "required": .array([.string("server_name"), .string("tool_name")]),
            "additionalProperties": .bool(false)
        ])
    )
    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["server_name", "tool_name", "arguments"])
        _ = try arguments.requiredString("server_name", maximumUTF8Bytes: 32)
        _ = try arguments.requiredString("tool_name", maximumUTF8Bytes: 512)
        if let value = arguments["arguments"], value.objectValue == nil { throw LocalToolError.invalidArguments }
    }
    func summary(arguments: [String: JSONValue]) -> String { "调用 MCP 工具 \((try? arguments.requiredString("tool_name", maximumUTF8Bytes: 512)) ?? "未知")" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["mcp-tool:\(try arguments.requiredString("server_name", maximumUTF8Bytes: 32)):\(try arguments.requiredString("tool_name", maximumUTF8Bytes: 512))"]
    }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { try approvalResources(arguments: arguments) }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await registry.call(
            serverName: try arguments.requiredString("server_name", maximumUTF8Bytes: 32),
            toolName: try arguments.requiredString("tool_name", maximumUTF8Bytes: 512),
            arguments: arguments["arguments"]?.objectValue ?? [:]
        )
        return JSONValue.object([
            "is_error": .bool(result.isError ?? false),
            "content": .array(result.content),
            "structured_content": result.structuredContent ?? .null
        ]).displayText
    }
}

private struct MCPDisconnectTool: LocalAgentTool {
    let registry: MCPClientRegistry
    let risk: ToolRisk = .localState
    let definition = ModelToolDefinition(
        name: "mcp_disconnect",
        description: "Stop one connected local MCP server and release its iSH process.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["server_name": .object(["type": .string("string")])]),
            "required": .array([.string("server_name")]),
            "additionalProperties": .bool(false)
        ])
    )
    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["server_name"])
        _ = try arguments.requiredString("server_name", maximumUTF8Bytes: 32)
    }
    func summary(arguments: [String: JSONValue]) -> String { "断开 MCP 服务" }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let name = try arguments.requiredString("server_name", maximumUTF8Bytes: 32)
        await registry.disconnect(serverName: name)
        return JSONValue.object(["server_name": .string(name), "disconnected": .bool(true)]).displayText
    }
}
