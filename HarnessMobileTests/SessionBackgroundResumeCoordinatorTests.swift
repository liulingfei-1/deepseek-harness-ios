import XCTest
@testable import HarnessMobileCore

final class SessionBackgroundResumeCoordinatorTests: XCTestCase {
    func testReplacementGenerationRejectsStaleResumeMonitor() async {
        let coordinator = SessionBackgroundResumeCoordinator()
        let sessionID = UUID()
        let stale = RunIdentity(sessionID: sessionID, runID: UUID(), generation: 1)
        let current = RunIdentity(sessionID: sessionID, runID: UUID(), generation: 2)
        let counter = AsyncResumeCounter()

        await coordinator.updateApplicationActivity(isActive: true)
        await coordinator.markSystemExpiration(stale)
        await coordinator.markSystemExpiration(current)

        let staleStarted = await coordinator.startMonitor(
            for: stale,
            readiness: { true },
            resume: { await counter.increment() }
        )
        let currentStarted = await coordinator.startMonitor(
            for: current,
            readiness: { true },
            resume: { await counter.increment() }
        )

        XCTAssertFalse(staleStarted)
        XCTAssertTrue(currentStarted)
        await waitUntil { await counter.value == 1 }
        let resumeCount = await counter.value
        let pending = await coordinator.pendingIdentity(sessionID: sessionID)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertNil(pending)
    }

    func testInactiveCoordinatorPreservesPendingIdentityUntilReactivated() async {
        let coordinator = SessionBackgroundResumeCoordinator()
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 7)
        let counter = AsyncResumeCounter()

        await coordinator.markSystemExpiration(identity)
        let inactiveStarted = await coordinator.startMonitor(
            for: identity,
            readiness: { true },
            resume: { await counter.increment() }
        )
        let pendingWhileInactive = await coordinator.pendingIdentity(
            sessionID: identity.sessionID
        )
        XCTAssertFalse(inactiveStarted)
        XCTAssertEqual(pendingWhileInactive, identity)

        await coordinator.updateApplicationActivity(isActive: true)
        let activeStarted = await coordinator.startMonitor(
            for: identity,
            readiness: { true },
            resume: { await counter.increment() }
        )
        XCTAssertTrue(activeStarted)
        await waitUntil { await counter.value == 1 }
        let resumeCount = await counter.value
        XCTAssertEqual(resumeCount, 1)
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await predicate() { return }
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch {
                XCTFail("wait cancelled", file: file, line: line)
                return
            }
        }
        XCTFail("condition did not become true", file: file, line: line)
    }
}

private actor AsyncResumeCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
