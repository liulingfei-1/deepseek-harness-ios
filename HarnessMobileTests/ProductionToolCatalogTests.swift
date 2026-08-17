import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ProductionToolCatalogTests: XCTestCase {
    func testProductionToolSetMatchesAuditedAllowlist() {
        let registry = ProductionToolCatalog.makeRegistry(workspaceStore: WorkspaceStore())
        XCTAssertEqual(
            Set(registry.definitions.map(\.name)),
            [
                "ask_user_question",
                "camera_ocr",
                "contacts_search",
                "device_capabilities",
                "device_time",
                "exit_plan_mode",
                "ios_native",
                "plugin_marketplace",
                "location_current",
                "motion_activity",
                "notification_schedule",
                "secure_authenticate",
                "shell_execute",
                "skill",
                "web_fetch",
                "work_state_replace_plan",
                "work_state_replace_todos",
                "work_state_set_goal",
                "workspace_list_files",
                "workspace_read_text",
                "workspace_write_text"
            ]
        )
    }

    func testSystemPromptExposesOnlyTheOnDeviceShell() {
        XCTAssertTrue(MobileHarnessPrompt.text.contains("shell_execute"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("embedded iSH ARM64 Alpine guest"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("no remote executor"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("generation-scoped contribution"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("audited native web_fetch"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("never sends model-provider API keys"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("cordis_inspect_*"))
        XCTAssertTrue(MobileHarnessPrompt.text.contains("reversible experiment"))
        XCTAssertFalse(MobileHarnessPrompt.text.contains("no remote executor, shell, terminal"))
    }

    func testPureDeviceTimeToolExplicitlyOptsIntoParallelExecution() throws {
        XCTAssertTrue(try DeviceTimeTool().isConcurrencySafe(arguments: [:]))
    }
}
