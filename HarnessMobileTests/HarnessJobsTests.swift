import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessJobsTests: XCTestCase {
    func testOwnedJobsAreIsolatedAndListedInRegistrationOrder() async throws {
        let registry = HarnessJobRegistry()
        let first = try await registry.start(
            kind: "bash",
            label: "first",
            ownerSession: "alice",
            outputLimitBytes: nil
        ) { _ in
            HarnessJobOutcome(status: .completed, detail: "exit code: 0")
        }
        let second = try await registry.start(
            kind: "subagent",
            label: "second",
            ownerSession: "alice",
            outputLimitBytes: nil
        ) { _ in
            HarnessJobOutcome(status: .completed)
        }
        _ = try await registry.start(
            kind: "bash",
            label: "private",
            ownerSession: "bob",
            outputLimitBytes: nil
        ) { _ in
            HarnessJobOutcome(status: .completed)
        }

        let aliceJobs = await registry.list(ownerSession: "alice")
        XCTAssertEqual(aliceJobs.map(\.id), [first, second])
        do {
            _ = try await registry.get(id: first, ownerSession: "bob")
            XCTFail("Foreign session should not access an owned job")
        } catch let error as HarnessJobError {
            XCTAssertEqual(error, .foreignJob(first))
        }
    }

    func testStreamOutputUsesOneConsumingCursor() async throws {
        let registry = HarnessJobRegistry()
        let gate = JobTestGate()
        let id = try await registry.start(
            kind: "bash",
            label: "stream",
            ownerSession: "session",
            outputLimitBytes: 1_024
        ) { emit in
            await emit("line one\n")
            await gate.wait()
            await emit("line two\n")
            return HarnessJobOutcome(status: .completed, detail: "exit code: 0")
        }

        let first = try await waitForOutput(
            registry: registry,
            id: id,
            ownerSession: "session"
        )
        XCTAssertEqual(first.text, "line one\n")
        let consumed = try await registry.read(id: id, ownerSession: "session")
        XCTAssertEqual(consumed.text, "")

        await gate.open()
        _ = try await registry.wait(
            id: id,
            timeoutMilliseconds: 1_000,
            ownerSession: "session"
        )
        let final = try await registry.read(id: id, ownerSession: "session")
        XCTAssertEqual(final.text, "line two\n")
        XCTAssertEqual(final.snapshot.status, .completed)
        XCTAssertTrue(final.snapshot.reported)
    }

    func testWaitTimeoutLeavesJobRunning() async throws {
        let registry = HarnessJobRegistry()
        let id = try await registry.start(
            kind: "bash",
            label: "slow",
            ownerSession: "session",
            outputLimitBytes: nil
        ) { _ in
            try await Task.sleep(for: .seconds(5))
            return HarnessJobOutcome(status: .completed)
        }

        let snapshot = try await registry.wait(
            id: id,
            timeoutMilliseconds: 5,
            ownerSession: "session"
        )
        XCTAssertEqual(snapshot.status, .running)

        _ = try await registry.kill(id: id, ownerSession: "session", reason: "test")
        let killed = try await registry.wait(
            id: id,
            timeoutMilliseconds: 1_000,
            ownerSession: "session"
        )
        XCTAssertEqual(killed.status, .killed)
    }

    func testKillTransitionsThroughStoppingAndSettlesKilled() async throws {
        let registry = HarnessJobRegistry()
        let id = try await registry.start(
            kind: "bash",
            label: "sleep",
            ownerSession: "session",
            outputLimitBytes: nil
        ) { _ in
            try await Task.sleep(for: .seconds(30))
            return HarnessJobOutcome(status: .completed)
        }

        let result = try await registry.kill(
            id: id,
            ownerSession: "session",
            reason: "obsolete"
        )
        XCTAssertEqual(result, .requested)
        let stopping = try await registry.get(id: id, ownerSession: "session")
        XCTAssertTrue(stopping.status == .stopping || stopping.status == .killed)
        XCTAssertTrue(stopping.reported)

        let terminal = try await registry.wait(
            id: id,
            timeoutMilliseconds: 1_000,
            ownerSession: "session"
        )
        XCTAssertEqual(terminal.status, .killed)
        XCTAssertNotNil(terminal.finishedAt)
        let repeatedKill = try await registry.kill(
            id: id,
            ownerSession: "session",
            reason: nil
        )
        XCTAssertEqual(repeatedKill, .alreadyFinished)
    }

    func testTerminalOutputIsDeliveredOnceAndCombinesStreamAndFinalResult() async throws {
        let registry = HarnessJobRegistry()
        let id = try await registry.start(
            kind: "subagent",
            label: "combined",
            ownerSession: "session",
            outputLimitBytes: nil
        ) { emit in
            await emit("partial\n")
            return HarnessJobOutcome(status: .completed, output: "final answer")
        }

        _ = try await registry.wait(id: id, timeoutMilliseconds: 1_000, ownerSession: "session")
        let first = try await registry.read(id: id, ownerSession: "session")
        XCTAssertTrue(first.text.contains("partial"))
        XCTAssertTrue(first.text.contains("final answer"))
        let second = try await registry.read(id: id, ownerSession: "session")
        XCTAssertEqual(second.text, "final answer")
    }

    func testFinalOutputUsesTheSameBoundedPersistenceLimitAsStreamOutput() async throws {
        let registry = HarnessJobRegistry()
        let oversized = String(repeating: "x", count: 4_096)
        let id = try await registry.start(
            kind: "bash",
            label: "bounded final",
            ownerSession: "session",
            outputLimitBytes: 256
        ) { _ in
            HarnessJobOutcome(status: .completed, output: oversized)
        }

        _ = try await registry.wait(id: id, timeoutMilliseconds: 1_000, ownerSession: "session")
        let read = try await registry.read(id: id, ownerSession: "session")
        XCTAssertLessThanOrEqual(read.text.utf8.count, 512)
        XCTAssertTrue(read.text.contains("earlier output truncated"))
        XCTAssertTrue(read.snapshot.detail?.contains("tail-truncated") == true)
    }

    func testPersistedJobsRecoverRunningWorkAsExplicitlyInterrupted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessJobsPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("jobs.json")
        let firstRegistry = HarnessJobRegistry(persistenceURL: file)
        let id = try await firstRegistry.start(
            kind: "subagent",
            label: "survive restart",
            ownerSession: "session",
            outputLimitBytes: nil
        ) { emit in
            await emit("checkpoint\n")
            try await Task.sleep(for: .seconds(30))
            return HarnessJobOutcome(status: .completed)
        }
        try await Task.sleep(for: .milliseconds(350))

        let recovered = HarnessJobRegistry(persistenceURL: file)
        let snapshot = try await recovered.get(id: id, ownerSession: "session")
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertTrue(snapshot.detail?.contains("app restart") == true)
        let output = try await recovered.read(id: id, ownerSession: "session")
        XCTAssertTrue(output.text.contains("checkpoint"))

        _ = try await firstRegistry.kill(id: id, ownerSession: "session", reason: "test cleanup")
        _ = try await firstRegistry.wait(id: id, timeoutMilliseconds: 1_000, ownerSession: "session")
    }

    func testSubagentToolsSupportForegroundBackgroundListWaitAndInterrupt() async throws {
        let registry = HarnessJobRegistry()
        let runner: LocalSubagentRunner = { request, emit in
            if request.prompt == "interrupt" {
                try await Task.sleep(for: .seconds(30))
            } else {
                await emit(AgentToolOutputChunk(channel: .progress, text: "child progress\n"))
                try await Task.sleep(for: .milliseconds(40))
            }
            return "child final"
        }
        let tools = SubagentToolSuite.makeTools(
            runner: runner,
            registry: registry,
            ownerSession: "parent"
        )
        let toolRegistry = LocalToolRegistry(tools: tools)
        let subagent = try XCTUnwrap(toolRegistry.tool(named: "subagent"))
        let list = try XCTUnwrap(toolRegistry.tool(named: "subagent_list"))
        let control = try XCTUnwrap(toolRegistry.tool(named: "subagent_control"))
        let sendMessage = try XCTUnwrap(toolRegistry.tool(named: "send_message"))
        let outputTool = JobToolSuite.makeTools(registry: registry, ownerSession: "parent")
            .first { $0.definition.name == "job_output" }
        let jobOutput = try XCTUnwrap(outputTool)

        let foreground = try await subagent.execute(arguments: [
            "prompt": .string("foreground"),
            "label": .string("foreground")
        ])
        XCTAssertTrue(foreground.contains("child final"))
        let foregroundJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(foreground.utf8)) as? [String: Any]
        )
        let foregroundAddress = try XCTUnwrap(foregroundJSON["subagent_id"] as? String)
        let followup = try await sendMessage.execute(arguments: [
            "subagent_id": .string(foregroundAddress),
            "message": .string("continue")
        ])
        XCTAssertTrue(followup.contains(foregroundAddress))

        let background = try await subagent.execute(arguments: [
            "prompt": .string("background"),
            "label": .string("background"),
            "run_in_background": .bool(true)
        ])
        let backgroundJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(background.utf8)) as? [String: Any]
        )
        let backgroundID = try XCTUnwrap(backgroundJSON["job_id"] as? String)
        let backgroundAddress = try XCTUnwrap(backgroundJSON["subagent_id"] as? String)
        XCTAssertFalse(backgroundID.isEmpty)
        let children = try await list.execute(arguments: [:])
        XCTAssertTrue(children.contains(backgroundAddress))
        let settled = try await control.execute(arguments: [
            "subagent_id": .string(backgroundAddress),
            "action": .string("wait"),
            "timeout_ms": .number(1_000)
        ])
        XCTAssertTrue(settled.contains("completed"))
        let childOutput = try await jobOutput.execute(arguments: [
            "job_id": .string(backgroundID)
        ])
        XCTAssertTrue(childOutput.contains("child progress"))
        XCTAssertTrue(childOutput.contains("child final"))

        let interrupt = try await subagent.execute(arguments: [
            "prompt": .string("interrupt"),
            "label": .string("interrupt"),
            "run_in_background": .bool(true)
        ])
        let interruptJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(interrupt.utf8)) as? [String: Any]
        )
        let interruptID = try XCTUnwrap(interruptJSON["job_id"] as? String)
        let interruptAddress = try XCTUnwrap(interruptJSON["subagent_id"] as? String)
        _ = try await control.execute(arguments: [
            "subagent_id": .string(interruptAddress),
            "action": .string("interrupt"),
            "reason": .string("test")
        ])
        let interrupted = try await control.execute(arguments: [
            "subagent_id": .string(interruptAddress),
            "action": .string("wait"),
            "timeout_ms": .number(1_000)
        ])
        XCTAssertTrue(interrupted.contains("killed"))
        let resumedAfterInterrupt = try await sendMessage.execute(arguments: [
            "subagent_id": .string(interruptAddress),
            "message": .string("wake again")
        ])
        let resumedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(resumedAfterInterrupt.utf8)) as? [String: Any]
        )
        let resumedJobID = try XCTUnwrap(resumedJSON["job_id"] as? String)
        _ = try await registry.wait(
            id: resumedJobID,
            timeoutMilliseconds: 1_000,
            ownerSession: "parent"
        )
        let resumedSubagent = try await registry.subagent(
            id: interruptAddress,
            requesterSession: "parent"
        )
        XCTAssertEqual(resumedSubagent.status, .completed)
        _ = interruptID
    }

    func testSubagentDefinitionExposesRC8ProviderBundleAndRejectsUnknownBundle() async throws {
        let registry = HarnessJobRegistry()
        let runner: LocalSubagentRunner = { _, _ in "done" }
        let subagent = try XCTUnwrap(
            SubagentToolSuite.makeTools(
                runner: runner,
                registry: registry,
                ownerSession: "parent"
            ).first { $0.definition.name == "subagent" }
        )

        XCTAssertTrue(subagent.definition.parameters.displayText.contains("provider_bundle"))
        XCTAssertTrue(subagent.definition.parameters.displayText.contains("claude-code"))
        XCTAssertTrue(subagent.definition.parameters.displayText.contains("acp_provider"))

        do {
            _ = try await subagent.execute(arguments: [
                "prompt": .string("invalid bundle"),
                "provider_bundle": .string("not-installed-bundle")
            ])
            XCTFail("unknown provider bundle should be rejected before execution")
        } catch {
            guard case LocalToolError.invalidArguments = error else {
                XCTFail("unexpected validation error: \(error)")
                return
            }
        }

        let requests = SubagentRequestRecorder()
        let acpRunner: LocalSubagentRunner = { request, _ in
            await requests.append(request)
            return "acp-result"
        }
        let acpTool = try XCTUnwrap(
            SubagentToolSuite.makeTools(
                runner: acpRunner,
                registry: registry,
                ownerSession: "parent"
            ).first { $0.definition.name == "subagent" }
        )
        _ = try await acpTool.execute(arguments: [
            "prompt": .string("acp child"),
            "acp_provider": .string("acp")
        ])
        let captured = await requests.snapshot()
        XCTAssertEqual(captured.first?.acpProviderID, "acp")
    }

    func testSubagentForkUsesCompletedParentContextAndHasDistinctDefinition() async throws {
        let registry = HarnessJobRegistry()
        let requests = SubagentRequestRecorder()
        let runner: LocalSubagentRunner = { request, _ in
            await requests.append(request)
            return "forked"
        }
        let fork = try XCTUnwrap(
            SubagentToolSuite.makeTools(
                runner: runner,
                registry: registry,
                ownerSession: "parent"
            ).first { $0.definition.name == "subagent_fork" }
        )

        XCTAssertTrue(fork.definition.description.contains("最近一个已完成回合"))
        let result = try await fork.execute(arguments: [
            "prompt": .string("fork this completed context"),
            "label": .string("fork")
        ])
        XCTAssertTrue(result.contains("forked"))
        let capturedRequests = await requests.snapshot()
        let captured = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(captured.contextMode, .forkCompletedParent)
        XCTAssertFalse(captured.runInBackground)
    }

    func testStructuredOutputFailureSettlesJobWithReadableDetail() async throws {
        let registry = HarnessJobRegistry()
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object(["summary": .object(["type": .string("string")])]),
            "required": .array([.string("summary")]),
            "additionalProperties": .bool(false)
        ])
        let runner: LocalSubagentRunner = { _, _ in "not-json" }
        let tool = try XCTUnwrap(
            SubagentToolSuite.makeTools(
                runner: runner,
                registry: registry,
                ownerSession: "parent",
                policy: LocalSubagentPolicy(outputSchema: schema)
            ).first { $0.definition.name == "subagent" }
        )

        do {
            _ = try await tool.execute(arguments: ["prompt": .string("bad output")])
            XCTFail("invalid structured output must fail the activation")
        } catch let error as LocalToolError {
            guard case let .pluginFailed(detail) = error else {
                XCTFail("unexpected tool error: \(error)")
                return
            }
            XCTAssertTrue(detail.contains("output schema"))
        }
        let children = await registry.listSubagents(rootSession: "parent", descendants: false)
        let child = try XCTUnwrap(children.first)
        XCTAssertEqual(child.status, .failed)
        let failedJobID = try XCTUnwrap(child.lastJobID)
        let failedJob = try await registry.get(id: failedJobID, ownerSession: "parent")
        XCTAssertTrue(failedJob.detail?.contains("schema") == true)
    }

    func testContinuableSubagentDirectorySurvivesColdRestoreAndListsTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSubagentsPersistence-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("jobs.json")
        let first = HarnessJobRegistry(persistenceURL: file)
        let parent = UUID().uuidString.lowercased()
        let child = UUID().uuidString.lowercased()
        let grandchild = UUID().uuidString.lowercased()
        _ = try await first.registerSubagent(
            id: child,
            parentSession: parent,
            label: "child",
            model: "deepseek-chat"
        )
        _ = try await first.registerSubagent(
            id: grandchild,
            parentSession: child,
            label: "grandchild",
            model: nil
        )
        let job = try await first.startSubagentActivation(id: child) { _ in
            HarnessJobOutcome(status: .completed, output: "done")
        }
        _ = try await first.wait(id: job, timeoutMilliseconds: 1_000, ownerSession: parent)

        let restored = HarnessJobRegistry(persistenceURL: file)
        let direct = await restored.listSubagents(rootSession: parent, descendants: false)
        XCTAssertEqual(direct.map(\.id), [child])
        let tree = await restored.listSubagents(rootSession: parent, descendants: true)
        XCTAssertEqual(tree.map(\.id), [child, grandchild])
        let recovered = try await restored.subagent(id: child, requesterSession: parent)
        XCTAssertEqual(recovered.status, .completed)
        XCTAssertEqual(recovered.model, "deepseek-chat")

        let continued = try await restored.startSubagentActivation(id: child) { _ in
            HarnessJobOutcome(status: .completed, output: "continued")
        }
        _ = try await restored.wait(id: continued, timeoutMilliseconds: 1_000, ownerSession: parent)
        XCTAssertNotEqual(job, continued)
        let resumedChild = try await restored.subagent(id: child, requesterSession: parent)
        XCTAssertEqual(resumedChild.id, child)
    }

    func testSubagentDirectoryUsesDeterministicParentFirstPreorder() async throws {
        let registry = HarnessJobRegistry()
        let parent = "tree-parent"
        let firstChild = "tree-child-a"
        let secondChild = "tree-child-b"
        let grandchild = "tree-grandchild"

        _ = try await registry.registerSubagent(
            id: firstChild,
            parentSession: parent,
            label: "first child",
            model: nil
        )
        _ = try await registry.registerSubagent(
            id: secondChild,
            parentSession: parent,
            label: "second child",
            model: nil
        )
        _ = try await registry.registerSubagent(
            id: grandchild,
            parentSession: firstChild,
            label: "grandchild",
            model: nil
        )

        // descendants=true is a tree view, not a flat timestamp list:
        // direct children are ordered first, and each child's subtree follows
        // immediately after that child.
        let tree = await registry.listSubagents(rootSession: parent, descendants: true)
        XCTAssertEqual(tree.map(\.id), [firstChild, grandchild, secondChild])

        let direct = await registry.listSubagents(rootSession: parent, descendants: false)
        XCTAssertEqual(direct.map(\.id), [firstChild, secondChild])
    }

    func testSubagentLineageReturnsRootToCurrentPath() async throws {
        let registry = HarnessJobRegistry()
        let root = "lineage-root"
        let child = "lineage-child"
        let grandchild = "lineage-grandchild"
        _ = try await registry.registerSubagent(
            id: child,
            parentSession: root,
            label: "child",
            model: nil
        )
        _ = try await registry.registerSubagent(
            id: grandchild,
            parentSession: child,
            label: "grandchild",
            model: nil
        )

        let lineage = await registry.subagentLineage(sessionID: grandchild)
        XCTAssertEqual(lineage.map(\.id), [child, grandchild])
        XCTAssertEqual(lineage.map(\.parentSession), [root, child])
        let rootLineage = await registry.subagentLineage(sessionID: root)
        XCTAssertEqual(rootLineage, [])
    }

    func testDurableSubagentCompositionDepthAndReportDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSubagentComposition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("jobs.json")
        let registry = HarnessJobRegistry(persistenceURL: file)
        let parent = "composition-parent"
        let child = "composition-child"
        let grandchild = "composition-grandchild"
        let filter = LocalSubagentToolFilter(
            allow: ["workspace_read_text", "report"],
            deny: ["shell_execute"]
        )

        let first = try await registry.registerSubagent(
            id: child,
            parentSession: parent,
            label: "child",
            model: "deepseek-chat",
            providerBundleID: nil,
            contextMode: .forkCompletedParent,
            persona: "Review changes carefully.",
            toolFilter: filter,
            reportDelivery: .quiet,
            maximumDepth: 3
        )
        XCTAssertEqual(first.delegationDepth, 1)
        XCTAssertEqual(first.contextMode, .forkCompletedParent)
        XCTAssertEqual(first.persona, "Review changes carefully.")
        XCTAssertEqual(first.toolFilter, filter)
        XCTAssertEqual(first.reportDelivery, .quiet)

        let second = try await registry.registerSubagent(
            id: grandchild,
            parentSession: child,
            label: "grandchild",
            model: nil,
            providerBundleID: nil,
            contextMode: .fresh,
            persona: nil,
            toolFilter: nil,
            reportDelivery: .wakeup,
            maximumDepth: 3
        )
        XCTAssertEqual(second.delegationDepth, 2)
        let refreshedChild = try await registry.subagent(id: child, requesterSession: parent)
        XCTAssertTrue(refreshedChild.hasChildren)

        do {
            _ = try await registry.registerSubagent(
                id: "too-deep",
                parentSession: grandchild,
                label: "too deep",
                model: nil,
                providerBundleID: nil,
                contextMode: .fresh,
                persona: nil,
                toolFilter: nil,
                reportDelivery: .wakeup,
                maximumDepth: 2
            )
            XCTFail("depth cap should reject before registration")
        } catch let error as HarnessJobError {
            XCTAssertEqual(error, .subagentDepthExceeded(depth: 3, maximum: 2))
        }

        let restored = HarnessJobRegistry(persistenceURL: file)
        let restoredChild = try await restored.subagent(id: child, requesterSession: parent)
        XCTAssertEqual(restoredChild.delegationDepth, 1)
        XCTAssertEqual(restoredChild.contextMode, .forkCompletedParent)
        XCTAssertEqual(restoredChild.persona, "Review changes carefully.")
        XCTAssertEqual(restoredChild.toolFilter, filter)
        XCTAssertEqual(restoredChild.reportDelivery, .quiet)
        XCTAssertTrue(restoredChild.hasChildren)
    }

    func testSubagentPolicyValidatesStructuredOutputAndPreservesComposition() async throws {
        let requests = SubagentRequestRecorder()
        let runner: LocalSubagentRunner = { request, _ in
            await requests.append(request)
            return #"{"summary":"done"}"#
        }
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "summary": .object(["type": .string("string")])
            ]),
            "required": .array([.string("summary")]),
            "additionalProperties": .bool(false)
        ])
        let registry = HarnessJobRegistry()
        let subagent = try XCTUnwrap(SubagentToolSuite.makeTools(
            runner: runner,
            registry: registry,
            ownerSession: "policy-parent",
            policy: LocalSubagentPolicy(
                contextMode: .forkCompletedParent,
                persona: "auditor",
                toolFilter: LocalSubagentToolFilter(deny: ["shell_execute"]),
                outputSchema: schema,
                reportDelivery: .quiet,
                maximumDepth: 2
            )
        ).first { $0.definition.name == "subagent" })

        let output = try await subagent.execute(arguments: [
            "prompt": .string("inspect"),
            "label": .string("audit")
        ])
        XCTAssertTrue(output.contains("summary"))
        let capturedRequests = await requests.snapshot()
        let captured = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(captured.contextMode, .forkCompletedParent)
        XCTAssertEqual(captured.delegationDepth, 1)
        XCTAssertEqual(captured.persona, "auditor")
        XCTAssertEqual(captured.toolFilter, LocalSubagentToolFilter(deny: ["shell_execute"]))
        XCTAssertEqual(captured.outputSchema, schema)
        XCTAssertEqual(captured.reportDelivery, .quiet)
    }

    func testContinuationRequestRetainsDurableCompositionAndDepth() async throws {
        let registry = HarnessJobRegistry()
        let filter = LocalSubagentToolFilter(
            allow: ["workspace_read_text"],
            deny: ["shell_execute"]
        )
        let child = try await registry.registerSubagent(
            id: "continuation-child",
            parentSession: "continuation-parent",
            label: "durable child",
            model: "deepseek-chat",
            providerBundleID: .codex,
            contextMode: .forkCompletedParent,
            persona: "Keep the review narrow.",
            toolFilter: filter,
            reportDelivery: .quiet,
            maximumDepth: 11
        )

        let request = LocalSubagentRequest.continuation(
            child: child,
            prompt: "continue the review"
        )

        XCTAssertEqual(request.childAddress, child.id)
        XCTAssertEqual(request.prompt, "continue the review")
        XCTAssertEqual(request.model, child.model)
        XCTAssertEqual(request.providerBundleID, .codex)
        XCTAssertEqual(request.contextMode, .forkCompletedParent)
        XCTAssertEqual(request.delegationDepth, child.delegationDepth)
        XCTAssertEqual(request.maximumDepth, 11)
        XCTAssertEqual(request.persona, child.persona)
        XCTAssertEqual(request.toolFilter, filter)
        XCTAssertNil(request.outputSchema)
        XCTAssertEqual(request.reportDelivery, .quiet)
        XCTAssertTrue(request.runInBackground)
        XCTAssertTrue(request.isContinuation)
    }

    func testReportToolUsesDeploymentOwnedQuietScheduling() async throws {
        let deliveries = SubagentReportDeliveryRecorder()
        let request = LocalSubagentRequest(
            childAddress: "report-child",
            prompt: "work",
            label: "reporter",
            model: nil,
            reportDelivery: .quiet,
            runInBackground: true,
            isContinuation: false
        )
        let report = SubagentToolSuite.makeReportTool(
            request: request,
            parentSession: "report-parent"
        ) { child, parent, output, delivery in
            await deliveries.append(
                child: child,
                parent: parent,
                output: output,
                delivery: delivery
            )
            return "message-1"
        }

        let result = try await report.execute(arguments: ["output": .string("finding")])
        XCTAssertTrue(result.contains("message-1"))
        let recorded = await deliveries.snapshot()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.child, "report-child")
        XCTAssertEqual(recorded.first?.parent, "report-parent")
        XCTAssertEqual(recorded.first?.output, "finding")
        XCTAssertEqual(recorded.first?.delivery, .quiet)
    }

    func testCompletionNoticesResumeAfterColdRestoreWithoutConsumingFinalOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessJobNotices-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("jobs.json")
        let first = HarnessJobRegistry(persistenceURL: file)
        let job = try await first.start(
            kind: "subagent",
            label: "background audit",
            ownerSession: "notice-owner",
            outputLimitBytes: nil
        ) { _ in
            HarnessJobOutcome(status: .completed, detail: "finished", output: "durable answer")
        }
        for _ in 0..<100 {
            if try await first.get(id: job, ownerSession: "notice-owner").status.isTerminal {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        let restored = HarnessJobRegistry(persistenceURL: file)
        let notices = await restored.claimCompletionNotices(ownerSession: "notice-owner")
        XCTAssertEqual(notices.map(\.id), [job])
        XCTAssertTrue(notices[0].text.contains("job_output"))
        let repeatedNotices = await restored.claimCompletionNotices(ownerSession: "notice-owner")
        XCTAssertEqual(repeatedNotices, [])
        let firstRead = try await restored.read(id: job, ownerSession: "notice-owner")
        let secondRead = try await restored.read(id: job, ownerSession: "notice-owner")
        XCTAssertEqual(firstRead.text, "durable answer")
        XCTAssertEqual(secondRead.text, "durable answer")
    }

    func testFailedCompletionDeliveryCanBeRequeuedExactlyOnce() async throws {
        let registry = HarnessJobRegistry()
        let job = try await registry.start(
            kind: "workflow",
            label: "delivery",
            ownerSession: "owner"
        ) { _ in
            HarnessJobOutcome(status: .completed, output: "result")
        }
        for _ in 0..<100 {
            if try await registry.get(id: job, ownerSession: "owner").status.isTerminal { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let claimed = await registry.claimCompletionNotices(ownerSession: "owner")
        XCTAssertEqual(claimed.map(\.id), [job])
        await registry.requeueCompletionNotice(id: job, ownerSession: "owner")
        let retried = await registry.claimCompletionNotices(ownerSession: "owner")
        XCTAssertEqual(retried.map(\.id), [job])
        let duplicate = await registry.claimCompletionNotices(ownerSession: "owner")
        XCTAssertTrue(duplicate.isEmpty)
        await registry.acknowledgeCompletionNotice(id: job, ownerSession: "owner")
        let acknowledged = try await registry.get(id: job, ownerSession: "owner")
        XCTAssertTrue(acknowledged.reported)
        let remaining = await registry.claimCompletionNotices(ownerSession: "owner")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testClaimedCompletionIsRecoverableAfterColdRestoreBeforeAcknowledgement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessJobClaimRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("jobs.json")
        let first = HarnessJobRegistry(persistenceURL: file)
        let job = try await first.start(
            kind: "bash",
            label: "crash between claim and delivery",
            ownerSession: "owner"
        ) { _ in HarnessJobOutcome(status: .completed, output: "result") }
        _ = try await first.wait(id: job, timeoutMilliseconds: 1_000, ownerSession: "owner")
        let firstNotices = await first.claimCompletionNotices(ownerSession: "owner")
        XCTAssertEqual(firstNotices.map(\.id), [job])

        let restored = HarnessJobRegistry(persistenceURL: file)
        let restoredNotices = await restored.claimCompletionNotices(ownerSession: "owner")
        XCTAssertEqual(restoredNotices.map(\.id), [job])
    }

    func testConcurrentAdmissionIsScopedPerOwner() async throws {
        let registry = HarnessJobRegistry(maxConcurrentJobsPerOwner: 1)
        let first = try await registry.start(
            kind: "bash",
            label: "first",
            ownerSession: "alice",
            outputLimitBytes: nil
        ) { _ in
            try await Task.sleep(for: .seconds(30))
            return HarnessJobOutcome(status: .completed)
        }

        do {
            _ = try await registry.start(
                kind: "bash",
                label: "second",
                ownerSession: "alice",
                outputLimitBytes: nil
            ) { _ in
                HarnessJobOutcome(status: .completed)
            }
            XCTFail("Owner capacity should be enforced")
        } catch let error as HarnessJobError {
            XCTAssertEqual(error, .capacityReached(limit: 1))
        }

        let bob = try await registry.start(
            kind: "bash",
            label: "other owner",
            ownerSession: "bob",
            outputLimitBytes: nil
        ) { _ in
            HarnessJobOutcome(status: .completed)
        }
        XCTAssertEqual(bob, "bash-2")

        _ = try await registry.kill(id: first, ownerSession: "alice", reason: nil)
        _ = try await registry.wait(
            id: first,
            timeoutMilliseconds: 1_000,
            ownerSession: "alice"
        )
    }

    private func waitForOutput(
        registry: HarnessJobRegistry,
        id: String,
        ownerSession: String
    ) async throws -> HarnessJobRead {
        for _ in 0..<100 {
            let read = try await registry.read(id: id, ownerSession: ownerSession)
            if !read.text.isEmpty { return read }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for job output")
        return try await registry.read(id: id, ownerSession: ownerSession)
    }
}

private actor SubagentRequestRecorder {
    private var requests: [LocalSubagentRequest] = []
    func append(_ request: LocalSubagentRequest) { requests.append(request) }
    func snapshot() -> [LocalSubagentRequest] { requests }
}

private actor SubagentReportDeliveryRecorder {
    struct Entry: Sendable, Equatable {
        let child: String
        let parent: String
        let output: String
        let delivery: LocalSubagentReportDelivery
    }

    private var entries: [Entry] = []
    func append(
        child: String,
        parent: String,
        output: String,
        delivery: LocalSubagentReportDelivery
    ) {
        entries.append(Entry(
            child: child,
            parent: parent,
            output: output,
            delivery: delivery
        ))
    }
    func snapshot() -> [Entry] { entries }
}

private actor JobTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}
