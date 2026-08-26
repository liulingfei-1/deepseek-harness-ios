import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class MCPClientTests: XCTestCase {
    func testNDJSONFramerHandlesFragmentsAndRejectsOversize() throws {
        var framer = MCPNDJSONFramer(maximumLineBytes: 16)
        XCTAssertEqual(try framer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(
            try framer.append(Data("1}\r\n{\"b\":2}\n".utf8)).map { String(decoding: $0, as: UTF8.self) },
            ["{\"a\":1}", "{\"b\":2}"]
        )
        XCTAssertThrowsError(try framer.append(Data(repeating: 0x61, count: 17))) { error in
            XCTAssertEqual(error as? MCPClientError, .frameTooLarge(maximumBytes: 16))
        }
    }

    func testRegistryInitializesDiscoversCallsAndDisconnectsLocalServer() async throws {
        let transport = FakeMCPTransport()
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let registry = MCPClientRegistry(
            workspaceURLProvider: { workspace },
            transportFactory: { _, _ in transport }
        )
        let config = MCPClientConfiguration(
            server: MCPStdioServerConfiguration(
                serverName: "fixture",
                command: "/usr/bin/fixture"
            ),
            toolCallTimeout: .seconds(2)
        )

        let initialized = try await registry.connect(config)
        XCTAssertEqual(initialized.protocolVersion, "2025-06-18")

        let tools = try await registry.tools(serverName: "fixture")
        XCTAssertEqual(tools.map(\.definition.name), ["echo"])
        XCTAssertEqual(
            MCPToolNames.publicName(serverName: "fixture", rawName: "echo"),
            "mcp__fixture__echo"
        )

        let call = try await registry.call(
            serverName: "fixture",
            toolName: "echo",
            arguments: ["text": .string("你好")]
        )
        XCTAssertEqual(call.isError, false)
        XCTAssertEqual(call.structuredContent, .object(["echo": .string("你好")]))

        let snapshots = await registry.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.state, .running)
        XCTAssertEqual(snapshots.first?.toolCount, 1)

        await registry.disconnect(serverName: "fixture")
        let didStop = await transport.didStop()
        let isEmpty = await registry.snapshots().isEmpty
        XCTAssertTrue(didStop)
        XCTAssertTrue(isEmpty)
    }

    func testConfigurationStorePersistsValidEntriesAndSkipsInvalidDiskEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPConfigurationStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("servers.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MCPConfigurationStore(fileURL: fileURL)
        let fixture = MCPConfiguredServer(server: MCPStdioServerConfiguration(
            serverName: "fixture",
            command: "fixture-server",
            args: ["--stdio"]
        ))

        try await store.replace([fixture])
        let stored = try await store.load()
        XCTAssertEqual(stored, [fixture])
        do {
            try await store.replace([fixture, fixture])
            XCTFail("Expected duplicate server names to be rejected")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .invalidConfiguration("MCP serverName 不能重复"))
        }

        let diskFixture = """
        {"schemaVersion":1,"servers":[
          {"server":{"serverName":"fixture","command":"fixture-server","args":[],"env":{},"cwd":null},"isEnabled":true},
          {"server":{"serverName":"bad name","command":"broken","args":[],"env":{},"cwd":null},"isEnabled":true},
          {"server":{"serverName":"credential","command":"broken","args":[],"env":{"API_KEY":"synthetic-secret"},"cwd":null},"isEnabled":true},
          {"transport":"streamable-http","server":{"serverName":"remote","command":"ignored","args":[],"env":{},"cwd":null},"isEnabled":true},
          {"server":{"serverName":"nested-remote","command":"ignored","args":[],"env":{},"cwd":null,"transport":"streamable-http"},"isEnabled":true}
        ]}
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(diskFixture.utf8).write(to: fileURL, options: .atomic)
        let recovered = try await store.load()
        XCTAssertEqual(recovered.map(\.server.serverName), ["fixture"])
    }

    func testConfiguredServerRegistersDirectToolsAndDisposesOnlyItsServer() async throws {
        let transport = FakeMCPTransport()
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { _, _ in transport }
        )
        let services = CordisAgentServices()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(services.pluginDefinition())
        let configuration = MCPConfiguredServer(server: MCPStdioServerConfiguration(
            serverName: "fixture",
            command: "fixture-server"
        ))

        let snapshot = try await runtime.install(
            MCPServerCordisPlugin.definition(configuration: configuration, registry: registry)
        )
        XCTAssertEqual(snapshot.state, .active)
        let registeredTools = await services.tools.snapshots()
        XCTAssertEqual(registeredTools.map(\.definition.name), ["mcp__fixture__echo"])
        let resolvedTool = await services.tools.tool(named: "mcp__fixture__echo")
        let tool = try XCTUnwrap(resolvedTool)
        let result = try await tool.execute(arguments: ["text": .string("hello")])
        XCTAssertTrue(result.contains("hello"))

        _ = try await runtime.uninstall("mcp.fixture")
        let remainingTools = await services.tools.snapshots()
        let didStop = await transport.didStop()
        XCTAssertTrue(remainingTools.isEmpty)
        XCTAssertTrue(didStop)
    }

    func testConfiguredServersUseIndependentQualifiedNamespaces() async throws {
        let alphaTransport = FakeMCPTransport()
        let betaTransport = FakeMCPTransport()
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { configuration, _ in
                configuration.server.serverName == "alpha" ? alphaTransport : betaTransport
            }
        )
        let services = CordisAgentServices()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(services.pluginDefinition())

        for name in ["alpha", "beta"] {
            _ = try await runtime.install(MCPServerCordisPlugin.definition(
                configuration: MCPConfiguredServer(server: MCPStdioServerConfiguration(
                    serverName: name,
                    command: "fixture-server"
                )),
                registry: registry
            ))
        }
        let registered = await services.tools.snapshots()
        let names = registered.map(\.definition.name)
        XCTAssertEqual(names, ["mcp__alpha__echo", "mcp__beta__echo"])

        _ = try await runtime.uninstall("mcp.alpha")
        let remainingSnapshots = await services.tools.snapshots()
        let remaining = remainingSnapshots.map(\.definition.name)
        let alphaStopped = await alphaTransport.didStop()
        let betaStopped = await betaTransport.didStop()
        XCTAssertEqual(remaining, ["mcp__beta__echo"])
        XCTAssertTrue(alphaStopped)
        XCTAssertFalse(betaStopped)
    }

    func testConfiguredServerRegistrationConflictLeavesNoPartialTools() async throws {
        let transport = FakeMCPTransport(toolNames: ["alpha", "echo"])
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { _, _ in transport }
        )
        let services = CordisAgentServices()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(CordisPluginDefinition(id: "foreign", version: "1") { context in
            try await context.registerTool(MCPTestTool(name: "mcp__fixture__echo"))
        })

        let snapshot = try await runtime.install(MCPServerCordisPlugin.definition(
            configuration: MCPConfiguredServer(server: MCPStdioServerConfiguration(
                serverName: "fixture",
                command: "fixture-server"
            )),
            registry: registry
        ))
        XCTAssertEqual(snapshot.state, .failed)
        let remainingTools = await services.tools.snapshots()
        let didStop = await transport.didStop()
        XCTAssertEqual(remainingTools.map(\.definition.name), ["mcp__fixture__echo"])
        XCTAssertTrue(didStop)
    }

    func testConfiguredServerReconnectsAndAtomicallyReplacesToolGeneration() async throws {
        let first = FakeMCPTransport(toolNames: ["echo"])
        let second = FakeMCPTransport(toolNames: ["search"])
        let sequence = MCPTransportSequence([first, second])
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { _, _ in sequence.next() }
        )
        let services = CordisAgentServices()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(MCPServerCordisPlugin.definition(
            configuration: MCPConfiguredServer(server: MCPStdioServerConfiguration(
                serverName: "fixture",
                command: "fixture-server"
            )),
            registry: registry,
            reconnectPolicy: MCPReconnectPolicy(
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(2),
                maximumAttempts: 2
            )
        ))
        let initialTools = await services.tools.snapshots().map(\.definition.name)
        XCTAssertEqual(initialTools, ["mcp__fixture__echo"])

        await first.exitNow()
        let didReplace = await eventually {
            await services.tools.snapshots().map(\.definition.name) == ["mcp__fixture__search"]
        }
        XCTAssertTrue(didReplace)
        let firstStarts = await first.startCount()
        let secondStarts = await second.startCount()
        XCTAssertEqual(firstStarts, 1)
        XCTAssertEqual(secondStarts, 1)
        let snapshots = await registry.snapshots()
        XCTAssertEqual(snapshots.map(\.state), [.running])
        XCTAssertEqual(snapshots.map(\.toolCount), [1])
    }

    func testReconnectStopsAfterBoundedFailuresAndRetractsTools() async throws {
        let first = FakeMCPTransport()
        let failures = MCPFailingTransport()
        let sequence = MCPTransportSequence([first, failures, failures])
        let published = MCPToolPublicationRecorder()
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { _, _ in sequence.next() }
        )
        let configuration = MCPClientConfiguration(
            server: MCPStdioServerConfiguration(serverName: "fixture", command: "fixture-server"),
            reconnectPolicy: MCPReconnectPolicy(
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(2),
                maximumAttempts: 2
            )
        )
        _ = try await registry.connect(configuration) { tools in
            await published.record(tools.map(\.name))
        }
        await first.exitNow()
        let didExhaust = await eventually {
            await registry.snapshots().isEmpty
        }
        XCTAssertTrue(didExhaust)
        let failureStarts = await failures.startCount()
        let lastPublication = await published.latest()
        XCTAssertEqual(failureStarts, 2)
        XCTAssertEqual(lastPublication, [])
    }

    func testDisposalDuringRecoveryCancelsPendingRestart() async throws {
        let first = FakeMCPTransport()
        let second = FakeMCPTransport(toolNames: ["search"])
        let sequence = MCPTransportSequence([first, second])
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { _, _ in sequence.next() }
        )
        let services = CordisAgentServices()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(MCPServerCordisPlugin.definition(
            configuration: MCPConfiguredServer(server: MCPStdioServerConfiguration(
                serverName: "fixture",
                command: "fixture-server"
            )),
            registry: registry,
            reconnectPolicy: MCPReconnectPolicy(
                initialDelay: .milliseconds(100),
                maximumDelay: .milliseconds(100),
                maximumAttempts: 1
            )
        ))
        await first.exitNow()
        _ = try await runtime.uninstall("mcp.fixture")
        try await Task.sleep(for: .milliseconds(150))
        let secondStarts = await second.startCount()
        let remainingTools = await services.tools.snapshots()
        XCTAssertEqual(secondStarts, 0)
        XCTAssertTrue(remainingTools.isEmpty)
    }

    func testInFlightCallRemainsBoundToExitedGeneration() async throws {
        let first = FakeMCPTransport(toolCallDelay: .milliseconds(200))
        let second = FakeMCPTransport()
        let sequence = MCPTransportSequence([first, second])
        let registry = MCPClientRegistry(
            workspaceURLProvider: { FileManager.default.temporaryDirectory },
            transportFactory: { _, _ in sequence.next() }
        )
        let configuration = MCPClientConfiguration(
            server: MCPStdioServerConfiguration(serverName: "fixture", command: "fixture-server"),
            reconnectPolicy: MCPReconnectPolicy(
                initialDelay: .milliseconds(1),
                maximumDelay: .milliseconds(2),
                maximumAttempts: 1
            )
        )
        _ = try await registry.connect(configuration)
        let call = Task {
            try await registry.call(
                serverName: "fixture",
                toolName: "echo",
                arguments: ["text": .string("in-flight")]
            )
        }
        let didStartCall = await eventually { await first.toolCallCount() == 1 }
        XCTAssertTrue(didStartCall)
        await first.exitNow()
        do {
            _ = try await call.value
            XCTFail("Expected old generation call to fail")
        } catch let error as MCPClientError {
            guard case .transportFailure = error else {
                return XCTFail("Expected transport failure, got \(error)")
            }
        }
        let didReconnect = await eventually { await second.startCount() == 1 }
        XCTAssertTrue(didReconnect)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }
}

private struct MCPTestTool: LocalAgentTool {
    let definition: ModelToolDefinition
    let risk: ToolRisk = .sideEffect

    init(name: String) {
        definition = ModelToolDefinition(name: name, description: "fixture", parameters: .object([:]))
    }

    func validate(arguments: [String: JSONValue]) throws {}
    func summary(arguments: [String: JSONValue]) -> String { "fixture" }
    func execute(arguments: [String: JSONValue]) async throws -> String { "fixture" }
}

private actor FakeMCPTransport: MCPStdioTransport {
    private var stdout: (@Sendable (Data) -> Void)?
    private var exit: (@Sendable (MCPTransportExit) -> Void)?
    private var stopped = false
    private var starts = 0
    private let toolNames: [String]
    private let toolCallDelay: Duration?
    private var toolCalls = 0

    init(toolNames: [String] = ["echo"], toolCallDelay: Duration? = nil) {
        self.toolNames = toolNames
        self.toolCallDelay = toolCallDelay
    }

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (MCPTransportExit) -> Void
    ) async throws -> Int32 {
        stdout = onStdout
        _ = onStderr
        exit = onExit
        stopped = false
        starts += 1
        return 77
    }

    func write(_ data: Data) async throws {
        guard !stopped else { throw MCPClientError.transportEOF }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String else {
            throw MCPClientError.malformedJSON
        }
        guard let id = object["id"] else { return }
        let result: Any
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "fixture", "version": "1"]
            ]
        case "tools/list":
            result = [
                "tools": toolNames.map { name in
                    [
                        "name": name,
                        "description": "Fixture \(name)",
                        "inputSchema": [
                            "type": "object",
                            "properties": ["text": ["type": "string"]],
                            "required": ["text"],
                            "additionalProperties": false
                        ]
                    ]
                }
            ]
        case "tools/call":
            toolCalls += 1
            let params = object["params"] as? [String: Any]
            let arguments = params?["arguments"] as? [String: Any]
            let text = arguments?["text"] as? String ?? ""
            result = [
                "content": [["type": "text", "text": text]],
                "structuredContent": ["echo": text],
                "isError": false
            ]
        default:
            throw MCPClientError.invalidJSONRPC("unexpected method \(method)")
        }
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ]
        var bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
        bytes.append(0x0A)
        if method == "tools/call", let toolCallDelay {
            let delayedStdout = stdout
            Task {
                try? await Task.sleep(for: toolCallDelay)
                delayedStdout?(bytes)
            }
        } else {
            stdout?(bytes)
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        exit?(MCPTransportExit(exitCode: 0, errorCode: 0))
    }

    func didStop() -> Bool { stopped }
    func startCount() -> Int { starts }
    func toolCallCount() -> Int { toolCalls }

    func exitNow() {
        stopped = true
        exit?(MCPTransportExit(exitCode: 1, errorCode: 0))
    }
}

private final class MCPTransportSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any MCPStdioTransport]

    init(_ transports: [any MCPStdioTransport]) {
        self.transports = transports
    }

    func next() -> any MCPStdioTransport {
        lock.lock()
        defer { lock.unlock() }
        guard !transports.isEmpty else { return MCPFailingTransport() }
        return transports.removeFirst()
    }
}

private actor MCPFailingTransport: MCPStdioTransport {
    private var starts = 0

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (MCPTransportExit) -> Void
    ) async throws -> Int32 {
        _ = onStdout
        _ = onStderr
        _ = onExit
        starts += 1
        throw MCPClientError.transportEOF
    }

    func write(_ data: Data) async throws { _ = data; throw MCPClientError.transportEOF }
    func stop() async {}
    func startCount() -> Int { starts }
}

private actor MCPToolPublicationRecorder {
    private var publications: [[String]] = []

    func record(_ names: [String]) {
        publications.append(names)
    }

    func latest() -> [String]? { publications.last }
}
