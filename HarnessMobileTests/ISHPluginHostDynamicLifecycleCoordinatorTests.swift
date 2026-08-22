import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ISHPluginHostDynamicLifecycleCoordinatorTests: XCTestCase {
    func testExplicitUpdateFailureReactivatesPreviousPackage() async throws {
        let client = DynamicLifecycleFixtureClient()
        let coordinator = ISHPluginHostDynamicLifecycleCoordinator(client: client)
        let original = definition(logicalID: "formatter", name: "Formatter v1")
        let installed = try await coordinator.install(original)
        await client.rejectRuns(containingPackage: "formatter-v2")

        do {
            _ = try await coordinator.replace(
                "formatter",
                with: definition(logicalID: "formatter", name: "Formatter v2")
            )
            XCTFail("Expected an explicit rollback result")
        } catch let error as ISHPluginHostDynamicLifecycleError {
            guard case .replacementRolledBack(logicalID: "formatter", _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let snapshots = await coordinator.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.state, .active)
        XCTAssertEqual(snapshot.packageID, installed.packageID)
        let runs = await client.runRequests()
        XCTAssertEqual(runs.map(\.mode), [.run, .update, .run])
        XCTAssertEqual(runs.last?.packageId, installed.packageID)
    }

    func testAmbiguousUpdateDoesNotBlindlyReplayLifecycleMutation() async throws {
        let client = DynamicLifecycleFixtureClient()
        let coordinator = ISHPluginHostDynamicLifecycleCoordinator(client: client)
        _ = try await coordinator.install(definition(logicalID: "memory", name: "Memory v1"))
        await client.throwRuns(containingPackage: "memory-v2")

        do {
            _ = try await coordinator.replace(
                "memory",
                with: definition(logicalID: "memory", name: "Memory v2")
            )
            XCTFail("Expected an unknown replacement outcome")
        } catch let error as ISHPluginHostDynamicLifecycleError {
            guard case .replacementOutcomeUnknown(logicalID: "memory", _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let snapshots = await coordinator.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.state, .recoveryRequired)
        let runModes = await client.runRequests().map(\.mode)
        XCTAssertEqual(runModes, [.run, .update])
    }

    func testRestartRecoveryIsPerDefinitionAndReportsUnrecoverableSource() async throws {
        let client = DynamicLifecycleFixtureClient()
        let coordinator = ISHPluginHostDynamicLifecycleCoordinator(client: client)
        _ = try await coordinator.install(definition(logicalID: "alpha", name: "Alpha"))
        _ = try await coordinator.install(definition(logicalID: "beta", name: "Beta"))
        _ = try await coordinator.install(definition(
            logicalID: "private",
            name: "Private",
            policy: .unavailable(reason: "source was intentionally not retained")
        ))
        await client.rejectDefines(named: "Beta")

        let report = await coordinator.recoverAfterHostRestart()

        XCTAssertEqual(report.recoveredCount, 1)
        XCTAssertEqual(report.outcomes.count, 3)
        XCTAssertTrue(report.outcomes.contains {
            if case .replayed(logicalID: "alpha", _, _) = $0 { return true }
            return false
        })
        XCTAssertTrue(report.outcomes.contains {
            if case .failed(logicalID: "beta", _) = $0 { return true }
            return false
        })
        XCTAssertTrue(report.outcomes.contains {
            if case .unrecoverable(
                logicalID: "private",
                reason: "source was intentionally not retained"
            ) = $0 { return true }
            return false
        })

        let snapshots = await coordinator.snapshots()
        let states = Dictionary(uniqueKeysWithValues: snapshots.map {
            ($0.logicalID, $0.state)
        })
        XCTAssertEqual(states["alpha"], .active)
        XCTAssertEqual(states["beta"], .recoveryRequired)
        XCTAssertEqual(states["private"], .unrecoverable)
    }

    private func definition(
        logicalID: String,
        name: String,
        policy: ISHPluginHostDefinitionRecoveryPolicy = .replayAfterProcessRestart
    ) -> ISHPluginHostRecoverableDefinition {
        ISHPluginHostRecoverableDefinition(
            logicalID: logicalID,
            idPrefix: logicalID,
            sessionID: "session-1",
            name: name,
            purpose: "fixture",
            code: ISHPluginHostDefinitionCode(host: "export default function () {}"),
            recoveryPolicy: policy
        )
    }
}

final class ISHPluginHostCodeDispatchBridgeTests: XCTestCase {
    func testHostedHandlerSharesNativeCodeDispatchCheckpoint() async throws {
        let transport = CodeDispatchBridgeFixtureTransport(mode: .replaceResult)
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(ISHPluginHostCordisBridge.definition(
            contributions: contributions(method: "tools/code-dispatch-log"),
            sessionID: "session-1",
            client: client
        ))

        let agentID = UUID()
        let runID = UUID()
        let result = try await runtime.run(
            CordisAgentLoopCheckpoints.toolsCodeDispatchLog,
            input: CordisCodeDispatchLogContext(
                agentID: agentID,
                runID: runID,
                turn: 2,
                step: 4,
                parentCallID: "parent",
                dispatchCallID: "child",
                toolName: "workspace_read_text"
            ),
            target: .agent(agentID)
        ) {
            CordisToolExecutionResult(text: "native", isError: false)
        }

        XCTAssertEqual(result.text, "host-curated")
        XCTAssertEqual(result.isError, false)
        let capturedArguments = await transport.lastArguments()
        let arguments = try XCTUnwrap(capturedArguments?.objectValue)
        XCTAssertEqual(arguments["checkpoint"], .string("tools/code-dispatch-log"))
        XCTAssertEqual(arguments["parentCallId"], .string("parent"))
        XCTAssertEqual(arguments["dispatchCallId"], .string("child"))
        XCTAssertEqual(arguments["toolName"], .string("workspace_read_text"))
        XCTAssertEqual(arguments["result"]?.objectValue?["text"], .string("native"))
        await client.stop()
    }

    func testHostedCodeDispatchFailureFallsBackToNativeResult() async throws {
        let transport = CodeDispatchBridgeFixtureTransport(mode: .hostFailure)
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(CordisAgentServices().pluginDefinition())
        _ = try await runtime.install(ISHPluginHostCordisBridge.definition(
            contributions: contributions(method: "tools/code-dispatch-log"),
            sessionID: "session-1",
            client: client
        ))
        let agentID = UUID()

        let result = try await runtime.run(
            CordisAgentLoopCheckpoints.toolsCodeDispatchLog,
            input: CordisCodeDispatchLogContext(
                agentID: agentID,
                runID: UUID(),
                turn: 1,
                step: 1,
                parentCallID: "parent",
                dispatchCallID: "child",
                toolName: "probe"
            ),
            target: .agent(agentID)
        ) {
            CordisToolExecutionResult(text: "native-result", isError: false)
        }

        XCTAssertEqual(result.text, "native-result")
        XCTAssertFalse(result.isError)
        await client.stop()
    }

    private func contributions(method: String) -> ISHPluginHostContributions {
        ISHPluginHostContributions(
            revision: 1,
            scope: "session",
            tools: [],
            prompt: ISHPluginHostPromptContributions(sections: [], contexts: [], variables: [:]),
            handlers: [
                ISHPluginHostHandlerContribution(
                    pluginId: "code-observer",
                    pluginRunId: "run-1",
                    method: method
                )
            ],
            services: []
        )
    }
}

private enum DynamicLifecycleFixtureError: LocalizedError {
    case rejected(String)
    var errorDescription: String? {
        switch self { case let .rejected(message): message }
    }
}

private actor DynamicLifecycleFixtureClient: ISHPluginHostDynamicLifecycleClient {
    private var definitionCounts: [String: Int] = [:]
    private var rejectedDefineNames: Set<String> = []
    private var rejectedPackageFragments: Set<String> = []
    private var throwingPackageFragments: Set<String> = []
    private var runs: [ISHPluginHostRunRequest] = []

    func rejectDefines(named name: String) { rejectedDefineNames.insert(name) }
    func rejectRuns(containingPackage fragment: String) { rejectedPackageFragments.insert(fragment) }
    func throwRuns(containingPackage fragment: String) { throwingPackageFragments.insert(fragment) }
    func runRequests() -> [ISHPluginHostRunRequest] { runs }

    func define(_ request: ISHPluginHostDefineRequest) async throws -> ISHPluginHostDefineReceipt {
        if rejectedDefineNames.contains(request.name) {
            throw DynamicLifecycleFixtureError.rejected("define rejected")
        }
        let slug = request.name.lowercased().replacingOccurrences(of: " ", with: "-")
        let next = (definitionCounts[slug] ?? 0) + 1
        definitionCounts[slug] = next
        let pluginID = request.plugin.pluginId ?? "plugin-\(request.plugin.idPrefix ?? slug)"
        return ISHPluginHostDefineReceipt(
            pluginId: pluginID,
            packageId: "\(slug)-package-\(next)",
            name: request.name,
            purpose: request.purpose,
            hasHostHalf: request.code.host != nil,
            hasClientHalf: request.code.client != nil
        )
    }

    func run(_ request: ISHPluginHostRunRequest) async throws -> ISHPluginHostRunResponse {
        runs.append(request)
        if throwingPackageFragments.contains(where: request.packageId.contains) {
            throw DynamicLifecycleFixtureError.rejected("transport lost")
        }
        let rejected = rejectedPackageFragments.contains(where: request.packageId.contains)
        return ISHPluginHostRunResponse(
            ok: !rejected,
            status: rejected ? "failed" : "running",
            reason: rejected ? "activation-failed" : nil,
            message: rejected ? "candidate activation failed" : nil,
            pluginId: request.pluginId,
            packageId: request.packageId,
            pluginRunId: rejected ? nil : "run-\(runs.count)",
            currentPackageId: rejected ? nil : request.packageId,
            nextPackageId: nil,
            waitingFor: nil
        )
    }
}

private actor CodeDispatchBridgeFixtureTransport: ISHPluginHostTransport {
    enum Mode: Sendable { case replaceResult, hostFailure }

    private let mode: Mode
    private var stdout: (@Sendable (Data) -> Void)?
    private var arguments: JSONValue?

    init(mode: Mode) { self.mode = mode }

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) async throws -> Int32 {
        stdout = onStdout
        _ = onStderr
        _ = onExit
        return 77
    }

    func write(_ data: Data) async throws {
        var line = data
        if line.last == 0x0A { line.removeLast() }
        let request = try JSONDecoder().decode(ISHPluginHostRPCRequest.self, from: line)
        arguments = request.params.objectValue?["arguments"]
        let result: JSONValue
        switch mode {
        case .replaceResult:
            result = .object([
                "ok": .bool(true),
                "value": .object([
                    "kind": .string("result"),
                    "text": .string("host-curated"),
                    "isError": .bool(false)
                ])
            ])
        case .hostFailure:
            result = .object([
                "ok": .bool(false),
                "message": .string("stale generation")
            ])
        }
        var response = try JSONEncoder().encode(ISHPluginHostRPCResponse(
            jsonrpc: "2.0",
            id: request.id,
            result: result,
            error: nil
        ))
        response.append(0x0A)
        stdout?(response)
    }

    func stop() async { stdout = nil }
    func lastArguments() -> JSONValue? { arguments }
}
