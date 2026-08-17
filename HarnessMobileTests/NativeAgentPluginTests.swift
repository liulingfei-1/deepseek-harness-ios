import Foundation
import XCTest
@testable import HarnessMobileCore

final class NativeAgentPluginTests: XCTestCase {
    func testOnlyDefinitiveNativeCompilationFailuresFallBackToISH() {
        XCTAssertTrue(NativeAgentPluginError.sourceNotAdaptable("unsupported").shouldFallbackToISH)
        XCTAssertTrue(NativeAgentPluginError.invalidCompiledPlugin("invalid").shouldFallbackToISH)
        XCTAssertFalse(NativeAgentPluginError.compilerDidNotReturnManifest.shouldFallbackToISH)
        XCTAssertFalse(NativeAgentPluginError.invalidSourceSnapshot.shouldFallbackToISH)
        XCTAssertFalse(NativeAgentPluginError.alreadyInstalled("native-agent.demo").shouldFallbackToISH)
    }

    func testCompilerBuildsValidatedNativeManifestFromToolCall() async throws {
        let arguments = JSONValue.object([
            "adaptable": .bool(true),
            "name": .string("Continual Memory Native"),
            "description": .string("Versioned memory stored in the iPhone workspace."),
            "prompt_sections": .array([
                .object([
                    "order": .number(118),
                    "text": .string("Use memory_add after durable discoveries.")
                ])
            ]),
            "tools": .array([
                .object([
                    "name": .string("memory_add"),
                    "description": .string("Persist one durable memory."),
                    "parameters": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("text")]),
                        "additionalProperties": .bool(false)
                    ]),
                    "risk": .string("localState"),
                    "instructions": .string("Append the memory to <plugin-id>/memories.json."),
                    "allowed_tools": .array([.string("workspace_write_text")])
                ])
            ]),
            "compatibility_notes": .array([
                .string("Desktop background timers are omitted on iPhone.")
            ])
        ]).displayText
        let compiler = NativeAgentPluginCompiler(
            client: NativeAgentCompilerMockClient(events: [
                .toolCallDelta(
                    index: 0,
                    id: "compile-1",
                    type: "function",
                    name: "emit_native_plugin_manifest",
                    arguments: arguments
                ),
                .finish(.toolCalls)
            ])
        )
        let source = NativeAgentPluginSourceSnapshot(
            schemaVersion: 1,
            failureReason: "missing-entrypoint",
            sourceDigest: String(repeating: "a", count: 64),
            source: ISHMarketplacePluginSource(
                kind: .github,
                location: "https://github.com/example/memory"
            ),
            packageName: "dsh-memory",
            version: "0.2.0",
            description: "Memory plugin",
            files: [
                NativeAgentPluginSourceFile(
                    path: "src/index.ts",
                    content: "export function apply() {}",
                    truncated: false
                )
            ]
        )
        let baseTool = ModelToolDefinition(
            name: "workspace_write_text",
            description: "Write workspace text.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(true)
            ])
        )

        let plugin = try await compiler.compile(
            source: source,
            configuration: AgentConfiguration(),
            apiKey: "test-key",
            allowedToolDefinitions: [baseTool]
        )

        XCTAssertEqual(plugin.id, "native-agent.dsh-memory")
        XCTAssertEqual(plugin.tools.map(\.name), ["memory_add"])
        XCTAssertEqual(plugin.tools[0].allowedTools, ["workspace_write_text"])
        XCTAssertFalse(plugin.enabled)
        XCTAssertEqual(plugin.compatibilityNotes.count, 1)
    }

    func testCompiledToolValidatesRequiredAndUnknownArguments() throws {
        let plugin = try makePlugin()
        let tool = NativeAgentCompiledLocalTool(
            plugin: plugin,
            compiledTool: plugin.tools[0],
            executor: { _, _, _, _ in "ok" }
        )

        XCTAssertNoThrow(try tool.validate(arguments: ["text": .string("remember")]))
        XCTAssertThrowsError(try tool.validate(arguments: [:]))
        XCTAssertThrowsError(
            try tool.validate(arguments: [
                "text": .string("remember"),
                "unexpected": .bool(true)
            ])
        )
    }

    func testStorePersistsEnableAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("plugins.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeAgentPluginStore(fileURL: fileURL)
        let allowed = Set(["workspace_write_text"])
        let plugin = try makePlugin()

        var plugins = try await store.upsert(
            plugin,
            replace: false,
            allowedBaseTools: allowed
        )
        XCTAssertEqual(plugins.map(\.id), [plugin.id])

        plugins = try await store.setEnabled(
            id: plugin.id,
            enabled: true,
            allowedBaseTools: allowed
        )
        XCTAssertTrue(try XCTUnwrap(plugins.first).enabled)

        plugins = try await store.remove(id: plugin.id, allowedBaseTools: allowed)
        XCTAssertTrue(plugins.isEmpty)
    }

    private func makePlugin() throws -> NativeAgentCompiledPlugin {
        try NativeAgentCompiledPlugin(
            schemaVersion: NativeAgentCompiledPlugin.schemaVersion,
            id: "native-agent.memory",
            name: "Memory",
            version: "1.0.0",
            description: "Native memory",
            source: ISHMarketplacePluginSource(
                kind: .github,
                location: "https://github.com/example/memory"
            ),
            sourceDigest: String(repeating: "b", count: 64),
            compiledAt: .now,
            compilerProviderID: "deepseek-official",
            compilerModel: "deepseek-v4-flash",
            enabled: false,
            promptSections: [],
            tools: [
                NativeAgentCompiledTool(
                    name: "memory_add",
                    description: "Persist memory.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "text": .object(["type": .string("string")])
                        ]),
                        "required": .array([.string("text")]),
                        "additionalProperties": .bool(false)
                    ]),
                    risk: .localState,
                    instructions: "Write memory under <plugin-id>.",
                    allowedTools: ["workspace_write_text"]
                )
            ],
            compatibilityNotes: []
        ).validated(allowedBaseTools: ["workspace_write_text"])
    }
}

private struct NativeAgentCompilerMockClient: LLMStreamingClient {
    let events: [LLMStreamEvent]

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
