import XCTest
@testable import HarnessMobileCore

final class BackgroundRunJournalTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-journal-(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("run.json")
    }

    private func identity() -> RunIdentity {
        RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
    }

    func testUpsertAndReloadPersistsOnlyRunDescriptor() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let entry = BackgroundRunJournalEntry(
            identity: identity(), phase: .running, lastDurableSequence: 42,
            continuedProcessingRequestIdentifier: "com.test.run",
            finiteBackgroundLeaseActive: true, continuedProcessingActive: true,
            audioKeepAliveActive: true, locationKeepAliveActive: true,
            liveActivityActive: true
        )
        try await BackgroundRunJournal(fileURL: url).upsert(entry)
        let loaded = try await BackgroundRunJournal(fileURL: url).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].identity, entry.identity)
        XCTAssertEqual(loaded[0].phase, entry.phase)
        XCTAssertEqual(loaded[0].lastDurableSequence, entry.lastDurableSequence)
        XCTAssertEqual(loaded[0].continuedProcessingRequestIdentifier, entry.continuedProcessingRequestIdentifier)
        XCTAssertEqual(loaded[0].finiteBackgroundLeaseActive, entry.finiteBackgroundLeaseActive)
    }

    func testLaunchAuditInterruptsAndClearsOrphansIdempotently() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = BackgroundRunJournal(fileURL: url)
        let entry = BackgroundRunJournalEntry(
            identity: identity(), phase: .running,
            continuedProcessingRequestIdentifier: "com.test.orphan",
            finiteBackgroundLeaseActive: true, continuedProcessingActive: true,
            audioKeepAliveActive: true, locationKeepAliveActive: true,
            liveActivityActive: true
        )
        try await journal.upsert(entry)
        let first = try await journal.auditOnLaunch()
        XCTAssertEqual(first.clearedRequestIdentifiers, ["com.test.orphan"])
        XCTAssertEqual(first.interruptedRunIDs, [entry.identity.runID])
        let second = try await journal.auditOnForeground()
        XCTAssertFalse(second.didCleanOrphans)
        let audited = try await journal.load()[0]
        XCTAssertEqual(audited.phase, .interrupted)
        XCTAssertNil(audited.continuedProcessingRequestIdentifier)
        XCTAssertFalse(audited.finiteBackgroundLeaseActive)
        XCTAssertFalse(audited.liveActivityActive)
    }

    func testMarkTerminalRejectsNonTerminalAndClearsLeaseFields() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let journal = BackgroundRunJournal(fileURL: url)
        let run = identity()
        try await journal.upsert(BackgroundRunJournalEntry(
            identity: run, phase: .running,
            continuedProcessingRequestIdentifier: "request",
            finiteBackgroundLeaseActive: true
        ))
        await XCTAssertThrowsErrorAsync {
            try await journal.markTerminal(identity: run, phase: .running)
        }
        try await journal.markTerminal(identity: run, phase: .succeeded)
        let saved = try await journal.load()[0]
        XCTAssertEqual(saved.phase, .succeeded)
        XCTAssertNil(saved.continuedProcessingRequestIdentifier)
        XCTAssertFalse(saved.finiteBackgroundLeaseActive)
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: @escaping () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {}
    }
}
