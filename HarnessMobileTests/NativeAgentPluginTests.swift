import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class NativeAgentPluginTests: XCTestCase {
    func testNativeCompilationDiagnosticRoundTripsAndKeepsRetryContract() throws {
        let diagnostic = NativeAgentCompilationDiagnostic(
            code: "NATIVE_MANIFEST_INVALID",
            stage: "validation",
            message: "tool schema invalid",
            retryable: true,
            preparedToken: "prepared-1",
            suggestedAction: "修正后使用同一 token 重试"
        )

        let data = try JSONEncoder().encode(diagnostic)
        let decoded = try JSONDecoder().decode(
            NativeAgentCompilationDiagnostic.self,
            from: data
        )

        XCTAssertEqual(decoded, diagnostic)
        XCTAssertTrue(decoded.retryable)
        XCTAssertEqual(decoded.preparedToken, "prepared-1")
    }

    func testNativePluginPolicyExposesAuditedPhoneCapabilitiesOnly() {
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("ios_native"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("diagnostics_read"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("contacts_search"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("device_capabilities"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("web_fetch"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("ask_user_question"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("work_state_set_goal"))
        XCTAssertTrue(NativeAgentPluginPolicy.approvedBaseToolNames.contains("job_output"))
        XCTAssertFalse(NativeAgentPluginPolicy.approvedBaseToolNames.contains("shell_execute"))
        XCTAssertFalse(NativeAgentPluginPolicy.approvedBaseToolNames.contains("plugin_marketplace"))
    }

    func testOnlyDefinitiveNativeCompilationFailuresFallBackToISH() {
        XCTAssertTrue(NativeAgentPluginError.sourceNotAdaptable("unsupported").shouldFallbackToISH)
        XCTAssertFalse(NativeAgentPluginError.invalidCompiledPlugin("invalid").shouldFallbackToISH)
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

    func testDirectHiddenPathReadManifestValidates() throws {
        let plugin = try makePlugin(
            instructions: "Read `.harness-mobile/native-agent-plugins/<plugin-id>/notes.md` directly with workspace_read_text. Treat not-found as an empty note set.",
            allowedTools: ["workspace_read_text"]
        )

        XCTAssertNoThrow(
            try plugin.validated(
                allowedBaseTools: ["workspace_list_files", "workspace_read_text"]
            )
        )
    }

    func testListGatedHiddenPathReadManifestIsRejectedWithRepairGuidance() throws {
        let plugin = try makePlugin(
            instructions: "Call workspace_list_files and check whether the list contains `.harness-mobile/native-agent-plugins/<plugin-id>/notes.md`; if it exists, read it with workspace_read_text.",
            allowedTools: ["workspace_list_files", "workspace_read_text"]
        )

        XCTAssertThrowsError(
            try plugin.validated(
                allowedBaseTools: ["workspace_list_files", "workspace_read_text"]
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("直接读取"))
            XCTAssertTrue(error.localizedDescription.contains("not-found"))
        }
    }

    func testCompilerSystemPromptDefinesHiddenPathContract() {
        let prompt = NativeAgentPluginCompiler.systemPrompt(toolDirectory: "[]")

        XCTAssertTrue(prompt.contains("Hidden paths are deliberately absent"))
        XCTAssertTrue(prompt.contains("Never generate list/enumerate -> contains/exists -> read"))
        XCTAssertTrue(prompt.contains("treat not-found as the initial empty state"))
        XCTAssertTrue(prompt.contains("diagnostics_read"))
        XCTAssertTrue(prompt.contains("ios_native"))
        XCTAssertTrue(prompt.contains("apple-healthkit"))
        XCTAssertTrue(prompt.contains("<session-storage>"))
        XCTAssertTrue(prompt.contains("prompt_contexts"))
        XCTAssertTrue(prompt.contains("tool_guards"))
    }

    func testLegacyCompiledManifestDecodesWithEmptyNewContributions() throws {
        let plugin = try makePlugin()
        let encoded = try JSONEncoder().encode(plugin)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "promptContexts")
        object.removeValue(forKey: "settings")
        object.removeValue(forKey: "toolGuards")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(NativeAgentCompiledPlugin.self, from: legacyData)

        XCTAssertTrue(decoded.promptContexts.isEmpty)
        XCTAssertNil(decoded.settings)
        XCTAssertTrue(decoded.toolGuards.isEmpty)
        XCTAssertEqual(decoded.tools.map(\.name), ["memory_add"])
    }

    func testRuntimePlaceholdersIncludeSessionStorageAndSettings() throws {
        let settings = try makeSettings(values: .object(["limit": .number(42)]))
        let plugin = try makePlugin(settings: settings)

        let rendered = plugin.runtimeText(
            "<plugin-id>|<session-id>|<plugin-storage>|<session-storage>|<settings-json>",
            sessionID: "session-7"
        )

        XCTAssertTrue(rendered.contains("native-agent.memory|session-7"))
        XCTAssertTrue(rendered.contains("native-agent.memory/sessions/session-7"))
        XCTAssertTrue(rendered.contains("\"limit\""))
        XCTAssertTrue(rendered.contains("42"))
    }

    func testDynamicFileContextUsesCurrentSessionPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkspaceStore(root: directory)
        let sessionID = UUID()
        let path = ".harness-mobile/native-agent-plugins/native-agent.memory/sessions/\(sessionID.uuidString)/state.md"
        try await store.writeText(path: path, text: "session-private-state {{literal-data}}")
        let plugin = try makePlugin(
            promptContexts: [
                NativeAgentPromptContext(
                    name: "session-memory",
                    order: 10,
                    source: .file,
                    path: "<session-storage>/state.md",
                    maximumCharacters: 2_000,
                    prefix: "<memory>",
                    suffix: "</memory>"
                )
            ]
        )
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition(baseSystemPrompt: "Base"))
        _ = try await runtime.install(WorkspaceFileSystemCordisPlugin.definition(store: store))
        _ = try await runtime.install(
            plugin.cordisDefinition { _, _, _, _ in "ok" }
        )

        let assembly = try await services.systemPrompt.assemble(
            CordisPromptAssemblyInput(
                runID: UUID(),
                agentID: sessionID,
                step: 2,
                configuration: AgentConfiguration(),
                messages: []
            )
        )

        XCTAssertTrue(
            assembly.runtimeContext.contains(
                "<memory>session-private-state {{literal-data}}</memory>"
            )
        )
    }

    func testDeclarativeToolGuardCanRequireApproval() async throws {
        let plugin = try makePlugin(
            toolGuards: [
                NativeAgentToolGuard(
                    label: "confirm-side-effects",
                    toolNames: [],
                    risks: [.sideEffect],
                    decision: .ask,
                    reason: "Confirm this action."
                )
            ]
        )
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(
            plugin.cordisDefinition { _, _, _, _ in "ok" }
        )
        let execution = CordisToolExecution(
            runID: UUID(),
            step: 1,
            call: AgentToolCall(id: "call-1", name: "ios_native", arguments: "{}"),
            arguments: [:],
            risk: .sideEffect,
            summary: "Native action"
        )

        let decision = try await runtime.run(
            CordisAgentLoopCheckpoints.toolsPreExecute,
            input: execution,
            target: .global
        ) {
            .allow
        }

        XCTAssertEqual(decision, .ask)
    }

    func testMarketplaceCompatibilityNotesAreNotReportedAsLoadFailure() throws {
        let plugin = try makePlugin(compatibilityNotes: ["Browser UI omitted on iPhone."])

        XCTAssertNil(plugin.marketplaceProjection.lastError)
        XCTAssertEqual(plugin.compatibilityNotes, ["Browser UI omitted on iPhone."])
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

    func testStorePersistsValidatedNativeSettings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("plugins.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NativeAgentPluginStore(fileURL: fileURL)
        let allowed = Set(["workspace_write_text"])
        let plugin = try makePlugin(settings: makeSettings())
        _ = try await store.upsert(plugin, replace: false, allowedBaseTools: allowed)

        let updated = try await store.setSettings(
            id: plugin.id,
            values: .object(["limit": .number(120)]),
            allowedBaseTools: allowed
        )

        XCTAssertEqual(updated.first?.settings?.values, .object(["limit": .number(120)]))
    }

    func testNativeSettingsJSONSchemaBuildsEditableForm() throws {
        let settings = try makeSettings()
        let namespace = ISHPluginSettingsNamespace(
            ns: "native-agent.memory",
            schema: settings.schema,
            value: settings.values,
            base: settings.defaults,
            user: settings.values,
            revision: 1,
            applies: .live,
            secrets: [],
            editable: true,
            unsupportedReason: nil
        )

        let form = try ISHPluginSettingsForm(namespace: namespace)

        XCTAssertEqual(form.rootFields.map(\.field.path), [["limit"]])
        guard case let .number(minimum, maximum, step) = form.rootFields[0].field.kind else {
            return XCTFail("Expected numeric setting field.")
        }
        XCTAssertEqual(minimum, 1)
        XCTAssertEqual(maximum, 1_000)
        XCTAssertEqual(step, 1)
    }

    private func makePlugin(
        instructions: String = "Write memory under <plugin-id>.",
        allowedTools: [String] = ["workspace_write_text"],
        promptContexts: [NativeAgentPromptContext] = [],
        settings: NativeAgentPluginSettings? = nil,
        toolGuards: [NativeAgentToolGuard] = [],
        compatibilityNotes: [String] = []
    ) throws -> NativeAgentCompiledPlugin {
        NativeAgentCompiledPlugin(
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
            promptContexts: promptContexts,
            settings: settings,
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
                    instructions: instructions,
                    allowedTools: allowedTools
                )
            ],
            toolGuards: toolGuards,
            compatibilityNotes: compatibilityNotes
        )
    }

    private func makeSettings(
        values: JSONValue = .object(["limit": .number(60)])
    ) throws -> NativeAgentPluginSettings {
        NativeAgentPluginSettings(
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .number(1),
                        "maximum": .number(1_000),
                        "default": .number(60)
                    ])
                ]),
                "required": .array([.string("limit")]),
                "additionalProperties": .bool(false)
            ]),
            defaults: .object(["limit": .number(60)]),
            values: values
        )
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
