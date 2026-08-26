import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class MobileAgentHandleTests: XCTestCase {
    func testRunIdentityRequiresSessionRunAndGenerationToMatch() {
        let sessionID = UUID()
        let runID = UUID()
        let identity = RunIdentity(sessionID: sessionID, runID: runID, generation: 7)

        XCTAssertTrue(identity.accepts(identity))
        XCTAssertFalse(identity.accepts(
            RunIdentity(sessionID: UUID(), runID: runID, generation: 7)
        ))
        XCTAssertFalse(identity.accepts(
            RunIdentity(sessionID: sessionID, runID: UUID(), generation: 7)
        ))
        XCTAssertFalse(identity.accepts(
            RunIdentity(sessionID: sessionID, runID: runID, generation: 6)
        ))
    }

    func testFollowupSteerAndInjectReuseIdentifiedQueuedInput() async throws {
        let recorder = MobileAgentHandleRecorder()
        let handle = makeHandle(recorder: recorder)
        let followup = try QueuedAgentInput(text: "next turn")
        let steer = try QueuedAgentInput(text: "change direction", disposition: .steer)
        let injection = try QueuedAgentInput(text: "model-only context")

        let acceptedFollowup = await handle.followup(followup)
        let acceptedSteer = await handle.steer(steer)
        let acceptedInjection = await handle.inject(injection)
        XCTAssertTrue(acceptedFollowup)
        XCTAssertTrue(acceptedSteer)
        XCTAssertTrue(acceptedInjection)

        let deliveries = await recorder.snapshot().deliveries
        XCTAssertEqual(deliveries.map(\.kind), [.followup, .steer, .inject])
        XCTAssertEqual(deliveries.map(\.input.id), [followup.id, steer.id, injection.id])
    }

    func testRepeatedConcurrentCancelSignalsRuntimeOnce() async {
        let recorder = MobileAgentHandleRecorder()
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity, recorder: recorder)
        let didBegin = await handle.beginRunning(for: identity)
        XCTAssertTrue(didBegin)

        let acceptedCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { await handle.cancel() }
            }
            var count = 0
            for await accepted in group where accepted {
                count += 1
            }
            return count
        }

        XCTAssertEqual(acceptedCount, 1)
        let cancellingSnapshot = await handle.snapshot()
        let cancelOutcome = await handle.finish(.cancelled, for: identity)
        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded.cancelSignalCount, 1)
        XCTAssertEqual(cancellingSnapshot.phase, .cancelling)
        XCTAssertEqual(cancelOutcome, .cancelled)
        XCTAssertEqual(recorded.terminalOutcomes, [.cancelled])
    }

    func testCancelAndSuccessRaceRecordsOneSuccessfulTerminalOutcome() async {
        let recorder = MobileAgentHandleRecorder()
        let cancelGate = AsyncGate()
        let identity = makeIdentity()
        let handle = MobileAgentHandle(
            identity: identity,
            deliveryHandler: { delivery in await recorder.record(delivery) },
            cancellationHandler: {
                await recorder.recordCancelSignal()
                await cancelGate.wait()
            },
            quiescenceHandler: { await recorder.recordQuiescence() },
            terminalHandler: { identity, outcome in
                await recorder.recordTerminal(identity: identity, outcome: outcome)
            }
        )
        let didBegin = await handle.beginRunning(for: identity)
        XCTAssertTrue(didBegin)

        let cancelTask = Task { await handle.cancel() }
        await recorder.waitForCancelSignals(1)
        let successOutcome = await handle.finish(.succeeded, for: identity)
        XCTAssertEqual(successOutcome, .succeeded)
        await cancelGate.open()

        let cancellationAccepted = await cancelTask.value
        let terminalSnapshot = await handle.snapshot()
        let recorded = await recorder.snapshot()
        XCTAssertTrue(cancellationAccepted)
        XCTAssertEqual(terminalSnapshot.phase, .terminal(.succeeded))
        XCTAssertEqual(recorded.terminalOutcomes, [.succeeded])
    }

    func testFourTerminalOutcomesRacingChooseOneAndCleanupOnce() async {
        let recorder = MobileAgentHandleRecorder()
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity, recorder: recorder)
        let didBegin = await handle.beginRunning(for: identity)
        XCTAssertTrue(didBegin)
        let proposals: [MobileAgentTerminalOutcome] = [
            .succeeded,
            .cancelled,
            .failed,
            .interrupted
        ]

        let results = await withTaskGroup(of: MobileAgentTerminalOutcome?.self) { group in
            for index in 0..<80 {
                let proposal = proposals[index % proposals.count]
                group.addTask { await handle.finish(proposal, for: identity) }
            }
            var collected: [MobileAgentTerminalOutcome] = []
            for await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }

        let recorded = await recorder.snapshot()
        XCTAssertEqual(Set(results).count, 1)
        XCTAssertEqual(recorded.terminalOutcomes.count, 1)
        XCTAssertEqual(Set(recorded.terminalOutcomes), Set(results))
    }

    func testOldGenerationCallbacksCannotTransitionOrFinishCurrentRun() async {
        let recorder = MobileAgentHandleRecorder()
        let sessionID = UUID()
        let runID = UUID()
        let current = RunIdentity(sessionID: sessionID, runID: runID, generation: 2)
        let stale = RunIdentity(sessionID: sessionID, runID: runID, generation: 1)
        let handle = makeHandle(identity: current, recorder: recorder)

        let staleBegin = await handle.beginRunning(for: stale)
        let initialSnapshot = await handle.snapshot()
        let currentBegin = await handle.beginRunning(for: current)
        let staleFinish = await handle.finish(.failed, for: stale)
        let runningSnapshot = await handle.snapshot()
        let beforeCurrentFinish = await recorder.snapshot()
        XCTAssertFalse(staleBegin)
        XCTAssertEqual(initialSnapshot.phase, .idle)
        XCTAssertTrue(currentBegin)
        XCTAssertNil(staleFinish)
        XCTAssertEqual(runningSnapshot.phase, .running)
        XCTAssertEqual(beforeCurrentFinish.terminalOutcomes, [])

        let currentFinish = await handle.finish(.succeeded, for: current)
        let afterCurrentFinish = await recorder.snapshot()
        XCTAssertEqual(currentFinish, .succeeded)
        XCTAssertEqual(afterCurrentFinish.terminalOutcomes, [.succeeded])
    }

    func testDisposeTwiceSharesQuiescenceAndTerminalCleanup() async throws {
        let recorder = MobileAgentHandleRecorder()
        let quiescenceGate = AsyncGate()
        let terminalCleanupGate = AsyncGate()
        let identity = makeIdentity()
        let handle = MobileAgentHandle(
            identity: identity,
            deliveryHandler: { delivery in await recorder.record(delivery) },
            cancellationHandler: { await recorder.recordCancelSignal() },
            quiescenceHandler: {
                await recorder.recordQuiescence()
                await quiescenceGate.wait()
            },
            terminalHandler: { identity, outcome in
                await recorder.recordTerminal(identity: identity, outcome: outcome)
                await terminalCleanupGate.wait()
            }
        )
        let didBegin = await handle.beginRunning(for: identity)
        XCTAssertTrue(didBegin)

        let first = Task {
            let outcome = await handle.dispose()
            await recorder.recordDisposalReturn()
            return outcome
        }
        let second = Task {
            let outcome = await handle.dispose()
            await recorder.recordDisposalReturn()
            return outcome
        }
        await recorder.waitForQuiescenceCalls(1)

        let beforeQuiescence = await recorder.snapshot()
        XCTAssertEqual(beforeQuiescence.cancelSignalCount, 1)
        XCTAssertEqual(beforeQuiescence.quiescenceCallCount, 1)
        XCTAssertEqual(beforeQuiescence.terminalOutcomes, [])
        await quiescenceGate.open()
        await recorder.waitForTerminalOutcomes(1)

        let duringTerminalCleanup = await recorder.snapshot()
        XCTAssertEqual(duringTerminalCleanup.disposalReturnCount, 0)
        await terminalCleanupGate.open()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let afterQuiescence = await recorder.snapshot()
        let lateDeliveryAccepted = await handle.followup(
            try QueuedAgentInput(text: "too late")
        )
        XCTAssertEqual(firstOutcome, .disposed)
        XCTAssertEqual(secondOutcome, .disposed)
        XCTAssertEqual(afterQuiescence.quiescenceCallCount, 1)
        XCTAssertEqual(afterQuiescence.terminalOutcomes, [.disposed])
        XCTAssertEqual(afterQuiescence.disposalReturnCount, 2)
        XCTAssertFalse(lateDeliveryAccepted)
    }

    func testWhenIdleWaitsForCurrentActivityAndThenReturns() async {
        let recorder = MobileAgentHandleRecorder()
        let completion = AsyncGate()
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity, recorder: recorder)
        let didBegin = await handle.beginMaintenance(for: identity)
        XCTAssertTrue(didBegin)

        let waiter = Task {
            await handle.whenIdle()
            await completion.open()
        }
        let didBecomeIdle = await handle.markIdle(for: identity)
        XCTAssertTrue(didBecomeIdle)
        await completion.wait()
        await waiter.value

        let idleSnapshot = await handle.snapshot()
        XCTAssertEqual(idleSnapshot.phase, .idle)
    }

    private func makeIdentity() -> RunIdentity {
        RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
    }

    private func makeHandle(
        identity: RunIdentity? = nil,
        recorder: MobileAgentHandleRecorder
    ) -> MobileAgentHandle {
        MobileAgentHandle(
            identity: identity ?? makeIdentity(),
            deliveryHandler: { delivery in await recorder.record(delivery) },
            cancellationHandler: { await recorder.recordCancelSignal() },
            quiescenceHandler: { await recorder.recordQuiescence() },
            terminalHandler: { identity, outcome in
                await recorder.recordTerminal(identity: identity, outcome: outcome)
            }
        )
    }
}

