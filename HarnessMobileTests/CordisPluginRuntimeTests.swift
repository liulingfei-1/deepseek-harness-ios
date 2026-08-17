import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class CordisPluginRuntimeTests: XCTestCase {
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
        XCTAssertEqual(loadCount, 2)
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
