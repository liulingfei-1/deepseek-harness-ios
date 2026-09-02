import Foundation

/// Opaque ownership marker for one background resource attached to a run.
///
/// The registry never performs OS work itself. It atomically transfers these
/// tokens to the run's terminal owner, which releases the corresponding
/// resources during the single terminal cleanup path.
struct SessionRunBackgroundLeaseToken: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Fully prepared, still-unpublished dependencies for one root Agent.
///
/// `register` awaits the configuration closure before publishing. A prepared
/// scope that loses the final collision check is unwound through
/// `rollbackHandler`; a published scope is unwound only through
/// `terminalCleanupHandler` after its `MobileAgentHandle` becomes terminal.
struct SessionRunPreparedConfiguration: Sendable {
    typealias PublicationCommitHandler = @Sendable () throws -> Void
    typealias TerminalCleanupHandler = @Sendable (
        _ identity: RunIdentity,
        _ outcome: MobileAgentTerminalOutcome,
        _ backgroundLeaseTokens: Set<SessionRunBackgroundLeaseToken>
    ) async -> Void
    typealias RollbackHandler = @Sendable () async -> Void

    let trajectorySessionID: UUID
    let backgroundLeaseTokens: Set<SessionRunBackgroundLeaseToken>
    let initialMessages: [AgentMessage]
    let initialQueuedInputs: [QueuedAgentInput]
    let questionContext: SessionRunQuestionContext
    let presentationHandler: SessionRunState.PresentationHandler
    let deliveryHandler: MobileAgentHandle.DeliveryHandler
    let cancellationHandler: MobileAgentHandle.CancellationHandler
    let quiescenceHandler: MobileAgentHandle.QuiescenceHandler
    let publicationCommitHandler: PublicationCommitHandler
    let terminalCleanupHandler: TerminalCleanupHandler
    let rollbackHandler: RollbackHandler

    init(
        trajectorySessionID: UUID,
        backgroundLeaseTokens: Set<SessionRunBackgroundLeaseToken> = [],
        initialMessages: [AgentMessage] = [],
        initialQueuedInputs: [QueuedAgentInput] = [],
        questionContext: SessionRunQuestionContext = SessionRunQuestionContext(),
        presentationHandler: @escaping SessionRunState.PresentationHandler = { _ in },
        deliveryHandler: @escaping MobileAgentHandle.DeliveryHandler = { _ in },
        cancellationHandler: @escaping MobileAgentHandle.CancellationHandler = {},
        quiescenceHandler: @escaping MobileAgentHandle.QuiescenceHandler = {},
        publicationCommitHandler: @escaping PublicationCommitHandler = {},
        terminalCleanupHandler: @escaping TerminalCleanupHandler = { _, _, _ in },
        rollbackHandler: @escaping RollbackHandler = {}
    ) {
        self.trajectorySessionID = trajectorySessionID
        self.backgroundLeaseTokens = backgroundLeaseTokens
        self.initialMessages = initialMessages
        self.initialQueuedInputs = initialQueuedInputs
        self.questionContext = questionContext
        self.presentationHandler = presentationHandler
        self.deliveryHandler = deliveryHandler
        self.cancellationHandler = cancellationHandler
        self.quiescenceHandler = quiescenceHandler
        self.publicationCommitHandler = publicationCommitHandler
        self.terminalCleanupHandler = terminalCleanupHandler
        self.rollbackHandler = rollbackHandler
    }
}

/// Consumer capability returned only to the owner that successfully publishes.
/// Registry lookup APIs deliberately expose snapshots instead of this handle.
struct SessionRunRegistration: Sendable {
    let identity: RunIdentity
    let handle: MobileAgentHandle
    let state: SessionRunState
}

struct SessionRunSnapshot: Sendable, Equatable {
    let identity: RunIdentity
    let trajectorySessionID: UUID
    let phase: MobileAgentPhase
    let createdGeneration: UInt64
    let backgroundLeaseTokens: Set<SessionRunBackgroundLeaseToken>
    let presentation: SessionRunPresentation
}

struct SessionRunAggregateSnapshot: Sendable, Equatable {
    let runs: [SessionRunSnapshot]

    var liveRootCount: Int {
        runs.count { snapshot in
            if case .terminal = snapshot.phase { return false }
            return true
        }
    }

