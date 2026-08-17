import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionTrajectoryRepositoryTests: XCTestCase {
    func testSessionsKeepIndependentStreamsAndIncrementalCursors() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let firstSession = UUID()
        let secondSession = UUID()

        let empty = try await repository.prepare(sessionID: firstSession)
        XCTAssertEqual(empty.nextTurn, 1)
        XCTAssertEqual(empty.requestHeaderReason, .initial)

        _ = try await repository.append(.turnStart(turn: 1, time: 1), sessionID: firstSession)
        _ = try await repository.append(
            .stepStart(turn: 1, step: 1, time: 2),
            sessionID: firstSession
        )
        _ = try await repository.append(
            .stepEnd(turn: 1, step: 1, time: 3),
            sessionID: firstSession
        )
        _ = try await repository.append(
            .turnEnd(
                turn: 1,
                reason: .object(["kind": .string("completed")]),
                time: 4
            ),
            sessionID: firstSession
        )

        let delta = try await repository.snapshot(
            sessionID: firstSession,
            after: empty.snapshot.cursor
        )
        XCTAssertEqual(delta.events.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(delta.metrics.turns, 1)

        let resumed = try await repository.prepare(sessionID: firstSession)
        XCTAssertEqual(resumed.nextTurn, 2)
        XCTAssertEqual(resumed.requestHeaderReason, .resume)

        let other = try await repository.prepare(sessionID: secondSession)
        XCTAssertEqual(other.snapshot.events, [])
        XCTAssertEqual(other.nextTurn, 1)
        let firstSnapshot = try await repository.snapshot(sessionID: firstSession)
        XCTAssertEqual(firstSnapshot.events.count, 4)
    }

    func testInterruptedTurnStillAdvancesNextTurnNumber() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()

        _ = try await repository.append(.turnStart(turn: 7, time: 1), sessionID: sessionID)

        let preparation = try await repository.prepare(sessionID: sessionID)
        XCTAssertEqual(preparation.nextTurn, 8)
        XCTAssertEqual(preparation.requestHeaderReason, .resume)
    }

    func testPluginEventRegistrationAppliesToOpenedStreams() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        let draft = SessionEventDraft(
            type: "plugin/memory-snapshot",
            time: 1,
            data: .object(["revision": .number(1)])
        )

        _ = try await repository.prepare(sessionID: sessionID)
        do {
            _ = try await repository.append(draft, sessionID: sessionID)
            XCTFail("Unknown required plugin events must be rejected")
        } catch let error as SessionEventLogError {
            XCTAssertEqual(
                error,
                .unsupportedEventType(type: "plugin/memory-snapshot", sequence: 0)
            )
        }

        try await repository.registerKnownEventTypes(["plugin/memory-snapshot"])
        let event = try await repository.append(draft, sessionID: sessionID)
        XCTAssertEqual(event.seq, 0)
        XCTAssertEqual(event.type, "plugin/memory-snapshot")
    }

    func testDeleteStartsTheSessionWithAnEmptyStream() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()

        _ = try await repository.append(.turnStart(turn: 3, time: 1), sessionID: sessionID)
        try await repository.delete(sessionID: sessionID)

        let reset = try await repository.prepare(sessionID: sessionID)
        XCTAssertEqual(reset.snapshot.events, [])
        XCTAssertEqual(reset.nextTurn, 1)
        XCTAssertEqual(reset.requestHeaderReason, .initial)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-trajectory-repository-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
