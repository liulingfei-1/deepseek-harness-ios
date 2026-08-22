import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

private extension JSONValue {
    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}

final class WorkflowToolTests: XCTestCase {
    func testForegroundWorkflowFansOutChildrenAndRecordsLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let registry = HarnessJobRegistry(
            persistenceURL: root.appendingPathComponent("jobs.json")
        )
        let events = WorkflowEventRecorder()
        let runner: LocalSubagentRunner = { request, _ in
            "completed:\(request.prompt)"
        }
        let executor: LocalWorkflowScriptExecutor = { request, started, dispatch, phase, log, _ in
            XCTAssertEqual(request.args, .object(["topic": .string("mobile")]))
            await started()
            await phase("audit")
            await log("starting")
            let first = await dispatch(WorkflowAgentCall(
                requestID: "call-1",
                sequence: 1,
                prompt: "one",
                label: "first",
                phase: "audit",
                model: nil
            ))
            let second = await dispatch(WorkflowAgentCall(
                requestID: "call-2",
                sequence: 2,
                prompt: "two",
                label: "second",
                phase: "audit",
                model: nil
            ))
            return WorkflowScriptExecutionResult(
                value: .array([first.value, second.value]),
                agentsStarted: 2
            )
        }
        let tool = LocalWorkflowTool(
            runner: runner,
            registry: registry,
            ownerSession: UUID().uuidString.lowercased(),
            lifecycleSink: { event in await events.append(event) },
            scriptExecutor: executor
        )

