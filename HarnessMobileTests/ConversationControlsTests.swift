import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ConversationControlsTests: XCTestCase {
    func testSteerInputsStayAheadOfNormalQueuedInputs() throws {
        var state = ConversationControlState()
        let first = try state.enqueue("normal one")
        let second = try state.enqueue("normal two")
        let steer = try state.enqueue("change direction", disposition: .steer)

        XCTAssertEqual(state.queuedInputs.map(\.id), [steer.id, first.id, second.id])
        XCTAssertEqual(state.popNext()?.disposition, .steer)
        XCTAssertEqual(state.popNext()?.text, "normal one")
    }

    func testQueuedInputCanBeEditedAndRemovedWithoutChangingIdentity() throws {
        var state = ConversationControlState()
        let input = try state.enqueue("before")

        try state.update(id: input.id, text: "after")
        XCTAssertEqual(state.queuedInputs.first?.id, input.id)
        XCTAssertEqual(state.queuedInputs.first?.text, "after")
        XCTAssertTrue(state.remove(id: input.id))
        XCTAssertTrue(state.queuedInputs.isEmpty)
    }

    func testQueuedInputCanBePromotedToSteerWithoutChangingIdentityOrTimestamp() throws {
        var state = ConversationControlState()
        let first = try state.enqueue("first")
        let second = try state.enqueue("second")

        try state.setDisposition(id: second.id, disposition: .steer)

        XCTAssertEqual(state.queuedInputs.map(\.id), [second.id, first.id])
        XCTAssertEqual(state.queuedInputs[0].createdAt, second.createdAt)
        XCTAssertEqual(state.queuedInputs[0].disposition, .steer)
    }

    func testSteerAllPreservesQueueOrder() throws {
        var state = ConversationControlState()
        let first = try state.enqueue("first")
        let second = try state.enqueue("second")

        state.steerAll()

        XCTAssertEqual(state.queuedInputs.map(\.id), [first.id, second.id])
        XCTAssertTrue(state.queuedInputs.allSatisfy { $0.disposition == .steer })
    }

    func testQueueEnforcesCountAndTextBounds() throws {
        var state = ConversationControlState()
        for index in 0..<ConversationControlState.maximumQueuedInputs {
            _ = try state.enqueue("item \(index)")
        }
        XCTAssertThrowsError(try state.enqueue("overflow"))
        XCTAssertThrowsError(try QueuedAgentInput(text: ""))
        XCTAssertThrowsError(try QueuedAgentInput(text: String(repeating: "x", count: 65_537)))
    }

    func testPermissionModesMapRiskToAllowAskAndDeny() {
        XCTAssertEqual(ToolPermissionMode.readOnly.decision(for: .pure), .allow)
        XCTAssertEqual(ToolPermissionMode.readOnly.decision(for: .sensitiveRead), .ask)
        XCTAssertEqual(ToolPermissionMode.readOnly.decision(for: .sideEffect), .deny)
        XCTAssertEqual(ToolPermissionMode.workspaceWrite.decision(for: .sideEffect), .ask)
        XCTAssertEqual(ToolPermissionMode.dangerFullAccess.decision(for: .destructive), .allow)
    }

    func testLegacyControlStateDefaultsToWorkspaceWritePermission() throws {
        let data = Data(
            """
            {
              "interactionMode":"agent",
              "queuedInputs":[]
            }
            """.utf8
        )

        let state = try JSONDecoder().decode(ConversationControlState.self, from: data)
        XCTAssertEqual(state.permissionMode, .workspaceWrite)
    }

    func testToolApprovalScopeNormalizesResourcesAndIncludesRiskDestination() throws {
        let scope = try ToolApprovalScope(
            toolName: "  shell_execute ",
            risk: .sideEffect,
            modelDestination: " HTTPS://API.EXAMPLE.COM ",
            resources: [" ish-sandbox:/workspace ", "ish-sandbox:/workspace"]
        )

        XCTAssertEqual(scope.toolName, "shell_execute")
        XCTAssertEqual(scope.risk, .sideEffect)
        XCTAssertEqual(scope.modelDestination, "https://api.example.com")
        XCTAssertEqual(scope.resources, ["ish-sandbox:/workspace"])
    }

    func testRememberedApprovalDoesNotCrossRiskOrModelDestination() throws {
        let call = AgentToolCall(
            id: "call-1",
            name: "shell_execute",
            arguments: "{\"command\":\"echo ok\"}"
        )
        let request = try ToolApprovalRequest(
            runID: UUID(),
            call: call,
            risk: .sideEffect,
            summary: "shell",
            modelHost: "api.example.com",
            approvalResources: ["ish-sandbox:/workspace"]
        )
        let grant = ToolApprovalGrant(scope: request.scope)
        XCTAssertTrue(grant.allows(request))

        let escalated = try ToolApprovalRequest(
            runID: request.runID,
            call: call,
            risk: .destructive,
            summary: "shell",
            modelHost: "api.example.com",
            approvalResources: ["ish-sandbox:/workspace"]
        )
        let otherDestination = try ToolApprovalRequest(
            runID: request.runID,
            call: call,
            risk: .sideEffect,
            summary: "shell",
            modelHost: "other.example.com",
            approvalResources: ["ish-sandbox:/workspace"]
        )
        XCTAssertFalse(grant.allows(escalated))
        XCTAssertFalse(grant.allows(otherDestination))
    }

    func testDeviceApprovalGrantCoversEveryLocalRiskLevel() throws {
        let shellCall = AgentToolCall(
            id: "call-device",
            name: "shell_execute",
            arguments: "{\"command\":\"echo ok\"}"
        )
        let shellRequest = try ToolApprovalRequest(
            runID: UUID(),
            call: shellCall,
            risk: .sideEffect,
            summary: "shell",
            modelHost: "api.example.com",
            approvalResources: ["ish-sandbox:/workspace"]
        )
        let deviceScope = try ToolApprovalScope(
            toolName: ToolApprovalScope.allLocalToolsMarker,
            risk: .sideEffect,
            modelDestination: "api.example.com",
            resources: [ToolApprovalScope.allLocalToolsResource]
        )
        let grant = ToolApprovalGrant(scope: deviceScope)
        XCTAssertTrue(grant.allows(shellRequest))

        let destructive = try ToolApprovalRequest(
            runID: shellRequest.runID,
            call: shellCall,
            risk: .destructive,
            summary: "shell",
            modelHost: "api.example.com",
            approvalResources: ["ish-sandbox:/workspace"]
        )
        XCTAssertTrue(grant.allows(destructive))

        let otherModel = try ToolApprovalRequest(
            runID: shellRequest.runID,
            call: shellCall,
            risk: .sideEffect,
            summary: "shell",
            modelHost: "other.example.com",
            approvalResources: ["ish-sandbox:/workspace"]
        )
        XCTAssertFalse(grant.allows(otherModel))
    }

    func testToolApprovalGrantsPersistAcrossSettingsStoreInstances() throws {
        let suiteName = "com.llf.harnessmobile.tool-approval.(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let scope = try ToolApprovalScope(
            toolName: "workspace_write_text",
            risk: .sideEffect,
            modelDestination: "api.example.com",
            resources: ["workspace:root"]
        )
        let grant = ToolApprovalGrant(
            scope: scope,
            grantedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try SettingsStore(defaults: defaults).saveToolApprovalGrants([grant])

        let reloaded = SettingsStore(defaults: defaults).loadToolApprovalGrants()
        XCTAssertEqual(reloaded, [grant])
        SettingsStore(defaults: defaults).clearToolApprovalGrants()
        XCTAssertTrue(SettingsStore(defaults: defaults).loadToolApprovalGrants().isEmpty)
    }
}
