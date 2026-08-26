import XCTest
@testable import HarnessMobileCore

final class SessionRunStateTests: XCTestCase {
    func testRuntimeEventsAreIsolatedByCompleteRunIdentity() async throws {
        let sessionID = UUID()
        let current = RunIdentity(sessionID: sessionID, runID: UUID(), generation: 2)
        let stale = RunIdentity(sessionID: sessionID, runID: current.runID, generation: 1)
        let state = SessionRunState(identity: current)

        let staleStepAccepted = await state.apply(.stepStarted(99), for: stale)
        let staleTextAccepted = await state.apply(.textDelta("stale"), for: stale)
        let currentStepAccepted = await state.apply(.stepStarted(3), for: current)
        let currentTextAccepted = await state.apply(.textDelta("current"), for: current)
        let didFlush = await state.flushPresentation(for: current)
        XCTAssertFalse(staleStepAccepted)
        XCTAssertFalse(staleTextAccepted)
        XCTAssertTrue(currentStepAccepted)
        XCTAssertTrue(currentTextAccepted)
        XCTAssertTrue(didFlush)

        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.currentStep, 3)
        XCTAssertEqual(snapshot.streamingText, "current")
        XCTAssertEqual(snapshot.staleCallbackCount, 2)
    }

    func testTwoRunStatesKeepStreamingToolsAndQuestionsIndependent() async throws {
        let a = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let b = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let stateA = SessionRunState(identity: a)
        let stateB = SessionRunState(identity: b)
        let question = ContinuationUserQuestionProvider.Pending(
            id: UUID(),
            request: AskUserQuestionRequest(
                questions: [AskUserQuestionItem(id: "choice", question: "A or B?")]
            )
        )
        let toolCall = AgentToolCall(id: "call-a", name: "read", arguments: "{}")

        let textAccepted = await stateA.apply(.textDelta("alpha"), for: a)
        let toolAccepted = await stateA.apply(
            .toolEventChanged(AgentToolEvent(call: toolCall, status: .running)),
            for: a
        )
        let questionAccepted = await stateA.setPendingQuestion(question, for: a)
        let streamFlushed = await stateA.flushPresentation(for: a)
        _ = await stateA.flushToolPresentation(for: a)
        XCTAssertTrue(textAccepted)
        XCTAssertTrue(toolAccepted)
        XCTAssertTrue(questionAccepted)
        XCTAssertTrue(streamFlushed)

        let snapshotA = await stateA.snapshot()
        let snapshotB = await stateB.snapshot()
        XCTAssertEqual(snapshotA.streamingText, "alpha")
        XCTAssertEqual(snapshotA.activeToolEvents.map(\.callID), ["call-a"])
        XCTAssertEqual(snapshotA.pendingUserQuestion?.id, question.id)
        XCTAssertEqual(snapshotB.streamingText, "")
        XCTAssertTrue(snapshotB.activeToolEvents.isEmpty)
        XCTAssertNil(snapshotB.pendingUserQuestion)
    }

    func testInboxOrderingAndClaimAreOwnedByExactRun() async throws {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 4)
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: identity.runID,
            generation: 3
        )
        let state = SessionRunState(identity: identity)

        let normal = try await state.enqueue(
            text: "normal",
            disposition: .queued,
            for: identity
        )
        let steer = try await state.enqueue(
            text: "steer",
            disposition: .steer,
            for: identity
        )

        let nextStep = await state.nextQueuedInput(at: .nextStep, for: identity)
        let turnStopping = await state.nextQueuedInput(at: .turnStopping, for: identity)
        let staleClaimed = await state.claimQueuedInput(id: steer.id, for: stale)
        let currentClaimed = await state.claimQueuedInput(id: steer.id, for: identity)
        let remaining = await state.nextQueuedInput(at: .turnStopping, for: identity)
        XCTAssertEqual(nextStep?.id, steer.id)
        XCTAssertEqual(turnStopping?.id, steer.id)
        XCTAssertFalse(staleClaimed)
        XCTAssertTrue(currentClaimed)
        XCTAssertEqual(remaining?.id, normal.id)
    }

    func testApprovalContinuationBelongsToOneRunAndOneRequest() async throws {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 8)
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: identity.runID,
            generation: 7
        )
        let state = SessionRunState(identity: identity)
        let request = try makeApprovalRequest(runID: identity.runID)

        let began = await state.beginApproval(request, for: identity)
        XCTAssertTrue(began)
        let waiter = Task {
            await state.awaitApproval(requestID: request.id, for: identity)
        }
        let staleResolved = await state.resolveApproval(
            requestID: request.id,
            approved: true,
            for: stale
        )
        let currentResolved = await state.resolveApproval(
            requestID: request.id,
            approved: true,
            for: identity
        )

        let approved = await waiter.value
        let snapshot = await state.snapshot()
        XCTAssertFalse(staleResolved)
        XCTAssertTrue(currentResolved)
        XCTAssertTrue(approved)
        XCTAssertNil(snapshot.pendingApproval)
    }

    func testTwoRunsResolveSimultaneousApprovalsIndependently() async throws {
        let identityA = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let identityB = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let stateA = SessionRunState(identity: identityA)
        let stateB = SessionRunState(identity: identityB)
        let requestA = try makeApprovalRequest(runID: identityA.runID)
        let requestB = try makeApprovalRequest(runID: identityB.runID)

        let beganA = await stateA.beginApproval(requestA, for: identityA)
        let beganB = await stateB.beginApproval(requestB, for: identityB)
        XCTAssertTrue(beganA)
        XCTAssertTrue(beganB)
        let waiterA = Task {
            await stateA.awaitApproval(requestID: requestA.id, for: identityA)
        }
        let waiterB = Task {
            await stateB.awaitApproval(requestID: requestB.id, for: identityB)
        }

        let resolvedA = await stateA.resolveApproval(
            requestID: requestA.id,
            approved: true,
            for: identityA
        )
        let resolvedB = await stateB.resolveApproval(
            requestID: requestB.id,
            approved: false,
            for: identityB
        )
        XCTAssertTrue(resolvedA)
        XCTAssertTrue(resolvedB)
        let decisionA = await waiterA.value
        let decisionB = await waiterB.value

        XCTAssertTrue(decisionA)
        XCTAssertFalse(decisionB)
        let snapshotA = await stateA.snapshot()
        let snapshotB = await stateB.snapshot()
        XCTAssertNil(snapshotA.pendingApproval)
        XCTAssertNil(snapshotB.pendingApproval)
    }

    func testTerminalCleanupCancelsOwnedTasksAndResolvesInteractionFailClosed() async throws {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let state = SessionRunState(identity: identity)
        let request = try makeApprovalRequest(runID: identity.runID)
        let task = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(3_600))
            } catch {
                // Cancellation is the expected terminal signal.
            }
        }

        let installed = await state.installTask(task, for: identity)
        let began = await state.beginApproval(request, for: identity)
        XCTAssertTrue(installed)
        XCTAssertTrue(began)
        let approval = Task {
            await state.awaitApproval(requestID: request.id, for: identity)
        }
        let textAccepted = await state.apply(.textDelta("partial"), for: identity)
        XCTAssertTrue(textAccepted)
        let terminal = await state.finish(.disposed, for: identity)

        let approved = await approval.value
        await task.value
        XCTAssertFalse(approved)
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(terminal.phase, .terminal(.disposed))
        XCTAssertNil(terminal.pendingApproval)
        XCTAssertNil(terminal.pendingUserQuestion)
        XCTAssertEqual(terminal.streamingText, "")
        XCTAssertTrue(terminal.activeToolEvents.isEmpty)
        XCTAssertFalse(terminal.hasOwnedTask)
    }

    func testStartOwnedTaskPublishesOwnershipBeforeOperationCompletes() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let state = SessionRunState(identity: identity)
        let gate = SessionRunStateGate()

        let started = await state.startOwnedTask(for: identity) {
            await gate.wait()
        }
        let whileBlocked = await state.snapshot()

        XCTAssertTrue(started)
        XCTAssertTrue(whileBlocked.hasOwnedTask)

        await gate.open()
        let joined = await state.awaitOwnedTask(for: identity)
        XCTAssertTrue(joined)
    }

    func testStartOwnedTaskRejectsStaleIdentityWithoutRunningOperation() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 2)
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: identity.runID,
            generation: 1
        )
        let state = SessionRunState(identity: identity)
        let recorder = SessionRunStateCounter()

        let started = await state.startOwnedTask(for: stale) {
            await recorder.increment()
        }
        let invocationCount = await recorder.value()
        let snapshot = await state.snapshot()

        XCTAssertFalse(started)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(snapshot.staleCallbackCount, 1)
    }

    func testTraceCursorAndBackgroundProjectionRejectStaleCallbacks() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 5)
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: identity.runID,
            generation: 4
        )
        let state = SessionRunState(identity: identity)
        let status = try! ContinuedProcessingStatus(
            title: "Harness",
            subtitle: "step",
            completedUnitCount: 1,
            totalUnitCount: 2
        )

        let stalePrepared = await state.prepareTrace(startSequence: 40, for: stale)
        let prepared = await state.prepareTrace(startSequence: 40, for: identity)
        let advanced = await state.advanceTrace(to: 44, for: identity)
        let staleAdvanced = await state.advanceTrace(to: 99, for: stale)
        let backgroundUpdated = await state.updateBackground(
            status: .running(status),
            submission: .submitted,
            event: "running",
            for: identity
        )
        XCTAssertFalse(stalePrepared)
        XCTAssertTrue(prepared)
        XCTAssertTrue(advanced)
        XCTAssertFalse(staleAdvanced)
        XCTAssertTrue(backgroundUpdated)

        let snapshot = await state.snapshot()
        XCTAssertEqual(snapshot.traceKey?.sessionID, identity.sessionID)
        XCTAssertEqual(snapshot.traceKey?.runID, identity.runID)
        XCTAssertEqual(snapshot.traceKey?.startSequence, 40)
        XCTAssertEqual(snapshot.traceKey?.cursor, 44)
        XCTAssertEqual(snapshot.backgroundRuntimeStatus, .running(status))
        XCTAssertEqual(snapshot.continuedProcessingSubmission, .submitted)
        XCTAssertEqual(snapshot.lastBackgroundEvent, "running")
        XCTAssertEqual(snapshot.staleCallbackCount, 2)
    }

    func testSystemExpirationUpgradesCancellationButCannotOverwriteFailure() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 3)
        let stale = RunIdentity(
            sessionID: identity.sessionID,
            runID: identity.runID,
            generation: 2
        )
        let state = SessionRunState(identity: identity)

        let cancelled = await state.proposeTerminalOutcome(.cancelled, for: identity)
        let interrupted = await state.proposeTerminalOutcome(.interrupted, for: identity)
        let failed = await state.proposeTerminalOutcome(.failed, for: identity)
        let staleProposal = await state.proposeTerminalOutcome(.failed, for: stale)
        let proposal = await state.terminalOutcomeProposal(for: identity)
        let snapshot = await state.snapshot()
        let failedIdentity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let failedState = SessionRunState(identity: failedIdentity)
        let recordedFailure = await failedState.proposeTerminalOutcome(
            .failed,
            for: failedIdentity
        )
        let overwroteFailure = await failedState.proposeTerminalOutcome(
            .interrupted,
            for: failedIdentity
        )

        XCTAssertTrue(cancelled)
        XCTAssertTrue(interrupted)
        XCTAssertFalse(failed)
        XCTAssertFalse(staleProposal)
        XCTAssertEqual(proposal, .interrupted)
        XCTAssertEqual(snapshot.staleCallbackCount, 1)
        XCTAssertTrue(recordedFailure)
        XCTAssertFalse(overwroteFailure)
    }

    func testRegistryRegistrationPublishesRunStateAndRoutesHandleDelivery() async throws {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let registry = SessionRunRegistry()
        let registration = try await registry.register(identity: identity) {
            SessionRunPreparedConfiguration(trajectorySessionID: identity.sessionID)
        }
        let queued = try QueuedAgentInput(text: "follow up")

        let began = await registration.handle.beginRunning(for: identity)
        let delivered = await registration.handle.followup(queued)
        XCTAssertTrue(began)
        XCTAssertTrue(delivered)

        let stateSnapshot = await registration.state.snapshot()
        XCTAssertEqual(stateSnapshot.queuedInputs.map(\.id), [queued.id])
        let registrySnapshot = await registry.snapshot(for: identity)
        XCTAssertEqual(registrySnapshot?.presentation.identity, identity)
    }

    func testPresentationHandlerReceivesMonotonicSnapshots() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let recorder = SessionRunPresentationRecorder()
        let state = SessionRunState(identity: identity) { snapshot in
            await recorder.append(snapshot)
        }

        _ = await state.markRunning(for: identity, startedAt: Date(timeIntervalSince1970: 1))
        _ = await state.apply(.stepStarted(1), for: identity)
        _ = await state.apply(.stepStarted(2), for: identity)

        let revisions = await recorder.snapshots().map(\.revision)
        XCTAssertEqual(revisions, revisions.sorted())
        XCTAssertEqual(Set(revisions).count, revisions.count)
        let currentRevision = await state.snapshot().revision
        XCTAssertEqual(revisions.last, currentRevision)
    }

    func testBackgroundPresentationIsFrozenAndForegroundFlushesOnce() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let recorder = SessionRunPresentationRecorder()
        let state = SessionRunState(identity: identity) { snapshot in
            await recorder.append(snapshot)
        }

        _ = await state.markRunning(for: identity)
        let before = await state.snapshot()
        _ = await state.setPresentationUpdatesEnabled(false, for: identity)
        for index in 0..<200 {
            _ = await state.apply(.textDelta("delta-\(index)\n"), for: identity)
        }
        let background = await state.snapshot()
        XCTAssertEqual(background.revision, before.revision)
        XCTAssertEqual(background.streamingPresentationRevision, before.streamingPresentationRevision)
        let backgroundSnapshotCount = await recorder.snapshots().count
        XCTAssertEqual(backgroundSnapshotCount, 1)

        _ = await state.setPresentationUpdatesEnabled(true, for: identity)
        let foreground = await state.snapshot()
        XCTAssertGreaterThan(foreground.revision, before.revision)
        XCTAssertGreaterThan(foreground.streamingPresentationRevision, before.streamingPresentationRevision)
        XCTAssertTrue(foreground.streamingText.contains("delta-199"))
        let foregroundSnapshotCount = await recorder.snapshots().count
        XCTAssertEqual(foregroundSnapshotCount, 2)
    }

    func testToolOutputSurvivesTerminalEventBeforeBatchFlush() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let state = SessionRunState(identity: identity)
        let call = AgentToolCall(id: "call-output", name: "shell", arguments: "{}")

        _ = await state.apply(
            .toolEventChanged(AgentToolEvent(call: call, status: .running)),
            for: identity
        )
        _ = await state.apply(
            .toolOutput(
                callID: call.id,
                chunk: AgentToolOutputChunk(channel: .stdout, text: "complete output")
            ),
            for: identity
        )
        _ = await state.apply(
            .toolEventChanged(AgentToolEvent(call: call, status: .succeeded)),
            for: identity
        )

        let flushed = await state.flushToolPresentation(for: identity)
        let snapshot = await state.snapshot()
        let event = try! XCTUnwrap(snapshot.activeToolEvents.first)
        XCTAssertTrue(flushed)
        XCTAssertEqual(event.status, .succeeded)
        XCTAssertEqual(event.output.map(\.text), ["complete output"])
    }

    func testToolOutputArrivingBeforeInitialEventIsRetained() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let state = SessionRunState(identity: identity)
        let call = AgentToolCall(id: "call-before-event", name: "shell", arguments: "{}")

        _ = await state.apply(
            .toolOutput(
                callID: call.id,
                chunk: AgentToolOutputChunk(channel: .stdout, text: "early output")
            ),
            for: identity
        )
        _ = await state.apply(
            .toolEventChanged(AgentToolEvent(call: call, status: .running)),
            for: identity
        )

        let flushed = await state.flushToolPresentation(for: identity)
        let snapshot = await state.snapshot()
        let event = try! XCTUnwrap(snapshot.activeToolEvents.first)
        XCTAssertTrue(flushed)
        XCTAssertEqual(event.output.map(\.text), ["early output"])
    }

    func testToolOutputSurvivesRunningEventReplacement() async {
        let identity = RunIdentity(sessionID: UUID(), runID: UUID(), generation: 1)
        let state = SessionRunState(identity: identity)
        let call = AgentToolCall(id: "call-replacement", name: "shell", arguments: "{}")

        _ = await state.apply(
            .toolEventChanged(AgentToolEvent(call: call, status: .running)),
            for: identity
        )
        _ = await state.apply(
            .toolOutput(
                callID: call.id,
                chunk: AgentToolOutputChunk(channel: .stdout, text: "during update")
            ),
            for: identity
        )
        _ = await state.apply(
            .toolEventChanged(
                AgentToolEvent(call: call, summary: "still running", status: .running)
            ),
            for: identity
        )

        _ = await state.flushToolPresentation(for: identity)
        let snapshot = await state.snapshot()
        let event = try! XCTUnwrap(snapshot.activeToolEvents.first)
        XCTAssertEqual(event.summary, "still running")
        XCTAssertEqual(event.output.map(\.text), ["during update"])
    }

    private func makeApprovalRequest(runID: UUID) throws -> ToolApprovalRequest {
        try ToolApprovalRequest(
            runID: runID,
            call: AgentToolCall(id: "approval-call", name: "write", arguments: "{}"),
            risk: .sideEffect,
            summary: "write",
            modelHost: "api.example.invalid",
            approvalResources: ["workspace:file.txt"]
        )
    }
}

private actor SessionRunPresentationRecorder {
    private var values: [SessionRunPresentation] = []

    func append(_ value: SessionRunPresentation) {
        values.append(value)
    }

    func snapshots() -> [SessionRunPresentation] {
        values
    }
}

private actor SessionRunStateGate {
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
        pending.forEach { $0.resume() }
    }
}

private actor SessionRunStateCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
