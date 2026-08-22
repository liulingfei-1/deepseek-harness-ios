import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class MessageFeedbackSidecarTests: XCTestCase {
    func testLegacyEmbeddedFeedbackMigratesWithStableIdentity() async throws {
        let root = try temporaryDirectory()
        let store = MessageFeedbackSidecarStore(root: root)
        let sessionID = UUID()
        let messageID = UUID()
        let legacyID = UUID()
        let message = AgentMessage(
            id: messageID,
            role: .assistant,
            content: "answer",
            feedback: MessageFeedback(
                rating: .positive,
                note: "keep this",
                version: legacyID
            )
        )

        let projected = try await store.project(sessionID: sessionID, messages: [message])
        XCTAssertEqual(projected[0].feedback?.rating, .positive)
        XCTAssertEqual(projected[0].feedback?.version, legacyID)
        guard let record = try await store.record(sessionID: sessionID, messageID: messageID) else {
            return XCTFail("migrated sidecar record missing")
        }
        XCTAssertEqual(record.id, legacyID)
        XCTAssertEqual(record.revision, 1)
        XCTAssertEqual(record.note, "keep this")
    }

    func testRevisionConflictAndClearTombstonePreserveIdentity() async throws {
        let root = try temporaryDirectory()
        let store = MessageFeedbackSidecarStore(root: root)
        let sessionID = UUID()
        let messageID = UUID()
        let first = try await store.setRating(
            sessionID: sessionID,
            messageID: messageID,
            rating: .positive
        )
        XCTAssertEqual(first.revision, 1)

        do {
            _ = try await store.setRating(
                sessionID: sessionID,
                messageID: messageID,
                rating: .negative,
                expectedRevision: 0
            )
            XCTFail("stale revision must be rejected")
        } catch let error as MessageFeedbackSidecarError {
            XCTAssertEqual(error, .revisionConflict(expected: 0, actual: 1))
            XCTAssertEqual(
                error.localizedDescription,
                "反馈已在其他位置更新（期望 revision 0，当前为 1）。请重新读取后再修改。"
            )
        }

        let cleared = try await store.clear(
            sessionID: sessionID,
            messageID: messageID,
            expectedRevision: first.revision
        )
        XCTAssertEqual(cleared.id, first.id)
        XCTAssertEqual(cleared.revision, 2)
        XCTAssertTrue(cleared.isEmpty)
        guard let persisted = try await store.record(sessionID: sessionID, messageID: messageID) else {
            return XCTFail("cleared tombstone missing")
        }
        XCTAssertEqual(persisted.id, first.id)
        XCTAssertEqual(persisted.revision, 2)
    }

    func testNoteRequiresExistingRating() async throws {
        let root = try temporaryDirectory()
        let store = MessageFeedbackSidecarStore(root: root)
        do {
            _ = try await store.updateNote(
                sessionID: UUID(),
                messageID: UUID(),
                note: "orphan"
            )
            XCTFail("note without rating must fail")
        } catch let error as MessageFeedbackSidecarError {
            XCTAssertEqual(error, .missingRating)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-sidecar-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
