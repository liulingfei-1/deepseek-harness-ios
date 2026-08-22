import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class PluginInstallCoordinatorTests: XCTestCase {
    private static let digest = String(repeating: "a", count: 64)

    private static func source(_ location: String = "https://github.com/example/plugin")
        -> ISHMarketplacePluginSource {
        ISHMarketplacePluginSource(kind: .github, location: location)
    }

    private static func result(
        id: String = "plugin.example",
        version: String = "1.0.0",
        source: PluginInstallSource? = nil,
        scope: PluginInstallScope = .global,
        backend: PluginBackend = .ish,
        enabled: Bool = false
    ) -> PluginInstallResult {
        let source = source ?? .marketplace(Self.source())
        return PluginInstallResult(
            pluginID: id,
            version: version,
            scope: scope,
            backend: backend,
            sourceKey: source.sourceKey,
            enabled: enabled
        )
    }

    func testSameSourceAndVersionIsIdempotent() async throws {
        let coordinator = PluginInstallCoordinator()
        let request = PluginInstallRequest(source: .marketplace(Self.source()))
        let first = try await coordinator.install(request) {
            Self.result()
        }
        let second = try await coordinator.install(request) {
            XCTFail("The backend must not run for an idempotent install.")
            return Self.result(version: "unexpected")
        }

        XCTAssertEqual(first, second)
        let snapshots = await coordinator.snapshots()
        XCTAssertEqual(snapshots, [first])
    }

    func testDuplicateDifferentVersionRequiresReplace() async throws {
        let coordinator = PluginInstallCoordinator()
        let firstRequest = PluginInstallRequest(source: .marketplace(Self.source()))
        _ = try await coordinator.install(firstRequest) { Self.result() }

        let request = PluginInstallRequest(
            source: .marketplace(Self.source()),
            requestedVersion: "2.0.0"
        )
        do {
            _ = try await coordinator.install(request) { Self.result(version: "2.0.0") }
            XCTFail("A version change without replace must be rejected.")
        } catch let error as PluginInstallCoordinatorError {
            guard case .duplicate = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
        }
        let snapshots = await coordinator.snapshots()
        XCTAssertEqual(snapshots.first?.version, "1.0.0")
    }

    func testReplacementFailurePreservesPreviousRecordAndRunsRollback() async throws {
        let coordinator = PluginInstallCoordinator()
        _ = try await coordinator.install(
            PluginInstallRequest(source: .marketplace(Self.source()))
        ) { Self.result() }

        let rollback = RollbackProbe()
        let request = PluginInstallRequest(
            source: .marketplace(Self.source()),
            requestedVersion: "2.0.0",
            replace: true
        )
        do {
            _ = try await coordinator.install(
                request,
                operation: {
                    throw TestError.failed
                },
                rollback: {
                    await rollback.mark()
                }
            )
            XCTFail("The failing operation should throw.")
        } catch TestError.failed {
            // Expected.
        }

        let rollbackCalled = await rollback.wasCalled()
        let snapshots = await coordinator.snapshots()
        XCTAssertTrue(rollbackCalled)
        XCTAssertEqual(snapshots.first?.version, "1.0.0")
    }

    func testReplacementWithDifferentPluginIDRemovesPreviousRecord() async throws {
        let coordinator = PluginInstallCoordinator()
        let source = Self.source()
        _ = try await coordinator.install(
            PluginInstallRequest(source: .marketplace(source))
        ) {
            Self.result(id: "plugin.old", source: .marketplace(source))
        }

        let replacement = try await coordinator.install(
            PluginInstallRequest(
                source: .marketplace(source),
                requestedVersion: "2.0.0",
                replace: true
            )
        ) {
            Self.result(
                id: "plugin.new",
                version: "2.0.0",
                source: .marketplace(source)
            )
        }

        XCTAssertEqual(replacement.pluginID, "plugin.new")
        let oldRecord = await coordinator.record(pluginID: "plugin.old")
        let newRecord = await coordinator.record(pluginID: "plugin.new")
        let snapshots = await coordinator.snapshots()
        XCTAssertNil(oldRecord)
        XCTAssertEqual(newRecord, replacement)
        XCTAssertEqual(snapshots, [replacement])
    }

    func testInFlightSourceIsScopedByConversation() async throws {
        let coordinator = PluginInstallCoordinator()
        let source = PluginInstallSource.marketplace(Self.source())
        let globalRequest = PluginInstallRequest(source: source)
        let conversation = UUID()
        let conversationRequest = PluginInstallRequest(
            source: source,
            scope: .conversation(conversation)
        )

        guard case let .ticket(globalTicket) = try await coordinator.begin(globalRequest) else {
            return XCTFail("The global request should create a ticket.")
        }
        guard case let .ticket(conversationTicket) = try await coordinator.begin(conversationRequest) else {
            return XCTFail("The conversation request should create a ticket.")
        }

        do {
            _ = try await coordinator.begin(globalRequest)
            XCTFail("A second install in the same scope should be rejected while active.")
        } catch let error as PluginInstallCoordinatorError {
            guard case .operationInFlight = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
        }

        await coordinator.abort(globalTicket)
        await coordinator.abort(conversationTicket)
    }

    func testAdoptRepairsSourceIdentityReplacement() async throws {
        let coordinator = PluginInstallCoordinator()
        let source = PluginInstallSource.marketplace(Self.source())
        try await coordinator.adopt(
            Self.result(id: "plugin.old", source: source)
        )
        try await coordinator.adopt(
            Self.result(id: "plugin.new", version: "2.0.0", source: source)
        )

        let oldRecord = await coordinator.record(pluginID: "plugin.old")
        let newRecord = await coordinator.record(pluginID: "plugin.new")
        let snapshots = await coordinator.snapshots()
        XCTAssertNil(oldRecord)
        XCTAssertEqual(newRecord?.version, "2.0.0")
        XCTAssertEqual(snapshots.count, 1)
    }

    func testReconcileRemovesStaleHostRecordsButKeepsNativeRecords() async throws {
        let coordinator = PluginInstallCoordinator()
        let staleHost = Self.result(id: "plugin.stale")
        let native = Self.result(
            id: "native.plugin",
            source: .native(sourceDigest: Self.digest),
            backend: .native
        )
        try await coordinator.adopt(staleHost)
        try await coordinator.adopt(native)

        let currentHost = Self.result(
            id: "plugin.current",
            source: .marketplace(Self.source("https://github.com/example/current"))
        )
        let removed = try await coordinator.reconcileGlobalInventory(
            [currentHost, native],
            authoritativeBackends: [.ish]
        )

        XCTAssertEqual(removed, [staleHost])
        let staleRecord = await coordinator.record(pluginID: staleHost.pluginID)
        let currentRecord = await coordinator.record(pluginID: currentHost.pluginID)
        let nativeRecord = await coordinator.record(pluginID: native.pluginID)
        XCTAssertNil(staleRecord)
        XCTAssertEqual(currentRecord, currentHost)
        XCTAssertEqual(nativeRecord, native)
    }

    func testInvalidResultDoesNotLeaveActiveTransaction() async throws {
        let coordinator = PluginInstallCoordinator()
        let request = PluginInstallRequest(source: .marketplace(Self.source()))
        do {
            _ = try await coordinator.install(request) {
                PluginInstallResult(
                    pluginID: "plugin.example",
                    version: "1.0.0",
                    scope: .conversation(UUID()),
                    backend: .ish,
                    sourceKey: request.sourceKey,
                    enabled: false
                )
            }
            XCTFail("A scope mismatch should be rejected.")
        } catch let error as PluginInstallCoordinatorError {
            guard case .resultMismatch = error else {
                return XCTFail("Unexpected coordinator error: \(error)")
            }
        }

        let valid = try await coordinator.install(request) { Self.result() }
        XCTAssertEqual(valid.pluginID, "plugin.example")
    }

    func testGlobalAndConversationAvailability() async throws {
        let conversation = UUID()
        let otherConversation = UUID()
        let coordinator = PluginInstallCoordinator()
        let global = try await coordinator.install(
            PluginInstallRequest(source: .marketplace(Self.source()))
        ) { Self.result() }
        let globalAvailable = await coordinator.isAvailable(pluginID: global.pluginID, in: .global)
        let globalAvailableInConversation = await coordinator.isAvailable(
            pluginID: global.pluginID,
            in: .conversation(conversation)
        )
        XCTAssertTrue(globalAvailable)
        XCTAssertTrue(globalAvailableInConversation)

        let scoped = try await coordinator.install(
            PluginInstallRequest(
                source: .marketplace(Self.source("https://github.com/example/scoped")),
                scope: .conversation(conversation)
            )
        ) {
            Self.result(
                id: "plugin.scoped",
                source: .marketplace(Self.source("https://github.com/example/scoped")),
                scope: .conversation(conversation)
            )
        }
        let scopedAvailable = await coordinator.isAvailable(
            pluginID: scoped.pluginID,
            in: .conversation(conversation)
        )
        let scopedAvailableElsewhere = await coordinator.isAvailable(
            pluginID: scoped.pluginID,
            in: .conversation(otherConversation)
        )
        XCTAssertTrue(scopedAvailable)
        XCTAssertFalse(scopedAvailableElsewhere)
    }

    func testEnableAndUninstallUpdateRecords() async throws {
        let coordinator = PluginInstallCoordinator()
        let installed = try await coordinator.install(
            PluginInstallRequest(source: .marketplace(Self.source()))
        ) { Self.result() }
        let enabled = try await coordinator.setEnabled(
            pluginID: installed.pluginID,
            enabled: true
        )
        XCTAssertTrue(enabled.enabled)
        let stored = await coordinator.record(pluginID: installed.pluginID)
        XCTAssertEqual(stored, enabled)

        let removed = try await coordinator.uninstall(pluginID: installed.pluginID)
        XCTAssertEqual(removed, enabled)
        let availableAfterUninstall = await coordinator.isAvailable(
            pluginID: installed.pluginID,
            in: .global
        )
        XCTAssertFalse(availableAfterUninstall)
    }

    private enum TestError: Error {
        case failed
    }
}

private actor RollbackProbe {
    private var called = false

    func mark() {
        called = true
    }

    func wasCalled() -> Bool {
        called
    }
}
