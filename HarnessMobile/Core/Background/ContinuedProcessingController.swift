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
    let requestIdentifier: String
    var status: ContinuedProcessingStatus
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

struct ContinuedProcessingRunHandle: Equatable, Sendable {
    let id: UUID
    let requestIdentifier: String
    let submission: ContinuedProcessingSubmission
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

    let identifierPrefix: String
    let permittedIdentifier: String

    private let identifiers: ContinuedProcessingIdentifiers
    private var stateMachine = ContinuedProcessingStateMachine()
    private var registeredSystemHandlers: Set<String> = []
    private var isSubmissionInFlight = false
    private var systemTasks: [UUID: BGTask] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var operations: [UUID: Operation] = [:]
    private var cancellationHandlers: [UUID: CancellationHandler] = [:]

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
        runID: UUID = UUID(),
        initialStatus: ContinuedProcessingStatus,
        cancellationHandler: @escaping CancellationHandler,
        operation: @escaping Operation
    ) async throws -> ContinuedProcessingRunHandle {
        guard !stateMachine.hasActiveRun, !isSubmissionInFlight else {
            throw ContinuedProcessingControllerError.runAlreadyActive
        }

        let requestIdentifier = identifiers.requestIdentifier(for: runID)
        let descriptor = ContinuedProcessingRunDescriptor(
            id: runID,
            requestIdentifier: requestIdentifier,
            status: initialStatus
        )
        guard stateMachine.begin(descriptor) else {
            throw ContinuedProcessingControllerError.runAlreadyActive
        }

        cancellationHandlers[runID] = cancellationHandler
        operations[runID] = operation

        isSubmissionInFlight = true
        let submission = await submitSystemRequest(
            identifier: requestIdentifier,
            status: initialStatus
        )
        isSubmissionInFlight = false
        if submission != .submitted {
            // On systems without Continued Processing, or if iOS rejects the
            // request, retain foreground behavior instead of leaving the run
            // permanently pending. It is intentionally not background-safe.
            startWorker(runID: runID)
        }
        if submission == .submitted,
           let run = stateMachine.currentRun,
           run.descriptor.id == runID,
           run.phase != .running,
           #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: requestIdentifier)
        }
        return ContinuedProcessingRunHandle(
            id: runID,
            requestIdentifier: requestIdentifier,
            submission: submission
        )
    }

    func report(runID: UUID, status: ContinuedProcessingStatus) {
        apply(stateMachine.report(runID: runID, status: status), runID: runID)
    }

    func finish(runID: UUID, success: Bool = true) {
        apply(stateMachine.finish(runID: runID, success: success), runID: runID)
    }

    func cancel(runID: UUID, reason: ContinuedProcessingCancellationReason = .user) {
        workers[runID]?.cancel()
        apply(stateMachine.cancel(runID: runID, reason: reason), runID: runID)
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
        guard stateMachine.canAttachSystemTask(identifier: task.identifier),
              let runID = stateMachine.currentRun?.descriptor.id,
              systemTasks[runID] == nil else {
            task.setTaskCompleted(success: false)
            return
        }

        systemTasks[runID] = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancel(runID: runID, reason: .systemExpiration)
            }
        }
        apply(stateMachine.attachSystemTask(identifier: task.identifier), runID: runID)
    }

    /// Work starts only after iOS has handed us the continued-processing task.
    /// Starting it before that handoff leaves a race where the app can suspend
    /// immediately after the user backgrounds it.
    private func startWorker(runID: UUID) {
        guard workers[runID] == nil,
              stateMachine.currentRun?.descriptor.id == runID,
              stateMachine.currentRun?.phase == .running,
              let operation = operations[runID] else {
            return
        }
        let context = ContinuedProcessingContext(runID: runID) { [weak self] status in
            await self?.report(runID: runID, status: status)
        }
        workers[runID] = Task { [weak self] in
            do {
                try await operation(context)
                self?.finish(runID: runID, success: true)
            } catch is CancellationError {
                self?.cancel(runID: runID, reason: .operationCancellation)
            } catch {
                self?.finish(runID: runID, success: false)
            }
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

        guard let run = stateMachine.currentRun,
              run.descriptor.id == runID,
              run.phase != .running else {
            return
        }
        workers.removeValue(forKey: runID)
        operations.removeValue(forKey: runID)
        cancellationHandlers.removeValue(forKey: runID)
    }
}
#endif
