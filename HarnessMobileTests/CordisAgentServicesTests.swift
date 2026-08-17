import XCTest
@testable import HarnessMobileCore

final class CordisAgentServicesTests: XCTestCase {
    func testCoreServicesResolveAndToolFollowsPluginLifecycle() async throws {
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition(baseSystemPrompt: "Base"))

        let resolvedTools = try await runtime.resolveService(CordisAgentServiceKeys.tools)
        let resolvedPrompt = try await runtime.resolveService(CordisAgentServiceKeys.systemPrompt)
        XCTAssertTrue(resolvedTools === services.tools)
        XCTAssertTrue(resolvedPrompt === services.systemPrompt)

        let toolPlugin = CordisPluginDefinition(
            id: "tool.echo",
            version: "1",
            dependencies: [CordisAgentServiceKeys.tools.name]
        ) { context in
            try await context.registerTool(CordisTestTool(description: "old"))
        }
        _ = try await runtime.install(toolPlugin)

        var tools = await services.tools.snapshots()
        XCTAssertEqual(tools.map(\.definition.name), ["echo"])
        XCTAssertEqual(tools.first?.pluginID, "tool.echo")

        _ = try await runtime.setEnabled(false, for: "tool.echo")
        tools = await services.tools.snapshots()
        XCTAssertTrue(tools.isEmpty)

        _ = try await runtime.setEnabled(true, for: "tool.echo")
        tools = await services.tools.snapshots()
        XCTAssertEqual(tools.map(\.definition.name), ["echo"])
    }

    func testPromptAssemblyOrdersInterpolatesAndRetractsContributions() async throws {
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition(baseSystemPrompt: "Base"))
        let promptPlugin = CordisPluginDefinition(
            id: "prompt.model",
            version: "1",
            dependencies: [CordisAgentServiceKeys.systemPrompt.name]
        ) { context in
            try await context.promptVariable("model") { input in
                input.configuration.model
            }
            try await context.promptSection(
                CordisPromptSection(name: "model-guidance", order: 10, text: "Use {{model}}.")
            )
            try await context.promptContext(
                CordisPromptContextContribution(name: "step", order: 0) { input in
                    "Step \(input.step)"
                }
            )
        }
        _ = try await runtime.install(promptPlugin)

        let input = CordisPromptAssemblyInput(
            runID: UUID(),
            step: 2,
            configuration: AgentConfiguration(model: "deepseek-chat"),
            messages: []
        )
        var assembly = try await services.systemPrompt.assemble(input)
        XCTAssertEqual(assembly.systemPrompt, "Base\n\nUse deepseek-chat.")
        XCTAssertTrue(assembly.runtimeContext.contains("Step 2"))

        _ = try await runtime.setEnabled(false, for: "prompt.model")
        assembly = try await services.systemPrompt.assemble(input)
        XCTAssertEqual(assembly.systemPrompt, "Base")
        XCTAssertEqual(assembly.runtimeContext, "")
    }

    func testCompletePromptSectionReplacesOrdinarySections() async throws {
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition(baseSystemPrompt: "Base"))
        _ = try await runtime.install(
            CordisPluginDefinition(
                id: "prompt.complete",
                version: "1",
                dependencies: [CordisAgentServiceKeys.systemPrompt.name]
            ) { context in
                try await context.promptSection(
                    CordisPromptSection(
                        name: "replacement",
                        order: 0,
                        complete: true,
                        text: "Replacement"
                    )
                )
            }
        )

        let assembly = try await services.systemPrompt.assemble(
            CordisPromptAssemblyInput(
                runID: UUID(),
                step: 1,
                configuration: AgentConfiguration(),
                messages: []
            )
        )
        XCTAssertEqual(assembly.systemPrompt, "Replacement")
    }

    func testToolGuardCanOnlyReturnDenialAndRetractsOnDisable() async throws {
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(
            CordisPluginDefinition(
                id: "guard.echo",
                version: "1",
                dependencies: [CordisAgentServiceKeys.tools.name]
            ) { context in
                try await context.guardTool(label: "deny.echo") { execution in
                    execution.call.name == "echo" ? "blocked by plugin" : nil
                }
            }
        )
        let execution = CordisToolExecution(
            runID: UUID(),
            step: 1,
            call: AgentToolCall(id: "call-1", name: "echo", arguments: "{}"),
            arguments: [:],
            risk: .pure,
            summary: "Echo"
        )

        let activeReason = await services.tools.guardReason(for: execution)
        XCTAssertEqual(activeReason, "blocked by plugin")
        _ = try await runtime.setEnabled(false, for: "guard.echo")
        let reasonAfterDisable = await services.tools.guardReason(for: execution)
        XCTAssertNil(reasonAfterDisable)
    }

    func testFailedToolReplacementRestoresOldContribution() async throws {
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        let original = CordisPluginDefinition(
            id: "tool.echo",
            version: "1",
            dependencies: [CordisAgentServiceKeys.tools.name]
        ) { context in
            try await context.registerTool(CordisTestTool(description: "old"))
        }
        _ = try await runtime.install(original)

        let replacement = CordisPluginDefinition(
            id: "tool.echo",
            version: "2",
            dependencies: [CordisAgentServiceKeys.tools.name]
        ) { context in
            try await context.registerTool(CordisTestTool(description: "new"))
            throw CordisAgentServicesTestError.replacementFailed
        }
        do {
            _ = try await runtime.replace("tool.echo", with: replacement)
            XCTFail("Expected replacement rollback.")
        } catch let error as CordisPluginRuntimeError {
            guard case .replacementRolledBack = error else {
                return XCTFail("Unexpected Cordis error: \(error)")
            }
        }

        let restored = await services.tools.snapshots()
        let restoredPlugin = try await runtime.snapshot(for: "tool.echo")
        XCTAssertEqual(restored.first?.definition.description, "old")
        XCTAssertEqual(restoredPlugin.state, .active)
    }

    func testModelRequestPlanRoundTripsWithoutOwningCredential() {
        let request = ModelRequest(
            configuration: AgentConfiguration(model: "deepseek-chat"),
            apiKey: "source-secret",
            systemPrompt: "Prompt",
            messages: [],
            tools: []
        )
        var plan = CordisModelRequestPlan(request)
        plan.configuration.model = "deepseek-reasoner"
        let rebuilt = plan.modelRequest(
            apiKey: "host-injected-secret",
            systemPrompt: request.systemPrompt,
            messages: request.messages,
            tools: request.tools
        )

        XCTAssertEqual(rebuilt.configuration.model, "deepseek-reasoner")
        XCTAssertEqual(rebuilt.apiKey, "host-injected-secret")
        XCTAssertEqual(rebuilt.systemPrompt, "Prompt")
    }
}

private struct CordisTestTool: LocalAgentTool {
    let description: String

    var definition: ModelToolDefinition {
        ModelToolDefinition(
            name: "echo",
            description: description,
            parameters: .object(["type": .string("object")])
        )
    }

    let risk = ToolRisk.pure

    func validate(arguments: [String: JSONValue]) throws {}

    func summary(arguments: [String: JSONValue]) -> String {
        "Echo"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "ok"
    }
}

private enum CordisAgentServicesTestError: Error {
    case replacementFailed
}