        let output = try await tool.execute(arguments: [
            "script": .string("return await parallel([])"),
            "meta": .object([
                "name": .string("mobile-audit"),
                "description": .string("Audit two independent items")
            ]),
            "args": .object(["topic": .string("mobile")])
        ])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(decoded.objectValue?["agentsStarted"], .number(2))
        XCTAssertEqual(
            decoded.objectValue?["result"],
            .array([.string("completed:one"), .string("completed:two")])
        )

        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.first, .runStart(
            runID: decoded.objectValue?["runId"]?.stringValue ?? "",
            name: "mobile-audit"
        ))
        XCTAssertTrue(snapshot.contains(.phase(
            runID: decoded.objectValue?["runId"]?.stringValue ?? "",
            title: "audit"
        )))
        XCTAssertEqual(snapshot.filter(Self.isAgentStart).count, 2)
        XCTAssertEqual(snapshot.filter(Self.isAgentEnd).count, 2)
        let starts = snapshot.compactMap { event -> SessionEventDraft? in
            guard case .agentStart = event else { return nil }
            return event.sessionEvent
        }
        XCTAssertEqual(starts.count, 2)
        for start in starts {
            XCTAssertEqual(start.type, "tool-workflow/agent-start")
            XCTAssertNotNil(start.data.objectValue?["childId"]?.stringValue)
            XCTAssertEqual(start.data.objectValue?["parentId"]?.stringValue, decoded.objectValue?["runId"]?.stringValue)
            XCTAssertEqual(start.data.objectValue?["depth"]?.numberValue, .some(1))
            XCTAssertNotNil(start.data.objectValue?["startedAtMilliseconds"]?.numberValue)
        }
        let ends = snapshot.compactMap { event -> SessionEventDraft? in
            guard case .agentEnd = event else { return nil }
            return event.sessionEvent
        }
        XCTAssertEqual(ends.count, 2)
        for end in ends {
            XCTAssertEqual(end.type, "tool-workflow/agent-end")
            XCTAssertNotNil(end.data.objectValue?["durationMilliseconds"]?.numberValue)
        }
        XCTAssertEqual(snapshot.last, .runEnd(
            runID: decoded.objectValue?["runId"]?.stringValue ?? "",
            stopReason: "completed"
        ))
    }

    func testWorkflowValidationRejectsDesktopOnlyMetaOverrides() throws {
        let tool = LocalWorkflowTool(
            runner: nil,
            registry: HarnessJobRegistry(),
            ownerSession: "parent",
            lifecycleSink: { _ in },
            scriptExecutor: { _, _, _, _, _, _ in
                WorkflowScriptExecutionResult(value: .null, agentsStarted: 0)
            }
        )

        XCTAssertThrowsError(try tool.validate(arguments: [
            "script": .string("return null"),
            "meta": .object([
                "name": .string("bad"),
                "description": .string("bad"),
                "phases": .array([.object([
                    "title": .string("x"),
                    "provider": .string("remote")
                ])])
            ])
        ]))
    }

    func testSettledChildFailureReturnsNullWithoutAbortingWorkflow() async throws {
        let runner: LocalSubagentRunner = { _, _ in
            throw LocalToolError.pluginDenied("provider unavailable")
        }
        let executor: LocalWorkflowScriptExecutor = { _, _, dispatch, _, _, _ in
            let result = await dispatch(WorkflowAgentCall(
                requestID: UUID().uuidString.lowercased(),
                sequence: 1,
                prompt: "fails",
                label: "failing child",
                phase: nil,
                model: nil
            ))
            XCTAssertNil(result.error)
            XCTAssertEqual(result.value, .null)
            return WorkflowScriptExecutionResult(value: result.value, agentsStarted: 1)
        }
        let tool = LocalWorkflowTool(
            runner: runner,
            registry: HarnessJobRegistry(),
            ownerSession: UUID().uuidString.lowercased(),
            lifecycleSink: { _ in },
            scriptExecutor: executor
        )

        let output = try await tool.execute(arguments: [
            "script": .string("return null"),
            "meta": .object([
                "name": .string("child-failure"),
                "description": .string("child failure is a null branch")
            ])
        ])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(decoded.objectValue?["result"], .null)
    }

    func testPartialFailureKeepsSuccessfulBranchesAndRecordsBothOutcomes() async throws {
        let events = WorkflowEventRecorder()
        let executor: LocalWorkflowScriptExecutor = { _, started, dispatch, _, _, _ in
            await started()
            let success = await dispatch(WorkflowAgentCall(
                requestID: "partial-success",
                sequence: 1,
                prompt: "ok",
                label: "success",
                phase: nil,
                model: nil
            ))
            let failure = await dispatch(WorkflowAgentCall(
                requestID: "partial-failure",
                sequence: 2,
                prompt: "bad",
                label: "failure",
                phase: nil,
                model: nil
            ))
            return WorkflowScriptExecutionResult(
                value: .array([success.value, failure.value]),
                agentsStarted: 2
            )
        }
        let tool = LocalWorkflowTool(
            runner: { request, _ in
                if request.prompt == "bad" { throw LocalToolError.pluginDenied("child failed") }
                return "child ok"
            },
            registry: HarnessJobRegistry(),
            ownerSession: "partial-parent",
            lifecycleSink: { event in await events.append(event) },
            scriptExecutor: executor
        )

        let output = try await tool.execute(arguments: [
            "script": .string("return null"),
            "meta": .object([
                "name": .string("partial"),
                "description": .string("partial failure")
            ])
        ])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(decoded.objectValue?["result"], .array([.string("child ok"), .null]))
        let snapshot = await events.snapshot()
        XCTAssertEqual(snapshot.filter(Self.isAgentStart).count, 2)
        XCTAssertEqual(snapshot.filter(Self.isAgentEnd).count, 2)
        XCTAssertTrue(snapshot.contains { event in
            guard case let .agentEnd(_, sequence, outcome, _, _) = event else { return false }
            return sequence == 2 && outcome == "failed"
        })
    }

    func testChildTimeoutCancelsActivationAndMarksBranchCancelled() async throws {
        let events = WorkflowEventRecorder()
        let executor: LocalWorkflowScriptExecutor = { _, started, dispatch, _, _, _ in
            await started()
            let result = await dispatch(WorkflowAgentCall(
                requestID: "timeout-child",
                sequence: 1,
                prompt: "slow",
                label: "slow child",
                phase: nil,
                model: nil
            ))
            return WorkflowScriptExecutionResult(value: result.value, agentsStarted: 1)
        }
        let tool = LocalWorkflowTool(
            runner: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return "late"
            },
            registry: HarnessJobRegistry(),
            ownerSession: "timeout-parent",
            childTimeoutMilliseconds: 10,
            childTerminationGraceMilliseconds: 20,
            lifecycleSink: { event in await events.append(event) },
            scriptExecutor: executor
        )

        let output = try await tool.execute(arguments: [
            "script": .string("return null"),
            "meta": .object([
                "name": .string("timeout"),
                "description": .string("timeout")
            ])
        ])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        XCTAssertEqual(decoded.objectValue?["result"], .null)
        let snapshot = await events.snapshot()
        XCTAssertTrue(snapshot.contains { event in
            guard case let .agentEnd(_, sequence, outcome, _, error) = event else { return false }
            return sequence == 1 && outcome == "cancelled" && error != nil
        })
    }

    func testCancellingWorkflowDoesNotPublishSuccessfulCompletion() async throws {
        let events = WorkflowEventRecorder()
        let executor: LocalWorkflowScriptExecutor = { _, started, dispatch, _, _, _ in
            await started()
            _ = await dispatch(WorkflowAgentCall(
                requestID: "cancel-child",
                sequence: 1,
                prompt: "cancel me",
                label: "cancelled child",
                phase: nil,
                model: nil
            ))
            return WorkflowScriptExecutionResult(value: .string("incorrect"), agentsStarted: 1)
        }
        let tool = LocalWorkflowTool(
            runner: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return "late"
            },
            registry: HarnessJobRegistry(),
            ownerSession: "cancel-parent",
            lifecycleSink: { event in await events.append(event) },
            scriptExecutor: executor
        )
        let task = Task {
            try await tool.execute(arguments: [
                "script": .string("return null"),
                "meta": .object([
                    "name": .string("cancel"),
                    "description": .string("cancel")
                ])
            ])
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled workflow must not return a successful result")
        } catch is CancellationError {
            // expected
        }
        let snapshot = await events.snapshot()
        XCTAssertTrue(snapshot.contains(.runEnd(
            runID: snapshot.compactMap { event in
                guard case let .runStart(runID, _) = event else { return nil }
                return runID
            }.first ?? "",
            stopReason: "cancelled"
        )))
    }

    func testJavaScriptWrapperExposesBoundedWorkflowHooksOnly() {
        let source = ISHWorkflowScriptExecutor.wrapJavaScript(
            body: "return {ok: true}",
            args: .object(["value": .number(1)]),
            maximumConcurrentAgents: 3,
            maximumTotalAgents: 12,
            maximumItemsPerCall: 64
        )

        XCTAssertTrue(source.contains("vm.createContext"))
        XCTAssertTrue(source.contains("{agent, parallel, pipeline, phase, log, args: argsValue}"))
        XCTAssertTrue(source.contains("codeGeneration: {strings: false, wasm: false}"))
        XCTAssertTrue(source.contains("const MAX_CONCURRENT = 3"))
        XCTAssertTrue(source.contains("const MAX_TOTAL = 12"))
        XCTAssertTrue(source.contains("const MAX_ITEMS = 64"))
        XCTAssertFalse(source.contains("args: argsValue, process"))
        XCTAssertFalse(source.contains("apiKey"))
        XCTAssertTrue(source.contains("'provider', 'schema'"))
        XCTAssertTrue(source.contains("structured child schemas" ) == false)
    }

    func testWorkflowChildCarriesProviderBundleAndStructuredSchema() async throws {
        let requests = WorkflowSubagentRequestRecorder()
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["answer": .object(["type": .string("string")])]),
            "required": .array([.string("answer")])
        ])
        let executor: LocalWorkflowScriptExecutor = { _, started, dispatch, _, _, _ in
            await started()
            let result = await dispatch(WorkflowAgentCall(
                requestID: "schema-call",
                sequence: 1,
                prompt: "structured",
                label: "structured child",
                phase: nil,
                model: "deepseek-chat",
                providerBundleID: .codex,
                outputSchema: schema
            ))
            return WorkflowScriptExecutionResult(value: result.value, agentsStarted: 1)
        }
        let tool = LocalWorkflowTool(
            runner: { request, _ in
                await requests.append(request)
                return "{\"answer\":\"ok\"}"
            },
            registry: HarnessJobRegistry(),
            ownerSession: "schema-parent",
            lifecycleSink: { _ in },
            scriptExecutor: executor
        )
        _ = try await tool.execute(arguments: [
            "script": .string("return await agent('structured')"),
            "meta": .object(["name": .string("schema"), "description": .string("schema")])
        ])
        let captured = await requests.snapshot()
        let request = captured.first
        XCTAssertEqual(request?.providerBundleID, .codex)
        XCTAssertEqual(request?.outputSchema, schema)
        XCTAssertEqual(request?.model, "deepseek-chat")
    }

    func testWorkflowChildPreservesNestedDelegationDepth() async throws {
        let registry = HarnessJobRegistry()
        let root = "workflow-root"
        let nestedOwner = "workflow-nested-owner"
        _ = try await registry.registerSubagent(
            id: nestedOwner,
            parentSession: root,
            label: "nested owner",
            model: nil
        )
        let requests = WorkflowSubagentRequestRecorder()
        let runner: LocalSubagentRunner = { request, _ in
            await requests.append(request)
            return "nested done"
        }
        let executor: LocalWorkflowScriptExecutor = { _, started, dispatch, _, _, _ in
            await started()
            let value = await dispatch(WorkflowAgentCall(
                requestID: "nested-call",
                sequence: 1,
                prompt: "nested work",
                label: "nested child",
                phase: nil,
                model: nil
            ))
            return WorkflowScriptExecutionResult(value: value.value, agentsStarted: 1)
        }
        let tool = LocalWorkflowTool(
            runner: runner,
            registry: registry,
            ownerSession: nestedOwner,
            lifecycleSink: { _ in },
            scriptExecutor: executor
        )

        _ = try await tool.execute(arguments: [
            "script": .string("return await agent('nested work')"),
            "meta": .object([
                "name": .string("nested-depth"),
                "description": .string("Preserve nested child depth")
            ])
        ])
        let captured = await requests.snapshot()
        XCTAssertEqual(captured.first?.delegationDepth, 2)
    }

    private static func isAgentStart(_ event: LocalWorkflowLifecycleEvent) -> Bool {
        if case .agentStart = event { return true }
        return false
    }

    private static func isAgentEnd(_ event: LocalWorkflowLifecycleEvent) -> Bool {
        if case .agentEnd = event { return true }
        return false
    }
}

private actor WorkflowEventRecorder {
    private var events: [LocalWorkflowLifecycleEvent] = []
    func append(_ event: LocalWorkflowLifecycleEvent) { events.append(event) }
    func snapshot() -> [LocalWorkflowLifecycleEvent] { events }
}

private actor WorkflowSubagentRequestRecorder {
    private var requests: [LocalSubagentRequest] = []
    func append(_ request: LocalSubagentRequest) { requests.append(request) }
    func snapshot() -> [LocalSubagentRequest] { requests }
}
