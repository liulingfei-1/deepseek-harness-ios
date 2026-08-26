import Foundation

enum ContinuedProcessingValidationError: Error, Equatable, Sendable {
    case invalidIdentifierPrefix
    case invalidProgress
}

struct ContinuedProcessingIdentifiers: Equatable, Sendable {
    let prefix: String

    var permittedIdentifier: String {
        prefix + ".*"
    }

    init(prefix: String) throws {
        let normalizedPrefix: String
        if prefix.hasSuffix(".*") {
            normalizedPrefix = String(prefix.dropLast(2))
        } else {
            normalizedPrefix = prefix
        }
        guard !normalizedPrefix.isEmpty,
              !normalizedPrefix.hasSuffix("."),
              !normalizedPrefix.contains(where: \Character.isWhitespace) else {
            throw ContinuedProcessingValidationError.invalidIdentifierPrefix
        }
        self.prefix = normalizedPrefix
    }

    func requestIdentifier(for runID: UUID) -> String {
        prefix + "." + runID.uuidString.lowercased()
    }
}

struct ContinuedProcessingStatus: Equatable, Sendable {
    let title: String
    let subtitle: String
    let completedUnitCount: Int64
    let totalUnitCount: Int64

    init(
        title: String,
        subtitle: String,
        completedUnitCount: Int64,
        totalUnitCount: Int64
    ) throws {
        guard totalUnitCount > 0,
              completedUnitCount >= 0,
              completedUnitCount <= totalUnitCount else {
            throw ContinuedProcessingValidationError.invalidProgress
        }

        self.title = title
        self.subtitle = subtitle
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

enum ContinuedProcessingCancellationReason: Equatable, Sendable {
    case user
    case systemExpiration
    case operationCancellation
}

struct ContinuedProcessingRunDescriptor: Equatable, Sendable {
    let id: UUID
    let identity: RunIdentity?
    let requestIdentifier: String
    var status: ContinuedProcessingStatus

    init(
        id: UUID,
        requestIdentifier: String,
        status: ContinuedProcessingStatus
    ) {
        self.id = id
        identity = nil
        self.requestIdentifier = requestIdentifier
        self.status = status
    }

    init(
        identity: RunIdentity,
        requestIdentifier: String,
        status: ContinuedProcessingStatus
    ) {
        id = identity.runID
        self.identity = identity
        self.requestIdentifier = requestIdentifier
        self.status = status
    }
}

enum ContinuedProcessingRunPhase: Equatable, Sendable {
    case running
    case finished(success: Bool)
    case cancelled(ContinuedProcessingCancellationReason)
}

struct ContinuedProcessingRunState: Equatable, Sendable {
    var descriptor: ContinuedProcessingRunDescriptor
    var phase: ContinuedProcessingRunPhase
    var isSystemTaskAttached: Bool
    var isSystemTaskCompleted: Bool
    var isCancellationCallbackDelivered: Bool
}

enum ContinuedProcessingStateMachineEffect: Equatable, Sendable {
    case updateSystemTask(ContinuedProcessingStatus)
    case startWorker
    case completeSystemTask(success: Bool)
    case cancelPendingRequest(identifier: String)
    case invokeCancellation(ContinuedProcessingCancellationReason)
}

struct ContinuedProcessingStateMachine: Sendable {
    private(set) var currentRun: ContinuedProcessingRunState?

    var hasActiveRun: Bool {
        currentRun?.phase == .running
    }

    mutating func begin(_ descriptor: ContinuedProcessingRunDescriptor) -> Bool {
        guard !hasActiveRun else { return false }
        currentRun = ContinuedProcessingRunState(
            descriptor: descriptor,
            phase: .running,
            isSystemTaskAttached: false,
            isSystemTaskCompleted: false,
            isCancellationCallbackDelivered: false
        )
        return true
    }

    func canAttachSystemTask(identifier: String) -> Bool {
        guard let currentRun else { return false }
        return currentRun.descriptor.requestIdentifier == identifier
            && !currentRun.isSystemTaskAttached
    }

    mutating func attachSystemTask(identifier: String) -> [ContinuedProcessingStateMachineEffect] {
        guard var run = currentRun,
              run.descriptor.requestIdentifier == identifier,
              !run.isSystemTaskAttached else {
            return []
        }

        run.isSystemTaskAttached = true
        switch run.phase {
        case .running:
            currentRun = run
            return [.updateSystemTask(run.descriptor.status), .startWorker]
        case let .finished(success):
            run.isSystemTaskCompleted = true
            currentRun = run
            return [.completeSystemTask(success: success)]
        case .cancelled:
            run.isSystemTaskCompleted = true
            currentRun = run
            return [.completeSystemTask(success: false)]
        }
    }

    mutating func report(
        runID: UUID,
        status: ContinuedProcessingStatus
    ) -> [ContinuedProcessingStateMachineEffect] {
        guard var run = currentRun,
              run.descriptor.id == runID,
              run.phase == .running else {
            return []
        }

        run.descriptor.status = status
        currentRun = run
        guard run.isSystemTaskAttached, !run.isSystemTaskCompleted else { return [] }
        return [.updateSystemTask(status)]
    }

    mutating func finish(
        runID: UUID,
        success: Bool
    ) -> [ContinuedProcessingStateMachineEffect] {
        guard var run = currentRun,
              run.descriptor.id == runID,
              run.phase == .running else {
            return []
        }

        run.phase = .finished(success: success)
        if run.isSystemTaskAttached {
            run.isSystemTaskCompleted = true
            currentRun = run
            return [.completeSystemTask(success: success)]
        }

        currentRun = run
        return [.cancelPendingRequest(identifier: run.descriptor.requestIdentifier)]
    }

    mutating func cancel(
        runID: UUID,
        reason: ContinuedProcessingCancellationReason
    ) -> [ContinuedProcessingStateMachineEffect] {
        guard var run = currentRun,
              run.descriptor.id == runID,
              run.phase == .running else {
            return []
        }

        run.phase = .cancelled(reason)
        var effects: [ContinuedProcessingStateMachineEffect] = []
        if !run.isCancellationCallbackDelivered {
            run.isCancellationCallbackDelivered = true
            effects.append(.invokeCancellation(reason))
        }
        if run.isSystemTaskAttached {
            run.isSystemTaskCompleted = true
            effects.append(.completeSystemTask(success: false))
        } else {
            effects.append(.cancelPendingRequest(identifier: run.descriptor.requestIdentifier))
        }
        currentRun = run
        return effects
    }
}

struct ContinuedProcessingContext: Sendable {
    let runID: UUID
    private let reporter: @Sendable (ContinuedProcessingStatus) async -> Void

    init(
        runID: UUID,
        reporter: @escaping @Sendable (ContinuedProcessingStatus) async -> Void
    ) {
        self.runID = runID
        self.reporter = reporter
    }

    func report(_ status: ContinuedProcessingStatus) async {
        await reporter(status)
    }
}

enum ContinuedProcessingSubmission: Equatable, Sendable {
    case submitted
    case unavailable
    case registrationRejected
    case failed(message: String)
}

enum ContinuedProcessingRunCompletionOutcome: Equatable, Sendable {
    case operationFinished(cancellationReason: ContinuedProcessingCancellationReason?)
    case cancelledBeforeStart(ContinuedProcessingCancellationReason)
}

/// One-shot completion signal shared by the OS-owned worker and the
/// registry-owned root task. Waiting on this signal keeps terminal cleanup
/// behind the real runtime exit, including the queued-before-system-handoff
/// case where no worker was ever started.
actor ContinuedProcessingRunCompletion {
    private var outcome: ContinuedProcessingRunCompletionOutcome?
    private var waiters: [CheckedContinuation<ContinuedProcessingRunCompletionOutcome, Never>] = []

    func resolve(_ proposed: ContinuedProcessingRunCompletionOutcome) {
        guard outcome == nil else { return }
        outcome = proposed
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume(returning: proposed) }
    }

    func wait() async -> ContinuedProcessingRunCompletionOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation in
            if let outcome {
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
            }
        }
    }
}

