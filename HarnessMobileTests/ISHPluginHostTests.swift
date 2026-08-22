import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ISHPluginHostTests: XCTestCase {
    func testContextProjectionDropsTokenDeltasButKeepsUsageAndFinalEvents() throws {
        func event(_ draft: SessionEventDraft, sequence: UInt64) throws -> SessionEvent {
            try SessionEvent(
                type: draft.type,
                seq: sequence,
                time: draft.time,
                data: draft.data,
                ignorable: draft.ignorable,
                sourceEventSeqs: draft.sourceEventSeqs,
                surfaceOp: draft.surfaceOp
            )
        }

        let delta = try event(
            .assistantTextDelta(turn: 1, step: 1, text: "token"),
            sequence: 0
        )
        let usage = try event(
            .assistantUsage(
                turn: 1,
                step: 1,
                usage: SessionTokenUsage(inputTokens: 10, outputTokens: 2)
            ),
            sequence: 1
        )
        let end = try event(
            .turnEnd(turn: 1, reason: .string("completed")),
            sequence: 2
        )

        let projected = ISHPluginHostContextProjection.events(from: [delta, usage, end])
        XCTAssertEqual(projected.map(\.seq), [0, 1])
        XCTAssertEqual(projected.map(\.type), [
            SessionEventVocabulary.assistantChunk,
            SessionEventVocabulary.turnEnd
        ])
    }

    func testNDJSONFramerHandlesFragmentedAndCRLFLines() throws {
        var framer = ISHPluginHostNDJSONFramer(maximumLineBytes: 64)

        XCTAssertEqual(try framer.append(Data("{\"id\":1".utf8)), [])
        let lines = try framer.append(Data("}\r\n\n{\"id\":2}\npartial".utf8))

        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"id\":1}", "{\"id\":2}"])
        XCTAssertEqual(framer.bufferedByteCount, 7)
        XCTAssertEqual(
            try framer.finish().map { String(decoding: $0, as: UTF8.self) },
            ["partial"]
        )
    }

    func testNDJSONFramerRejectsOversizedIncompleteFrame() throws {
        var framer = ISHPluginHostNDJSONFramer(maximumLineBytes: 4)

        XCTAssertThrowsError(try framer.append(Data("12345".utf8))) { error in
            XCTAssertEqual(error as? ISHPluginHostError, .frameTooLarge(maximumBytes: 4))
        }
    }

    func testCredentialFirewallRejectsKeysAndSecretShapedValues() {
        let keyed = JSONValue.object([
            "nested": .object(["api_key": .string("not-even-a-real-key")])
        ])
        let embedded = JSONValue.object([
            "code": .string("return 'sk-1234567890abcdef'")
        ])

        for value in [keyed, embedded] {
            XCTAssertThrowsError(try ISHPluginHostCredentialFirewall.validate(value)) { error in
                XCTAssertEqual(error as? ISHPluginHostError, .credentialsForbidden)
            }
        }
        XCTAssertNoThrow(
            try ISHPluginHostCredentialFirewall.validate(
                .object(["code": .string("return { name: 'safe-plugin' }")])
            )
        )
    }

    func testMarketplaceErrorPolicySilencesCancellationButKeepsRecoverableFailure() {
        XCTAssertNil(
            ISHPluginMarketplaceErrorPolicy.message(
                for: CancellationError(),
                taskIsCancelled: false
            )
        )
        XCTAssertNil(
            ISHPluginMarketplaceErrorPolicy.message(
                for: URLError(.cancelled),
                taskIsCancelled: false
            )
        )
        XCTAssertNil(
            ISHPluginMarketplaceErrorPolicy.message(
                for: CocoaError(.userCancelled),
                taskIsCancelled: false
            )
        )

        let offline = NSError(
            domain: NSURLErrorDomain,
            code: URLError.notConnectedToInternet.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "目录暂时不可用"]
        )
        XCTAssertEqual(
            ISHPluginMarketplaceErrorPolicy.message(
                for: offline,
                taskIsCancelled: false
            ),
            "目录暂时不可用"
        )
        XCTAssertNil(
            ISHPluginMarketplaceErrorPolicy.message(
                for: offline,
                taskIsCancelled: true
            )
        )

        let remote = ISHPluginHostError.remote(
            code: -32_010,
            message: "fetch failed",
            data: .object(["reason": .string("download-failed")])
        )
        XCTAssertEqual(
            ISHPluginMarketplaceErrorPolicy.message(
                for: remote,
                taskIsCancelled: false
            ),
            "插件目录暂时无法连接，已自动刷新 iSH DNS；请确认 iSH 网络已开启后重试。"
        )

        let incompletePackage = ISHPluginHostError.remote(
            code: -32_010,
            message: "Runtime package dsh-toolkit declares missing entrypoint ./lib/index.js.",
            data: .object(["reason": .string("missing-entrypoint")])
        )
        XCTAssertEqual(
            ISHPluginMarketplaceErrorPolicy.message(
                for: incompletePackage,
                taskIsCancelled: false
            ),
            "插件包不完整，缺少发布时声明的构建文件：Runtime package dsh-toolkit declares missing entrypoint ./lib/index.js."
        )

        let dependencyFailure = ISHPluginHostError.remote(
            code: -32_010,
            message: "npm exited with code 1",
            data: .object(["reason": .string("npm-install-failed")])
        )
        XCTAssertEqual(
            ISHPluginMarketplaceErrorPolicy.message(
                for: dependencyFailure,
                taskIsCancelled: false
            ),
            "插件依赖安装失败：npm exited with code 1"
        )
    }

    func testGuestNetworkStartsEnabledAndLeasesKeepAccessUntilLastOperationFinishes() async {
        let coordinator = ISHSandboxCoordinator()

        let startsEnabled = await coordinator.isGuestNetworkEnabled()
        let startsEffectivelyEnabled = await coordinator.isGuestNetworkEffectivelyEnabled()
        XCTAssertTrue(startsEnabled)
        XCTAssertTrue(startsEffectivelyEnabled)

        await coordinator.setGuestNetworkEnabled(false)
        let disabledByUser = await coordinator.isGuestNetworkEffectivelyEnabled()
        XCTAssertFalse(disabledByUser)

        let first = await coordinator.beginTemporaryGuestNetworkAccess()
        let second = await coordinator.beginTemporaryGuestNetworkAccess()
        let enabledByLeases = await coordinator.isGuestNetworkEffectivelyEnabled()
        XCTAssertTrue(enabledByLeases)

        await coordinator.endTemporaryGuestNetworkAccess(first)
        let heldBySecondLease = await coordinator.isGuestNetworkEffectivelyEnabled()
        XCTAssertTrue(heldBySecondLease)

        await coordinator.setGuestNetworkEnabled(true)
        await coordinator.endTemporaryGuestNetworkAccess(second)
        let heldByUserSetting = await coordinator.isGuestNetworkEffectivelyEnabled()
        XCTAssertTrue(heldByUserSetting)

        await coordinator.setGuestNetworkEnabled(false)
        let disabledAfterAllOwnersRelease = await coordinator.isGuestNetworkEffectivelyEnabled()
        XCTAssertFalse(disabledAfterAllOwnersRelease)
    }

    func testClientDecodesFragmentedPingResponse() async throws {
        let transport = FakePluginHostTransport { request in
            XCTAssertEqual(request.method, .ping)
            return ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "protocolVersion": .number(1),
                    "hostVersion": .string("1.1.0"),
                    "runtime": .string("iSH/Node/Cordis"),
                    "dynamicDefinitionLifetime": .string("process-memory-only"),
                    "credentialBoundary": .string("provider credentials are rejected before dispatch"),
                    "packages": .object([
                        "@deepseek-ai/cordis": .string("4.0.1"),
                        "@deepseek-ai/dsh-tool-cordis": .string("0.1.0-rc.6")
                    ]),
                    "capabilities": .array(ISHPluginHostRPCMethod.allCases.map { .string($0.rawValue) })
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))

        try await client.start()
        let ping = try await client.ping()
        let diagnostics = await client.diagnostics()

        XCTAssertEqual(ping.protocolVersion, 1)
        XCTAssertEqual(ping.hostVersion, "1.1.0")
        XCTAssertEqual(ping.packages["@deepseek-ai/cordis"], "4.0.1")
        XCTAssertEqual(ping.packages["@deepseek-ai/dsh-tool-cordis"], "0.1.0-rc.6")
        XCTAssertEqual(ping.capabilities, ISHPluginHostRPCMethod.allCases)
        XCTAssertEqual(diagnostics.state, .running(pid: 42))
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        XCTAssertEqual(diagnostics.outboundQueuedBytes, 0)
        XCTAssertFalse(diagnostics.outboundWriteInFlight)
        await client.stop()
    }

    func testClientPreservesTransportCallbackOrderAcrossByteFragments() async throws {
        let transport = FakePluginHostTransport(fragmentSize: 1) { request in
            ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "protocolVersion": .number(1),
                    "hostVersion": .string("1.1.0"),
                    "runtime": .string("iSH/Node/Cordis"),
                    "dynamicDefinitionLifetime": .string("process-memory-only"),
                    "credentialBoundary": .string("provider credentials are rejected before dispatch"),
                    "packages": .object([
                        "@deepseek-ai/cordis": .string("4.0.1"),
                        "@deepseek-ai/dsh-tool-cordis": .string("0.1.0-rc.6")
                    ]),
                    "capabilities": .array(ISHPluginHostRPCMethod.allCases.map { .string($0.rawValue) })
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))

        try await client.start()
        let ping = try await client.ping()

        XCTAssertEqual(ping.hostVersion, "1.1.0")
        XCTAssertEqual(ping.capabilities, ISHPluginHostRPCMethod.allCases)
        await client.stop()
    }

    func testClientRetriesRejectedStdinWritesWithBackoff() async throws {
        let transport = RejectingWritePluginHostTransport(rejectionsBeforeSuccess: 2)
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(3))

        try await client.start()
        let ping = try await client.ping()
        let diagnostics = await client.diagnostics()

        XCTAssertEqual(ping.hostVersion, "retry-host")
        XCTAssertEqual(diagnostics.rejectedWriteCount, 2)
        XCTAssertEqual(diagnostics.automaticRestartCount, 0)
        XCTAssertTrue(diagnostics.lastTransportFailure?.contains("attempt 2") == true)
        let writeCount = await transport.writeCount
        XCTAssertEqual(writeCount, 3)
        await client.stop()
    }

    func testClientRecyclesHostAfterPersistentRejectedWrites() async throws {
        let transport = RejectingWritePluginHostTransport(rejectionsBeforeSuccess: .max)
        let client = ISHPluginHostClient(
            transport: transport,
            requestTimeout: .seconds(2),
            rejectedWriteBackoff: []
        )

        try await client.start()
        do {
            _ = try await client.ping()
            XCTFail("Expected rejected stdin write")
        } catch {
            XCTAssertEqual(error as? ISHPluginHostError, .transportRejectedWrite)
        }
        let diagnostics = await client.diagnostics()
        XCTAssertEqual(diagnostics.state, .stopped)
        XCTAssertEqual(diagnostics.pendingRequestCount, 0)
        XCTAssertEqual(diagnostics.outboundQueuedBytes, 0)
        XCTAssertFalse(diagnostics.outboundWriteInFlight)
        XCTAssertEqual(diagnostics.rejectedWriteCount, 2)
        XCTAssertEqual(diagnostics.automaticRestartCount, 1)
        let startCount = await transport.startCount
        XCTAssertEqual(startCount, 2)
        let transportEvents = await transport.events
        XCTAssertEqual(transportEvents, ["start", "write", "stop", "start", "write", "stop"])
        let wasStopped = await transport.wasStopped
        XCTAssertTrue(wasStopped)
        await client.stop()
    }

    func testClientRestartsHostAndReplaysFrameRejectedBeforeDelivery() async throws {
        let transport = RejectingWritePluginHostTransport(rejectionsBeforeSuccess: 1)
        let client = ISHPluginHostClient(
            transport: transport,
            requestTimeout: .seconds(2),
            rejectedWriteBackoff: []
        )

        try await client.start()
        let ping = try await client.ping()
        let diagnostics = await client.diagnostics()

        XCTAssertEqual(ping.hostVersion, "retry-host")
        XCTAssertEqual(diagnostics.rejectedWriteCount, 1)
        XCTAssertEqual(diagnostics.automaticRestartCount, 1)
        XCTAssertEqual(diagnostics.state, .running(pid: 73))
        let startCount = await transport.startCount
        XCTAssertEqual(startCount, 2)
        let writeCount = await transport.writeCount
        XCTAssertEqual(writeCount, 2)
        await client.stop()
    }

    func testClientSerializesConcurrentWrites() async throws {
        let transport = SerializingProbePluginHostTransport()
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(3))
        try await client.start()

        async let first = client.request(method: .ping)
        async let second = client.request(method: .ping)
        async let third = client.request(method: .ping)
        _ = try await (first, second, third)

        let maxConcurrentWrites = await transport.maxConcurrentWrites
        let requestIDs = await transport.requestIDs
        XCTAssertEqual(maxConcurrentWrites, 1)
        XCTAssertEqual(requestIDs, ["1", "2", "3"])
        await client.stop()
    }

    func testClientSurfacesRemoteJSONRPCError() async throws {
        let transport = FakePluginHostTransport { request in
            ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: nil,
                error: ISHPluginHostRPCError(
                    code: -32002,
                    message: "Client halves are not supported.",
                    data: .object(["kind": .string("client-half")])
                )
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        do {
            _ = try await client.run(
                ISHPluginHostRunRequest(
                    sessionId: "session-1",
                    pluginId: "probe-1",
                    packageId: "pkg-1",
                    mode: .run
                )
            )
            XCTFail("Expected the JSON-RPC error")
        } catch let error as ISHPluginHostError {
            XCTAssertEqual(
                error,
                .remote(
                    code: -32002,
                    message: "Client halves are not supported.",
                    data: .object(["kind": .string("client-half")])
                )
            )
        }
        await client.stop()
    }

    func testClientDecodesMarketplaceCatalogAndInstalledPlugins() async throws {
        let transport = FakePluginHostTransport { request in
            switch request.method {
            case .marketCatalog:
                XCTAssertEqual(
                    request.params.objectValue?["forceRefresh"],
                    .bool(true)
                )
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object([
                        "sourceURL": .string("https://github.com/example/awesome-dsh-plugin"),
                        "fetchedAt": .string("2026-08-15T00:00:00.000Z"),
                        "stale": .bool(false),
                        "items": .array([.object([
                            "id": .string("example/phone-plugin"),
                            "name": .string("Phone Plugin"),
                            "repositoryURL": .string("https://github.com/example/phone-plugin"),
                            "repositoryKey": .string("example/phone-plugin"),
                            "description": .string("Runs in the local iSH host."),
                            "category": .string("tools"),
                            "compatibility": .string("supported"),
                            "unsupportedReason": .null,
                            "installed": .bool(true),
                            "installedPluginID": .string("phone-plugin"),
                            "installedVersion": .string("1.0.0")
                        ])])
                    ]),
                    error: nil
                )
            case .pluginList:
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object([
                        "revision": .number(3),
                        "plugins": .array([.object([
                            "id": .string("phone-plugin"),
                            "name": .string("Phone Plugin"),
                            "version": .string("1.0.0"),
                            "description": .string("Runs in the local iSH host."),
                            "license": .string("MIT"),
                            "source": .object([
                                "kind": .string("github"),
                                "location": .string("https://github.com/example/phone-plugin"),
                                "repositoryURL": .string("https://github.com/example/phone-plugin"),
                                "repositoryKey": .string("example/phone-plugin"),
                                "ref": .string("main"),
                                "subpath": .null
                            ]),
                            "enabled": .bool(false),
                            "state": .string("disabled"),
                            "installedAt": .string("2026-08-15T00:00:00.000Z"),
                            "updatedAt": .string("2026-08-15T00:00:00.000Z"),
                            "entryCount": .number(1),
                            "lastError": .null
                        ])])
                    ]),
                    error: nil
                )
            default:
                XCTFail("Unexpected marketplace RPC: \(request.method.rawValue)")
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .null,
                    error: nil
                )
            }
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let catalog = try await client.marketCatalog(forceRefresh: true)
        let installed = try await client.marketplacePlugins()

        XCTAssertEqual(catalog.items.first?.compatibility, .supported)
        XCTAssertEqual(catalog.items.first?.installedPluginID, "phone-plugin")
        XCTAssertEqual(installed.revision, 3)
        XCTAssertEqual(installed.plugins.first?.source.kind, .github)
        XCTAssertEqual(installed.plugins.first?.state, .disabled)
        await client.stop()
    }

    func testClientPreparesNativeSourceAndReusesTokenForFallbackInstall() async throws {
        let token = String(repeating: "a", count: 32)
        let digest = String(repeating: "b", count: 64)
        let transport = FakePluginHostTransport { request in
            switch request.method {
            case .pluginPrepareNative:
                XCTAssertEqual(
                    request.params.objectValue?["source"]?.objectValue?["kind"],
                    .string("github")
                )
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object([
                        "preparedToken": .string(token),
                        "nativeCandidate": .object([
                            "schemaVersion": .number(1),
                            "failureReason": .string("native-first-analysis"),
                            "sourceDigest": .string(digest),
                            "source": .object([
                                "kind": .string("github"),
                                "location": .string("https://github.com/example/plugin")
                            ]),
                            "packageName": .string("example-plugin"),
                            "version": .string("1.0.0"),
                            "files": .array([.object([
                                "path": .string("src/index.ts"),
                                "content": .string("export function apply() {}"),
                                "truncated": .bool(false)
                            ])])
                        ])
                    ]),
                    error: nil
                )
            case .pluginInstall:
                XCTAssertEqual(request.params.objectValue?["preparedToken"], .string(token))
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object([
                        "plugin": .object([
                            "id": .string("example-plugin"),
                            "name": .string("example-plugin"),
                            "version": .string("1.0.0"),
                            "source": .object([
                                "kind": .string("github"),
                                "location": .string("https://github.com/example/plugin")
                            ]),
                            "enabled": .bool(false),
                            "state": .string("disabled"),
                            "installedAt": .string("2026-08-17T00:00:00.000Z"),
                            "updatedAt": .string("2026-08-17T00:00:00.000Z"),
                            "entryCount": .number(1)
                        ])
                    ]),
                    error: nil
                )
            case .pluginDiscardPreparedNative:
                XCTAssertEqual(request.params.objectValue?["preparedToken"], .string(token))
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object(["ok": .bool(true)]),
                    error: nil
                )
            default:
                XCTFail("Unexpected native preparation RPC: \(request.method.rawValue)")
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .null,
                    error: nil
                )
            }
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        let source = ISHMarketplacePluginSource(
            kind: .github,
            location: "https://github.com/example/plugin"
        )
        try await client.start()

        let prepared = try await client.prepareNativeMarketplacePlugin(source: source)
        let installed = try await client.installMarketplacePlugin(
            ISHMarketplacePluginInstallRequest(
                source: source,
                preparedToken: prepared.preparedToken
            )
        )
        let discarded = try await client.discardPreparedNativeMarketplacePlugin(token: token)

        XCTAssertEqual(prepared.nativeCandidate?.packageName, "example-plugin")
        XCTAssertEqual(prepared.nativeCandidate?.sourceDigest, digest)
        XCTAssertEqual(installed.plugin.id, "example-plugin")
        XCTAssertTrue(discarded.ok)
        await client.stop()
    }

    func testClientDescribesAndMutatesOfficialSettingsWithRevision() async throws {
        let descriptor = JSONValue.object([
            "ns": .string("plugin-demo"),
            "schema": .object([
                "uid": .number(2),
                "refs": .object([
                    "1": .object(["type": .string("boolean"), "meta": .object([:])]),
                    "2": .object([
                        "type": .string("object"),
                        "meta": .object(["default": .object([:])]),
                        "dict": .object(["enabled": .number(1)])
                    ])
                ])
            ]),
            "value": .object(["enabled": .bool(true)]),
            "user": .object(["enabled": .bool(true)]),
            "revision": .number(5),
            "applies": .string("live"),
            "secrets": .array([]),
            "editable": .bool(true)
        ])
        let transport = FakePluginHostTransport { request in
            switch request.method {
            case .settingsDescribe:
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object([
                        "writable": .bool(true),
                        "hasDocument": .bool(true),
                        "namespaces": .array([descriptor])
                    ]),
                    error: nil
                )
            case .settingsMutate:
                let params = request.params.objectValue
                XCTAssertEqual(params?["ns"], .string("plugin-demo"))
                XCTAssertEqual(params?["expectedRevision"], .number(5))
                XCTAssertEqual(
                    params?["ops"],
                    .array([.object([
                        "op": .string("unset"),
                        "path": .array([.string("enabled")])
                    ])])
                )
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: descriptor,
                    error: nil
                )
            default:
                XCTFail("Unexpected Settings RPC \(request.method.rawValue)")
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .null,
                    error: nil
                )
            }
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let snapshot = try await client.settings()
        XCTAssertEqual(snapshot.namespaces.first?.ns, "plugin-demo")
        XCTAssertEqual(snapshot.namespaces.first?.revision, 5)
        let updated = try await client.mutateSettings(
            ISHPluginSettingsMutateRequest(
                ns: "plugin-demo",
                ops: [.unset(path: ["enabled"])],
                expectedRevision: 5
            )
        )
        XCTAssertEqual(updated.revision, 5)
        await client.stop()
    }

    func testSettingsConflictMetadataIsPreserved() {
        let error = ISHPluginHostError.remote(
            code: -32_012,
            message: "Settings changed.",
            data: .object([
                "reason": .string("settings-conflict"),
                "ns": .string("plugin-demo"),
                "expectedRevision": .number(4),
                "actualRevision": .number(5)
            ])
        )

        XCTAssertEqual(
            error.settingsConflict,
            ISHPluginSettingsConflict(
                namespace: "plugin-demo",
                expectedRevision: 4,
                actualRevision: 5
            )
        )
    }

    func testNativeSettingsSchemaParsesSupportedFields() throws {
        let namespace = ISHPluginSettingsNamespace(
            ns: "plugin-demo",
            schema: .object([
                "uid": .number(8),
                "refs": .object([
                    "1": .object([
                        "type": .string("boolean"),
                        "meta": .object(["default": .bool(true)])
                    ]),
                    "2": .object([
                        "type": .string("const"),
                        "meta": .object(["description": .string("Fast")]),
                        "value": .string("fast")
                    ]),
                    "3": .object([
                        "type": .string("const"),
                        "meta": .object(["description": .string("Safe")]),
                        "value": .string("safe")
                    ]),
                    "4": .object([
                        "type": .string("union"),
                        "meta": .object([:]),
                        "list": .array([.number(2), .number(3)])
                    ]),
                    "5": .object([
                        "type": .string("number"),
                        "meta": .object([
                            "min": .number(0),
                            "max": .number(10),
                            "step": .number(1)
                        ])
                    ]),
                    "6": .object([
                        "type": .string("string"),
                        "meta": .object(["description": .string("Label")])
                    ]),
                    "7": .object([
                        "type": .string("object"),
                        "meta": .object(["default": .object([:])]),
                        "dict": .object(["label": .number(6)])
                    ]),
                    "8": .object([
                        "type": .string("object"),
                        "meta": .object(["default": .object([:])]),
                        "dict": .object([
                            "enabled": .number(1),
                            "mode": .number(4),
                            "count": .number(5),
                            "nested": .number(7)
                        ])
                    ])
                ])
            ]),
            value: .object([
                "enabled": .bool(true),
                "mode": .string("safe"),
                "count": .number(2),
                "nested": .object(["label": .string("phone")])
            ]),
            base: nil,
            user: .object(["count": .number(2)]),
            revision: 3,
            applies: .live,
            secrets: [],
            editable: true,
            unsupportedReason: nil
        )

        let form = try ISHPluginSettingsForm(namespace: namespace)
        XCTAssertEqual(form.fields.map(\.name), ["count", "enabled", "mode", "nested"])
        XCTAssertTrue(namespace.isUserOverridden(at: ["count"]))
        XCTAssertFalse(namespace.isUserOverridden(at: ["enabled"]))
        guard let mode = form.fields.first(where: { $0.name == "mode" }),
              case let .selection(options) = mode.kind else {
            return XCTFail("Expected a constant-union Picker field")
        }
        XCTAssertEqual(options.map(\.label), ["Fast", "Safe"])
    }

    func testNativeSettingsSchemaFailsClosedForComplexSchema() {
        let namespace = ISHPluginSettingsNamespace(
            ns: "plugin-complex",
            schema: nil,
            value: .null,
            base: nil,
            user: nil,
            revision: 0,
            applies: .restart,
            secrets: [],
            editable: false,
            unsupportedReason: "Schema type transform is not wire-safe."
        )

        XCTAssertThrowsError(try ISHPluginSettingsForm(namespace: namespace)) { error in
            XCTAssertEqual(error as? ISHPluginSettingsSchemaError, .missingSchema)
        }
    }

    func testHostedToolSynchronizesOnlySuccessfulLifecycleMutations() async throws {
        let transport = FakePluginHostTransport { request in
            ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "isError": .bool(false),
                    "value": .string("ok")
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        let probe = ISHContributionSynchronizationProbe()
        try await client.start()

        for name in ["cordis_define", "cordis_run", "cordis_stop", "cordis_undefine"] {
            let tool = ISHHostedCordisTool(
                contribution: ISHPluginHostToolContribution(
                    name: name,
                    description: name,
                    parameters: .object(["type": .string("object")])
                ),
                sessionID: "session-1",
                client: client,
                synchronizeContributions: {
                    await probe.recordSynchronization()
                }
            )
            let result = try await tool.execute(arguments: [:])
            XCTAssertEqual(result, "ok")
        }

        let ordinaryTool = ISHHostedCordisTool(
            contribution: ISHPluginHostToolContribution(
                name: "plugin_echo",
                description: "echo",
                parameters: .object(["type": .string("object")])
            ),
            sessionID: "session-1",
            client: client,
            synchronizeContributions: {
                await probe.recordSynchronization()
            }
        )
        let ordinaryResult = try await ordinaryTool.execute(arguments: [:])
        XCTAssertEqual(ordinaryResult, "ok")

        let synchronizationCount = await probe.count
        XCTAssertEqual(synchronizationCount, 4)
        await client.stop()
    }

    func testHostCommandsMergeExecuteAndWithdrawThroughNativeRegistry() async throws {
        let transport = FakePluginHostTransport { request in
            XCTAssertEqual(request.method, .commandExecute)
            let rawInput = request.params.objectValue?["rawInput"]?.stringValue ?? ""
            return ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "ok": .bool(true),
                    "value": .object([
                        "kind": .string("success"),
                        "text": .string("host:\(rawInput)")
                    ])
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let commands = SlashCommandRegistry(includeBuiltIns: false)
        let native = try SlashCommandDefinition(
            name: "phone_echo",
            description: "Native fallback"
        ) { _ in
            .success(text: "native")
        }
        _ = try await commands.register(native, origin: .native)

        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        let contributions = ISHPluginHostContributions(
            revision: 7,
            scope: "session",
            tools: [],
            commands: [
                ISHPluginHostCommandContribution(
                    name: "phone_echo",
                    description: "Host-scoped echo",
                    input: .init(hint: "<text>", images: false),
                    recordInput: false
                )
            ],
            prompt: ISHPluginHostPromptContributions(
                sections: [],
                contexts: [],
                variables: [:]
            )
        )
        _ = try await runtime.install(
            ISHPluginHostCordisBridge.definition(
                contributions: contributions,
                sessionID: "session-1",
                client: client,
                commandRegistry: commands
            )
        )

        let hostedDescriptor = await commands.descriptor(
            named: "phone_echo",
            scope: "session-1"
        )
        XCTAssertEqual(hostedDescriptor?.description, "Host-scoped echo")
        guard case let .prepared(prepared) = await commands.prepare(
            "/phone_echo hello",
            scope: "session-1"
        ) else {
            return XCTFail("Expected Host command to resolve")
        }
        let hosted = await commands.execute(prepared)
        XCTAssertEqual(hosted.result.kind, .success)
        XCTAssertEqual(hosted.result.text, "host: hello")
        XCTAssertFalse(hosted.recordInput)

        _ = try await runtime.uninstall(ISHPluginHostCordisBridge.pluginID)
        guard case let .prepared(fallback) = await commands.prepare(
            "/phone_echo",
            scope: "session-1"
        ) else {
            return XCTFail("Expected native command to be revealed after Host withdrawal")
        }
        let nativeExecution = await commands.execute(fallback)
        XCTAssertEqual(nativeExecution.result.text, "native")
        await client.stop()
    }

    func testDynamicBridgeRegistersHandlerAndMemoryServiceCheckpoints() async throws {
        let recorder = ISHInvocationRecorder()
        let transport = FakePluginHostTransport { request in
            let arguments = request.params.objectValue?["arguments"] ?? .null
            let checkpoint = arguments.objectValue?["checkpoint"]?.stringValue
            if let checkpoint {
                recorder.record(checkpoint, arguments: arguments)
            }
            let value: JSONValue
            switch checkpoint {
            case "agent/pre-step", "memory/recall":
                value = .object([
                    "kind": .string("enter"),
                    "messages": .array([])
                ])
            case "agent/inbox/pre-claim":
                value = .object([
                    "kind": .string("rewrite"),
                    "text": .string("host rewritten")
                ])
            default:
                value = .object(["kind": .string("next")])
            }
            return ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "ok": .bool(true),
                    "value": value
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        let contributions = ISHPluginHostContributions(
            revision: 1,
            scope: "session",
            tools: [],
            prompt: ISHPluginHostPromptContributions(
                sections: [],
                contexts: [],
                variables: [:]
            ),
            handlers: [
                ISHPluginHostHandlerContribution(
                    pluginId: "dynamic-plugin",
                    pluginRunId: "run-1",
                    method: "agent/pre-step"
                ),
                ISHPluginHostHandlerContribution(
                    pluginId: "dynamic-plugin",
                    pluginRunId: "run-1",
                    method: "agent/turn-stopping"
                ),
                ISHPluginHostHandlerContribution(
                    pluginId: "dynamic-plugin",
                    pluginRunId: "run-1",
                    method: "agent/inbox/pre-claim"
                )
            ],
            services: [
                ISHPluginHostServiceContribution(
                    pluginId: "dynamic-plugin",
                    pluginRunId: "run-1",
                    name: "memory",
                    methods: ["recall", "record"]
                )
            ]
        )
        _ = try await runtime.install(
            ISHPluginHostCordisBridge.definition(
                contributions: contributions,
                sessionID: "session-1",
                client: client
            )
        )

        let agentID = UUID()
        let runID = UUID()
        let preStep = try await runtime.run(
            CordisAgentLoopCheckpoints.preStep,
            input: CordisAgentPreStepContext(
                agentID: agentID,
                runID: runID,
                turn: 1,
                step: 1,
                messages: []
            ),
            target: .agent(agentID)
        ) {
            .reject(reason: "native fallback")
        }
        XCTAssertEqual(preStep, .enter([]))

        let pending = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000711")!,
            text: "original",
            disposition: .queued,
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let inboxDecision = try await runtime.run(
            CordisAgentLoopCheckpoints.inboxPreClaim,
            input: CordisAgentInboxPreClaimContext(
                agentID: agentID,
                runID: runID,
                turn: 2,
                step: 0,
                boundary: .turnStopping,
                message: pending,
                source: "user",
                workspaceBoundary: "/workspace/session-1"
            ),
            target: .agent(agentID)
        ) {
            .claim(text: pending.text)
        }
        XCTAssertEqual(inboxDecision, .claim(text: "host rewritten"))

        let memoryRecall = try await runtime.run(
            CordisAgentLoopCheckpoints.memoryRecall,
            input: CordisAgentPreStepContext(
                agentID: agentID,
                runID: runID,
                turn: 1,
                step: 1,
                messages: []
            ),
            target: .agent(agentID)
        ) {
            .reject(reason: "native fallback")
        }
        XCTAssertEqual(memoryRecall, .enter([]))

        try await runtime.serial(
            CordisAgentLoopCheckpoints.memoryRecord,
            input: CordisMemoryRecordContext(runID: runID, step: 1, messages: []),
            target: .agent(agentID)
        )
        try await runtime.serial(
            CordisAgentLoopCheckpoints.turnStopping,
            input: CordisAgentTurnStoppingContext(
                agentID: agentID,
                runID: runID,
                turn: 2,
                step: 1,
                messages: []
            ),
            target: .agent(agentID)
        )
        XCTAssertTrue(recorder.contains("agent/pre-step"))
        XCTAssertTrue(recorder.contains("agent/inbox/pre-claim"))
        XCTAssertTrue(recorder.contains("agent/turn-stopping"))
        XCTAssertTrue(recorder.contains("memory/recall"))
        XCTAssertTrue(recorder.contains("memory/record"))
        let memoryRecord = try XCTUnwrap(recorder.arguments(for: "memory/record")?.objectValue)
        XCTAssertNil(memoryRecord["agentId"])
        XCTAssertNil(memoryRecord["turn"])
        let turnStopping = try XCTUnwrap(
            recorder.arguments(for: "agent/turn-stopping")?.objectValue
        )
        XCTAssertEqual(turnStopping["agentId"]?.stringValue, agentID.uuidString.lowercased())
        XCTAssertEqual(turnStopping["turn"], .number(2))
        let inbox = try XCTUnwrap(
            recorder.arguments(for: "agent/inbox/pre-claim")?.objectValue
        )
        XCTAssertEqual(inbox["boundary"], .string("next-turn"))
        XCTAssertEqual(inbox["workspaceBoundary"], .string("/workspace/session-1"))
        XCTAssertEqual(
            inbox["message"]?.objectValue?["id"],
            .string(pending.id.uuidString.lowercased())
        )
        XCTAssertEqual(inbox["message"]?.objectValue?["source"], .string("user"))
        await client.stop()
    }

    func testDynamicInboxPreClaimFailsOpenOnHostFailureAndUnsafeMutations() async throws {
        let invocation = ISHInvocationRecorder()
        let transport = FakePluginHostTransport { request in
            let arguments = request.params.objectValue?["arguments"] ?? .null
            invocation.record("attempt", arguments: arguments)
            let attempt = invocation.count(for: "attempt")
            if attempt == 3 {
                return ISHPluginHostRPCResponse(
                    jsonrpc: "2.0",
                    id: request.id,
                    result: .object([
                        "ok": .bool(false),
                        "message": .string("host unavailable")
                    ]),
                    error: nil
                )
            }
            let value: JSONValue
            if attempt == 2 {
                value = .object([
                    "kind": .string("rewrite"),
                    "text": .string("must not apply"),
                    "messageId": .string(UUID().uuidString.lowercased())
                ])
            } else {
                value = .object([
                    "kind": .string("rewrite"),
                    "text": .string("must not apply"),
                    "workspaceBoundary": .string("/other-workspace")
                ])
            }
            return ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "ok": .bool(true),
                    "value": value
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()
        let runtime = CordisPluginRuntime()
        let contributions = ISHPluginHostContributions(
            revision: 1,
            scope: "session",
            tools: [],
            prompt: ISHPluginHostPromptContributions(sections: [], contexts: [], variables: [:]),
            handlers: [ISHPluginHostHandlerContribution(
                pluginId: "inbox-guard",
                pluginRunId: "run-1",
                method: "agent/inbox/pre-claim"
            )],
            services: []
        )
        _ = try await runtime.install(
            ISHPluginHostCordisBridge.definition(
                contributions: contributions,
                sessionID: "session-1",
                client: client
            )
        )
        let agentID = UUID()
        let pending = try QueuedAgentInput(text: "unchanged")
        let input = CordisAgentInboxPreClaimContext(
            agentID: agentID,
            runID: UUID(),
            turn: 2,
            step: 0,
            boundary: .turnStopping,
            message: pending,
            source: "user",
            workspaceBoundary: "/workspace/session-1"
        )

        for _ in 0..<3 {
            let decision = try await runtime.run(
                CordisAgentLoopCheckpoints.inboxPreClaim,
                input: input,
                target: .agent(agentID)
            ) {
                .claim(text: pending.text)
            }
            XCTAssertEqual(decision, .claim(text: "unchanged"))
        }
        await client.stop()
    }

    func testDynamicBridgeForwardsOfficialReadOnlyLifecycleEvents() async throws {
        let recorder = ISHInvocationRecorder()
        let transport = FakePluginHostTransport { request in
            let arguments = request.params.objectValue?["arguments"] ?? .null
            if let checkpoint = arguments.objectValue?["checkpoint"]?.stringValue {
                recorder.record(checkpoint, arguments: arguments)
            }
            return ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "ok": .bool(true),
                    "value": .null
                ]),
                error: nil
            )
        }
        let client = ISHPluginHostClient(transport: transport, requestTimeout: .seconds(2))
        try await client.start()

        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        let handlerNames = [
            "agent/created",
            "agent/disposed",
            "agent/status",
            "agent/session-start",
            "agent/error",
            "tools/result",
            "tools/change"
        ]
        let contributions = ISHPluginHostContributions(
            revision: 1,
            scope: "session",
            tools: [],
            prompt: ISHPluginHostPromptContributions(
                sections: [],
                contexts: [],
                variables: [:]
            ),
            handlers: handlerNames.map {
                ISHPluginHostHandlerContribution(
                    pluginId: "observer-plugin",
                    pluginRunId: "run-1",
                    method: $0
                )
            },
            services: []
        )
        _ = try await runtime.install(
            ISHPluginHostCordisBridge.definition(
                contributions: contributions,
                sessionID: "session-1",
                client: client
            )
        )

        let agentID = UUID()
        let runID = UUID()
        let target = CordisDispatchTarget.agent(agentID)
        try await runtime.serial(
            CordisAgentLoopEvents.agentCreated,
            input: CordisAgentIdentityContext(agentID: agentID, runID: runID),
            target: target
        )
        try await runtime.serial(
            CordisAgentLoopEvents.agentStatus,
            input: CordisAgentStatusContext(agentID: agentID, runID: runID, status: .running),
            target: target
        )
        try await runtime.serial(
            CordisAgentLoopEvents.agentSessionStart,
            input: CordisAgentSessionStartContext(
                agentID: agentID,
                runID: runID,
                source: .resume
            ),
            target: target
        )
        try await runtime.serial(
            CordisAgentLoopEvents.agentError,
            input: CordisAgentErrorContext(
                agentID: agentID,
                runID: runID,
                turn: 3,
                step: 2,
                error: "failed"
            ),
            target: target
        )
        let execution = CordisToolExecution(
            agentID: agentID,
            runID: runID,
            turn: 3,
            step: 2,
            call: AgentToolCall(id: "call-1", name: "device_time", arguments: "{}"),
            arguments: [:],
            risk: .pure,
            summary: "Read time"
        )
        try await runtime.serial(
            CordisAgentLoopEvents.toolsResult,
            input: CordisToolResultContext(
                execution: execution,
                result: CordisToolExecutionResult(text: "ok", isError: false)
            ),
            target: target
        )
        try await runtime.serial(
            CordisAgentLoopEvents.toolsChange,
            input: .value,
            target: .unfiltered
        )
        try await runtime.serial(
            CordisAgentLoopEvents.agentDisposed,
            input: CordisAgentIdentityContext(agentID: agentID, runID: runID),
            target: target
        )

        for name in handlerNames {
            XCTAssertTrue(recorder.contains(name), "Missing forwarded event \(name)")
        }
        let status = try XCTUnwrap(recorder.arguments(for: "agent/status")?.objectValue)
        XCTAssertEqual(status["agentId"]?.stringValue, agentID.uuidString.lowercased())
        XCTAssertEqual(status["runId"]?.stringValue, runID.uuidString.lowercased())
        XCTAssertEqual(status["status"]?.stringValue, "running")
        let result = try XCTUnwrap(recorder.arguments(for: "tools/result")?.objectValue)
        XCTAssertEqual(result["turn"], .number(3))
        XCTAssertEqual(result["result"]?.objectValue?["text"]?.stringValue, "ok")
        await client.stop()
    }

    func testInstallManifestDecodesPinnedMirrorConfiguration() throws {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "hostVersion": "1.0.0",
              "protocolVersion": 1,
              "entrypoint": "host.mjs",
              "primaryRegistry": "https://registry.npmjs.org",
              "mirrors": ["https://registry.npmmirror.com"],
              "packages": [{
                "name": "@deepseek-ai/cordis",
                "version": "4.0.1",
                "integrity": "sha512-test"
              }]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(ISHPluginHostInstallManifest.self, from: data)

        XCTAssertEqual(manifest.primaryRegistry.host, "registry.npmjs.org")
        XCTAssertEqual(manifest.mirrors.first?.host, "registry.npmmirror.com")
        XCTAssertEqual(manifest.packages.first?.version, "4.0.1")
    }
}

