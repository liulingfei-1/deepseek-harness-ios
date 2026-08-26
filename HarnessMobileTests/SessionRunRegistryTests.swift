import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionRunRegistryTests: XCTestCase {
    func testAllocatedGenerationIsMonotonicEvenWhenEarlierIdentityIsNeverPublished() async {
        let registry = SessionRunRegistry()
        let sessionID = UUID()

        let first = await registry.allocateIdentity(sessionID: sessionID)
        let second = await registry.allocateIdentity(sessionID: sessionID)

        XCTAssertEqual(first.sessionID, sessionID)
        XCTAssertEqual(first.generation, 1)
        XCTAssertEqual(second.sessionID, sessionID)
        XCTAssertEqual(second.generation, 2)
        XCTAssertNotEqual(first.runID, second.runID)
    }

    func testOneOfOneHundredConcurrentRegistrationsPublishesAndLosersRollback() async throws {
        let registry = SessionRunRegistry()
        let recorder = SessionRunRegistryRecorder()
        let rendezvous = SessionRunRegistryRendezvous(target: 100)
        let identity = makeIdentity(generation: 4)

        let attempts = await withTaskGroup(of: SessionRunRegistrationAttempt.self) { group in
            for attempt in 0..<100 {
                group.addTask {
                    do {
                        let registration = try await registry.register(identity: identity) {
                            await recorder.recordConfiguration(attempt)
                            await rendezvous.arriveAndWait()
                            return SessionRunPreparedConfiguration(
                                trajectorySessionID: identity.sessionID,
                                backgroundLeaseTokens: [
                                    SessionRunBackgroundLeaseToken(rawValue: UUID())
                                ],
                                terminalCleanupHandler: { _, outcome, tokens in
                                    await recorder.recordTerminal(outcome: outcome, tokens: tokens)
                                },
                                rollbackHandler: {
                                    await recorder.recordRollback(attempt)
                                }
                            )
                        }
                        return .published(registration)
                    } catch let error as SessionRunRegistryError {
                        return .rejected(error)
                    } catch {
                        return .unexpected(String(describing: error))
                    }
                }
            }

            var values: [SessionRunRegistrationAttempt] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let published = attempts.compactMap(\.registration)
        let rejected = attempts.compactMap(\.registryError)
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(rejected.count, 99)
        XCTAssertFalse(attempts.contains { $0.isUnexpected })
        for error in rejected {
            guard case let .sessionAlreadyHasLiveRoot(sessionID, existing, proposed) = error else {
                return XCTFail("Expected structured collision, got \(error)")
            }
            XCTAssertEqual(sessionID, identity.sessionID)
            XCTAssertEqual(existing, identity)
            XCTAssertEqual(proposed, identity)
        }

        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded.configurationAttempts.count, 100)
        XCTAssertEqual(Set(recorded.rollbackAttempts).count, 99)
        let aggregate = await registry.aggregate()
        XCTAssertEqual(aggregate.liveRootCount, 1)
        XCTAssertEqual(aggregate.runs.map(\.identity), [identity])
        let initialViolations = await registry.invariantViolations()
        XCTAssertEqual(initialViolations, [])

        let outcome = await published[0].handle.dispose()
        XCTAssertEqual(outcome, .disposed)
        let removedLookup = await registry.lookup(sessionID: identity.sessionID)
        let emptyAggregate = await registry.aggregate()
        XCTAssertNil(removedLookup)
        XCTAssertEqual(emptyAggregate.liveRootCount, 0)
    }

    func testConfigurationFailureNeverPublishesAnEntry() async {
        let registry = SessionRunRegistry()
        let identity = makeIdentity()

        do {
            _ = try await registry.register(identity: identity) {
                throw SessionRunRegistryTestError.configurationFailed
            }
            XCTFail("Expected configuration failure")
        } catch SessionRunRegistryTestError.configurationFailed {
            // Expected: no prepared scope reached the publication boundary.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let lookup = await registry.lookup(sessionID: identity.sessionID)
        let aggregate = await registry.aggregate()
        XCTAssertNil(lookup)
        XCTAssertEqual(aggregate.runs, [])
    }

    func testTrajectoryMismatchRollsBackWithoutPublishing() async {
        let registry = SessionRunRegistry()
        let recorder = SessionRunRegistryRecorder()
        let identity = makeIdentity()
        let mismatchedTrajectorySessionID = UUID()

        do {
            _ = try await registry.register(identity: identity) {
                SessionRunPreparedConfiguration(
                    trajectorySessionID: mismatchedTrajectorySessionID,
                    rollbackHandler: { await recorder.recordRollback(1) }
                )
            }
            XCTFail("Expected trajectory identity rejection")
        } catch let error as SessionRunRegistryError {
            XCTAssertEqual(
                error,
                .trajectorySessionMismatch(
                    identity: identity,
                    trajectorySessionID: mismatchedTrajectorySessionID
                )
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recorded = await recorder.snapshot()
        let lookup = await registry.lookup(sessionID: identity.sessionID)
        XCTAssertEqual(recorded.rollbackAttempts, [1])
        XCTAssertNil(lookup)
    }

    func testPublicationCommitFailureRollsBackWithoutPublishing() async {
        let registry = SessionRunRegistry()
        let recorder = SessionRunRegistryRecorder()
        let identity = makeIdentity()

        do {
            _ = try await registry.register(identity: identity) {
                SessionRunPreparedConfiguration(
                    trajectorySessionID: identity.sessionID,
                    publicationCommitHandler: {
                        throw SessionRunRegistryTestError.commitFailed
                    },
                    rollbackHandler: { await recorder.recordRollback(2) }
                )
            }
            XCTFail("Expected publication commit failure")
        } catch SessionRunRegistryTestError.commitFailed {
            // Expected: synchronous commit rejected the unpublished candidate.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let recorded = await recorder.snapshot()
        let lookup = await registry.lookup(sessionID: identity.sessionID)
        XCTAssertEqual(recorded.rollbackAttempts, [2])
        XCTAssertNil(lookup)
    }

    func testDifferentSessionsCoexistAndDisposingBDoesNotChangeA() async throws {
        let registry = SessionRunRegistry()
        let identityA = makeIdentity(generation: 1)
        let identityB = makeIdentity(generation: 9)
        let registrationA = try await register(identityA, in: registry)
        let registrationB = try await register(identityB, in: registry)
        let beganA = await registrationA.handle.beginRunning(for: identityA)
        let beganB = await registrationB.handle.beginRunning(for: identityB)
        XCTAssertTrue(beganA)
        XCTAssertTrue(beganB)

        let beforeAValue = await registry.snapshot(for: identityA)
        let beforeA = try XCTUnwrap(beforeAValue)
        let beforeAggregate = await registry.aggregate()
        XCTAssertEqual(beforeAggregate.liveRootCount, 2)
        XCTAssertEqual(Set(beforeAggregate.runs.map(\.identity)), [identityA, identityB])

        let outcomeB = try await registry.dispose(identityB)
        XCTAssertEqual(outcomeB, .disposed)
        let afterAValue = await registry.snapshot(for: identityA)
        let afterA = try XCTUnwrap(afterAValue)
        XCTAssertEqual(afterA, beforeA)
        let removedB = await registry.lookup(sessionID: identityB.sessionID)
        let afterBAggregate = await registry.aggregate()
        XCTAssertNil(removedB)
        XCTAssertEqual(afterBAggregate.runs.map(\.identity), [identityA])

        _ = try await registry.dispose(identityA)
        let finalAggregate = await registry.aggregate()
        let finalViolations = await registry.invariantViolations()
        XCTAssertEqual(finalAggregate.liveRootCount, 0)
        XCTAssertEqual(finalViolations, [])
    }

    func testMaximumLiveRootsAllowsTwoSessionsAndRejectsThirdWithoutPublishing() async throws {
        let registry = SessionRunRegistry()
        let identityA = makeIdentity()
        let identityB = makeIdentity()
        let identityC = makeIdentity()
        let registrationA = try await registry.register(
            identity: identityA,
            maximumLiveRoots: 2
        ) {
            SessionRunPreparedConfiguration(trajectorySessionID: identityA.sessionID)
        }
        let registrationB = try await registry.register(
            identity: identityB,
            maximumLiveRoots: 2
        ) {
            SessionRunPreparedConfiguration(trajectorySessionID: identityB.sessionID)
        }
        _ = await registrationA.handle.beginRunning(for: identityA)
        _ = await registrationB.handle.beginRunning(for: identityB)

        do {
            _ = try await registry.register(
                identity: identityC,
                maximumLiveRoots: 2
            ) {
                XCTFail("The third root must be rejected before configuration")
                return SessionRunPreparedConfiguration(
                    trajectorySessionID: identityC.sessionID
                )
            }
            XCTFail("Expected the concurrent root limit")
        } catch let error as SessionRunRegistryError {
            XCTAssertEqual(error, .rootRunLimitReached(limit: 2))
        }

        let presentationA = await registry.presentation(sessionID: identityA.sessionID)
        let presentationB = await registry.presentation(sessionID: identityB.sessionID)
        let lookupC = await registry.lookup(sessionID: identityC.sessionID)
        XCTAssertEqual(presentationA?.identity, identityA)
        XCTAssertEqual(presentationB?.identity, identityB)
        XCTAssertNil(lookupC)

        _ = await registrationA.handle.dispose()
        _ = await registrationB.handle.dispose()
    }

    func testCancelRoutesOnlyToExactIdentityAndKeepsEntryUntilTerminalOwnerFinishes() async throws {
        let registry = SessionRunRegistry()
        let recorder = SessionRunRegistryRecorder()
        let identity = makeIdentity(generation: 3)
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: identity.runID,
            generation: 2
        )
        let registration = try await registry.register(identity: identity) {
            SessionRunPreparedConfiguration(
                trajectorySessionID: identity.sessionID,
                cancellationHandler: { await recorder.recordCancellation() },
                terminalCleanupHandler: { _, outcome, tokens in
                    await recorder.recordTerminal(outcome: outcome, tokens: tokens)
                }
            )
        }
        let didBegin = await registration.handle.beginRunning(for: identity)
        XCTAssertTrue(didBegin)

        do {
            _ = try await registry.cancel(stale)
            XCTFail("Expected stale identity rejection")
        } catch let error as SessionRunRegistryError {
            XCTAssertEqual(error, .staleRunIdentity(expected: identity, received: stale))
        }
        let beforeCancel = await recorder.snapshot()
        XCTAssertEqual(beforeCancel.cancellationCount, 0)

        let cancellationAccepted = try await registry.cancel(identity)
        let afterCancel = await recorder.snapshot()
        let cancellingSnapshot = await registry.lookup(sessionID: identity.sessionID)
        XCTAssertTrue(cancellationAccepted)
        XCTAssertEqual(afterCancel.cancellationCount, 1)
        XCTAssertEqual(cancellingSnapshot?.phase, .cancelling)

        let outcome = await registration.handle.finish(.cancelled, for: identity)
        XCTAssertEqual(outcome, .cancelled)
        let removedLookup = await registry.lookup(sessionID: identity.sessionID)
        let terminalRecord = await recorder.snapshot()
        XCTAssertNil(removedLookup)
        XCTAssertEqual(terminalRecord.terminalOutcomes, [.cancelled])
    }

    func testTerminalOwnerClaimsLeasesBeforeCleanupAndLeavesNoOrphan() async throws {
        let registry = SessionRunRegistry()
        let recorder = SessionRunRegistryRecorder()
        let cleanupGate = SessionRunRegistryGate()
        let identity = makeIdentity()
        let tokens: Set<SessionRunBackgroundLeaseToken> = [
            SessionRunBackgroundLeaseToken(rawValue: UUID()),
            SessionRunBackgroundLeaseToken(rawValue: UUID())
        ]
        let registration = try await registry.register(identity: identity) {
            SessionRunPreparedConfiguration(
                trajectorySessionID: identity.sessionID,
                backgroundLeaseTokens: tokens,
                terminalCleanupHandler: { _, outcome, claimedTokens in
                    await recorder.recordTerminal(outcome: outcome, tokens: claimedTokens)
                    await cleanupGate.wait()
                }
            )
        }
        let didBegin = await registration.handle.beginRunning(for: identity)
        XCTAssertTrue(didBegin)

        let disposal = Task { try await registry.dispose(identity) }
        await recorder.waitForTerminalCount(1)

        let duringCleanupValue = await registry.lookup(sessionID: identity.sessionID)
        let duringCleanup = try XCTUnwrap(duringCleanupValue)
        XCTAssertEqual(duringCleanup.phase, .terminal(.disposed))
        XCTAssertEqual(duringCleanup.backgroundLeaseTokens, [])
        let cleanupViolations = await registry.invariantViolations()
        let cleanupRecord = await recorder.snapshot()
        XCTAssertEqual(cleanupViolations, [])
        XCTAssertEqual(cleanupRecord.terminalTokens, [tokens])

        await cleanupGate.open()
        let disposalOutcome = try await disposal.value
        let removedLookup = await registry.lookup(sessionID: identity.sessionID)
        let finalAggregate = await registry.aggregate()
        XCTAssertEqual(disposalOutcome, .disposed)
        XCTAssertNil(removedLookup)
        XCTAssertEqual(finalAggregate.runs, [])
    }

    func testCancelThenImmediateReplacementWaitsForCleanupAndRejectsOldGeneration() async throws {
        let registry = SessionRunRegistry()
        let recorder = SessionRunRegistryRecorder()
        let cleanupGate = SessionRunRegistryGate()
        let sessionID = UUID()
        let firstIdentity = await registry.allocateIdentity(sessionID: sessionID)
        let first = try await registry.register(identity: firstIdentity) {
            SessionRunPreparedConfiguration(
                trajectorySessionID: sessionID,
                cancellationHandler: { await recorder.recordCancellation() },
                terminalCleanupHandler: { _, outcome, tokens in
                    await recorder.recordTerminal(outcome: outcome, tokens: tokens)
                    await cleanupGate.wait()
                }
            )
        }
        let didBegin = await first.handle.beginRunning(for: firstIdentity)
        let didCancel = try await registry.cancel(firstIdentity)
        XCTAssertTrue(didBegin)
        XCTAssertTrue(didCancel)

        let terminal = Task {
            await first.handle.finish(.cancelled, for: firstIdentity)
        }
        await recorder.waitForTerminalCount(1)

        let replacementIdentity = await registry.allocateIdentity(sessionID: sessionID)
        XCTAssertEqual(replacementIdentity.generation, firstIdentity.generation + 1)
        do {
            _ = try await registry.register(identity: replacementIdentity) {
                SessionRunPreparedConfiguration(trajectorySessionID: sessionID)
            }
            XCTFail("Expected replacement to wait for terminal cleanup")
        } catch let error as SessionRunRegistryError {
            XCTAssertEqual(
                error,
                .sessionAlreadyHasLiveRoot(
                    sessionID: sessionID,
                    existing: firstIdentity,
                    proposed: replacementIdentity
                )
            )
        }

        await cleanupGate.open()
        let terminalOutcome = await terminal.value
        XCTAssertEqual(terminalOutcome, .cancelled)
        let replacement = try await registry.register(identity: replacementIdentity) {
            SessionRunPreparedConfiguration(trajectorySessionID: sessionID)
        }

        do {
            _ = try await registry.cancel(firstIdentity)
            XCTFail("Expected the old generation to be rejected")
        } catch let error as SessionRunRegistryError {
            XCTAssertEqual(
                error,
                .staleRunIdentity(expected: replacementIdentity, received: firstIdentity)
            )
        }

        let replacementOutcome = await replacement.handle.dispose()
        XCTAssertEqual(replacementOutcome, .disposed)
        let final = await registry.aggregate()
        XCTAssertEqual(final.runs, [])
        let record = await recorder.snapshot()
        XCTAssertEqual(record.cancellationCount, 1)
        XCTAssertEqual(record.terminalOutcomes, [.cancelled])
    }

    func testBackgroundLeaseAdmissionUsesExactLiveEntry() async throws {
        let registry = SessionRunRegistry()
        let identity = makeIdentity()
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: UUID(),
            generation: identity.generation
        )
        _ = try await register(identity, in: registry)
        let token = SessionRunBackgroundLeaseToken(rawValue: UUID())

        do {
            try await registry.addBackgroundLease(token, to: stale)
            XCTFail("Expected stale identity rejection")
        } catch let error as SessionRunRegistryError {
            XCTAssertEqual(error, .staleRunIdentity(expected: identity, received: stale))
        }

        try await registry.addBackgroundLease(token, to: identity)
        let leaseSnapshot = await registry.snapshot(for: identity)
        XCTAssertEqual(
            leaseSnapshot?.backgroundLeaseTokens,
            [token]
        )
        let firstRemoval = try await registry.removeBackgroundLease(token, from: identity)
        let secondRemoval = try await registry.removeBackgroundLease(token, from: identity)
        XCTAssertTrue(firstRemoval)
        XCTAssertFalse(secondRemoval)
        _ = try await registry.dispose(identity)
    }

    private func makeIdentity(generation: UInt64 = 1) -> RunIdentity {
        RunIdentity(sessionID: UUID(), runID: UUID(), generation: generation)
    }

    private func register(
        _ identity: RunIdentity,
        in registry: SessionRunRegistry
    ) async throws -> SessionRunRegistration {
        try await registry.register(identity: identity) {
            SessionRunPreparedConfiguration(trajectorySessionID: identity.sessionID)
        }
    }
}

private enum SessionRunRegistryTestError: Error {
    case configurationFailed
    case commitFailed
}

private enum SessionRunRegistrationAttempt: Sendable {
    case published(SessionRunRegistration)
    case rejected(SessionRunRegistryError)
    case unexpected(String)

    var registration: SessionRunRegistration? {
        guard case let .published(registration) = self else { return nil }
        return registration
    }

    var registryError: SessionRunRegistryError? {
        guard case let .rejected(error) = self else { return nil }
        return error
    }

    var isUnexpected: Bool {
        if case .unexpected = self { return true }
        return false
    }
}

private actor SessionRunRegistryRendezvous {
    private let target: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == target {
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            for waiter in pending {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            if arrivals >= target {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}

private actor SessionRunRegistryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor SessionRunRegistryRecorder {
    private var configurationAttempts: [Int] = []
    private var rollbackAttempts: [Int] = []
    private var cancellationCount = 0
    private var terminalOutcomes: [MobileAgentTerminalOutcome] = []
    private var terminalTokens: [Set<SessionRunBackgroundLeaseToken>] = []
    private var terminalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func recordConfiguration(_ attempt: Int) {
        configurationAttempts.append(attempt)
    }

    func recordRollback(_ attempt: Int) {
        rollbackAttempts.append(attempt)
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func recordTerminal(
        outcome: MobileAgentTerminalOutcome,
        tokens: Set<SessionRunBackgroundLeaseToken>
    ) {
        terminalOutcomes.append(outcome)
        terminalTokens.append(tokens)
        let count = terminalOutcomes.count
        let ready = terminalWaiters.filter { $0.0 <= count }
        terminalWaiters.removeAll { $0.0 <= count }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }

    func waitForTerminalCount(_ count: Int) async {
        guard terminalOutcomes.count < count else { return }
        await withCheckedContinuation { continuation in
            terminalWaiters.append((count, continuation))
        }
    }

    func snapshot() -> SessionRunRegistryRecorderSnapshot {
        SessionRunRegistryRecorderSnapshot(
            configurationAttempts: configurationAttempts,
            rollbackAttempts: rollbackAttempts,
            cancellationCount: cancellationCount,
            terminalOutcomes: terminalOutcomes,
            terminalTokens: terminalTokens
        )
    }
}

private struct SessionRunRegistryRecorderSnapshot: Sendable {
    let configurationAttempts: [Int]
    let rollbackAttempts: [Int]
    let cancellationCount: Int
    let terminalOutcomes: [MobileAgentTerminalOutcome]
    let terminalTokens: [Set<SessionRunBackgroundLeaseToken>]
}
