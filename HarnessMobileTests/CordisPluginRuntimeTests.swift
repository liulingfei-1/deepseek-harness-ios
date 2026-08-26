import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class CordisPluginRuntimeTests: XCTestCase {
    func testTimeoutPolicyWaitsForCooperativeQuiescenceAndReturnsStructuredTimeout() async throws {
        let runtime = try await makeTimeoutRuntime(
            tool: TimeoutTestTool(name: "slow", timeoutMs: 20)
        )
        let execution = timeoutExecution(name: "slow")
        let recorder = TimeoutTestRecorder()
        let started = Date.now
        let result = try await Self.runTimeoutExecute(runtime, execution: execution) {
            try await execution.signal.runCooperatively {
                await recorder.append("started")
                do {
                    while !execution.signal.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                } catch is CancellationError {
                    // A cooperative tool owns cleanup even after its child
                    // task has been cancelled by the policy.
                }
                if !execution.signal.isCancelled {
                    return CordisToolExecutionResult(text: "unexpected", isError: true)
                }
                await recorder.append("cancelled")
                let cleanupDeadline = Date.now.addingTimeInterval(0.025)
                while Date.now < cleanupDeadline {
                    await Task.yield()
                }
                await recorder.append("quiesced")
                return CordisToolExecutionResult(text: "late", isError: false)
            }
        }

        XCTAssertGreaterThanOrEqual(Date.now.timeIntervalSince(started), 0.03)
        XCTAssertEqual(result.errorCode, TimeoutPolicy.toolTimeoutCode)
        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Error: tool call timed out after 20ms")
        XCTAssertEqual(
            try XCTUnwrap(result.value?.objectValue?["error"]?.objectValue?["code"]),
            JSONValue.string("TOOL_TIMEOUT")
        )
        let entries = await recorder.values
        XCTAssertEqual(entries, ["started", "cancelled", "quiesced"])
    }

    func testTimeoutPolicyPreservesFastResultAndUpstreamCancellation() async throws {
        let runtime = try await makeTimeoutRuntime(
            tool: TimeoutTestTool(name: "fast", timeoutMs: 200)
        )
        let fastExecution = timeoutExecution(name: "fast")
        let fast = try await Self.runTimeoutExecute(runtime, execution: fastExecution) {
            try await fastExecution.signal.runCooperatively {
                CordisToolExecutionResult(text: "ok", isError: false)
            }
        }
        XCTAssertEqual(fast.text, "ok")
        XCTAssertNil(fast.errorCode)

        let upstream = ToolCancellationSignal()
        let cancelledExecution = timeoutExecution(name: "fast", signal: upstream)
        let task = Task {
            try await Self.runTimeoutExecute(runtime, execution: cancelledExecution) {
                try await cancelledExecution.signal.runCooperatively {
                    while !cancelledExecution.signal.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000)
                    }
                    throw CancellationError()
                }
            }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = upstream.cancel(reason: .upstream)
        do {
            _ = try await task.value
            XCTFail("expected upstream cancellation")
        } catch is CancellationError {
            // User cancellation must not be relabeled as TOOL_TIMEOUT.
        }
    }

    func testTimeoutPolicyRestoresUpstreamSignalForPostExecuteAndDispose() async throws {
        let runtime = try await makeTimeoutRuntime(
            tool: TimeoutTestTool(name: "slow", timeoutMs: 10)
        )
        let execution = timeoutExecution(name: "slow")
        let upstream = execution.signal
        let observed = TimeoutTestRecorder()
        let observer = CordisPluginDefinition(id: "timeout-observer", version: "1") { context in
            try await context.intercept(CordisAgentLoopCheckpoints.toolsPostExecute) { input, next in
                await observed.append(input.execution.signal === upstream ? "upstream" : "replacement")
                return try await next()
            }
        }
        _ = try await runtime.install(observer)
        let result = try await Self.runTimeoutExecute(runtime, execution: execution) {
            try await execution.signal.runCooperatively {
                while !execution.signal.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                throw CancellationError()
            }
        }
        _ = try await runtime.run(
            CordisAgentLoopCheckpoints.toolsPostExecute,
            input: CordisPostToolExecutionContext(execution: execution, result: result),
            traceContext: CordisTraceContext(runID: execution.runID, turn: execution.turn, step: execution.step),
            default: { result }
        )
        XCTAssertEqual(result.errorCode, TimeoutPolicy.toolTimeoutCode)
        _ = try await runtime.setEnabled(false, for: TimeoutPolicy.pluginID)
        let afterDispose = try await Self.runTimeoutExecute(runtime, execution: timeoutExecution(name: "slow")) {
            CordisToolExecutionResult(text: "plain", isError: false)
        }
        XCTAssertEqual(afterDispose.text, "plain")
        XCTAssertNil(afterDispose.errorCode)
        let observedSignals = await observed.values
        XCTAssertEqual(observedSignals, ["upstream"])
    }

    func testTimeoutPolicyDoesNotWrapUntimedTools() async throws {
        let runtime = try await makeTimeoutRuntime(
            tool: TimeoutTestTool(name: "plain", timeoutMs: nil)
        )
        let execution = timeoutExecution(name: "plain")
        let result = try await Self.runTimeoutExecute(runtime, execution: execution) {
            CordisToolExecutionResult(text: "plain", isError: false)
        }
        XCTAssertEqual(result, CordisToolExecutionResult(text: "plain", isError: false))
    }

    private func makeTimeoutRuntime(tool: TimeoutTestTool) async throws -> CordisPluginRuntime {
        let runtime = CordisPluginRuntime()
        let tools = CordisToolRuntime()
        _ = try await runtime.install(CordisAgentServices(tools: tools).pluginDefinition())
        let registration = CordisPluginDefinition(id: "timeout-test-tool", version: "1") { context in
            _ = try await context.registerTool(tool, in: tools)
        }
        _ = try await runtime.install(registration)
        _ = try await runtime.install(TimeoutPolicy.pluginDefinition())
        return runtime
    }

    private func timeoutExecution(
        name: String,
        signal: ToolCancellationSignal = ToolCancellationSignal()
    ) -> CordisToolExecution {
        CordisToolExecution(
            runID: UUID(),
            step: 1,
            call: AgentToolCall(id: "timeout-call", name: name, arguments: "{}"),
            arguments: [:],
            risk: .pure,
            summary: name,
            signal: signal
        )
    }

    private static func runTimeoutExecute(
        _ runtime: CordisPluginRuntime,
        execution: CordisToolExecution,
        default: @escaping @Sendable () async throws -> CordisToolExecutionResult
    ) async throws -> CordisToolExecutionResult {
        try await runtime.run(
            CordisAgentLoopCheckpoints.toolsExecute,
            input: execution,
            traceContext: CordisTraceContext(runID: execution.runID, turn: execution.turn, step: execution.step),
            default: `default`
        )
    }

    func testRepeatToolReminderCanonicalizesArgumentsAndPreservesDownstreamResult() async throws {
        let runtime = CordisPluginRuntime()
        let agentID = UUID()
        let runID = UUID()
        let configuration = RepeatToolReminder.Configuration(
            thresholds: [2, 3],
            argumentsPreviewChars: 12
        )
        _ = try await runtime.install(RepeatToolReminder.pluginDefinition(configuration: configuration))

        let first = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 1,
                name: "search",
                arguments: [
                    "query": .object(["b": .number(2), "a": .number(1)]),
                    "items": .array([.string("one"), .string("two")])
                ]
            ),
            result: CordisToolExecutionResult(text: "first", isError: false)
        )
        XCTAssertTrue(first.additionalContexts.isEmpty)

        let downstreamContext = AgentMessage(
            role: .user,
            content: "downstream context",
            source: .object(["kind": .string("plugin"), "plugin": .string("downstream")])
        )
        let second = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 2,
                name: "search",
                arguments: [
                    "items": .array([.string("one"), .string("two")]),
                    "query": .object(["a": .number(1), "b": .number(2)])
                ]
            ),
            result: CordisToolExecutionResult(
                text: "replaced downstream text",
                isError: true,
                value: .object(["stable": .bool(true)]),
                additionalContexts: [downstreamContext]
            )
        )

        XCTAssertEqual(second.text, "replaced downstream text")
        XCTAssertTrue(second.isError)
        XCTAssertEqual(second.value, .object(["stable": .bool(true)]))
        XCTAssertEqual(second.additionalContexts.count, 2)
        XCTAssertEqual(second.additionalContexts.last, downstreamContext)
        let reminder = try XCTUnwrap(second.additionalContexts.first)
        XCTAssertEqual(reminder.role, .user)
        XCTAssertTrue(reminder.content.contains("exact same tool call"))
        XCTAssertEqual(reminder.source?.objectValue?["summary"], .string("search × 2"))

        let third = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 3,
                name: "search",
                arguments: [
                    "query": .object(["a": .number(1), "b": .number(2)]),
                    "items": .array([.string("one"), .string("two")])
                ]
            ),
            result: CordisToolExecutionResult(text: "third", isError: false)
        )
        let detailed = try XCTUnwrap(third.additionalContexts.first)
        XCTAssertTrue(detailed.content.contains("consecutive_calls: 3"))
        XCTAssertTrue(detailed.content.contains("more chars"))
    }

    func testRepeatToolReminderHonorsFiltersAndResetsAtNewDirectUserMessage() async throws {
        let runtime = CordisPluginRuntime()
        let agentID = UUID()
        let runID = UUID()
        let configuration = RepeatToolReminder.Configuration(
            thresholds: [2],
            include: ["query-*"],
            exclude: ["query-secret"]
        )
        _ = try await runtime.install(RepeatToolReminder.pluginDefinition(configuration: configuration))

        for step in 1...3 {
            let excluded = try await runRepeatPostExecute(
                runtime,
                execution: repeatExecution(
                    agentID: agentID,
                    runID: runID,
                    step: step,
                    name: "query-secret",
                    arguments: ["q": .string("same")]
                )
            )
            XCTAssertTrue(excluded.additionalContexts.isEmpty)
        }

        _ = try await runRepeatPreStep(
            runtime,
            agentID: agentID,
            runID: runID,
            messages: [.user("first")]
        )
        _ = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 4,
                name: "query-public",
                arguments: ["q": .string("same")]
            )
        )
        let secondBeforeReset = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 5,
                name: "query-public",
                arguments: ["q": .string("same")]
            )
        )
        XCTAssertEqual(secondBeforeReset.additionalContexts.count, 1)

        let newUser = AgentMessage.user("second")
        _ = try await runRepeatPreStep(runtime, agentID: agentID, runID: runID, messages: [newUser])
        _ = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 6,
                name: "query-public",
                arguments: ["q": .string("same")]
            )
        )
        let afterReset = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: agentID,
                runID: runID,
                step: 7,
                name: "query-public",
                arguments: ["q": .string("same")]
            )
        )
        XCTAssertEqual(afterReset.additionalContexts.count, 1)

        let otherAgent = try await runRepeatPostExecute(
            runtime,
            execution: repeatExecution(
                agentID: UUID(),
                runID: UUID(),
                step: 1,
                name: "query-public",
                arguments: ["q": .string("same")]
            )
        )
        XCTAssertTrue(otherAgent.additionalContexts.isEmpty)
    }

    func testRepeatToolReminderInvalidConfigurationFailsPluginActivation() async throws {
        let runtime = CordisPluginRuntime()
        let definition = RepeatToolReminder.pluginDefinition(
            configuration: .init(thresholds: [3, 3])
        )
        let snapshot = try await runtime.install(definition)
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertTrue(snapshot.error?.contains("must not contain duplicates") == true)
    }

    private func repeatExecution(
        agentID: UUID,
        runID: UUID,
        step: Int,
        name: String,
        arguments: [String: JSONValue]
    ) -> CordisToolExecution {
        CordisToolExecution(
            agentID: agentID,
            runID: runID,
            step: step,
            call: AgentToolCall(id: "call-\(step)", name: name, arguments: "{}"),
            arguments: arguments,
            risk: .pure,
            summary: name
        )
    }

    private func runRepeatPostExecute(
        _ runtime: CordisPluginRuntime,
        execution: CordisToolExecution,
        result: CordisToolExecutionResult = CordisToolExecutionResult(text: "ok", isError: false)
    ) async throws -> CordisToolExecutionResult {
        try await runtime.run(
            CordisAgentLoopCheckpoints.toolsPostExecute,
            input: CordisPostToolExecutionContext(execution: execution, result: result),
            traceContext: CordisTraceContext(runID: execution.runID, turn: execution.turn, step: execution.step),
            default: { result }
        )
    }

    private func runRepeatPreStep(
        _ runtime: CordisPluginRuntime,
        agentID: UUID,
        runID: UUID,
        messages: [AgentMessage]
    ) async throws -> CordisAgentPreStepDecision {
        try await runtime.run(
            CordisAgentLoopCheckpoints.preStep,
            input: CordisAgentPreStepContext(
                agentID: agentID,
                runID: runID,
                turn: 1,
                step: 1,
                messages: messages
            ),
            traceContext: CordisTraceContext(runID: runID, turn: 1, step: 1),
            default: { .enter(messages) }
        )
    }

    func testDependencyLossUnloadsConsumerAndServiceReturnReconnectsIt() async throws {
        let recorder = CordisTestRecorder()
        let serviceKey = CordisServiceKey<CordisTestService>("greeter")
        let runtime = CordisPluginRuntime()

        let consumer = CordisPluginDefinition(
            id: "consumer",
            version: "1",
            dependencies: [serviceKey.name]
        ) { context in
            let service = try await context.service(serviceKey)
            await recorder.append("load:\(service.value)")
            try await context.onDispose("consumer cleanup") {
                await recorder.append("unload:consumer")
            }
        }
        let provider = CordisPluginDefinition(
            id: "provider",
            version: "1",
            provides: [serviceKey.name]
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "hello"))
        }

        let pending = try await runtime.install(consumer)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.missingDependencies, ["greeter"])

        _ = try await runtime.install(provider)
        var providerSnapshot = try await runtime.snapshot(for: "provider")
        var consumerSnapshot = try await runtime.snapshot(for: "consumer")
        XCTAssertEqual(providerSnapshot.state, .active)
        XCTAssertEqual(consumerSnapshot.state, .active)

        _ = try await runtime.setEnabled(false, for: "provider")
        providerSnapshot = try await runtime.snapshot(for: "provider")
        consumerSnapshot = try await runtime.snapshot(for: "consumer")
        XCTAssertEqual(providerSnapshot.state, .pending)
        XCTAssertEqual(consumerSnapshot.state, .pending)

        _ = try await runtime.setEnabled(true, for: "provider")
        providerSnapshot = try await runtime.snapshot(for: "provider")
        consumerSnapshot = try await runtime.snapshot(for: "consumer")
        let recorded = await recorder.values
        XCTAssertEqual(providerSnapshot.state, .active)
        XCTAssertEqual(consumerSnapshot.state, .active)
        XCTAssertEqual(
            recorded,
            ["load:hello", "unload:consumer", "load:hello"]
        )
    }

    func testEffectsDisposeInReverseRegistrationOrder() async throws {
        let recorder = CordisTestRecorder()
        let runtime = CordisPluginRuntime()
        let plugin = CordisPluginDefinition(id: "effects", version: "1") { context in
            try await context.onDispose("first") {
                await recorder.append("first")
            }
            try await context.onDispose("second") {
                await recorder.append("second")
            }
        }

        _ = try await runtime.install(plugin)
        _ = try await runtime.setEnabled(false, for: plugin.id)

        let recorded = await recorder.values
        XCTAssertEqual(recorded, ["second", "first"])
    }

    func testWaterfallWrapsInOrderAndPluginDisableRemovesInterceptor() async throws {
        let recorder = CordisTestRecorder()
        let runtime = CordisPluginRuntime()
        let checkpoint = CordisCheckpointKey<String, String>("demo/transform")

        let ordinary = CordisPluginDefinition(id: "ordinary", version: "1") { context in
            try await context.intercept(checkpoint) { input, next in
                await recorder.append("ordinary:before:\(input)")
                let value = try await next()
                await recorder.append("ordinary:after")
                return value + ":ordinary"
            }
        }
        let prepended = CordisPluginDefinition(id: "prepended", version: "1") { context in
            try await context.intercept(checkpoint, prepend: true) { _, next in
                await recorder.append("prepended:before")
                let value = try await next()
                await recorder.append("prepended:after")
                return value.uppercased()
            }
        }

        _ = try await runtime.install(ordinary)
        _ = try await runtime.install(prepended)
        let transformed = try await runtime.run(checkpoint, input: "hello") { "base" }
        let recorded = await recorder.values

        XCTAssertEqual(transformed, "BASE:ORDINARY")
        XCTAssertEqual(
            recorded,
            [
                "prepended:before",
                "ordinary:before:hello",
                "ordinary:after",
                "prepended:after"
            ]
        )

        _ = try await runtime.setEnabled(false, for: prepended.id)
        let withoutPrepended = try await runtime.run(checkpoint, input: "hello") { "base" }
        XCTAssertEqual(withoutPrepended, "base:ordinary")
    }

    func testWaterfallMayShortCircuitDefaultHandler() async throws {
        let runtime = CordisPluginRuntime()
        let checkpoint = CordisCheckpointKey<String, String>("demo/veto")
        let defaultCounter = CordisTestCounter()
        let plugin = CordisPluginDefinition(id: "veto", version: "1") { context in
            try await context.intercept(checkpoint) { input, next in
                guard input != "blocked" else { return "denied" }
                return try await next()
            }
        }
        _ = try await runtime.install(plugin)

        let blocked = try await runtime.run(checkpoint, input: "blocked") {
            await defaultCounter.increment()
            return "default"
        }
        let allowed = try await runtime.run(checkpoint, input: "allowed") {
            await defaultCounter.increment()
            return "default"
        }

        XCTAssertEqual(blocked, "denied")
        XCTAssertEqual(allowed, "default")
        let defaultCount = await defaultCounter.value
        XCTAssertEqual(defaultCount, 1)
    }

    func testSerialSkipsListenerUnloadedAfterDispatchSnapshot() async throws {
        let runtime = CordisPluginRuntime()
        let event = CordisEventKey<CordisNoPayload>("demo/generation-listener")
        let gate = CordisTestGate()
        let recorder = CordisTestRecorder()

        let blocking = CordisPluginDefinition(id: "blocking-listener", version: "1") { context in
            try await context.on(event) { _ in
                await recorder.append("blocking")
                await gate.enterAndWait()
            }
        }
        let stale = CordisPluginDefinition(id: "stale-listener", version: "1") { context in
            try await context.on(event) { _ in
                await recorder.append("stale")
            }
        }

        _ = try await runtime.install(blocking)
        _ = try await runtime.install(stale)

        let dispatch = Task {
            try await runtime.serial(event, input: .value)
        }
        await gate.waitForEntry()
        _ = try await runtime.setEnabled(false, for: stale.id)
        await gate.release()
        try await dispatch.value

        let recorded = await recorder.values
        XCTAssertEqual(recorded, ["blocking"])
    }

    func testCheckpointDiscardsResultFromReplacedGeneration() async throws {
        let runtime = CordisPluginRuntime()
        let checkpoint = CordisCheckpointKey<String, String>("demo/generation-checkpoint")
        let gate = CordisTestGate()
        let oldPlugin = CordisPluginDefinition(id: "replaceable-interceptor", version: "1") { context in
            try await context.intercept(checkpoint) { _, next in
                let downstream = try await next()
                await gate.enterAndWait()
                return downstream + ":stale"
            }
        }
        let replacement = CordisPluginDefinition(id: oldPlugin.id, version: "2") { context in
            try await context.intercept(checkpoint) { _, next in
                try await next() + ":current"
            }
        }

        _ = try await runtime.install(oldPlugin)
        let inFlight = Task {
            try await runtime.run(checkpoint, input: "input") { "base" }
        }
        await gate.waitForEntry()
        _ = try await runtime.replace(oldPlugin.id, with: replacement)
        await gate.release()

        let staleRunResult = try await inFlight.value
        let currentRunResult = try await runtime.run(checkpoint, input: "input") { "base" }
        XCTAssertEqual(staleRunResult, "base")
        XCTAssertEqual(currentRunResult, "base:current")
    }

    func testCheckpointSkipsInterceptorUnloadedAfterDispatchSnapshot() async throws {
        let runtime = CordisPluginRuntime()
        let checkpoint = CordisCheckpointKey<String, String>("demo/generation-snapshot")
        let gate = CordisTestGate()
        let recorder = CordisTestRecorder()
        let blocking = CordisPluginDefinition(id: "blocking-interceptor", version: "1") { context in
            try await context.intercept(checkpoint) { _, next in
                await recorder.append("blocking")
                await gate.enterAndWait()
                return try await next()
            }
        }
        let stale = CordisPluginDefinition(id: "stale-interceptor", version: "1") { context in
            try await context.intercept(checkpoint) { _, next in
                await recorder.append("stale")
                return try await next() + ":stale"
            }
        }

        _ = try await runtime.install(blocking)
        _ = try await runtime.install(stale)
        let dispatch = Task {
            try await runtime.run(checkpoint, input: "input") { "base" }
        }
        await gate.waitForEntry()
        _ = try await runtime.setEnabled(false, for: stale.id)
        await gate.release()

        let result = try await dispatch.value
        let recorded = await recorder.values
        XCTAssertEqual(result, "base")
        XCTAssertEqual(recorded, ["blocking"])
    }

    func testCheckpointTraceIdentifiesRunAndExactPluginGenerationChain() async throws {
        let traceRecorder = CordisTraceRecorder()
        let runtime = CordisPluginRuntime { draft in
            await traceRecorder.append(draft)
        }
        let checkpoint = CordisCheckpointKey<String, String>("demo/trace")
        let plugin = CordisPluginDefinition(id: "trace-plugin", version: "1") { context in
            try await context.intercept(
                checkpoint,
                scope: .global,
                label: "trace-handler"
            ) { _, next in
                try await next()
            }
        }
        _ = try await runtime.install(plugin)

        let runID = UUID()
        let output = try await runtime.run(
            checkpoint,
            input: "input",
            target: .global,
            traceContext: CordisTraceContext(runID: runID, turn: 3, step: 7)
        ) {
            "output"
        }

        XCTAssertEqual(output, "output")
        let allDrafts = await traceRecorder.values
        let drafts = allDrafts.filter {
            $0.kind == .checkpointStarted || $0.kind == .checkpointFinished
        }
        XCTAssertEqual(drafts.count, 2)
        for draft in drafts {
            XCTAssertEqual(draft.runID, runID)
            XCTAssertEqual(draft.turn, 3)
            XCTAssertEqual(draft.step, 7)
            XCTAssertEqual(draft.name, checkpoint.name)
            XCTAssertEqual(draft.attributes["handlerCount"], .number(1))
            guard case let .array(handlers)? = draft.attributes["handlers"],
                  case let .object(handler)? = handlers.first else {
                return XCTFail("Expected one structured checkpoint handler")
            }
            XCTAssertEqual(handler["pluginId"], .string("trace-plugin"))
            XCTAssertEqual(handler["generation"], .number(1))
            XCTAssertEqual(handler["label"], .string("trace-handler"))
            XCTAssertEqual(handler["scope"], .string("global"))
        }
    }

    func testCheckpointTraceProjectionRedactsCredentialLikeContent() async throws {
        let traceRecorder = CordisTraceRecorder()
        let runtime = CordisPluginRuntime { draft in
            await traceRecorder.append(draft)
        }
        let plugin = CordisPluginDefinition(id: "trace-redaction", version: "1") { context in
            try await context.intercept(CordisAgentLoopCheckpoints.toolsPreExecute) { _, next in
                try await next()
            }
        }
        _ = try await runtime.install(plugin)

        let runID = UUID()
        let execution = CordisToolExecution(
            runID: runID,
            step: 2,
            call: AgentToolCall(
                id: "call-1",
                name: "probe",
                arguments: #"{"apiKey":"sk-abcdefghijklmnop"}"#
            ),
            arguments: [
                "apiKey": .string("sk-abcdefghijklmnop"),
                "header": .string("Bearer abcdefghijklmnop")
            ],
            risk: .sensitiveRead,
            summary: "inspect sk-abcdefghijklmnop"
        )
        _ = try await runtime.run(
            CordisAgentLoopCheckpoints.toolsPreExecute,
            input: execution,
            traceContext: CordisTraceContext(runID: runID, turn: 1, step: 2)
        ) {
            CordisPreToolDecision.allow
        }

        let drafts = await traceRecorder.values
        guard let started = drafts.first(where: { $0.kind == .checkpointStarted }),
              case let .object(input)? = started.attributes["input"],
              case let .object(arguments)? = input["arguments"] else {
            return XCTFail("Expected structured checkpoint input")
        }
        XCTAssertEqual(arguments["apiKey"], .string("<redacted>"))
        XCTAssertEqual(arguments["header"], .string("<redacted>"))
        XCTAssertFalse(JSONValue.object(started.attributes).displayText.contains("sk-abcdefghijklmnop"))

        let traceMessage = HarnessTraceMessage(.user("token sk-abcdefghijklmnop"))
        XCTAssertEqual(traceMessage.content, "token <redacted>")
    }

    func testFailedHotReplacementRollsBackAndReconnectsDependants() async throws {
        let serviceKey = CordisServiceKey<CordisTestService>("replaceable")
        let loads = CordisTestCounter()
        let runtime = CordisPluginRuntime()
        let original = CordisPluginDefinition(
            id: "provider",
            version: "1",
            provides: [serviceKey.name]
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "v1"))
        }
        let consumer = CordisPluginDefinition(
            id: "consumer",
            version: "1",
            dependencies: [serviceKey.name]
        ) { context in
            _ = try await context.service(serviceKey)
            await loads.increment()
        }
        let broken = CordisPluginDefinition(
            id: "provider",
            version: "2",
            provides: [serviceKey.name]
        ) { _ in
            throw CordisTestError.activationFailed
        }

        _ = try await runtime.install(original)
        _ = try await runtime.install(consumer)

        do {
            _ = try await runtime.replace("provider", with: broken)
            XCTFail("Broken replacement must report its rollback.")
        } catch let error as CordisPluginRuntimeError {
            guard case .replacementRolledBack = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let restored = try await runtime.snapshot(for: "provider")
        let restoredConsumer = try await runtime.snapshot(for: "consumer")
        let loadCount = await loads.value
        XCTAssertEqual(restored.version, "1")
        XCTAssertEqual(restored.state, .active)
        XCTAssertEqual(restoredConsumer.state, .active)
        // The old generation remains active while the candidate fails, so the
        // dependent is not needlessly unloaded and reactivated.
        XCTAssertEqual(loadCount, 1)
        let service = try await runtime.resolveService(serviceKey)
        XCTAssertEqual(service.value, "v1")
        let inventory = await runtime.inventory()
        XCTAssertEqual(inventory.stagedPluginCount, 0)
    }

    func testSuccessfulHotReplacementStagesBeforeOldCleanupAndReconnectsDependants() async throws {
        let serviceKey = CordisServiceKey<CordisTestService>("staged")
        let recorder = CordisTestRecorder()
        let loads = CordisTestCounter()
        let runtime = CordisPluginRuntime()
        let original = CordisPluginDefinition(
            id: "staged-provider",
            version: "1",
            provides: [serviceKey.name]
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "v1"))
            _ = try await context.effect("old-resource") {
                await recorder.append("old-acquired")
                return { await recorder.append("old-cleaned") }
            }
        }
        let consumer = CordisPluginDefinition(
            id: "staged-consumer",
            version: "1",
            dependencies: [serviceKey.name]
        ) { context in
            await loads.increment()
            await recorder.append(try await context.service(serviceKey).value)
        }
        let replacement = CordisPluginDefinition(
            id: original.id,
            version: "2",
            provides: [serviceKey.name]
        ) { context in
            // The old generation must remain available until this activation
            // has fully registered the replacement generation.
            let visible = try await context.service(serviceKey).value
            await recorder.append("candidate-saw-\(visible)")
            try await context.provide(serviceKey, value: CordisTestService(value: "v2"))
        }

        _ = try await runtime.install(original)
        _ = try await runtime.install(consumer)
        let before = await recorder.values
        XCTAssertEqual(before, ["old-acquired", "v1"])

        _ = try await runtime.replace(original.id, with: replacement)

        let after = await recorder.values
        XCTAssertEqual(after, ["old-acquired", "v1", "candidate-saw-v1", "old-cleaned", "v2"])
        let service = try await runtime.resolveService(serviceKey)
        let loadCount = await loads.value
        let inventory = await runtime.inventory()
        XCTAssertEqual(service.value, "v2")
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(inventory.stagedPluginCount, 0)
    }

    func testConcurrentDisableInvalidatesStagedReplacementWithoutLeakingCandidate() async throws {
        let serviceKey = CordisServiceKey<CordisTestService>("staged-disable")
        let runtime = CordisPluginRuntime()
        let gate = CordisTestGate()
        let original = CordisPluginDefinition(
            id: "staged-disable-provider",
            version: "1",
            provides: [serviceKey.name]
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "v1"))
        }
        let replacement = CordisPluginDefinition(
            id: original.id,
            version: "2",
            provides: [serviceKey.name]
        ) { context in
            await gate.enterAndWait()
            try await context.provide(serviceKey, value: CordisTestService(value: "v2"))
        }

        _ = try await runtime.install(original)
        let replacing = Task {
            try await runtime.replace(original.id, with: replacement)
        }
        await gate.waitForEntry()

        _ = try await runtime.setEnabled(false, for: original.id)
        await gate.release()

        do {
            _ = try await replacing.value
            XCTFail("A replacement invalidated by disable must fail closed")
        } catch let error as CordisPluginRuntimeError {
            guard case .replacementRolledBack = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let snapshot = try await runtime.snapshot(for: original.id)
        XCTAssertEqual(snapshot.state, .pending)
        XCTAssertFalse(snapshot.isEnabled)
        XCTAssertEqual(snapshot.generation, 2)
        let inventory = await runtime.inventory()
        XCTAssertEqual(inventory.stagedPluginCount, 0)
        XCTAssertEqual(inventory.serviceCount, 0)
        XCTAssertEqual(inventory.activePluginCount, 0)
    }

    func testDuplicateReplacementIsRejectedWhileCandidateIsActivating() async throws {
        let runtime = CordisPluginRuntime()
        let gate = CordisTestGate()
        let original = CordisPluginDefinition(id: "duplicate-replacement", version: "1") { _ in }
        let replacement = CordisPluginDefinition(id: original.id, version: "2") { _ in
            await gate.enterAndWait()
        }
        let secondReplacement = CordisPluginDefinition(id: original.id, version: "3") { _ in }

        _ = try await runtime.install(original)
        let first = Task { try await runtime.replace(original.id, with: replacement) }
        await gate.waitForEntry()

        do {
            _ = try await runtime.replace(original.id, with: secondReplacement)
            XCTFail("Only one replacement candidate may be staged")
        } catch let error as CordisPluginRuntimeError {
            XCTAssertEqual(error, .replacementInProgress(original.id))
        }

        await gate.release()
        _ = try await first.value
        let snapshot = try await runtime.snapshot(for: original.id)
        XCTAssertEqual(snapshot.version, "2")
        let inventory = await runtime.inventory()
        XCTAssertEqual(inventory.stagedPluginCount, 0)
    }

    func testUninstallRemovesEveryRegistrationFromRuntimeInventory() async throws {
        let serviceKey = CordisServiceKey<CordisTestService>("inventory")
        let runtime = CordisPluginRuntime()
        let provider = CordisPluginDefinition(
            id: "inventory-provider",
            version: "1",
            provides: [serviceKey.name]
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "ok"))
            _ = try await context.on(CordisEventKey<CordisNoPayload>("inventory/event")) { _ in }
            _ = try await context.intercept(CordisCheckpointKey<String, String>("inventory/checkpoint")) { _, next in
                try await next()
            }
        }
        _ = try await runtime.install(provider)
        let installedInventory = await runtime.inventory()
        XCTAssertFalse(installedInventory.hasNoRegistrations)

        _ = try await runtime.uninstall(provider.id)
        let inventory = await runtime.inventory()
        XCTAssertTrue(inventory.hasNoRegistrations)
    }

    func testServiceIsolationAllowsSameNameProvidersAndKeepsRootPending() async throws {
        let serviceKey = CordisServiceKey<CordisTestService>("shell")
        let alphaIsolation = CordisServiceIsolation(labels: [serviceKey.name: "alpha"])
        let betaIsolation = CordisServiceIsolation(labels: [serviceKey.name: "beta"])
        let recorder = CordisTestRecorder()
        let runtime = CordisPluginRuntime()

        let alphaProvider = CordisPluginDefinition(
            id: "alpha-provider",
            version: "1",
            provides: [serviceKey.name],
            isolation: alphaIsolation
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "alpha"))
        }
        let betaProvider = CordisPluginDefinition(
            id: "beta-provider",
            version: "1",
            provides: [serviceKey.name],
            isolation: betaIsolation
        ) { context in
            try await context.provide(serviceKey, value: CordisTestService(value: "beta"))
        }
        let alphaConsumer = CordisPluginDefinition(
            id: "alpha-consumer",
            version: "1",
            dependencies: [serviceKey.name],
            isolation: alphaIsolation
        ) { context in
            await recorder.append(try await context.service(serviceKey).value)
        }
        let betaConsumer = CordisPluginDefinition(
            id: "beta-consumer",
            version: "1",
            dependencies: [serviceKey.name],
            isolation: betaIsolation
        ) { context in
            await recorder.append(try await context.service(serviceKey).value)
        }
        let rootConsumer = CordisPluginDefinition(
            id: "root-consumer",
            version: "1",
            dependencies: [serviceKey.name]
        ) { _ in
            XCTFail("Root consumer must not see isolated services.")
        }

        _ = try await runtime.install(alphaProvider)
        _ = try await runtime.install(betaProvider)
        _ = try await runtime.install(alphaConsumer)
        _ = try await runtime.install(betaConsumer)
        let root = try await runtime.install(rootConsumer)
        let recorded = await recorder.values

        XCTAssertEqual(Set(recorded), Set(["alpha", "beta"]))
        XCTAssertEqual(root.state, .pending)
        XCTAssertEqual(root.missingDependencies, ["shell"])
    }

    func testActivationFailureIsContainedToOnePlugin() async throws {
        let runtime = CordisPluginRuntime()
        let broken = CordisPluginDefinition(id: "broken", version: "1") { _ in
            throw CordisTestError.activationFailed
        }
        let healthy = CordisPluginDefinition(id: "healthy", version: "1") { _ in }

        let brokenSnapshot = try await runtime.install(broken)
        let healthySnapshot = try await runtime.install(healthy)

        XCTAssertEqual(brokenSnapshot.state, .failed)
        XCTAssertNotNil(brokenSnapshot.error)
        XCTAssertEqual(healthySnapshot.state, .active)
    }
}