struct ContinuedProcessingRunHandle: Sendable, Equatable {
    let id: UUID
    let identity: RunIdentity?
    let requestIdentifier: String
    let submission: ContinuedProcessingSubmission
    let completion: ContinuedProcessingRunCompletion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.identity == rhs.identity
            && lhs.requestIdentifier == rhs.requestIdentifier
            && lhs.submission == rhs.submission
    }
}

/// Keeps one independent state machine per run while preserving the strict
/// single-run transition contract inside `ContinuedProcessingStateMachine`.
/// This is the controller's ownership boundary; a process may have multiple
/// sessions waiting for or attached to Continued Processing simultaneously.
struct ContinuedProcessingRunBook: Sendable {
    private var machines: [UUID: ContinuedProcessingStateMachine] = [:]

    var hasActiveRun: Bool {
        machines.values.contains { $0.hasActiveRun }
    }

    func contains(_ runID: UUID) -> Bool {
        machines[runID] != nil
    }

    func currentRun(for runID: UUID) -> ContinuedProcessingRunState? {
        machines[runID]?.currentRun
    }

    func accepts(_ identity: RunIdentity, for runID: UUID) -> Bool {
        guard let descriptor = machines[runID]?.currentRun?.descriptor else { return false }
        return descriptor.id == identity.runID && descriptor.identity == identity
    }

