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
            runtimeContext: "local context",
            fallback: "fallback"
        )
        XCTAssertTrue(prompt.contains("reversible Cordis experiments"))
        XCTAssertTrue(prompt.contains("local context"))
    }

    func testStandardPresetKeepsCordisLifecycleToolsOptIn() throws {
        let standard = try XCTUnwrap(
            AgentPresetRegistry.systemPresets.first { $0.id == AgentPresetRegistry.defaultID }
        )
        let projection = standard.runtimeProjection

        XCTAssertFalse(projection.allowsTool("cordis_define"))
        XCTAssertFalse(projection.allowsTool("cordis_run"))
        XCTAssertTrue(projection.allowsTool("plugin_marketplace"))
    }
}
