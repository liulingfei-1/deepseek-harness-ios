import Foundation

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

/// Owns the system wake-up request for persisted local Agent schedules.
/// The schedule payload remains in HarnessScheduleStore; BGTask only wakes
/// the app and gives AppModel a bounded execution window.
@MainActor
final class ScheduleBackgroundController {
    static let identifier = "com.llf.harnessmobile.schedule-processing"

    private var isRegistered = false

    /// BGTaskScheduler delivers into this process-level queue before the
    /// SwiftUI model has restored sessions. The task is retained until the
    /// model attaches its bounded execution handler.
    private static var launchRegistrationComplete = false

    @discardableResult
    static func registerLaunchHandler() -> Bool {
        guard !launchRegistrationComplete else { return true }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: .main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                ScheduleBackgroundLaunchCoordinator.shared.enqueue(processingTask)
            }
        }
        launchRegistrationComplete = registered
        return registered
    }

    @discardableResult
    func register(
        handler: @escaping @MainActor @Sendable (BGProcessingTask) async -> Void
    ) -> Bool {
        guard !isRegistered else { return true }
        guard Self.registerLaunchHandler() else { return false }
        isRegistered = true
        ScheduleBackgroundLaunchCoordinator.shared.attach(handler: handler)
        return true
    }

    func submit(earliestBeginDate: Date?) throws {
        let request = BGProcessingTaskRequest(identifier: Self.identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier)
    }
}

@MainActor
final class ScheduleBackgroundLaunchCoordinator {
    static let shared = ScheduleBackgroundLaunchCoordinator()

    private var handler: (@MainActor @Sendable (BGProcessingTask) async -> Void)?
    private var pendingTasks: [BGProcessingTask] = []

    func attach(handler: @escaping @MainActor @Sendable (BGProcessingTask) async -> Void) {
        self.handler = handler
        drain()
    }

    func enqueue(_ task: BGProcessingTask) {
        guard handler != nil else {
            task.expirationHandler = { [weak self, weak task] in
                Task { @MainActor in
                    guard let self, let task else { return }
                    self.expirePending(task)
                }
            }
            pendingTasks.append(task)
            return
        }
        deliver(task)
    }

    private func drain() {
        let tasks = pendingTasks
        pendingTasks.removeAll(keepingCapacity: false)
        for task in tasks { deliver(task) }
    }

    private func deliver(_ task: BGProcessingTask) {
        guard let handler else {
            pendingTasks.append(task)
            return
        }
        Task { @MainActor in
            await handler(task)
        }
    }

    private func expirePending(_ task: BGProcessingTask) {
        pendingTasks.removeAll { $0 === task }
        task.setTaskCompleted(success: false)
    }
}
#endif
