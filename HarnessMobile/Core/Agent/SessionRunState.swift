import Foundation

struct SessionRunTraceKey: Sendable, Equatable {
    let sessionID: UUID
    let runID: UUID
    let startSequence: UInt64
    var cursor: UInt64
}

/// Immutable projection of all mutable state owned by one root run.
///
/// App/UI consumers receive this value snapshot; the task, continuations,
/// timers and buffers that produce it never leave `SessionRunState`.
struct SessionRunPresentation: Sendable, Equatable {
    let identity: RunIdentity
    var revision: UInt64
    var phase: MobileAgentPhase
    var runStartedAt: Date?
    var currentStep: Int
    var activeContextInjections: [AgentContextInjection]
    var activeToolStatus: String?
    var activeToolEvents: [AgentToolEvent]
    var pendingApproval: ToolApprovalRequest?
    var pendingUserQuestion: ContinuationUserQuestionProvider.Pending?
    var queuedInputs: [QueuedAgentInput]
    var streamingText: String
    var streamingReasoning: String
    var streamingPresentationRevision: UInt64
    var latestUsage: ModelTokenUsage?
    var continuedProcessingSubmission: ContinuedProcessingSubmission?
    var lastBackgroundEvent: String
    var backgroundRuntimeStatus: BackgroundRuntimeStatus
    var traceKey: SessionRunTraceKey?
    var staleCallbackCount: UInt64
    var hasOwnedTask: Bool

    init(
        identity: RunIdentity,
        queuedInputs: [QueuedAgentInput] = []
    ) {
        self.identity = identity
        revision = 0
        phase = .idle
        runStartedAt = nil
        currentStep = 0
        activeContextInjections = []
        activeToolStatus = nil
        activeToolEvents = []
        pendingApproval = nil
        pendingUserQuestion = nil
        self.queuedInputs = queuedInputs
        streamingText = ""
        streamingReasoning = ""
        streamingPresentationRevision = 0
        latestUsage = nil
        continuedProcessingSubmission = nil
        lastBackgroundEvent = "idle"
        backgroundRuntimeStatus = .idle
        traceKey = nil
        staleCallbackCount = 0
        hasOwnedTask = false
    }
}

enum SessionRunStateError: Error, Sendable, Equatable {
    case staleRunIdentity(expected: RunIdentity, received: RunIdentity)
    case terminalRun(identity: RunIdentity)
    case taskAlreadyInstalled(identity: RunIdentity)
}

/// Per-run question capability prepared before registry publication so the
/// tool catalog and the run state share one provider without an app-global
/// continuation slot.
struct SessionRunQuestionContext: Sendable {
    let provider: ContinuationUserQuestionProvider
    let service: UserQuestionService

    init() {
        let provider = ContinuationUserQuestionProvider()
        self.provider = provider
        service = UserQuestionService(provider: provider)
    }
}

