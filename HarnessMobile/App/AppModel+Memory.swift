import Foundation

@MainActor
extension AppModel {
    func refreshMemory() async {
        let sessionID = activeSessionID
        do {
            let records = try await memoryStore.list()
            let isEnabled: Bool
            if let sessionID {
                isEnabled = try await memoryStore.isEnabled(for: sessionID)
            } else {
                isEnabled = true
            }
            memoryRecords = records
            guard activeSessionID == sessionID else { return }
            isMemoryEnabledForActiveSession = isEnabled
        } catch {
            presentError(error)
        }
    }

    func setMemoryEnabledForActiveSession(_ isEnabled: Bool) async {
        guard let sessionID = activeSessionID else {
            presentError(MemoryManagementError.noActiveSession)
            return
        }
        do {
            try await memoryStore.setEnabled(isEnabled, for: sessionID)
            guard activeSessionID == sessionID else { return }
            isMemoryEnabledForActiveSession = isEnabled
        } catch {
            presentError(error)
        }
    }

    func deleteMemory(id: UUID) async {
        do {
            try await memoryStore.delete(id: id)
            memoryRecords.removeAll { $0.id == id }
        } catch {
            presentError(error)
        }
    }

    func memoryExportData() async throws -> Data {
        try await memoryStore.exportData()
    }
}

enum MemoryManagementError: LocalizedError, Sendable, Equatable {
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            "No active conversation is available for this memory setting."
        }
    }
}
