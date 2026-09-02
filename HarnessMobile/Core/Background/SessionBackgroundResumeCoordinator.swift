import Foundation

/// Owns foreground auto-resume monitors outside `AppModel` while keeping every
/// pending expiration keyed by the complete run identity that produced it.
actor SessionBackgroundResumeCoordinator {
    typealias Readiness = @Sendable () async -> Bool
    typealias ResumeOperation = @Sendable () async -> Void

    private var isApplicationActive = false
    private var pendingBySession: [UUID: RunIdentity] = [:]
    private var monitorTasks: [UUID: Task<Void, Never>] = [:]

    func updateApplicationActivity(isActive: Bool) {
        isApplicationActive = isActive
        guard !isActive else { return }
        for task in monitorTasks.values {
            task.cancel()
        }
        monitorTasks.removeAll(keepingCapacity: true)
    }

    func markSystemExpiration(_ identity: RunIdentity) {
        pendingBySession[identity.sessionID] = identity
        monitorTasks.removeValue(forKey: identity.sessionID)?.cancel()
    }

    func pendingIdentity(sessionID: UUID) -> RunIdentity? {
        pendingBySession[sessionID]
    }

    /// Claims a pending expiration for a system-scheduled recovery attempt.
    /// Foreground monitors use the same claim, so a run can only be resumed
    /// once even when a scene activation and a BGProcessingTask race.
    @discardableResult
    func consumePending(_ identity: RunIdentity) -> Bool {
        guard pendingBySession[identity.sessionID] == identity else { return false }
        pendingBySession.removeValue(forKey: identity.sessionID)
        monitorTasks.removeValue(forKey: identity.sessionID)?.cancel()
        return true
    }

    @discardableResult
    func startMonitor(
        for identity: RunIdentity,
        readiness: @escaping Readiness,
        resume: @escaping ResumeOperation
    ) -> Bool {
        guard isApplicationActive,
              pendingBySession[identity.sessionID] == identity,
              monitorTasks[identity.sessionID] == nil else {
            return false
        }

        monitorTasks[identity.sessionID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      await self.isPendingAndActive(identity) else { return }
                if await readiness() {
                    guard await self.consume(identity) else { return }
                    await resume()
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
        return true
    }

    private func isPendingAndActive(_ identity: RunIdentity) -> Bool {
        isApplicationActive && pendingBySession[identity.sessionID] == identity
    }

    private func consume(_ identity: RunIdentity) -> Bool {
        guard pendingBySession[identity.sessionID] == identity else { return false }
        pendingBySession.removeValue(forKey: identity.sessionID)
        monitorTasks.removeValue(forKey: identity.sessionID)
        return true
    }
}