    func runID(for requestIdentifier: String) -> UUID? {
        machines.first { _, machine in
            machine.currentRun?.descriptor.requestIdentifier == requestIdentifier
        }?.key
    }

    mutating func begin(_ descriptor: ContinuedProcessingRunDescriptor) -> Bool {
        guard machines[descriptor.id] == nil else { return false }
        var machine = ContinuedProcessingStateMachine()
        guard machine.begin(descriptor) else { return false }
        machines[descriptor.id] = machine
        return true
    }

    mutating func attachSystemTask(
        identifier: String
    ) -> (runID: UUID, effects: [ContinuedProcessingStateMachineEffect])? {
        guard let runID = runID(for: identifier), var machine = machines[runID] else {
            return nil
        }
        let effects = machine.attachSystemTask(identifier: identifier)
        machines[runID] = machine
        return (runID, effects)
    }

    mutating func report(
        runID: UUID,
        status: ContinuedProcessingStatus
    ) -> [ContinuedProcessingStateMachineEffect] {
        guard var machine = machines[runID] else { return [] }
        let effects = machine.report(runID: runID, status: status)
        machines[runID] = machine
        return effects
    }

    mutating func finish(
        runID: UUID,
        success: Bool
    ) -> [ContinuedProcessingStateMachineEffect] {
        guard var machine = machines[runID] else { return [] }
        let effects = machine.finish(runID: runID, success: success)
        machines[runID] = machine
        return effects
    }

    mutating func cancel(
        runID: UUID,
        reason: ContinuedProcessingCancellationReason
    ) -> [ContinuedProcessingStateMachineEffect] {
        guard var machine = machines[runID] else { return [] }
        let effects = machine.cancel(runID: runID, reason: reason)
        machines[runID] = machine
        return effects
    }

    mutating func remove(_ runID: UUID) {
        machines.removeValue(forKey: runID)
    }
}

enum ContinuedProcessingControllerError: Error, Equatable, Sendable {
    case runAlreadyActive
}

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

@MainActor
final class ContinuedProcessingController {
    typealias Operation = @Sendable (ContinuedProcessingContext) async throws -> Void
    typealias CancellationHandler = @Sendable (ContinuedProcessingCancellationReason) async -> Void
    typealias SystemTaskAttachedHandler = @MainActor () -> Void

    let identifierPrefix: String
    let permittedIdentifier: String

    private let identifiers: ContinuedProcessingIdentifiers
    private var runBook = ContinuedProcessingRunBook()
    private var registeredSystemHandlers: Set<String> = []
    private var systemTasks: [UUID: BGTask] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var operations: [UUID: Operation] = [:]
    private var cancellationHandlers: [UUID: CancellationHandler] = [:]
    private var systemTaskAttachedHandlers: [UUID: SystemTaskAttachedHandler] = [:]
    private var completions: [UUID: ContinuedProcessingRunCompletion] = [:]

    var hasActiveRun: Bool {
        runBook.hasActiveRun
    }

