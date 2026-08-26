import Foundation

extension AppModel {
    /// Drains only after normal bootstrap and while no Agent run owns the
    /// composer. A handoff stages user content in the active composer; it does
    /// not create a session or bypass provider/tool approval paths.
    @discardableResult
    func consumeShareHandoffs() async -> Bool {
        guard isReady, !isRunning else { return false }
        let handoffStore = ShareHandoffStore()
        guard await handoffStore.isAvailable else { return false }

        var acceptedAny = false
        do {
            while let claim = try await handoffStore.claimNext() {
                let admission: WorkspaceShareAdmission
                do {
                    admission = try await workspaceStore.admitShareHandoff(claim)
                } catch {
                    try? await handoffStore.reject(claim.envelope.id)
                    presentError(error)
                    continue
                }

                // Install before acknowledging. If the process is killed after
                // WorkspaceStore commits but before the ack, the next launch
                // reuses the deterministic manifest and presents it once.
                installShareAdmission(admission)
                do {
                    try await handoffStore.complete(claim.envelope.id)
                } catch {
                    presentError(error)
                    return acceptedAny
                }
                acceptedAny = true
            }
        } catch {
            presentError(error)
        }
        return acceptedAny
    }
}