/// Actor-owned mutable world for one root Agent generation.
///
/// The registry owns this actor and only the successful registration receives
/// its mutation capability. Every callback supplies the complete identity;
/// an old generation is counted and rejected before touching current state.
actor SessionRunState {
    typealias PresentationHandler = @Sendable (SessionRunPresentation) async -> Void

    private static let maximumPresentedStreamingCharacters = 8_000
    private static let maximumPresentedReasoningCharacters = 4_000

    private struct PendingToolPresentation: Sendable {
        var replacement: AgentToolEvent?
        var outputByCallID: [String: [AgentToolOutputChunk]] = [:]

        mutating func replace(with event: AgentToolEvent) {
            replacement = event
            // A replacement may describe the same call while output chunks
            // are still waiting for the presentation batch. Filter only
            // chunks already represented by the replacement event.
            let replacementChunkIDs = Self.outputChunkIDs(in: event)
            outputByCallID = outputByCallID.compactMapValues { chunks in
                let retained = chunks.filter { !replacementChunkIDs.contains($0.id) }
                return retained.isEmpty ? nil : retained
            }
        }

        private static func outputChunkIDs(in event: AgentToolEvent) -> Set<UUID> {
            var ids = Set(event.output.map(\.id))
            for child in event.children {
                ids.formUnion(outputChunkIDs(in: child))
            }
            return ids
        }

        mutating func discardReplacement() {
            replacement = nil
        }

        mutating func append(callID: String, chunk: AgentToolOutputChunk) {
            var output = outputByCallID[callID, default: []]
            AgentToolEvent.appendOutput(chunk, to: &output)
            outputByCallID[callID] = output
        }
    }

    private struct ApprovalSlot {
        let request: ToolApprovalRequest
        var waiters: [CheckedContinuation<Bool, Never>] = []
    }

    nonisolated let identity: RunIdentity
    nonisolated let userQuestionProvider: ContinuationUserQuestionProvider
    nonisolated let userQuestionService: UserQuestionService

    private let presentationHandler: PresentationHandler
    private var presentation: SessionRunPresentation
    private var inboxControlState: ConversationControlState
    private var runTask: Task<Void, Never>?
    private var questionMonitorTask: Task<Void, Never>?
    private var streamingPresentationTask: Task<Void, Never>?
    private var activeToolPresentationTask: Task<Void, Never>?
    private var traceRefreshTask: Task<Void, Never>?
    private var presentationUpdatesEnabled = true
    private var suppressedPresentationMutation = false
    private var pendingStreamingText = ""
    private var pendingStreamingReasoning = ""
    private var streamingPresentationByteCount = 0
    private var pendingToolPresentations: [String: PendingToolPresentation] = [:]
    private var approvalSlot: ApprovalSlot?
    private var completedApprovalDecisions: [UUID: Bool] = [:]
    private var promptStateSummary: String?
    private var proposedTerminalOutcome: MobileAgentTerminalOutcome?
    private var committedMessages: [AgentMessage]

    init(
        identity: RunIdentity,
        initialMessages: [AgentMessage] = [],
        initialQueuedInputs: [QueuedAgentInput] = [],
        questionContext: SessionRunQuestionContext = SessionRunQuestionContext(),
        presentationHandler: @escaping PresentationHandler = { _ in }
    ) {
        self.identity = identity
        self.presentationHandler = presentationHandler
        presentation = SessionRunPresentation(
            identity: identity,
            queuedInputs: initialQueuedInputs
        )
        inboxControlState = ConversationControlState(queuedInputs: initialQueuedInputs)
        userQuestionProvider = questionContext.provider
        userQuestionService = questionContext.service
        committedMessages = initialMessages
    }

    func snapshot() -> SessionRunPresentation {
        presentation
    }

    /// Stops publishing high-frequency UI projections while the scene is
    /// inactive/backgrounded. Runtime state and durable trajectory writes
    /// continue; re-enabling performs one coalesced flush.
    @discardableResult
    func setPresentationUpdatesEnabled(
        _ enabled: Bool,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard presentationUpdatesEnabled != enabled else { return false }
        presentationUpdatesEnabled = enabled
        if !enabled {
            streamingPresentationTask?.cancel()
            streamingPresentationTask = nil
            activeToolPresentationTask?.cancel()
            activeToolPresentationTask = nil
            return true
        }

        let streamingChanged = flushStreamingState()
        let toolChanged = flushToolPresentationState()
        if streamingChanged || toolChanged || suppressedPresentationMutation {
            suppressedPresentationMutation = false
            presentation.revision &+= 1
            await presentationHandler(presentation)
        }
        return true
    }

    @discardableResult
    func markRunning(
        for callbackIdentity: RunIdentity,
        startedAt: Date = .now
    ) async -> Bool {
        guard await accept(callbackIdentity) else { return false }
        guard !isTerminal else { return false }
        presentation.phase = .running
        presentation.runStartedAt = startedAt
        await publishMutation()
        return true
    }

    @discardableResult
    func installTask(
        _ task: Task<Void, Never>,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity) else {
            task.cancel()
            return false
        }
        guard !isTerminal, runTask == nil else {
            task.cancel()
            return false
        }
        runTask = task
        presentation.hasOwnedTask = true
        await publishMutation()
        return true
    }

    /// Creates and publishes the root task while still isolated to this actor.
    /// This removes the window where a caller-created task could finish before
    /// the state had recorded ownership of it.
    @discardableResult
    func startOwnedTask(
        for callbackIdentity: RunIdentity,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal, runTask == nil else {
            return false
        }
        let task = Task {
            await operation()
        }
        runTask = task
        presentation.hasOwnedTask = true
        await publishMutation()
        return true
    }

    @discardableResult
    func startQuestionMonitor(
        for callbackIdentity: RunIdentity,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal, questionMonitorTask == nil else {
            return false
        }
        questionMonitorTask = Task {
            await operation()
        }
        return true
    }

    @discardableResult
    func startTraceRefresh(
        for callbackIdentity: RunIdentity,
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal, traceRefreshTask == nil else {
            return false
        }
        traceRefreshTask = Task {
            await operation()
        }
        return true
    }

    @discardableResult
    func clearTraceRefresh(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity), traceRefreshTask != nil else { return false }
        traceRefreshTask = nil
        return true
    }

    func setPromptStateSummary(
        _ summary: String?,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        promptStateSummary = summary
        return true
    }

    func currentPromptStateSummary(for callbackIdentity: RunIdentity) async -> String? {
        guard await accept(callbackIdentity), !isTerminal else { return nil }
        return promptStateSummary
    }

    /// Records the runtime's terminal proposal without publishing terminal
    /// state. System expiration may upgrade an ordinary cancellation to an
    /// interruption, but late callbacks cannot overwrite success or failure.
    @discardableResult
    func proposeTerminalOutcome(
        _ outcome: MobileAgentTerminalOutcome,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        switch (proposedTerminalOutcome, outcome) {
        case (nil, _):
            proposedTerminalOutcome = outcome
            return true
        case (.some(.cancelled), .interrupted):
            proposedTerminalOutcome = .interrupted
            return true
        default:
            return false
        }
    }

    func terminalOutcomeProposal(
        for callbackIdentity: RunIdentity
    ) async -> MobileAgentTerminalOutcome? {
        guard await accept(callbackIdentity), !isTerminal else { return nil }
        return proposedTerminalOutcome
    }

    @discardableResult
    func clearTask(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity) else { return false }
        guard runTask != nil else { return false }
        runTask = nil
        presentation.hasOwnedTask = false
        await publishMutation()
        return true
    }

    @discardableResult
    func cancelTask(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity) else { return false }
        guard let runTask, !runTask.isCancelled else { return false }
        runTask.cancel()
        if !isTerminal {
            presentation.phase = .cancelling
        }
        await publishMutation()
        return true
    }

    func awaitOwnedTask(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity) else { return false }
        let task = runTask
        await task?.value
        return task != nil
    }

    @discardableResult
    func receive(
        _ delivery: MobileAgentDelivery,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        do {
            var input = delivery.input
            switch delivery.kind {
            case .followup:
                input.disposition = .queued
            case .steer:
                input.disposition = .steer
            case .inject:
                break
            }
            try inboxControlState.enqueue(input)
            presentation.queuedInputs = inboxControlState.queuedInputs
            await publishMutation()
            return true
        } catch {
            return false
        }
    }

    func enqueue(
        text: String,
        disposition: QueuedInputDisposition,
        for callbackIdentity: RunIdentity
    ) async throws -> QueuedAgentInput {
        try requireCurrent(callbackIdentity)
        guard !isTerminal else { throw SessionRunStateError.terminalRun(identity: identity) }
        let input = try inboxControlState.enqueue(text, disposition: disposition)
        presentation.queuedInputs = inboxControlState.queuedInputs
        await publishMutation()
        return input
    }

    @discardableResult
    func updateQueuedInput(
        id: UUID,
        text: String,
        for callbackIdentity: RunIdentity
    ) async throws -> Bool {
        try requireCurrent(callbackIdentity)
        try inboxControlState.update(id: id, text: text)
        presentation.queuedInputs = inboxControlState.queuedInputs
        await publishMutation()
        return true
    }

    @discardableResult
    func removeQueuedInput(
        id: UUID,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard inboxControlState.remove(id: id) else { return false }
        presentation.queuedInputs = inboxControlState.queuedInputs
        await publishMutation()
        return true
    }

    @discardableResult
    func steerQueuedInput(
        id: UUID,
        for callbackIdentity: RunIdentity
    ) async throws -> Bool {
        try requireCurrent(callbackIdentity)
        try inboxControlState.setDisposition(id: id, disposition: .steer)
        presentation.queuedInputs = inboxControlState.queuedInputs
        await publishMutation()
        return true
    }

    @discardableResult
    func steerAllQueuedInputs(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal,
              !inboxControlState.queuedInputs.isEmpty else { return false }
        inboxControlState.steerAll()
        presentation.queuedInputs = inboxControlState.queuedInputs
        await publishMutation()
        return true
    }

    func nextQueuedInput(
        at boundary: QueuedInputBoundary,
        for callbackIdentity: RunIdentity
    ) async -> QueuedAgentInput? {
        guard await accept(callbackIdentity), !isTerminal else { return nil }
        switch boundary {
        case .nextStep:
            return inboxControlState.queuedInputs.first { $0.disposition == .steer }
        case .turnStopping:
            return inboxControlState.queuedInputs.first
        }
    }

    @discardableResult
    func claimQueuedInput(
        id: UUID,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard inboxControlState.remove(id: id) else { return false }
        presentation.queuedInputs = inboxControlState.queuedInputs
        await publishMutation()
        return true
    }

    @discardableResult
    func beginApproval(
        _ request: ToolApprovalRequest,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        if let previous = approvalSlot {
            if previous.waiters.isEmpty {
                completedApprovalDecisions[previous.request.id] = false
            }
            previous.waiters.forEach { $0.resume(returning: false) }
        }
        approvalSlot = ApprovalSlot(request: request)
        presentation.pendingApproval = request
        await publishMutation()
        return true
    }

    func awaitApproval(
        requestID: UUID,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        if let completed = completedApprovalDecisions.removeValue(forKey: requestID) {
            return completed
        }
        guard approvalSlot?.request.id == requestID else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard approvalSlot?.request.id == requestID else {
                    continuation.resume(returning: false)
                    return
                }
                approvalSlot?.waiters.append(continuation)
            }
        } onCancel: {
            Task { [weak self] in
                _ = await self?.resolveApproval(
                    requestID: requestID,
                    approved: false,
                    for: callbackIdentity
                )
            }
        }
    }

    @discardableResult
    func resolveApproval(
        requestID: UUID,
        approved: Bool,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity) else { return false }
        guard let slot = approvalSlot, slot.request.id == requestID else { return false }
        approvalSlot = nil
        presentation.pendingApproval = nil
        if slot.waiters.isEmpty {
            completedApprovalDecisions[requestID] = approved
        }
        slot.waiters.forEach { $0.resume(returning: approved) }
        await publishMutation()
        return true
    }

    @discardableResult
    func setPendingQuestion(
        _ pending: ContinuationUserQuestionProvider.Pending?,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard presentation.pendingUserQuestion != pending else { return true }
        presentation.pendingUserQuestion = pending
        await publishMutation()
        return true
    }

    @discardableResult
    func apply(
        _ event: AgentRuntimeEvent,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        switch event {
        case let .stepStarted(step):
            presentation.currentStep = step
            resetStreamingState()
            if let status = try? ContinuedProcessingStatus(
                title: "Harness 正在执行",
                subtitle: "第 \(step) 步 · 持续执行",
                completedUnitCount: Int64(clamping: max(0, step - 1)),
                totalUnitCount: max(1, Int64(clamping: step))
            ) {
                presentation.backgroundRuntimeStatus = .running(status)
            }
        case let .contextInjected(injection):
            if let index = presentation.activeContextInjections.firstIndex(where: {
                $0.sourceLabel == injection.sourceLabel && $0.form == injection.form
            }) {
                let existingID = presentation.activeContextInjections[index].id
                presentation.activeContextInjections[index] = AgentContextInjection(
                    id: existingID,
                    sourceLabel: injection.sourceLabel,
                    content: injection.content,
                    form: injection.form,
                    turn: injection.turn,
                    step: injection.step
                )
            } else {
                presentation.activeContextInjections.append(injection)
                if presentation.activeContextInjections.count > 16 {
                    presentation.activeContextInjections.removeFirst(
                        presentation.activeContextInjections.count - 16
                    )
                }
            }
        case let .textDelta(delta):
            guard !delta.isEmpty else { return true }
            pendingStreamingText += delta
            scheduleStreamingPresentation()
            return true
        case let .reasoningDelta(delta):
            guard !delta.isEmpty else { return true }
            pendingStreamingReasoning += delta
            scheduleStreamingPresentation()
            return true
        case let .messagesCommitted(messages):
            committedMessages.append(contentsOf: messages)
            for message in messages where message.role == .user {
                _ = inboxControlState.remove(id: message.id)
            }
            presentation.queuedInputs = inboxControlState.queuedInputs
            resetStreamingState()
            presentation.activeToolStatus = nil
            resetToolPresentationState()
        case let .toolEventChanged(event):
            guard upsertToolEvent(event) else { return true }
        case let .toolOutput(callID, chunk):
            appendToolOutput(callID: callID, chunk: chunk)
            return true
        case let .toolStarted(call, summary):
            presentation.activeToolStatus = "\(call.name)：\(summary)"
        case .toolFinished:
            presentation.activeToolStatus = nil
        case let .usage(usage):
            presentation.latestUsage = usage
        }
        await publishMutation()
        return true
    }

    func messages(for callbackIdentity: RunIdentity) async -> [AgentMessage]? {
        guard await accept(callbackIdentity) else { return nil }
        return committedMessages
    }

    @discardableResult
    func flushPresentation(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard presentationUpdatesEnabled else { return false }
        streamingPresentationTask?.cancel()
        streamingPresentationTask = nil
        let changed = flushStreamingState()
        if changed {
            await publishMutation()
        }
        return changed
    }

    @discardableResult
    func flushToolPresentation(for callbackIdentity: RunIdentity) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard presentationUpdatesEnabled else { return false }
        activeToolPresentationTask?.cancel()
        activeToolPresentationTask = nil
        let changed = flushToolPresentationState()
        if changed {
            await publishMutation()
        }
        return changed
    }

    @discardableResult
    func updateBackground(
        status: BackgroundRuntimeStatus,
        submission: ContinuedProcessingSubmission?,
        event: String,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        presentation.backgroundRuntimeStatus = status
        presentation.continuedProcessingSubmission = submission
        presentation.lastBackgroundEvent = event
        await publishMutation()
        return true
    }

    @discardableResult
    func prepareTrace(
        startSequence: UInt64,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        traceRefreshTask?.cancel()
        traceRefreshTask = nil
        presentation.traceKey = SessionRunTraceKey(
            sessionID: identity.sessionID,
            runID: identity.runID,
            startSequence: startSequence,
            cursor: startSequence
        )
        await publishMutation()
        return true
    }

    @discardableResult
    func advanceTrace(
        to cursor: UInt64,
        for callbackIdentity: RunIdentity
    ) async -> Bool {
        guard await accept(callbackIdentity), !isTerminal else { return false }
        guard var key = presentation.traceKey else { return false }
        key.cursor = max(key.cursor, cursor)
        presentation.traceKey = key
        await publishMutation()
        return true
    }

    @discardableResult
    func finish(
        _ outcome: MobileAgentTerminalOutcome,
        for callbackIdentity: RunIdentity
    ) async -> SessionRunPresentation {
        guard await accept(callbackIdentity) else { return presentation }
        if case .terminal = presentation.phase { return presentation }

        // Ordinary terminal outcomes are published by the root task itself.
        // Only disposal is an external teardown that must cancel that task here.
        if outcome == .disposed {
            runTask?.cancel()
        }
        questionMonitorTask?.cancel()
        streamingPresentationTask?.cancel()
        activeToolPresentationTask?.cancel()
        traceRefreshTask?.cancel()
        runTask = nil
        questionMonitorTask = nil
        streamingPresentationTask = nil
        activeToolPresentationTask = nil
        traceRefreshTask = nil

        if let slot = approvalSlot {
            if slot.waiters.isEmpty {
                completedApprovalDecisions[slot.request.id] = false
            }
            slot.waiters.forEach { $0.resume(returning: false) }
            approvalSlot = nil
        }
        let pendingQuestionID = presentation.pendingUserQuestion?.id
        presentation.phase = .terminal(outcome)
        presentation.runStartedAt = nil
        presentation.pendingApproval = nil
        presentation.pendingUserQuestion = nil
        presentation.hasOwnedTask = false
        presentation.activeToolStatus = nil
        resetStreamingState()
        resetToolPresentationState()
        promptStateSummary = nil
        proposedTerminalOutcome = nil
        if let pendingQuestionID {
            try? await userQuestionProvider.cancel(requestID: pendingQuestionID)
        }
        await publishMutation()
        return presentation
    }

    private var isTerminal: Bool {
        if case .terminal = presentation.phase { return true }
        return false
    }

    private func requireCurrent(_ callbackIdentity: RunIdentity) throws {
        guard identity.accepts(callbackIdentity) else {
            presentation.staleCallbackCount &+= 1
            presentation.revision &+= 1
            throw SessionRunStateError.staleRunIdentity(
                expected: identity,
                received: callbackIdentity
            )
        }
    }

    private func accept(_ callbackIdentity: RunIdentity) async -> Bool {
        guard identity.accepts(callbackIdentity) else {
            presentation.staleCallbackCount &+= 1
            await publishMutation()
            return false
        }
        return true
    }

    private func publishMutation() async {
        guard presentationUpdatesEnabled else {
            suppressedPresentationMutation = true
            return
        }
        presentation.revision &+= 1
        await presentationHandler(presentation)
    }

    private func scheduleStreamingPresentation() {
        guard presentationUpdatesEnabled else { return }
        guard streamingPresentationTask == nil else { return }
        let pendingBytes = pendingStreamingText.utf8.count + pendingStreamingReasoning.utf8.count
        let interval = Self.streamingPresentationInterval(
            forByteCount: streamingPresentationByteCount + pendingBytes
        )
        streamingPresentationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.flushPresentation(for: self.identity)
        }
    }

    private func flushStreamingState() -> Bool {
        var changed = false
        if !pendingStreamingText.isEmpty {
            streamingPresentationByteCount += pendingStreamingText.utf8.count
            presentation.streamingText = Self.boundedStreamingTail(
                presentation.streamingText + pendingStreamingText,
                maximumCharacters: Self.maximumPresentedStreamingCharacters,
                marker: "[earlier streaming text hidden]\n"
            )
            pendingStreamingText.removeAll(keepingCapacity: true)
            changed = true
        }
        if !pendingStreamingReasoning.isEmpty {
            streamingPresentationByteCount += pendingStreamingReasoning.utf8.count
            presentation.streamingReasoning = Self.boundedStreamingTail(
                presentation.streamingReasoning + pendingStreamingReasoning,
                maximumCharacters: Self.maximumPresentedReasoningCharacters,
                marker: "[earlier reasoning hidden]\n"
            )
            pendingStreamingReasoning.removeAll(keepingCapacity: true)
            changed = true
        }
        if changed {
            presentation.streamingPresentationRevision &+= 1
        }
        return changed
    }

    private func resetStreamingState() {
        streamingPresentationTask?.cancel()
        streamingPresentationTask = nil
        pendingStreamingText.removeAll(keepingCapacity: true)
        pendingStreamingReasoning.removeAll(keepingCapacity: true)
        streamingPresentationByteCount = 0
        presentation.streamingText = ""
        presentation.streamingReasoning = ""
    }

    private func upsertToolEvent(_ event: AgentToolEvent) -> Bool {
        if event.status == .running,
           presentation.activeToolEvents.contains(where: { $0.callID == event.callID }) {
            var pending = pendingToolPresentations[event.callID, default: .init()]
            pending.replace(with: event)
            pendingToolPresentations[event.callID] = pending
            scheduleToolPresentation()
            return false
        }
        if var pending = pendingToolPresentations[event.callID] {
            // A terminal event must supersede a queued running replacement, but
            // its batched output still belongs to the event being applied now.
            pending.discardReplacement()
            pendingToolPresentations[event.callID] = pending
        }
        applyToolEvent(event)
        if pendingToolPresentations[event.callID] != nil {
            scheduleToolPresentation()
        } else if pendingToolPresentations.isEmpty {
            activeToolPresentationTask?.cancel()
            activeToolPresentationTask = nil
        }
        return true
    }

    private func applyToolEvent(_ event: AgentToolEvent) {
        for index in presentation.activeToolEvents.indices {
            if presentation.activeToolEvents[index].replaceRecursively(event) {
                return
            }
        }
        presentation.activeToolEvents.append(event)
    }

    private func appendToolOutput(callID: String, chunk: AgentToolOutputChunk) {
        let rootCallID = pendingToolPresentations.first(where: { _, pending in
            pending.replacement?.containsRecursively(callID: callID) == true
        })?.key ?? presentation.activeToolEvents.first(where: {
            $0.containsRecursively(callID: callID)
        })?.callID ?? callID
        var pending = pendingToolPresentations[rootCallID, default: .init()]
        pending.append(callID: callID, chunk: chunk)
        pendingToolPresentations[rootCallID] = pending
        scheduleToolPresentation()
    }

    private func scheduleToolPresentation() {
        guard presentationUpdatesEnabled else { return }
        guard activeToolPresentationTask == nil else { return }
        activeToolPresentationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.flushToolPresentation(for: self.identity)
        }
    }

    private func flushToolPresentationState() -> Bool {
        guard !pendingToolPresentations.isEmpty else { return false }
        let pending = pendingToolPresentations
        pendingToolPresentations.removeAll(keepingCapacity: true)
        var changed = false
        for rootCallID in pending.keys.sorted() {
            guard var item = pending[rootCallID] else { continue }
            if let replacement = item.replacement {
                applyToolEvent(replacement)
                item.discardReplacement()
                changed = true
            }
            for callID in item.outputByCallID.keys.sorted() {
                guard let chunks = item.outputByCallID[callID] else { continue }
                var wasAppended = false
                for chunk in chunks {
                    for index in presentation.activeToolEvents.indices {
                        if presentation.activeToolEvents[index].appendOutputRecursively(
                            callID: callID,
                            chunk: chunk
                        ) {
                            wasAppended = true
                            changed = true
                            break
                        }
                    }
                }
                if wasAppended {
                    item.outputByCallID.removeValue(forKey: callID)
                }
            }
            if item.replacement != nil || !item.outputByCallID.isEmpty {
                // Tool output may arrive ahead of its event. Retain it rather
                // than treating a presentation-only timing race as data loss.
                pendingToolPresentations[rootCallID] = item
            }
        }
        return changed
    }

    private func resetToolPresentationState() {
        activeToolPresentationTask?.cancel()
        activeToolPresentationTask = nil
        pendingToolPresentations.removeAll(keepingCapacity: true)
        presentation.activeToolEvents = []
    }

    private static func streamingPresentationInterval(forByteCount byteCount: Int) -> Duration {
        if byteCount < 8 * 1_024 { return .milliseconds(66) }
        if byteCount < 32 * 1_024 { return .milliseconds(100) }
        return .milliseconds(160)
    }

    private static func boundedStreamingTail(
        _ text: String,
        maximumCharacters: Int,
        marker: String
    ) -> String {
        guard text.count > maximumCharacters else { return text }
        return marker + String(text.suffix(maximumCharacters))
    }
}
