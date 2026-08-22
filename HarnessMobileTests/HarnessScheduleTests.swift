import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class HarnessScheduleTests: XCTestCase {
    func testSchedulesPersistSortAndClaimExactlyOnce() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-schedules-(UUID().uuidString).json")
        let store = HarnessScheduleStore(url: url)
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let later = try await store.create(
            ownerSession: "Alice",
            label: "later",
            prompt: "later prompt",
            runAt: now + 20_000
        )
        let due = try await store.create(
            ownerSession: "alice",
            label: "due",
            prompt: "due prompt",
            runAt: now + 1_000
        )
        let pendingBeforeClaim = await store.list(ownerSession: "alice")
        XCTAssertEqual(pendingBeforeClaim.map(\.id), [due.id, later.id])

        let claimed = await store.claimDue(now: now + 1_000, limit: 10)
        XCTAssertEqual(claimed.map(\.id), [due.id])
        let pendingAfterClaim = await store.list(ownerSession: "alice")
        XCTAssertTrue(pendingAfterClaim.map(\.id).contains(later.id))
        let claimedAgain = await store.claimDue(now: now + 1_000, limit: 10)
        XCTAssertTrue(claimedAgain.isEmpty)

        let reloaded = HarnessScheduleStore(url: url)
        let reloadedPending = await reloaded.list(ownerSession: "alice")
        XCTAssertEqual(reloadedPending.map(\.id), [later.id])
        try? FileManager.default.removeItem(at: url)
    }

    func testDeleteIsOwnerScopedAndIdempotentForClaimedRecords() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-schedules-(UUID().uuidString).json")
        let store = HarnessScheduleStore(url: url)
        let now = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        let schedule = try await store.create(
            ownerSession: "alice",
            label: "one",
            prompt: "do it",
            runAt: now + 10_000
        )
        do {
            _ = try await store.delete(id: schedule.id, ownerSession: "bob")
            XCTFail("foreign owner must be rejected")
        } catch let error as HarnessScheduleError {
            XCTAssertEqual(error, .foreignSchedule(schedule.id))
        }
        let cancelled = try await store.delete(id: schedule.id, ownerSession: "alice")
        XCTAssertEqual(cancelled.status, .cancelled)
        let deletedAgain = try await store.delete(id: schedule.id, ownerSession: "alice")
        XCTAssertEqual(deletedAgain.status, .cancelled)
        try? FileManager.default.removeItem(at: url)
    }
}
