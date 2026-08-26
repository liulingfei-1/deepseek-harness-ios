import Foundation
import XCTest

#if canImport(HarnessMobileCore)
@testable import HarnessMobileCore
#else
@testable import HarnessMobile
#endif

final class MemoryStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessMobileMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        rootURL = nil
    }

    func testPersistsRecordsAndUsesNewestFirstListing() async throws {
        let url = storeURL()
        let store = MemoryStore(fileURL: url)
        let older = try await store.write(content: "older", now: Date(timeIntervalSince1970: 10))
        let newer = try await store.write(content: "newer", now: Date(timeIntervalSince1970: 20))

        let reloaded = MemoryStore(fileURL: url)
        let records = try await reloaded.list()
        XCTAssertEqual(records.map(\.id), [newer.id, older.id])
    }

    func testCorruptAndUnknownVersionStoreFailClosed() async throws {
        let corruptURL = storeURL(named: "corrupt.json")
        try Data("not json".utf8).write(to: corruptURL)
        do {
            _ = try await MemoryStore(fileURL: corruptURL).list()
            XCTFail("Expected corrupt memory store to fail closed")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .unreadableStore)
        }

        let unknownURL = storeURL(named: "unknown.json")
        try Data("{\"version\":99,\"records\":[],\"disabledSessionIDs\":[]}".utf8).write(to: unknownURL)
        do {
            _ = try await MemoryStore(fileURL: unknownURL).list()
            XCTFail("Expected unsupported memory version")
        } catch let error as MemoryStoreError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }
    }

    func testSessionScopeAndDisableGateRecall() async throws {
        let store = MemoryStore(fileURL: storeURL())
        let firstSession = UUID()
        let secondSession = UUID()
        let global = try await store.write(content: "global")
        let firstOnly = try await store.write(content: "first", scope: .session(firstSession))
        let secondOnly = try await store.write(content: "second", scope: .session(secondSession))

        let firstSessionRecords = try await store.recall(for: firstSession)
        let secondSessionRecords = try await store.recall(for: secondSession)
        XCTAssertEqual(firstSessionRecords.map(\.id), [global.id, firstOnly.id])
        XCTAssertEqual(secondSessionRecords.map(\.id), [global.id, secondOnly.id])

        try await store.setEnabled(false, for: firstSession)
        let disabledSessionRecords = try await store.recall(for: firstSession)
        let stillEnabledSessionRecords = try await store.recall(for: secondSession)
        XCTAssertTrue(disabledSessionRecords.isEmpty)
        XCTAssertEqual(stillEnabledSessionRecords.map(\.id), [global.id, secondOnly.id])
    }

    func testDeleteAndExportAreConsistentAndDeterministic() async throws {
        let store = MemoryStore(fileURL: storeURL())
        let deleted = try await store.write(content: "remove", now: Date(timeIntervalSince1970: 10))
        _ = try await store.write(content: "retain", now: Date(timeIntervalSince1970: 20))

        let firstExport = try await store.exportData()
        let repeatedExport = try await store.exportData()
        XCTAssertEqual(firstExport, repeatedExport)
        XCTAssertTrue(String(decoding: firstExport, as: UTF8.self).contains("remove"))

        try await store.delete(id: deleted.id)
        let finalExport = try await store.exportData()
        let records = try await store.list()
        XCTAssertFalse(String(decoding: finalExport, as: UTF8.self).contains("remove"))
        XCTAssertEqual(records.map(\.content), ["retain"])
    }

    func testRejectsEmptyAndOversizedRecords() async throws {
        let store = MemoryStore(fileURL: storeURL())
        do {
            _ = try await store.write(content: "   ")
            XCTFail("Expected empty memory content to be rejected")
        } catch {
            XCTAssertEqual(error as? MemoryStoreError, .invalidContent)
        }
        do {
            _ = try await store.write(content: String(repeating: "x", count: MemoryStore.maximumRecordBytes + 1))
            XCTFail("Expected oversized memory content to be rejected")
        } catch {
            XCTAssertEqual(error as? MemoryStoreError, .contentTooLarge)
        }
    }

    func testPluginRegistersToolsRetractsThemAndKeepsRecordEventObservationOnly() async throws {
        let store = MemoryStore(fileURL: storeURL())
        let services = CordisAgentServices()
        let runtime = CordisPluginRuntime()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(DefaultMemoryCordisPlugin.definition(store: store))

        let registeredTools = await services.tools.definitions(allowedBy: .dangerFullAccess)
        XCTAssertEqual(registeredTools.map(\.name), ["memory_get", "memory_write"])

        try await runtime.parallel(
            CordisAgentLoopCheckpoints.memoryRecord,
            input: CordisMemoryRecordContext(
                runID: UUID(),
                step: 1,
                messages: [.user("do not persist this chat body")]
            )
        )
        let recordsAfterObservation = try await store.list()
        XCTAssertTrue(recordsAfterObservation.isEmpty)

        _ = try await runtime.uninstall(DefaultMemoryCordisPlugin.pluginID)
        let remainingTools = await services.tools.definitions(allowedBy: .dangerFullAccess)
        XCTAssertTrue(remainingTools.isEmpty)
    }

    func testRecallInjectionRecordsIDsAndDisabledSessionDoesNotInject() async throws {
        let store = MemoryStore(fileURL: storeURL())
        let sessionID = UUID()
        let record = try await store.write(content: "durable preference")
        let runtime = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await runtime.install(services.pluginDefinition())
        _ = try await runtime.install(DefaultMemoryCordisPlugin.definition(store: store))

        let context = CordisAgentPreStepContext(
            agentID: sessionID,
            runID: UUID(),
            turn: 1,
            step: 1,
            messages: [.user("latest request")]
        )
        let decision = try await runtime.run(
            CordisAgentLoopCheckpoints.memoryRecall,
            input: context,
            target: .agent(sessionID),
            traceContext: CordisTraceContext(runID: context.runID, turn: 1, step: 1)
        ) {
            .enter(context.messages)
        }
        guard case let .enter(messages) = decision, let injected = messages.last else {
            return XCTFail("Expected an injected memory message")
        }
        XCTAssertTrue(injected.content.contains("background context"))
        XCTAssertEqual(
            injected.source?.objectValue?["recordIds"],
            .array([.string(record.id.uuidString.lowercased())])
        )

        try await store.setEnabled(false, for: sessionID)
        let disabledDecision = try await runtime.run(
            CordisAgentLoopCheckpoints.memoryRecall,
            input: context,
            target: .agent(sessionID),
            traceContext: CordisTraceContext(runID: context.runID, turn: 2, step: 1)
        ) {
            .enter(context.messages)
        }
        XCTAssertEqual(disabledDecision, .enter(context.messages))
    }

    private func storeURL(named name: String = "memory.json") -> URL {
        rootURL.appendingPathComponent(name)
    }
}
