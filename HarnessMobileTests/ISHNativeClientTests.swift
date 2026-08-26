import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ISHNativeClientTests: XCTestCase {
    func testNativeSlotRegistryProjectsAllowlistedSlotsAndDisposesByToken() async throws {
        let plugin = makeSlotPlugin()
        let registry = ISHNativeClientSlotRegistry()

        let settingsToken = try await registry.register(
            plugin: plugin,
            contributionID: "settings",
            kind: .settingsCard
        )
        let cardToken = try await registry.register(
            plugin: plugin,
            contributionID: "card",
            kind: .conversationRenderer
        )
        let actionToken = try await registry.register(
            plugin: plugin,
            contributionID: "open",
            kind: .sidebarAction
        )

        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.settingsCards.map(\.id), ["settings"])
        XCTAssertEqual(snapshot.conversationRenderers.map(\.id), ["card"])
        XCTAssertEqual(snapshot.sidebarActions.map(\.id), ["open"])
        XCTAssertEqual(snapshot.conversationRenderers.first?.renderer, .markdown)

        await registry.dispose(cardToken)
        await registry.dispose(cardToken)
        await registry.dispose(settingsToken)
        await registry.dispose(actionToken)
        let empty = await registry.snapshot()
        XCTAssertTrue(empty.settingsCards.isEmpty)
        XCTAssertTrue(empty.conversationRenderers.isEmpty)
        XCTAssertTrue(empty.sidebarActions.isEmpty)
        XCTAssertGreaterThan(empty.revision, snapshot.revision)
    }

    func testNativeSlotRegistryRejectsUnknownContributionAndStaleGeneration() async throws {
        let plugin = makeSlotPlugin()
        let registry = ISHNativeClientSlotRegistry()

        do {
            _ = try await registry.register(
                plugin: plugin,
                contributionID: "missing",
                kind: .conversationRenderer
            )
            XCTFail("Unknown slot contribution must fail closed")
        } catch let error as ISHNativeClientSlotRegistryError {
            guard case .invalidContribution = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await registry.register(
                plugin: plugin,
                contributionID: "settings",
                kind: .settingsCard,
                generation: plugin.activationGeneration + 1
            )
            XCTFail("Stale generation must fail closed")
        } catch let error as ISHNativeClientSlotRegistryError {
            guard case .invalidContribution = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeSlotPlugin() -> ISHNativeClientPlugin {
        ISHNativeClientPlugin(
            pluginId: "slot-plugin",
            packageName: "slot-package",
            version: "1",
            scope: .process,
            activationGeneration: 1,
            sourceDigest: String(repeating: "a", count: 64),
            schemaVersion: 2,
            minimumRuntime: 2,
            inject: [],
            immediately: false,
            contributions: ISHNativeClientContributions(
                inspectors: [],
                settings: [
                    ISHNativeClientSettingsContribution(
                        id: "settings",
                        title: "Settings",
                        namespace: "slot.settings",
                        order: 1
                    )
                ],
                commands: [
                    ISHNativeClientCommandContribution(
                        name: "open",
                        description: "Open",
                        inputHint: nil,
                        order: 2,
                        action: ISHNativeClientActionDescriptor(
                            kind: .hostTool,
                            name: "slot.open",
                            arguments: [:],
                            inputKey: nil
                        )
                    )
                ],
                cards: [
                    ISHNativeClientCardContribution(
                        id: "card",
                        title: "Card",
                        description: nil,
                        order: 0,
                        renderer: .markdown,
                        value: .string("hello")
                    )
                ]
            ),
            endpoints: [],
            permissions: []
        )
    }

    func testNativeCommandImageCapabilityIsOptionalAndRoundTrips() throws {
        let command = ISHNativeClientCommandContribution(
            name: "vision_status",
            description: "Inspect an image.",
            inputHint: "<query>",
            inputImages: true,
            order: 1,
            action: ISHNativeClientActionDescriptor(
                kind: .hostTool,
                name: "vision_status_tool",
                arguments: [:],
                inputKey: "query"
            )
        )
        let data = try JSONEncoder().encode(command)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["inputImages"] as? Bool, true)
        XCTAssertEqual(
            try JSONDecoder().decode(ISHNativeClientCommandContribution.self, from: data),
            command
        )

        let legacy = Data(
            "{\"name\":\"legacy\",\"description\":\"Legacy\",\"order\":1,\"action\":{\"kind\":\"hostTool\",\"name\":\"legacy_tool\",\"arguments\":{}}}".utf8
        )
        XCTAssertFalse(
            try JSONDecoder().decode(ISHNativeClientCommandContribution.self, from: legacy).inputImages
        )
    }

    func testManifestValidationFailsClosedForUnknownRenderer() {
        let data = Data(
            """
            {
              "revision": 1,
              "scope": "process",
              "plugins": [{
                "pluginId": "native-probe",
                "packageName": "native-probe",
                "version": "1.0.0",
                "scope": "process",
                "activationGeneration": 1,
                "sourceDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "schemaVersion": 1,
                "minimumRuntime": 1,
                "inject": [],
                "immediately": false,
                "contributions": {
                  "inspectors": [{
                    "id": "status",
                    "title": "Status",
                    "order": 10,
                    "renderer": "webComponent",
                    "endpoint": "status"
                  }],
                  "settings": [],
                  "commands": []
                },
                "endpoints": [{
                  "id": "status",
                  "kind": "hostService",
                  "entry": "native-probe",
                  "service": "probe",
                  "method": "status",
                  "readOnly": true
                }],
                "permissions": ["ui.inspector", "host.service:probe.status"]
              }]
            }
            """.utf8
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ISHNativeClientSnapshot.self, from: data)
        )
    }

    func testManifestValidationRejectsCredentialArguments() {
        let plugin = makePlugin(
            generation: 1,
            arguments: ["apiKey": .string("not-even-a-real-key")]
        )

        XCTAssertThrowsError(try plugin.validated()) { error in
            XCTAssertEqual(
                error as? ISHNativeClientError,
                .invalidManifest(
                    pluginID: plugin.pluginId,
                    reason: "command arguments contain credentials"
                )
            )
        }
    }

    func testCoordinatorUsesCordisRollbackAndDisposesCommands() async throws {
        let runtime = CordisPluginRuntime()
        let registry = ISHNativeClientContributionRegistry()
        let slotRegistry = ISHNativeClientSlotRegistry()
        let commands = SlashCommandRegistry(includeBuiltIns: false)
        let coordinator = ISHNativeClientCordisCoordinator(
            runtime: runtime,
            registry: registry,
            slotRegistry: slotRegistry,
            commandRegistry: commands
        )
        let client = ISHPluginHostClient(transport: NativeClientTestTransport())
        let original = makePlugin(generation: 1)

        var failures = await coordinator.synchronize(
            ISHNativeClientSnapshot(revision: 1, scope: .process, plugins: [original]),
            sessionID: "session-1",
            client: client
        )
        XCTAssertTrue(failures.isEmpty)
        let initiallyActivePlugin = await registry.plugins().first
        let initiallyActiveCommand = await commands.descriptor(named: "native_status")
        let initiallyActiveSlots = await slotRegistry.snapshot()
        XCTAssertEqual(initiallyActivePlugin?.activationGeneration, 1)
        XCTAssertNotNil(initiallyActiveCommand)
        XCTAssertEqual(initiallyActiveSlots.settingsCards.map(\.id), ["settings"])
        XCTAssertEqual(initiallyActiveSlots.sidebarActions.map(\.id), ["native_status"])

        let rejectedReplacement = makePlugin(
            generation: 2,
            digest: String(repeating: "b", count: 64),
            arguments: ["password": .string("blocked")]
        )
        failures = await coordinator.synchronize(
            ISHNativeClientSnapshot(
                revision: 2,
                scope: .process,
                plugins: [rejectedReplacement]
            ),
            sessionID: "session-1",
            client: client
        )

        XCTAssertEqual(failures.count, 1)
        let activePluginAfterRejectedReplacement = await registry.plugins().first
        let runtimeSnapshotAfterRejectedReplacement = try await runtime.snapshot(
            for: ISHNativeClientCordisBridge.cordisPluginID(for: original.pluginId)
        )
        XCTAssertEqual(activePluginAfterRejectedReplacement?.activationGeneration, 1)
        XCTAssertEqual(runtimeSnapshotAfterRejectedReplacement.state, .active)

        await coordinator.removeAll()
        let pluginsAfterRemoval = await registry.plugins()
        let commandAfterRemoval = await commands.descriptor(named: "native_status")
        let slotsAfterRemoval = await slotRegistry.snapshot()
        XCTAssertTrue(pluginsAfterRemoval.isEmpty)
        XCTAssertNil(commandAfterRemoval)
        XCTAssertTrue(slotsAfterRemoval.settingsCards.isEmpty)
        XCTAssertTrue(slotsAfterRemoval.sidebarActions.isEmpty)
    }

    func testCoordinatorRejectsDuplicatePluginIDsWithoutReplacingActiveGeneration() async throws {
        let runtime = CordisPluginRuntime()
        let registry = ISHNativeClientContributionRegistry()
        let slotRegistry = ISHNativeClientSlotRegistry()
        let commands = SlashCommandRegistry(includeBuiltIns: false)
        let coordinator = ISHNativeClientCordisCoordinator(
            runtime: runtime,
            registry: registry,
            slotRegistry: slotRegistry,
            commandRegistry: commands
        )
        let client = ISHPluginHostClient(transport: NativeClientTestTransport())
        let original = makePlugin(generation: 1)

        let initialFailures = await coordinator.synchronize(
            ISHNativeClientSnapshot(revision: 1, scope: .process, plugins: [original]),
            sessionID: "session-1",
            client: client
        )
        XCTAssertTrue(initialFailures.isEmpty)

        let duplicateFailures = await coordinator.synchronize(
            ISHNativeClientSnapshot(
                revision: 2,
                scope: .process,
                plugins: [
                    makePlugin(generation: 2, digest: String(repeating: "b", count: 64)),
                    makePlugin(generation: 3, digest: String(repeating: "c", count: 64))
                ]
            ),
            sessionID: "session-1",
            client: client
        )

        let activePlugin = await registry.plugins().first
        let activeCommand = await commands.descriptor(named: "native_status")
        let runtimeSnapshot = try await runtime.snapshot(
            for: ISHNativeClientCordisBridge.cordisPluginID(for: original.pluginId)
        )
        XCTAssertEqual(duplicateFailures.count, 1)
        XCTAssertEqual(duplicateFailures.first?.pluginID, original.pluginId)
        XCTAssertEqual(activePlugin?.activationGeneration, 1)
        XCTAssertNotNil(activeCommand)
        XCTAssertEqual(runtimeSnapshot.state, .active)
    }

    func testManifestValidationRejectsGenerationBeyondJSONSafeInteger() {
        let plugin = makePlugin(generation: 9_007_199_254_740_992)

        XCTAssertThrowsError(try plugin.validated())
    }

    func testClientRejectsGenerationBeyondJSONSafeIntegerBeforeEncoding() async {
        let client = ISHPluginHostClient(transport: NativeClientTestTransport())

        do {
            _ = try await client.invokeNativeClientEndpoint(
                ISHNativeClientEndpointInvocation(
                    pluginId: "native-probe",
                    activationGeneration: 9_007_199_254_740_992,
                    endpointId: "status"
                )
            )
            XCTFail("Expected an unsafe activation generation to be rejected")
        } catch let error as ISHNativeClientError {
            XCTAssertEqual(
                error,
                .invalidManifest(
                    pluginID: "native-probe",
                    reason: "activation generation exceeds JSON safe integer range"
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testClientInvokesExactNativeEndpointGeneration() async throws {
        let transport = NativeClientTestTransport { request in
            XCTAssertEqual(request.method, .invoke)
            XCTAssertEqual(request.params.objectValue?["target"], .string("nativeClientEndpoint"))
            XCTAssertEqual(request.params.objectValue?["pluginId"], .string("native-probe"))
            XCTAssertEqual(request.params.objectValue?["activationGeneration"], .number(7))
            XCTAssertEqual(request.params.objectValue?["endpointId"], .string("status"))
            return ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "ok": .bool(true),
                    "value": .object(["state": .string("active")])
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let value = try await client.invokeNativeClientEndpoint(
            ISHNativeClientEndpointInvocation(
                pluginId: "native-probe",
                activationGeneration: 7,
                endpointId: "status"
            )
        )

        XCTAssertEqual(value.objectValue?["state"], .string("active"))
        await client.stop()
    }

    private func makePlugin(
        generation: UInt64,
        digest: String = String(repeating: "a", count: 64),
        arguments: [String: JSONValue] = [:]
    ) -> ISHNativeClientPlugin {
        ISHNativeClientPlugin(
            pluginId: "native-probe",
            packageName: "@example/native-probe",
            version: "1.0.0",
            scope: .process,
            activationGeneration: generation,
            sourceDigest: digest,
            schemaVersion: 1,
            minimumRuntime: 1,
            inject: [],
            immediately: false,
            contributions: ISHNativeClientContributions(
                inspectors: [
                    ISHNativeClientInspectorContribution(
                        id: "status",
                        title: "Status",
                        description: nil,
                        order: 10,
                        renderer: .keyValue,
                        endpoint: "status"
                    )
                ],
                settings: [
                    ISHNativeClientSettingsContribution(
                        id: "settings",
                        title: "Settings",
                        namespace: "native-probe",
                        order: 20
                    )
                ],
                commands: [
                    ISHNativeClientCommandContribution(
                        name: "native_status",
                        description: "Read native status.",
                        inputHint: nil,
                        order: 30,
                        action: ISHNativeClientActionDescriptor(
                            kind: .hostTool,
                            name: "native_probe_status",
                            arguments: arguments,
                            inputKey: nil
                        )
                    )
                ]
            ),
            endpoints: [
                ISHNativeClientEndpoint(
                    id: "status",
                    kind: .hostService,
                    entry: "native-probe",
                    service: "nativeProbe",
                    method: "status",
                    readOnly: true
                )
            ],
            permissions: [
                "host.service:nativeProbe.status",
                "host.tool:native_probe_status",
                "settings.read:native-probe",
                "ui.command",
                "ui.inspector",
                "ui.settings-link"
            ]
        )
    }
}

private actor NativeClientTestTransport: ISHPluginHostTransport {
    typealias Responder = @Sendable (ISHPluginHostRPCRequest) -> ISHPluginHostRPCResponse

    private let responder: Responder?
    private var stdout: (@Sendable (Data) -> Void)?
    private var exit: (@Sendable (ISHPluginHostTransportExit) -> Void)?

    init(responder: Responder? = nil) {
        self.responder = responder
    }

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) async throws -> Int32 {
        stdout = onStdout
        exit = onExit
        _ = onStderr
        return 42
    }

    func write(_ data: Data) async throws {
        guard let responder else { return }
        var line = data
        if line.last == 0x0A { line.removeLast() }
        let request = try JSONDecoder().decode(ISHPluginHostRPCRequest.self, from: line)
        var response = try JSONEncoder().encode(responder(request))
        response.append(0x0A)
        stdout?(response)
    }

    func stop() async {
        exit?(ISHPluginHostTransportExit(exitCode: 0, errorCode: 0))
        stdout = nil
        exit = nil
    }
}
