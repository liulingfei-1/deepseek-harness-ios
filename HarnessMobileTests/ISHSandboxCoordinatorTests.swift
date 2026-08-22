import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ISHSandboxCoordinatorTests: XCTestCase {
    func testArbitraryShellBoundaryIsAlwaysDestructive() {
        let tool = ISHShellExecuteTool(
            store: WorkspaceStore(),
            coordinator: ISHSandboxCoordinator(),
            sessionID: "approval-test"
        )

        XCTAssertEqual(tool.risk, .destructive)
        XCTAssertEqual(
            ToolPermissionMode.dangerFullAccess.decision(for: tool.risk),
            .ask
        )
    }

    func testExecutionPolicyCanonicalizesWorkspaceRoot() {
        let url = URL(fileURLWithPath: "/tmp/workspace/../workspace", isDirectory: true)
        let policy = ISHSandboxExecutionPolicy(mode: .workspaceWrite, workspaceRoot: url)

        XCTAssertEqual(policy.mode, .workspaceWrite)
        XCTAssertEqual(policy.workspaceRoot, "/tmp/workspace")
    }

    func testReadOnlyPolicyIsExplicitlyRepresented() {
        let policy = ISHSandboxExecutionPolicy(
            mode: .readOnly,
            workspaceRoot: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)
        )

        XCTAssertEqual(policy.mode.rawValue, "read-only")
        XCTAssertEqual(policy.workspaceRoot, "/tmp/workspace")
    }

    func testUnavailableCoordinatorFailsClosedBeforeSpawning() async throws {
        #if !os(iOS) || !canImport(HarnessISH)
        let coordinator = ISHSandboxCoordinator()
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)

        do {
            _ = try await coordinator.execute(
                sessionID: "test",
                command: "printf no",
                workspaceURL: workspace,
                policy: ISHSandboxExecutionPolicy(
                    mode: .dangerFullAccess,
                    workspaceRoot: workspace
                )
            )
            XCTFail("an unavailable sandbox must never execute a command")
        } catch let error as ISHSandboxError {
            XCTAssertEqual(error, .unavailable)
        }
        #endif
    }

    func testReadOnlyCoordinatorPolicyFailsClosedInsteadOfUsingWritableMount() async throws {
        let coordinator = ISHSandboxCoordinator()
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)

        do {
            _ = try await coordinator.execute(
                sessionID: "test",
                command: "touch should-not-run",
                workspaceURL: workspace,
                policy: ISHSandboxExecutionPolicy(mode: .readOnly, workspaceRoot: workspace)
            )
            XCTFail("read-only policy must not silently run against writable /workspace")
        } catch let error as ISHSandboxError {
            XCTAssertEqual(error, .policyUnavailable(.readOnly))
        }
    }

    func testWorkspaceWritePolicyFailsClosedUntilGuestRootCanBeConfined() async throws {
        let coordinator = ISHSandboxCoordinator()
        let workspace = URL(fileURLWithPath: "/tmp/workspace", isDirectory: true)

        do {
            _ = try await coordinator.execute(
                sessionID: "test",
                command: "touch /root/should-not-run",
                workspaceURL: workspace,
                policy: ISHSandboxExecutionPolicy(
                    mode: .workspaceWrite,
                    workspaceRoot: workspace
                )
            )
            XCTFail("workspace-write must not run while the guest root remains writable")
        } catch let error as ISHSandboxError {
            XCTAssertEqual(error, .policyUnavailable(.workspaceWrite))
        }
    }
}
