import Foundation

struct BackgroundAutoResumeGate: Sendable, Equatable {
    private(set) var isApplicationActive = false
    private(set) var pendingRunID: UUID?

    mutating func updateApplicationActivity(isActive: Bool) {
        isApplicationActive = isActive
    }

    mutating func markSystemExpiration(runID: UUID) {
        pendingRunID = runID
    }

    func shouldResume(isRunning: Bool, hasResumableRun: Bool) -> Bool {
        isApplicationActive
            && pendingRunID != nil
            && !isRunning
            && hasResumableRun
    }

    @discardableResult
    mutating func consumePendingRun() -> UUID? {
        defer { pendingRunID = nil }
        return pendingRunID
    }

    mutating func reset() {
        pendingRunID = nil
    }
}