/// Locked storage keeps the synchronous fake transport's Sendable callback
/// deterministic without letting XCTest state cross an actor boundary.
private final class ISHInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var checkpoints: Set<String> = []
    private var payloads: [String: JSONValue] = [:]
    private var counts: [String: Int] = [:]

    func record(_ checkpoint: String, arguments: JSONValue? = nil) {
        lock.lock()
        checkpoints.insert(checkpoint)
        counts[checkpoint, default: 0] += 1
        if let arguments {
            payloads[checkpoint] = arguments
        }
        lock.unlock()
    }

    func contains(_ checkpoint: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return checkpoints.contains(checkpoint)
    }

    func arguments(for checkpoint: String) -> JSONValue? {
        lock.lock()
        defer { lock.unlock() }
        return payloads[checkpoint]
    }

    func count(for checkpoint: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[checkpoint, default: 0]
    }
}

private actor ISHContributionSynchronizationProbe {
    private(set) var count = 0

    func recordSynchronization() {
        count += 1
    }
}

private actor FakePluginHostTransport: ISHPluginHostTransport {
    typealias Responder = @Sendable (ISHPluginHostRPCRequest) -> ISHPluginHostRPCResponse

    private let responder: Responder
    private let fragmentSize: Int?
    private var stdout: (@Sendable (Data) -> Void)?
    private var exit: (@Sendable (ISHPluginHostTransportExit) -> Void)?

    init(
        fragmentSize: Int? = nil,
        responder: @escaping Responder
    ) {
        self.fragmentSize = fragmentSize
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
        var line = data
        if line.last == 0x0A {
            line.removeLast()
        }
        let request = try JSONDecoder().decode(ISHPluginHostRPCRequest.self, from: line)
        var response = try JSONEncoder().encode(responder(request))
        response.append(0x0A)
        if let fragmentSize {
            var lowerBound = 0
            while lowerBound < response.count {
                let upperBound = min(lowerBound + fragmentSize, response.count)
                stdout?(response.subdata(in: lowerBound..<upperBound))
                lowerBound = upperBound
            }
            return
        }
        let split = max(response.count / 2, 1)
        stdout?(Data(response[..<split]))
        stdout?(Data(response[split...]))
    }

    func stop() async {
        exit?(ISHPluginHostTransportExit(exitCode: 0, errorCode: 0))
        stdout = nil
        exit = nil
    }
}