    var terminalCleanupCount: Int {
        runs.count { snapshot in
            if case .terminal = snapshot.phase { return true }
            return false
        }
    }

    var backgroundLeaseCount: Int {
        runs.reduce(into: 0) { count, snapshot in
            count += snapshot.backgroundLeaseTokens.count
        }
    }
}

enum SessionRunRegistryError: Error, Sendable, Equatable {
    case sessionAlreadyHasLiveRoot(
        sessionID: UUID,
        existing: RunIdentity,
        proposed: RunIdentity
    )
    case trajectorySessionMismatch(identity: RunIdentity, trajectorySessionID: UUID)
    case runNotFound(sessionID: UUID)
    case rootRunLimitReached(limit: Int)
    case staleRunIdentity(expected: RunIdentity, received: RunIdentity)
    case terminalRun(identity: RunIdentity)
}

extension SessionRunRegistryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .sessionAlreadyHasLiveRoot(sessionID, existing, proposed):
            "Session \(sessionID.uuidString) already has live root \(existing.runID.uuidString) "
                + "generation \(existing.generation); rejected \(proposed.runID.uuidString) "
                + "generation \(proposed.generation)."
        case let .trajectorySessionMismatch(identity, trajectorySessionID):
            "Run session \(identity.sessionID.uuidString) does not match trajectory session "
                + "\(trajectorySessionID.uuidString)."
        case let .runNotFound(sessionID):
            "No live root Agent is registered for session \(sessionID.uuidString)."
        case let .rootRunLimitReached(limit):
            "The mobile root Agent limit of \(limit) concurrent runs has been reached."
        case let .staleRunIdentity(expected, received):
            "Stale run identity \(received.runID.uuidString)/\(received.generation); expected "
                + "\(expected.runID.uuidString)/\(expected.generation)."
        case let .terminalRun(identity):
            "Run \(identity.runID.uuidString)/\(identity.generation) is terminal."
        }
    }
}

enum SessionRunInvariantViolation: Sendable, Equatable {
    case trajectorySessionMismatch(identity: RunIdentity, trajectorySessionID: UUID)
    case createdGenerationMismatch(identity: RunIdentity, createdGeneration: UInt64)
    case terminalEntryRetainsBackgroundLeases(
        identity: RunIdentity,
        tokens: Set<SessionRunBackgroundLeaseToken>
    )
}

/// Stable, content-free identifiers for the cross-module runtime checks.
/// Records intentionally carry only identity and a short code so diagnostics
/// can be shared with the model without exposing prompts or tool payloads.
enum RuntimeInvariantKind: String, Codable, CaseIterable, Sendable, Equatable {
    case oneRootPerSession = "one_root_per_session"
    case modelVisibleRecorded = "model_visible_recorded"
    case leaseOwnerExists = "lease_owner_exists"
    case terminalHasNoResources = "terminal_has_no_resources"
    case contiguousSequence = "contiguous_sequence"
}

struct RuntimeInvariantViolationRecord: Codable, Sendable, Equatable, Identifiable {
    let module: String
    let kind: RuntimeInvariantKind
    let sessionID: UUID?
    let runID: UUID?
    let code: String

    var id: String {
        [module, kind.rawValue, sessionID?.uuidString ?? "none", runID?.uuidString ?? "none", code]
            .joined(separator: "|")
    }
}

