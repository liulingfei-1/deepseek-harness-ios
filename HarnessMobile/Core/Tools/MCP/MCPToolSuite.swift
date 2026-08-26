import Foundation

/// A user-administered local MCP server entry. It is intentionally limited to
/// stdio: network transports and credential-backed OAuth are outside this
/// application's execution boundary.
struct MCPConfiguredServer: Codable, Sendable, Equatable {
    let server: MCPStdioServerConfiguration
    var isEnabled: Bool

    init(server: MCPStdioServerConfiguration, isEnabled: Bool = true) {
        self.server = server
        self.isEnabled = isEnabled
    }

    func validate() throws {
        try server.validate()
        try ISHPluginHostCredentialFirewall.validate(
            .object(server.env.mapValues(JSONValue.string))
        )
    }
}

/// Durable MCP configuration owned by the settings/admin surface, never by a
/// model tool call. Invalid individual disk entries are skipped so one stale
/// server cannot hide otherwise valid local configuration.
actor MCPConfigurationStore {
    private struct Document: Codable {
        let schemaVersion: Int
        let servers: [MCPConfiguredServer]
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let maximumServerCount = 32
    private let maximumFileBytes = 256 * 1_024
    private let allowedEntryKeys: Set<String> = ["server", "isEnabled"]
    private let allowedServerKeys: Set<String> = ["serverName", "command", "args", "env", "cwd"]

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = base
                .appendingPathComponent("HarnessMobile", isDirectory: true)
                .appendingPathComponent("mcp-servers.json", isDirectory: false)
        }
    }

    func load() throws -> [MCPConfiguredServer] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= maximumFileBytes else {
            throw MCPClientError.invalidConfiguration("MCP 配置文件超过大小上限")
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let document = object as? [String: Any],
              document["schemaVersion"] as? Int == 1,
              let entries = document["servers"] as? [Any] else {
            throw MCPClientError.invalidConfiguration("MCP 配置文件格式或版本无效")
        }
        guard entries.count <= maximumServerCount else {
            throw MCPClientError.invalidConfiguration("MCP 服务数量超过上限")
        }

        var names = Set<String>()
        var valid: [MCPConfiguredServer] = []
        for entry in entries {
            guard Self.isLocalStdioEntry(
                entry,
                allowedEntryKeys: allowedEntryKeys,
                allowedServerKeys: allowedServerKeys
            ),
                  JSONSerialization.isValidJSONObject(entry),
                  let entryData = try? JSONSerialization.data(withJSONObject: entry),
                  let configured = try? JSONDecoder().decode(MCPConfiguredServer.self, from: entryData),
                  (try? configured.validate()) != nil,
                  names.insert(configured.server.serverName).inserted else {
                continue
            }
            valid.append(configured)
        }
        return valid.sorted { $0.server.serverName < $1.server.serverName }
    }

    private static func isLocalStdioEntry(
        _ entry: Any,
        allowedEntryKeys: Set<String>,
        allowedServerKeys: Set<String>
    ) -> Bool {
        guard let entryObject = entry as? [String: Any],
              Set(entryObject.keys).isSubset(of: allowedEntryKeys),
              let serverObject = entryObject["server"] as? [String: Any],
              Set(serverObject.keys).isSubset(of: allowedServerKeys) else {
            return false
        }
        return true
    }

    func replace(_ servers: [MCPConfiguredServer]) throws {
        guard servers.count <= maximumServerCount else {
            throw MCPClientError.invalidConfiguration("MCP 服务数量超过上限")
        }
        var names = Set<String>()
        for server in servers {
            try server.validate()
            guard names.insert(server.server.serverName).inserted else {
                throw MCPClientError.invalidConfiguration("MCP serverName 不能重复")
            }
        }
        let ordered = servers.sorted { $0.server.serverName < $1.server.serverName }
        let data = try JSONEncoder().encode(Document(schemaVersion: 1, servers: ordered))
        guard data.count <= maximumFileBytes else {
            throw MCPClientError.invalidConfiguration("MCP 配置文件超过大小上限")
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
#if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: fileURL, options: [.atomic])
#endif
    }
}

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
        let generation: UUID
        let publishTools: @Sendable ([MCPToolDefinition]) async throws -> Void
        var recoveryTask: Task<Void, Never>?
    }

    private let workspaceURLProvider: @Sendable () async throws -> URL
    private let transportFactory: @Sendable (MCPClientConfiguration, URL) -> any MCPStdioTransport
    private let authorization: any MCPAuthorizationChecking
    private var entries: [String: Entry] = [:]

    init(
        workspaceURLProvider: @escaping @Sendable () async throws -> URL,
        // The direct discovered LocalAgentTool is the authoritative approval
        // checkpoint. This inner gate still validates a stable MCP scope, but
        // must not independently deny a call that passed the Harness pipeline.
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

    func connect(
        _ configuration: MCPClientConfiguration,
        publishTools: @escaping @Sendable ([MCPToolDefinition]) async throws -> Void = { _ in }
    ) async throws -> MCPInitializeResult {
        try configuration.validate()
        if let existing = entries[configuration.server.serverName] {
            return try await existing.client.start()
        }
        let workspaceURL = try await workspaceURLProvider()
        let generation = UUID()
        let client = makeClient(configuration: configuration, workspaceURL: workspaceURL, generation: generation)
        do {
            let result = try await client.start()
            try await publishTools(await client.discoveredTools())
            entries[configuration.server.serverName] = Entry(
                configuration: configuration,
                client: client,
                generation: generation,
                publishTools: publishTools,
                recoveryTask: nil
            )
            return result
        } catch {
            await client.stop()
            throw error
        }
    }

    func disconnect(serverName: String) async {
        guard let entry = entries.removeValue(forKey: serverName) else { return }
        entry.recoveryTask?.cancel()
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

    private func makeClient(
        configuration: MCPClientConfiguration,
        workspaceURL: URL,
        generation: UUID
    ) -> MCPStdioClient {
        MCPStdioClient(
            configuration: configuration,
            transport: transportFactory(configuration, workspaceURL),
            authorization: authorization,
            exitObserver: { [weak self] _ in
                await self?.recover(serverName: configuration.server.serverName, generation: generation)
            }
        )
    }

    private func recover(serverName: String, generation: UUID) async {
        guard var entry = entries[serverName], entry.generation == generation,
              entry.recoveryTask == nil else { return }
        entry.recoveryTask = Task { [weak self] in
            await self?.runRecovery(serverName: serverName, generation: generation)
        }
        entries[serverName] = entry
    }

    private func runRecovery(serverName: String, generation: UUID) async {
        guard let initial = entries[serverName], initial.generation == generation else { return }
        let configuration = initial.configuration
        let workspaceURL: URL
        do {
            workspaceURL = try await workspaceURLProvider()
        } catch {
            await exhaustRecovery(serverName: serverName, generation: generation)
            return
        }
        for attempt in 1...configuration.reconnectPolicy.maximumAttempts {
            do {
                try await Task.sleep(for: configuration.reconnectPolicy.delay(forAttempt: attempt))
                try Task.checkCancellation()
                guard let current = entries[serverName], current.generation == generation else { return }
                let replacementGeneration = UUID()
                let replacement = makeClient(
                    configuration: configuration,
                    workspaceURL: workspaceURL,
                    generation: replacementGeneration
                )
                _ = try await replacement.start()
                let tools = await replacement.discoveredTools()
                try await current.publishTools(tools)
                guard var live = entries[serverName], live.generation == generation else {
                    await replacement.stop()
                    return
                }
                live = Entry(
                    configuration: configuration,
                    client: replacement,
                    generation: replacementGeneration,
                    publishTools: current.publishTools,
                    recoveryTask: nil
                )
                entries[serverName] = live
                return
            } catch is CancellationError {
                return
            } catch {
                continue
            }
        }
        await exhaustRecovery(serverName: serverName, generation: generation)
    }

    private func exhaustRecovery(serverName: String, generation: UUID) async {
        guard let entry = entries[serverName], entry.generation == generation else { return }
        entries.removeValue(forKey: serverName)
        try? await entry.publishTools([])
    }
}

/// One Cordis generation per configured server. Discovery completes before the
/// plugin becomes active; failed registration is cleaned up by the generation
/// transaction, so a server never exposes a partial tool set.
enum MCPServerCordisPlugin {
    static func definition(
        configuration: MCPConfiguredServer,
        registry: MCPClientRegistry,
        reconnectPolicy: MCPReconnectPolicy = MCPReconnectPolicy()
    ) -> CordisPluginDefinition {
        let server = configuration.server
        return CordisPluginDefinition(
            id: CordisPluginID(rawValue: "mcp.\(server.serverName)"),
            version: "stdio-1",
            dependencies: [CordisAgentServiceKeys.tools.name]
        ) { context in
            try configuration.validate()
            let tools = try await context.service(CordisAgentServiceKeys.tools)
            let publisher = MCPToolGenerationPublisher(
                pluginID: context.pluginID,
                tools: tools,
                registry: registry,
                serverName: server.serverName,
                onChanged: {
                    await context.emit(
                        CordisAgentLoopEvents.toolsChange,
                        input: .value,
                        target: .unfiltered
                    )
                }
            )
            try await context.onDispose("mcp.dispose(\(server.serverName))") {
                await publisher.dispose()
                await registry.disconnect(serverName: server.serverName)
            }
            _ = try await registry.connect(
                MCPClientConfiguration(server: server, reconnectPolicy: reconnectPolicy),
                publishTools: { definitions in
                    try await publisher.publish(definitions)
                }
            )
        }
    }
}

private actor MCPToolGenerationPublisher {
    private let pluginID: CordisPluginID
    private let tools: CordisToolRuntime
    private let registry: MCPClientRegistry
    private let serverName: String
    private let onChanged: @Sendable () async -> Void
    private let generationID = UUID()

    init(
        pluginID: CordisPluginID,
        tools: CordisToolRuntime,
        registry: MCPClientRegistry,
        serverName: String,
        onChanged: @escaping @Sendable () async -> Void
    ) {
        self.pluginID = pluginID
        self.tools = tools
        self.registry = registry
        self.serverName = serverName
        self.onChanged = onChanged
    }

    func publish(_ definitions: [MCPToolDefinition]) async throws {
        let publicNames = definitions.map {
            MCPToolNames.publicName(serverName: serverName, rawName: $0.name)
        }
        guard Set(publicNames).count == publicNames.count else {
            throw MCPClientError.invalidConfiguration("MCP 服务返回了冲突的公开工具名")
        }
        let directTools = definitions.map {
            MCPDiscoveredLocalTool(
                serverName: serverName,
                discoveredDefinition: $0,
                registry: registry
            )
        }
        try await tools.replaceMCPTools(
            pluginID: pluginID,
            generationID: generationID,
            tools: directTools
        )
        await onChanged()
    }

    func dispose() async {
        await tools.removeMCPTools(generationID: generationID)
        await onChanged()
    }
}

private struct MCPDiscoveredLocalTool: LocalAgentTool {
    let serverName: String
    let discoveredDefinition: MCPToolDefinition
    let registry: MCPClientRegistry
    let risk: ToolRisk = .sideEffect
    var definition: ModelToolDefinition {
        discoveredDefinition.modelDefinition(serverName: serverName)
    }

    func validate(arguments: [String: JSONValue]) throws {
        let encoded = try JSONEncoder().encode(JSONValue.object(arguments))
        guard encoded.count <= 256 * 1_024 else {
            throw MCPClientError.payloadTooLarge(kind: "arguments", maximumBytes: 256 * 1_024)
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "调用 MCP 工具 \(serverName)/\(discoveredDefinition.name)"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["mcp-tool:\(serverName):\(discoveredDefinition.name)"]
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try approvalResources(arguments: arguments)
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await registry.call(
            serverName: serverName,
            toolName: discoveredDefinition.name,
            arguments: arguments
        )
        return JSONValue.object([
            "is_error": .bool(result.isError ?? false),
            "content": .array(result.content),
            "structured_content": result.structuredContent ?? .null
        ]).displayText
    }
}