private struct CordisTestService: Sendable, Equatable {
    let value: String
}

private struct TimeoutTestTool: LocalAgentTool {
    let definition: ModelToolDefinition

    init(name: String, timeoutMs: Int?) {
        definition = ModelToolDefinition(
            name: name,
            description: "timeout test tool",
            parameters: .object(["type": .string("object")]),
            timeoutMs: timeoutMs
        )
    }

    let risk: ToolRisk = .pure

    func validate(arguments _: [String: JSONValue]) throws {}

    func summary(arguments _: [String: JSONValue]) -> String {
        definition.name
    }

    func execute(arguments _: [String: JSONValue]) async throws -> String {
        "tool"
    }
}

private actor TimeoutTestRecorder {
    private var storage: [String] = []

    var values: [String] { storage }

    func append(_ value: String) {
        storage.append(value)
    }
}

private enum CordisTestError: Error {
    case activationFailed
}

private actor CordisTestRecorder {
    private var storage: [String] = []

    var values: [String] { storage }

    func append(_ value: String) {
        storage.append(value)
    }
}

private actor CordisTestCounter {
    private var storage = 0

    var value: Int { storage }

    func increment() {
        storage += 1
    }
}

private actor CordisTraceRecorder {
    private var storage: [HarnessTraceDraft] = []

    var values: [HarnessTraceDraft] { storage }

    func append(_ draft: HarnessTraceDraft) {
        storage.append(draft)
    }
}

private actor CordisTestGate {
    private var hasEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        hasEntered = true
        let entryWaiters = entryWaiters
        self.entryWaiters.removeAll(keepingCapacity: true)
        for waiter in entryWaiters {
            waiter.resume()
        }
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForEntry() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = releaseWaiters
        self.releaseWaiters.removeAll(keepingCapacity: true)
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}
