import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class AgentPresetTests: XCTestCase {
    func testCreativePresetKeepsCordisLifecycleToolsAndAddsExperimentGuidance() throws {
        let creative = try XCTUnwrap(
            AgentPresetRegistry.systemPresets.first { $0.id == "cordis" }
        )
        let projection = creative.runtimeProjection

        XCTAssertTrue(projection.allowsTool("cordis_inspect_list"))
        XCTAssertTrue(projection.allowsTool("cordis_define"))
        XCTAssertTrue(projection.allowsTool("plugin_marketplace"))

        let prompt = projection.systemPrompt(
            assembledSystemPrompt: "base prompt",
            fallback: "fallback"
        )
        XCTAssertTrue(prompt.contains("reversible Cordis experiments"))
        XCTAssertFalse(prompt.contains("local context"))
        XCTAssertEqual(projection.runtimeContext("local context"), "local context")
    }

    func testStandardPresetKeepsCordisLifecycleToolsOptIn() throws {
        let standard = try XCTUnwrap(
            AgentPresetRegistry.systemPresets.first { $0.id == AgentPresetRegistry.defaultID }
        )
        let projection = standard.runtimeProjection

        XCTAssertFalse(projection.allowsTool("cordis_define"))
        XCTAssertFalse(projection.allowsTool("cordis_run"))
        XCTAssertTrue(projection.allowsTool("plugin_marketplace"))
        XCTAssertFalse(projection.allowsTool("run_code"))
    }

    func testCodePresetIsMountableAndCollapsesPresentationToRunCode() throws {
        let code = try XCTUnwrap(
            AgentPresetRegistry.systemPresets.first { $0.id == "code" }
        )
        XCTAssertTrue(code.isMountable)
        let projection = code.runtimeProjection
        XCTAssertTrue(projection.isCodeMode)
        XCTAssertTrue(projection.allowsTool("run_code"))
        XCTAssertFalse(projection.allowsTool("read"))
        XCTAssertEqual(
            projection.filterTools([
                ModelToolDefinition(name: "read", description: "read", parameters: .object([:])),
                ModelToolDefinition(name: "run_code", description: "code", parameters: .object([:]))
            ]).map(\.name),
            ["run_code"]
        )
    }

    func testGeneratedPythonSDKCarriesLiveToolSchemas() {
        let sdk = CodeModePythonSDK.render(definitions: [
            ModelToolDefinition(
                name: "workspace_read_text",
                description: "Read a workspace file.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(["type": .string("string")])]),
                    "required": .array([.string("path")])
                ])
            )
        ])
        XCTAssertTrue(sdk.contains("async def workspace_read_text"))
        XCTAssertTrue(sdk.contains("Parameters JSON Schema"))
        XCTAssertTrue(sdk.contains("ToolCallError"))
    }
}