    init(identifierPrefix: String) throws {
        let identifiers = try ContinuedProcessingIdentifiers(prefix: identifierPrefix)
        self.identifiers = identifiers
        self.identifierPrefix = identifiers.prefix
        permittedIdentifier = identifiers.permittedIdentifier
    }

    @discardableResult
    private func registerSystemHandler(for identifier: String) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard identifier.hasPrefix(identifierPrefix + "."),
              identifier != permittedIdentifier else {
            return false
        }
        if registeredSystemHandlers.contains(identifier) { return true }

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self?.attach(continuedTask)
                    ?? continuedTask.setTaskCompleted(success: false)
            }
        }
        if registered {
            registeredSystemHandlers.insert(identifier)
        }
        return registered
    }

    @discardableResult
    func startUserInitiated(
        identity: RunIdentity? = nil,
        runID: UUID = UUID(),
        initialStatus: ContinuedProcessingStatus,
        cancellationHandler: @escaping CancellationHandler,
        systemTaskAttachedHandler: SystemTaskAttachedHandler? = nil,
        operation: @escaping Operation
    ) async throws -> ContinuedProcessingRunHandle {
        let effectiveRunID = identity?.runID ?? runID
        let requestIdentifier = identifiers.requestIdentifier(for: effectiveRunID)
        let descriptor: ContinuedProcessingRunDescriptor = if let identity {
            ContinuedProcessingRunDescriptor(
                identity: identity,
                requestIdentifier: requestIdentifier,
                status: initialStatus
            )
        } else {
            ContinuedProcessingRunDescriptor(
                id: effectiveRunID,
                requestIdentifier: requestIdentifier,
                status: initialStatus
            )
        }
        guard runBook.begin(descriptor) else {
            throw ContinuedProcessingControllerError.runAlreadyActive
        }

        cancellationHandlers[effectiveRunID] = cancellationHandler
        if let systemTaskAttachedHandler {
            systemTaskAttachedHandlers[effectiveRunID] = systemTaskAttachedHandler
        }
        operations[effectiveRunID] = operation
        let completion = ContinuedProcessingRunCompletion()
        completions[effectiveRunID] = completion

        let submission = await submitSystemRequest(
            identifier: requestIdentifier,
            status: initialStatus
        )
        if submission != .submitted {
            // On systems without Continued Processing, or if iOS rejects the
            // request, retain foreground behavior instead of leaving the run
            // permanently pending. It is intentionally not background-safe.
            startWorker(runID: effectiveRunID)
        }
        if submission == .submitted,
           let run = runBook.currentRun(for: effectiveRunID),
           run.phase != .running,
           #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestIdentifier)
        }
        return ContinuedProcessingRunHandle(
            id: effectiveRunID,
            identity: identity,
            requestIdentifier: requestIdentifier,
            submission: submission,
            completion: completion
        )
    }

    func report(
        runID: UUID,
        identity: RunIdentity? = nil,
        status: ContinuedProcessingStatus
    ) {
        guard identity == nil || runBook.accepts(identity!, for: runID) else { return }
        apply(runBook.report(runID: runID, status: status), runID: runID)
    }

    func finish(
        runID: UUID,
        identity: RunIdentity? = nil,
        success: Bool = true
    ) {
        guard identity == nil || runBook.accepts(identity!, for: runID) else { return }
        apply(runBook.finish(runID: runID, success: success), runID: runID)
    }

    func cancel(
        runID: UUID,
        identity: RunIdentity? = nil,
        reason: ContinuedProcessingCancellationReason = .user
    ) {
        guard identity == nil || runBook.accepts(identity!, for: runID) else { return }
        let worker = workers[runID]
        worker?.cancel()
        let effects = runBook.cancel(runID: runID, reason: reason)
        apply(effects, runID: runID)
        if !effects.isEmpty, worker == nil, let completion = completions[runID] {
            Task {
                await completion.resolve(.cancelledBeforeStart(reason))
            }
        }
    }

    func releaseCompletion(runID: UUID, identity: RunIdentity? = nil) {
        guard identity == nil || runBook.accepts(identity!, for: runID) else { return }
        completions.removeValue(forKey: runID)
        runBook.remove(runID)
    }

    /// Cold-launch orphan cleanup has no in-memory run identity. Cancel only
    /// the exact persisted request identifier; never cancel the whole prefix.
    func cancelOrphanRequest(identifier: String) {
#if os(iOS) && canImport(BackgroundTasks)
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
#else
        _ = identifier
#endif
    }

    private func submitSystemRequest(
        identifier: String,
        status: ContinuedProcessingStatus
    ) async -> ContinuedProcessingSubmission {
        guard #available(iOS 26.0, *) else { return .unavailable }
        guard registerSystemHandler(for: identifier) else { return .registrationRejected }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: status.title,
            subtitle: status.subtitle
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            return .submitted
        } catch {
            return .failed(message: String(describing: error))
        }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard let runID = runBook.runID(for: task.identifier),
              let run = runBook.currentRun(for: runID),
              !run.isSystemTaskAttached,
              systemTasks[runID] == nil else {
            task.setTaskCompleted(success: false)
            return
        }

        systemTasks[runID] = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
            self?.cancel(
                runID: runID,
                identity: run.descriptor.identity,
                reason: .systemExpiration
            )
            }
        }
        systemTaskAttachedHandlers[runID]?()
        guard let attached = runBook.attachSystemTask(identifier: task.identifier) else {
            task.setTaskCompleted(success: false)
            return
        }
        apply(attached.effects, runID: attached.runID)
    }

    /// Work starts only after iOS has handed us the continued-processing task.
    /// Starting it before that handoff leaves a race where the app can suspend
    /// immediately after the user backgrounds it.
    private func startWorker(runID: UUID) {
        guard workers[runID] == nil,
              runBook.currentRun(for: runID)?.descriptor.id == runID,
              runBook.currentRun(for: runID)?.phase == .running,
              let operation = operations[runID] else {
            return
        }
        let runIdentity = runBook.currentRun(for: runID)?.descriptor.identity
        let context = ContinuedProcessingContext(runID: runID) { [weak self] status in
            await self?.report(runID: runID, identity: runIdentity, status: status)
        }
        guard let completion = completions[runID] else { return }
        workers[runID] = Task { [weak self, completion] in
            do {
                try await operation(context)
                self?.finish(runID: runID, identity: runIdentity, success: true)
            } catch is CancellationError {
                self?.cancel(runID: runID, identity: runIdentity, reason: .operationCancellation)
            } catch {
                self?.finish(runID: runID, identity: runIdentity, success: false)
            }
            let cancellationReason: ContinuedProcessingCancellationReason?
            if let run = self?.runBook.currentRun(for: runID),
               case let .cancelled(reason) = run.phase {
                cancellationReason = reason
            } else {
                cancellationReason = nil
            }
            await completion.resolve(
                .operationFinished(cancellationReason: cancellationReason)
            )
        }
    }

    private func apply(
        _ effects: [ContinuedProcessingStateMachineEffect],
        runID: UUID
    ) {
        for effect in effects {
            switch effect {
            case let .updateSystemTask(status):
                guard #available(iOS 26.0, *),
                      let task = systemTasks[runID] as? BGContinuedProcessingTask else {
                    continue
                }
                task.progress.totalUnitCount = status.totalUnitCount
                task.progress.completedUnitCount = status.completedUnitCount
                task.updateTitle(status.title, subtitle: status.subtitle)

            case .startWorker:
                startWorker(runID: runID)

            case let .completeSystemTask(success):
                guard #available(iOS 26.0, *), let task = systemTasks.removeValue(forKey: runID) else {
                    continue
                }
                task.setTaskCompleted(success: success)

            case let .cancelPendingRequest(identifier):
                if #available(iOS 26.0, *) {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                }

            case let .invokeCancellation(reason):
                if let handler = cancellationHandlers[runID] {
                    Task { await handler(reason) }
                }
            }
        }

        guard let run = runBook.currentRun(for: runID),
              run.descriptor.id == runID,
              run.phase != .running else {
            return
        }
        workers.removeValue(forKey: runID)
        operations.removeValue(forKey: runID)
        cancellationHandlers.removeValue(forKey: runID)
        systemTaskAttachedHandlers.removeValue(forKey: runID)
    }
}
#endif