/// Actor-isolated registry used by diagnostics and module-owned audits.
/// Replacing the snapshot keeps stale failures from surviving a later healthy
/// audit and makes the output deterministic for tests and support reports.
actor RuntimeInvariantRegistry {
    private var violations: [String: RuntimeInvariantViolationRecord] = [:]

    func replace(_ records: [RuntimeInvariantViolationRecord]) {
        violations = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func snapshot() -> [RuntimeInvariantViolationRecord] {
        violations.values.sorted { lhs, rhs in
            if lhs.kind.rawValue == rhs.kind.rawValue { return lhs.id < rhs.id }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }
}

extension SessionRunInvariantViolation {
    var runtimeRecord: RuntimeInvariantViolationRecord {
        switch self {
        case let .trajectorySessionMismatch(identity, trajectorySessionID):
            return RuntimeInvariantViolationRecord(
                module: "session_run_registry",
                kind: .oneRootPerSession,
                sessionID: identity.sessionID,
                runID: identity.runID,
                code: "trajectory_session_mismatch:\(trajectorySessionID.uuidString)"
            )
        case let .createdGenerationMismatch(identity, createdGeneration):
            return RuntimeInvariantViolationRecord(
                module: "session_run_registry",
                kind: .oneRootPerSession,
                sessionID: identity.sessionID,
                runID: identity.runID,
                code: "created_generation_mismatch:\(createdGeneration)"
            )
        case let .terminalEntryRetainsBackgroundLeases(identity, tokens):
            return RuntimeInvariantViolationRecord(
                module: "session_run_registry",
                kind: .terminalHasNoResources,
                sessionID: identity.sessionID,
                runID: identity.runID,
                code: "background_lease_count:\(tokens.count)"
            )
        }
    }
}

/// Actor-isolated registry of live top-level mobile Agent runs.
///
/// The durable session UUID is the single key, so one session can publish at
/// most one root while unrelated sessions coexist. Configuration occurs while
/// unpublished; the final collision check and insertion contain no suspension.
actor SessionRunRegistry {
    typealias Configuration = @Sendable () async throws -> SessionRunPreparedConfiguration

    private struct Entry: Sendable {
        let registrationID: UUID
        let identity: RunIdentity
        let trajectorySessionID: UUID
        let createdGeneration: UInt64
        let registrationOrdinal: UInt64
        let handle: MobileAgentHandle
        let state: SessionRunState
        var phase: MobileAgentPhase
        var backgroundLeaseTokens: Set<SessionRunBackgroundLeaseToken>
        var terminalCleanupClaimed: Bool

        func snapshot(presentation: SessionRunPresentation) -> SessionRunSnapshot {
            SessionRunSnapshot(
                identity: identity,
                trajectorySessionID: trajectorySessionID,
                phase: phase,
                createdGeneration: createdGeneration,
                backgroundLeaseTokens: backgroundLeaseTokens,
                presentation: presentation
            )
        }
    }

    private var entries: [UUID: Entry] = [:]
    private var latestGenerationBySession: [UUID: UInt64] = [:]
    private var nextRegistrationOrdinal: UInt64 = 0

    /// Allocate a process-monotonic generation for a durable session.
    /// Consuming a generation without publishing is legal; reuse is not.
    func allocateIdentity(sessionID: UUID, runID: UUID = UUID()) -> RunIdentity {
        let current = latestGenerationBySession[sessionID] ?? 0
        precondition(current < UInt64.max, "Session run generation exhausted")
        let next = current + 1
        latestGenerationBySession[sessionID] = next
        return RunIdentity(sessionID: sessionID, runID: runID, generation: next)
    }

    /// Prepare a scoped world, then atomically publish one root Agent.
    ///
    /// Concurrent candidates may all finish private preparation. Exactly one
    /// wins the final entry check; every prepared loser is rolled back before
    /// its structured collision error is returned.
    func register(
        identity: RunIdentity,
        maximumLiveRoots: Int? = nil,
        configure: Configuration
    ) async throws -> SessionRunRegistration {
        try Task.checkCancellation()
        if let maximumLiveRoots,
           entries.values.reduce(into: 0, { count, entry in
               if case .terminal = entry.phase { return }
               count += 1
           }) >= maximumLiveRoots {
            throw SessionRunRegistryError.rootRunLimitReached(limit: maximumLiveRoots)
        }
        if let existing = entries[identity.sessionID] {
            throw collision(existing: existing.identity, proposed: identity)
        }

        let prepared = try await configure()

        do {
            try Task.checkCancellation()
        } catch {
            await prepared.rollbackHandler()
            throw error
        }

        guard prepared.trajectorySessionID == identity.sessionID else {
            await prepared.rollbackHandler()
            throw SessionRunRegistryError.trajectorySessionMismatch(
                identity: identity,
                trajectorySessionID: prepared.trajectorySessionID
            )
        }

        if let existing = entries[identity.sessionID] {
            await prepared.rollbackHandler()
            throw collision(existing: existing.identity, proposed: identity)
        }
        if let maximumLiveRoots,
           entries.values.reduce(into: 0, { count, entry in
               if case .terminal = entry.phase { return }
               count += 1
           }) >= maximumLiveRoots {
            await prepared.rollbackHandler()
            throw SessionRunRegistryError.rootRunLimitReached(limit: maximumLiveRoots)
        }

        do {
            // DeepSeek Harness setup commits synchronously at the publication
            // boundary so mutable provider/tool/plugin provisioning can
            // revalidate after every asynchronous preparation step.
            try prepared.publicationCommitHandler()
        } catch {
            await prepared.rollbackHandler()
            throw error
        }

        let registrationID = UUID()
        let state = SessionRunState(
            identity: identity,
            initialMessages: prepared.initialMessages,
            initialQueuedInputs: prepared.initialQueuedInputs,
            questionContext: prepared.questionContext,
            presentationHandler: prepared.presentationHandler
        )
        let handle = MobileAgentHandle(
            identity: identity,
            deliveryHandler: { delivery in
                guard await state.receive(delivery, for: identity) else { return }
                await prepared.deliveryHandler(delivery)
            },
            cancellationHandler: {
                _ = await state.cancelTask(for: identity)
                await prepared.cancellationHandler()
            },
            quiescenceHandler: {
                _ = await state.awaitOwnedTask(for: identity)
                await prepared.quiescenceHandler()
            },
            terminalHandler: { identity, outcome in
                guard let claimedTokens = await self.claimTerminalResources(
                    registrationID: registrationID,
                    identity: identity,
                    outcome: outcome
                ) else {
                    return
                }
                _ = await state.finish(outcome, for: identity)
                await prepared.terminalCleanupHandler(identity, outcome, claimedTokens)
                await self.completeTerminalCleanup(
                    registrationID: registrationID,
                    identity: identity
                )
            }
        )
        let ordinal = nextRegistrationOrdinal
        nextRegistrationOrdinal += 1
        entries[identity.sessionID] = Entry(
            registrationID: registrationID,
            identity: identity,
            trajectorySessionID: prepared.trajectorySessionID,
            createdGeneration: identity.generation,
            registrationOrdinal: ordinal,
            handle: handle,
            state: state,
            phase: .idle,
            backgroundLeaseTokens: prepared.backgroundLeaseTokens,
            terminalCleanupClaimed: false
        )
        return SessionRunRegistration(identity: identity, handle: handle, state: state)
    }

    /// Read one exact generation. A stale identity cannot observe a replacement.
    func snapshot(for identity: RunIdentity) async -> SessionRunSnapshot? {
        guard let entry = entries[identity.sessionID], entry.identity == identity else {
            return nil
        }
        return await refreshedSnapshot(for: entry)
    }

    /// Read the current live root for a durable session without exposing its disposer.
    func lookup(sessionID: UUID) async -> SessionRunSnapshot? {
        guard let entry = entries[sessionID] else { return nil }
        return await refreshedSnapshot(for: entry)
    }

    /// Read the current presentation for a session without requiring the UI
    /// to already know that session's run identity.
    func presentation(sessionID: UUID) async -> SessionRunPresentation? {
        guard let entry = entries[sessionID] else { return nil }
        return await entry.state.snapshot()
    }

    func presentation(for identity: RunIdentity) async -> SessionRunPresentation? {
        guard let entry = try? requireExactEntry(identity) else { return nil }
        return await entry.state.snapshot()
    }

    @discardableResult
    func setPresentationUpdatesEnabled(
        _ enabled: Bool,
        for identity: RunIdentity
    ) async -> Bool {
        guard let entry = try? requireExactEntry(identity) else { return false }
        return await entry.state.setPresentationUpdatesEnabled(enabled, for: identity)
    }

    func messages(for identity: RunIdentity) async -> [AgentMessage]? {
        guard let entry = try? requireExactEntry(identity) else { return nil }
        return await entry.state.messages(for: identity)
    }

    func enqueue(
        text: String,
        disposition: QueuedInputDisposition,
        for identity: RunIdentity
    ) async throws -> QueuedAgentInput {
        let entry = try requireExactEntry(identity)
        return try await entry.state.enqueue(
            text: text,
            disposition: disposition,
            for: identity
        )
    }

    @discardableResult
    func updateQueuedInput(id: UUID, text: String, for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return try await entry.state.updateQueuedInput(id: id, text: text, for: identity)
    }

    @discardableResult
    func removeQueuedInput(id: UUID, for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.removeQueuedInput(id: id, for: identity)
    }

    @discardableResult
    func steerQueuedInput(id: UUID, for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return try await entry.state.steerQueuedInput(id: id, for: identity)
    }

    @discardableResult
    func steerAllQueuedInputs(for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.steerAllQueuedInputs(for: identity)
    }

    @discardableResult
    func resolveApproval(
        requestID: UUID,
        approved: Bool,
        for identity: RunIdentity
    ) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.resolveApproval(
            requestID: requestID,
            approved: approved,
            for: identity
        )
    }

    func requestApproval(
        _ request: ToolApprovalRequest,
        for identity: RunIdentity
    ) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        guard await entry.state.beginApproval(request, for: identity) else { return false }
        return await entry.state.awaitApproval(requestID: request.id, for: identity)
    }

    @discardableResult
    func setPendingQuestion(
        _ pending: ContinuationUserQuestionProvider.Pending?,
        for identity: RunIdentity
    ) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.setPendingQuestion(pending, for: identity)
    }

    func questionProvider(for identity: RunIdentity) throws -> ContinuationUserQuestionProvider {
        try requireExactEntry(identity).state.userQuestionProvider
    }

    func questionService(for identity: RunIdentity) throws -> UserQuestionService {
        try requireExactEntry(identity).state.userQuestionService
    }

    @discardableResult
    func installTask(_ task: Task<Void, Never>, for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.installTask(task, for: identity)
    }

    @discardableResult
    func startOwnedTask(
        for identity: RunIdentity,
        operation: @escaping @Sendable () async -> Void
    ) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.startOwnedTask(for: identity, operation: operation)
    }

    @discardableResult
    func prepareTrace(startSequence: UInt64, for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.prepareTrace(startSequence: startSequence, for: identity)
    }

    @discardableResult
    func advanceTrace(to cursor: UInt64, for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.advanceTrace(to: cursor, for: identity)
    }

    @discardableResult
    func startTraceRefresh(
        for identity: RunIdentity,
        operation: @escaping @Sendable () async -> Void
    ) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.startTraceRefresh(for: identity, operation: operation)
    }

    @discardableResult
    func clearTraceRefresh(for identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        return await entry.state.clearTraceRefresh(for: identity)
    }

    func promptStateSummary(for identity: RunIdentity) async throws -> String? {
        let entry = try requireExactEntry(identity)
        return await entry.state.currentPromptStateSummary(for: identity)
    }

    @discardableResult
    func finish(
        _ outcome: MobileAgentTerminalOutcome,
        for identity: RunIdentity
    ) async throws -> MobileAgentTerminalOutcome? {
        let entry = try requireExactEntry(identity)
        return await entry.handle.finish(outcome, for: identity)
    }

    func awaitQuiescence(for identity: RunIdentity) async throws {
        let entry = try requireExactEntry(identity)
        _ = await entry.state.awaitOwnedTask(for: identity)
    }

    /// Signal cancellation for one exact generation; terminal removal happens later.
    @discardableResult
    func cancel(_ identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        let accepted = await entry.handle.cancel()
        _ = await refreshedSnapshot(for: entry)
        return accepted
    }

    /// Signal an externally imposed interruption for one exact generation.
    /// Commit the terminal proposal before task cancellation so an iOS
    /// expiration cannot be durably misclassified as a user-requested stop.
    @discardableResult
    func interrupt(_ identity: RunIdentity) async throws -> Bool {
        let entry = try requireExactEntry(identity)
        _ = await entry.state.proposeTerminalOutcome(.interrupted, for: identity)
        let accepted = await entry.handle.cancel()
        _ = await refreshedSnapshot(for: entry)
        return accepted
    }

    /// Stop, drain, and remove one exact generation through its terminal owner.
    @discardableResult
    func dispose(_ identity: RunIdentity) async throws -> MobileAgentTerminalOutcome {
        let entry = try requireExactEntry(identity)
        return await entry.handle.dispose()
    }

    /// Deterministic registration-order projection for UI/background consumers.
    func aggregate() async -> SessionRunAggregateSnapshot {
        let captured = entries.values.sorted {
            $0.registrationOrdinal < $1.registrationOrdinal
        }
        var snapshots: [SessionRunSnapshot] = []
        snapshots.reserveCapacity(captured.count)
        for entry in captured {
            if let snapshot = await refreshedSnapshot(for: entry) {
                snapshots.append(snapshot)
            }
        }
        return SessionRunAggregateSnapshot(runs: snapshots)
    }

    /// Attach an opaque background resource only to the exact live generation.
    func addBackgroundLease(
        _ token: SessionRunBackgroundLeaseToken,
        to identity: RunIdentity
    ) throws {
        var entry = try requireExactEntry(identity)
        guard !entry.terminalCleanupClaimed else {
            throw SessionRunRegistryError.terminalRun(identity: identity)
        }
        entry.backgroundLeaseTokens.insert(token)
        entries[identity.sessionID] = entry
    }

    /// Release ownership of an already-ended lease without affecting the run.
    @discardableResult
    func removeBackgroundLease(
        _ token: SessionRunBackgroundLeaseToken,
        from identity: RunIdentity
    ) throws -> Bool {
        var entry = try requireExactEntry(identity)
        let removed = entry.backgroundLeaseTokens.remove(token) != nil
        entries[identity.sessionID] = entry
        return removed
    }

    /// Synchronous audit of registry-owned invariants.
    func invariantViolations() -> [SessionRunInvariantViolation] {
        entries.values
            .sorted { $0.registrationOrdinal < $1.registrationOrdinal }
            .flatMap { entry -> [SessionRunInvariantViolation] in
                var violations: [SessionRunInvariantViolation] = []
                if entry.identity.sessionID != entry.trajectorySessionID {
                    violations.append(.trajectorySessionMismatch(
                        identity: entry.identity,
                        trajectorySessionID: entry.trajectorySessionID
                    ))
                }
                if entry.identity.generation != entry.createdGeneration {
                    violations.append(.createdGenerationMismatch(
                        identity: entry.identity,
                        createdGeneration: entry.createdGeneration
                    ))
                }
                if case .terminal = entry.phase,
                   !entry.backgroundLeaseTokens.isEmpty {
                    violations.append(.terminalEntryRetainsBackgroundLeases(
                        identity: entry.identity,
                        tokens: entry.backgroundLeaseTokens
                    ))
                }
                return violations
            }
    }

    private func refreshedSnapshot(for captured: Entry) async -> SessionRunSnapshot? {
        let handleSnapshot = await captured.handle.snapshot()
        let presentation = await captured.state.snapshot()
        guard var current = entries[captured.identity.sessionID],
              current.registrationID == captured.registrationID else {
            return nil
        }

        // Only the terminal-owner callback may publish terminal state. It first
        // moves every lease token out of the entry, preserving the invariant
        // even if handle termination and registry observation race.
        if case .terminal = handleSnapshot.phase {
            // Wait for claimTerminalResources to publish the terminal phase.
        } else if !current.terminalCleanupClaimed {
            current.phase = handleSnapshot.phase
            entries[current.identity.sessionID] = current
        }
        return current.snapshot(presentation: presentation)
    }

    private func claimTerminalResources(
        registrationID: UUID,
        identity: RunIdentity,
        outcome: MobileAgentTerminalOutcome
    ) -> Set<SessionRunBackgroundLeaseToken>? {
        guard var entry = entries[identity.sessionID],
              entry.registrationID == registrationID,
              entry.identity == identity,
              !entry.terminalCleanupClaimed else {
            return nil
        }
        let claimed = entry.backgroundLeaseTokens
        entry.backgroundLeaseTokens.removeAll(keepingCapacity: false)
        entry.phase = .terminal(outcome)
        entry.terminalCleanupClaimed = true
        entries[identity.sessionID] = entry
        return claimed
    }

    private func completeTerminalCleanup(
        registrationID: UUID,
        identity: RunIdentity
    ) {
        guard let entry = entries[identity.sessionID],
              entry.registrationID == registrationID,
              entry.identity == identity,
              entry.terminalCleanupClaimed else {
            return
        }
        entries.removeValue(forKey: identity.sessionID)
    }

    private func requireExactEntry(_ identity: RunIdentity) throws -> Entry {
        guard let entry = entries[identity.sessionID] else {
            throw SessionRunRegistryError.runNotFound(sessionID: identity.sessionID)
        }
        guard entry.identity == identity else {
            throw SessionRunRegistryError.staleRunIdentity(
                expected: entry.identity,
                received: identity
            )
        }
        return entry
    }

    private func collision(
        existing: RunIdentity,
        proposed: RunIdentity
    ) -> SessionRunRegistryError {
        .sessionAlreadyHasLiveRoot(
            sessionID: proposed.sessionID,
            existing: existing,
            proposed: proposed
        )
    }
}