private actor RejectingWritePluginHostTransport: ISHPluginHostTransport {
    private let rejectionsBeforeSuccess: Int
    private var stdout: (@Sendable (Data) -> Void)?
    private(set) var writeCount = 0
    private(set) var startCount = 0
    private(set) var wasStopped = false
    private(set) var events: [String] = []

    init(rejectionsBeforeSuccess: Int) {
        self.rejectionsBeforeSuccess = rejectionsBeforeSuccess
    }

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) async throws -> Int32 {
        startCount += 1
        events.append("start")
        stdout = onStdout
        _ = onStderr
        _ = onExit
        wasStopped = false
        return 73
    }

    func write(_ data: Data) async throws {
        writeCount += 1
        events.append("write")
        guard writeCount > rejectionsBeforeSuccess else {
            throw ISHPluginHostError.transportRejectedWrite
        }
        var line = data
        if line.last == 0x0A {
            line.removeLast()
        }
        let request = try JSONDecoder().decode(ISHPluginHostRPCRequest.self, from: line)
        var response = try JSONEncoder().encode(
            ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object([
                    "protocolVersion": .number(1),
                    "hostVersion": .string("retry-host"),
                    "runtime": .string("test"),
                    "dynamicDefinitionLifetime": .string("process-memory-only"),
                    "credentialBoundary": .string("test"),
                    "packages": .object([:]),
                    "capabilities": .array(ISHPluginHostRPCMethod.allCases.map { .string($0.rawValue) })
                ]),
                error: nil
            )
        )
        response.append(0x0A)
        stdout?(response)
    }

    func stop() async {
        wasStopped = true
        events.append("stop")
        stdout = nil
    }
}

private actor SerializingProbePluginHostTransport: ISHPluginHostTransport {
    private var stdout: (@Sendable (Data) -> Void)?
    private(set) var maxConcurrentWrites = 0
    private(set) var requestIDs: [String] = []
    private var activeWrites = 0

    func start(
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (ISHPluginHostTransportExit) -> Void
    ) async throws -> Int32 {
        stdout = onStdout
        _ = onStderr
        _ = onExit
        return 91
    }

    func write(_ data: Data) async throws {
        var line = data
        if line.last == 0x0A {
            line.removeLast()
        }
        let request = try JSONDecoder().decode(ISHPluginHostRPCRequest.self, from: line)
        activeWrites += 1
        maxConcurrentWrites = max(maxConcurrentWrites, activeWrites)
        requestIDs.append(request.id)
        try? await Task.sleep(for: .milliseconds(20))
        var response = try JSONEncoder().encode(
            ISHPluginHostRPCResponse(
                jsonrpc: "2.0",
                id: request.id,
                result: .object(["id": .string(request.id)]),
                error: nil
            )
        )
        response.append(0x0A)
        stdout?(response)
        activeWrites -= 1
    }

    func stop() async {
        stdout = nil
    }
}
