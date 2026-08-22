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

    func testProductionCatalogContainsBoundedMCPControlTools() throws {
        let tools = MCPToolSuite.makeTools(
            workspaceStore: WorkspaceStore()
        )
        let definitions = tools.map(\.definition)
        let names = Set(definitions.map(\.name))
        XCTAssertTrue(MCPToolSuite.toolNames.isSubset(of: names))

        let call = try XCTUnwrap(definitions.first { $0.name == "mcp_call" })
        XCTAssertEqual(call.parameters.objectValue?["additionalProperties"], .bool(false))

        let connect = try XCTUnwrap(tools.first { $0.definition.name == "mcp_connect" })
        XCTAssertThrowsError(try connect.validate(arguments: [
            "server_name": .string("unsafe"),
            "command": .string("server"),
            "env": .object(["API_KEY": .string("sk-example-credential-must-not-cross")])
        ])) { error in
            XCTAssertEqual(error as? ISHPluginHostError, .credentialsForbidden)
        }
    }
}

private actor FakeMCPTransport: MCPStdioTransport {
    private var stdout: (@Sendable (Data) -> Void)?
    private var exit: (@Sendable (MCPTransportExit) -> Void)?
    private var stopped = false

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (MCPTransportExit) -> Void
    ) async throws -> Int32 {
        stdout = onStdout
        _ = onStderr
        exit = onExit
        stopped = false
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
                "tools": [[
                    "name": "echo",
                    "description": "Echo text",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["text": ["type": "string"]],
                        "required": ["text"],
                        "additionalProperties": false
                    ]
                ]]
            ]
        case "tools/call":
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
        stdout?(bytes)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        exit?(MCPTransportExit(exitCode: 0, errorCode: 0))
    }

    func didStop() -> Bool { stopped }
}
