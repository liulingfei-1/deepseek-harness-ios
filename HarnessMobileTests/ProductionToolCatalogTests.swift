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
                "code_execute",
                "contacts_search",
                "diagnostics_read",
                "device_capabilities",
                "device_time",
                "exit_plan_mode",
                "glob",
                "grep",
                "ios_native",
                "job_kill",
                "job_list",
                "job_output",
                "lsp",
                "schedule_create",
                "schedule_list",
                "schedule_delete",
                "plugin_marketplace",
                "read",
                "read_image",
                "ralph",
                "run_code",
                "session_event_get",
                "session_event_types",
                "session_search",
                "session_trace",
                "location_current",
                "motion_activity",
                "notification_schedule",
                "secure_authenticate",
                "send_message",
                "shell_execute",
                "skill",
                "str_replace_editor",
                "subagent",
                "subagent_fork",
                "subagent_control",
                "subagent_list",
                "terminal_open",
                "terminal_read",
                "terminal_send",
                "terminal_signal",
                "terminal_list",
                "terminal_close",
                "web_fetch",
                "web_search",
                "browser_use",
                "workflow",
                "work_state_replace_plan",
                "work_state_replace_todos",
                "work_state_set_goal",
                "write",
                "edit",
                "workspace_list_files",
                "workspace_read_text",
                "workspace_write_text",
                "workspace_search"
                ,"workspace_diff"
                ,"deliverable_write"
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