private actor AsyncGate {
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

private actor MobileAgentHandleRecorder {
    private(set) var deliveries: [MobileAgentDelivery] = []
    private(set) var cancelSignalCount = 0
    private(set) var quiescenceCallCount = 0
    private(set) var terminalIdentities: [RunIdentity] = []
    private(set) var terminalOutcomes: [MobileAgentTerminalOutcome] = []
    private(set) var disposalReturnCount = 0

    private var cancelSignalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var quiescenceWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var terminalOutcomeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func snapshot() -> MobileAgentHandleRecorderSnapshot {
        MobileAgentHandleRecorderSnapshot(
            deliveries: deliveries,
            cancelSignalCount: cancelSignalCount,
            quiescenceCallCount: quiescenceCallCount,
            terminalIdentities: terminalIdentities,
            terminalOutcomes: terminalOutcomes,
            disposalReturnCount: disposalReturnCount
        )
    }

    func record(_ delivery: MobileAgentDelivery) {
        deliveries.append(delivery)
    }

    func recordCancelSignal() {
        cancelSignalCount += 1
        resumeSatisfied(&cancelSignalWaiters, count: cancelSignalCount)
    }

    func waitForCancelSignals(_ count: Int) async {
        guard cancelSignalCount < count else { return }
        await withCheckedContinuation { continuation in
            cancelSignalWaiters.append((count, continuation))
        }
    }

    func recordQuiescence() {
        quiescenceCallCount += 1
        resumeSatisfied(&quiescenceWaiters, count: quiescenceCallCount)
    }

    func waitForQuiescenceCalls(_ count: Int) async {
        guard quiescenceCallCount < count else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append((count, continuation))
        }
    }

    func recordTerminal(identity: RunIdentity, outcome: MobileAgentTerminalOutcome) {
        terminalIdentities.append(identity)
        terminalOutcomes.append(outcome)
        resumeSatisfied(&terminalOutcomeWaiters, count: terminalOutcomes.count)
    }

    func waitForTerminalOutcomes(_ count: Int) async {
        guard terminalOutcomes.count < count else { return }
        await withCheckedContinuation { continuation in
            terminalOutcomeWaiters.append((count, continuation))
        }
    }

    func recordDisposalReturn() {
        disposalReturnCount += 1
    }

    private func resumeSatisfied(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in waiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        waiters = remaining
    }
}

private struct MobileAgentHandleRecorderSnapshot: Sendable {
    let deliveries: [MobileAgentDelivery]
    let cancelSignalCount: Int
    let quiescenceCallCount: Int
    let terminalIdentities: [RunIdentity]
    let terminalOutcomes: [MobileAgentTerminalOutcome]
    let disposalReturnCount: Int
}
