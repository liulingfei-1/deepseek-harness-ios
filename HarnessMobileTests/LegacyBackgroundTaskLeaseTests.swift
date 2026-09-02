import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

@MainActor
final class LegacyBackgroundTaskLeaseTests: XCTestCase {
    func testMultipleRunsShareOneSystemTaskAndReleaseIsIdempotent() {
        var nextID: UInt64 = 40
        var beginCount = 0
        var endIDs: [UInt64] = []
        var expiration: (() -> Void)?
        let lease = LegacyBackgroundTaskLease(
            beginSystemTask: { callback in
                beginCount += 1
                expiration = callback
                defer { nextID += 1 }
                return nextID
            },
            endSystemTask: { endIDs.append($0) }
        )
        let first = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let second = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)

        let firstToken = lease.acquire(identity: first) { _ in false }
        let secondToken = lease.acquire(identity: second) { _ in false }
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(lease.activeTokenCount, 2)
        XCTAssertTrue(lease.hasSystemTask)

        lease.release(firstToken)
        lease.release(firstToken)
        XCTAssertEqual(endIDs, [])
        XCTAssertEqual(lease.activeTokenCount, 1)

        lease.release(secondToken)
        XCTAssertEqual(endIDs, [40])
        XCTAssertFalse(lease.hasSystemTask)
        expiration?()
        XCTAssertEqual(endIDs, [40])
    }

    func testExpirationCallsOnlyExactOwnersAndLeavesTokensForCleanup() async {
        var expiration: (() -> Void)?
        var expired: [RunIdentity] = []
        var ended: [UInt64] = []
        let lease = LegacyBackgroundTaskLease(
            beginSystemTask: { callback in
                expiration = callback
                return 7
            },
            endSystemTask: { ended.append($0) }
        )
        let first = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let second = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 2)
        let firstToken = lease.acquire(identity: first) {
            expired.append($0)
            return false
        }
        let secondToken = lease.acquire(identity: second) {
            expired.append($0)
            return false
        }

        expiration?()
        await Task.yield()
        XCTAssertEqual(Set(expired), Set([first, second]))
        XCTAssertEqual(ended, [7])
        XCTAssertEqual(lease.activeTokenCount, 2)
        XCTAssertFalse(lease.hasSystemTask)

        lease.release(firstToken)
        lease.release(secondToken)
        XCTAssertEqual(lease.activeTokenCount, 0)
    }

    func testReleaseAllForIdentityDoesNotTouchAnotherRun() {
        var endCount = 0
        let lease = LegacyBackgroundTaskLease(
            beginSystemTask: { _ in 1 },
            endSystemTask: { _ in endCount += 1 }
        )
        let first = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let second = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        _ = lease.acquire(identity: first) { _ in false }
        let secondToken = lease.acquire(identity: second) { _ in false }

        lease.releaseAll(for: first)
        XCTAssertEqual(lease.activeTokenCount, 1)
        XCTAssertEqual(endCount, 0)
        lease.release(secondToken)
        XCTAssertEqual(endCount, 1)
    }

    func testExpirationRearmsFiniteLeaseWhenExtendedModeOwnsSurvival() async {
        var nextID: UInt64 = 70
        var expirations: [() -> Void] = []
        var callbacks = 0
        var ended: [UInt64] = []
        let lease = LegacyBackgroundTaskLease(
            beginSystemTask: { callback in
                expirations.append(callback)
                defer { nextID += 1 }
                return nextID
            },
            endSystemTask: { ended.append($0) }
        )
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let token = lease.acquire(identity: identity) { received in
            XCTAssertEqual(received, identity)
            callbacks += 1
            return true
        }

        XCTAssertEqual(expirations.count, 1)
        expirations[0]()
        await Task.yield()

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(expirations.count, 2)
        XCTAssertEqual(ended, [70])
        XCTAssertTrue(lease.hasSystemTask)
        XCTAssertEqual(lease.activeTokenCount, 1)

        lease.release(token)
        XCTAssertEqual(ended, [70, 71])
        XCTAssertFalse(lease.hasSystemTask)
    }
}
