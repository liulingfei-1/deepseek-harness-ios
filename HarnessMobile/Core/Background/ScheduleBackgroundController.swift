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

    @discardableResult
    func register(
        handler: @escaping @MainActor @Sendable (BGProcessingTask) async -> Void
    ) -> Bool {
        guard !isRegistered else { return true }
        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.identifier,
            using: .main
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                await handler(processingTask)
            }
        }
        isRegistered = registered
        return registered
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
#endif
