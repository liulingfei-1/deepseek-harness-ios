import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionQueryReadModelTests: XCTestCase {
    func testRefreshCreatesWALProjectionAndSearchesLiteralContent() async throws {
        let root = makeDatabaseURL()
        defer { removeDatabaseFiles(root) }
        let canonicalRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let persistence = SessionTrajectoryRepository(root: canonicalRoot)
        let sessionID = UUID()

        _ = try await persistence.append(
            .userMessage(userPayload("alpha"), time: 10),
            sessionID: sessionID
        )
        _ = try await persistence.append(
            .toolCall(turn: 1, step: 1, callID: "call-1", name: "workspace_read", arguments: "{\"path\":\"alpha.txt\"}", time: 20),
            sessionID: sessionID
        )
        try await persistence.flush(sessionID: sessionID)

        let query = SessionQueryReadModel(root: root)
        try await query.refresh(sessionID: sessionID, persistence: persistence)
        let listed = try await query.listSessions()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed[0].title, "alpha")
        XCTAssertEqual(listed[0].indexedThroughSequence, 2)
        let toolHits = try await query.searchEvents(sessionID: sessionID, query: "workspace_read")
        let sessionHits = try await query.searchSessions(query: "alpha")
        XCTAssertEqual(toolHits.count, 1)
        XCTAssertEqual(sessionHits.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path + "-wal"))
        try await query.close()
    }

    func testRefreshIndexesOnlyDurableSuffixAndRepairsCanonicalAppendAfterIndexCrash() async throws {
        let root = makeDatabaseURL()
        defer { removeDatabaseFiles(root) }
        let canonicalRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let persistence = SessionTrajectoryRepository(root: canonicalRoot)
        let sessionID = UUID()
        _ = try await persistence.append(.userMessage(userPayload("first"), time: 1), sessionID: sessionID)
        try await persistence.flush(sessionID: sessionID)

        let initial = SessionQueryReadModel(root: root)
        try await initial.refresh(sessionID: sessionID, persistence: persistence)
        let initialRevision = try await initial.indexedRevision(sessionID: sessionID)
        XCTAssertEqual(initialRevision, 1)
        // Model an append that happened after the old query actor stopped.
        _ = try await persistence.append(.userMessage(userPayload("second"), time: 2), sessionID: sessionID)
        try await persistence.flush(sessionID: sessionID)

        let recovered = SessionQueryReadModel(root: root)
        try await recovered.refresh(sessionID: sessionID, persistence: persistence)
        let recoveredRevision = try await recovered.indexedRevision(sessionID: sessionID)
        let recoveredHits = try await recovered.searchEvents(sessionID: sessionID, query: "second")
        XCTAssertEqual(recoveredRevision, 2)
        XCTAssertEqual(recoveredHits.count, 1)
    }

    func testDeletedDatabaseRebuildsFromCanonicalAndRemovesDeletedSessions() async throws {
        let root = makeDatabaseURL()
        defer { removeDatabaseFiles(root) }
        let canonicalRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let persistence = SessionTrajectoryRepository(root: canonicalRoot)
        let first = UUID()
        let second = UUID()
        _ = try await persistence.append(.userMessage(userPayload("keep"), time: 1), sessionID: first)
        _ = try await persistence.append(.userMessage(userPayload("remove"), time: 2), sessionID: second)
        try await persistence.flush(sessionID: first)
        try await persistence.flush(sessionID: second)

        let query = SessionQueryReadModel(root: root)
        _ = try await query.rebuild(persistence: persistence)
        let initialSessions = try await query.listSessions()
        XCTAssertEqual(initialSessions.count, 2)
        try await query.close()
        removeDatabaseFiles(root)

        let rebuilt = SessionQueryReadModel(root: root)
        let stats = try await rebuilt.rebuild(persistence: persistence)
        XCTAssertEqual(stats.sessionsIndexed, 2)
        let keepHits = try await rebuilt.searchSessions(query: "keep")
        XCTAssertEqual(keepHits.count, 1)

        try await persistence.delete(sessionID: second)
        let afterDelete = try await rebuilt.rebuild(persistence: persistence)
        XCTAssertEqual(afterDelete.sessionsRemoved, 1)
        let remaining = try await rebuilt.listSessions()
        XCTAssertEqual(remaining.map(\.id), [first])
    }

    func testRevisionRewindForcesSessionLocalRebuild() async throws {
        let root = makeDatabaseURL()
        defer { removeDatabaseFiles(root) }
        let canonicalRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let persistence = SessionTrajectoryRepository(root: canonicalRoot)
        let sessionID = UUID()
        _ = try await persistence.append(.userMessage(userPayload("old one"), time: 1), sessionID: sessionID)
        _ = try await persistence.append(.userMessage(userPayload("old two"), time: 2), sessionID: sessionID)
        try await persistence.flush(sessionID: sessionID)
        let query = SessionQueryReadModel(root: root)
        try await query.refresh(sessionID: sessionID, persistence: persistence)

        try await persistence.delete(sessionID: sessionID)
        _ = try await persistence.append(.userMessage(userPayload("new only"), time: 3), sessionID: sessionID)
        try await persistence.flush(sessionID: sessionID)
        try await query.refresh(sessionID: sessionID, persistence: persistence)
        let sessions = try await query.listSessions()
        let newHits = try await query.searchEvents(sessionID: sessionID, query: "new only")
        let oldHits = try await query.searchEvents(sessionID: sessionID, query: "old one")
        XCTAssertEqual(sessions[0].eventCount, 1)
        XCTAssertEqual(newHits.count, 1)
        XCTAssertTrue(oldHits.isEmpty)
    }

    func testFTSOperatorsAreLiteralPhraseText() async throws {
        let root = makeDatabaseURL()
        defer { removeDatabaseFiles(root) }
        let canonicalRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let persistence = SessionTrajectoryRepository(root: canonicalRoot)
        let alpha = UUID()
        let beta = UUID()
        _ = try await persistence.append(.userMessage(userPayload("alpha"), time: 1), sessionID: alpha)
        _ = try await persistence.append(.userMessage(userPayload("beta"), time: 2), sessionID: beta)
        try await persistence.flush(sessionID: alpha)
        try await persistence.flush(sessionID: beta)
        let query = SessionQueryReadModel(root: root)
        _ = try await query.rebuild(persistence: persistence)
        let operatorHits = try await query.searchSessions(query: "alpha OR beta")
        XCTAssertTrue(operatorHits.isEmpty)
        do {
            _ = try await query.searchSessions(query: "   ")
            XCTFail("blank query must be rejected")
        } catch let error as SessionQueryReadModelError {
            XCTAssertEqual(error, .invalidQuery)
        }
    }

    func testTenThousandSessionRebuildHasBoundedListBaseline() async throws {
        let root = makeDatabaseURL()
        defer { removeDatabaseFiles(root) }
        let canonicalRoot = makeRoot()
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        let persistence = SessionTrajectoryRepository(root: canonicalRoot)
        let sessionIDs = (0..<10_000).map { _ in UUID() }
        for (index, sessionID) in sessionIDs.enumerated() {
            _ = try await persistence.append(
                .userMessage(userPayload("baseline-\(index)"), time: Int64(index)),
                sessionID: sessionID
            )
            try await persistence.flush(sessionID: sessionID)
        }

        let query = SessionQueryReadModel(root: root)
        let started = Date()
        let stats = try await query.rebuild(persistence: persistence)
        let listed = try await query.listSessions(limit: 1_000)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(stats.sessionsIndexed, 10_000)
        XCTAssertEqual(listed.count, 1_000)
        XCTAssertLessThan(elapsed, 60, "10k session rebuild/list baseline exceeded 60 seconds")
    }

    private func userPayload(_ text: String) -> JSONValue {
        .object([
            "id": .string(UUID().uuidString),
            "role": .string("user"),
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)])
            ]),
            "source": .object(["kind": .string("user")])
        ])
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionQueryCanonical-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionQuery-\(UUID().uuidString).sqlite")
    }

    private func removeDatabaseFiles(_ root: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: root.path + suffix)
        }
    }
}
