import Foundation

struct SessionTrajectoryPreparation: Sendable, Equatable {
    let snapshot: SessionTrajectorySnapshot
    let nextTurn: Int

    var requestHeaderReason: SessionRequestHeaderReason {
        snapshot.events.isEmpty ? .initial : .resume
    }
}

enum SessionTrajectoryRepositoryError: Error, Sendable, Equatable, LocalizedError {
    case sessionUnavailable(UUID)
    case resetInProgress
    case turnNumberExhausted

    var errorDescription: String? {
        switch self {
        case let .sessionUnavailable(sessionID):
            return "会话轨迹 \(sessionID.uuidString) 正在关闭。"
        case .resetInProgress:
            return "会话轨迹正在重置。"
        case .turnNumberExhausted:
            return "会话 Turn 编号已达到上限。"
        }
    }
}

/// Owns one append-only DSH-compatible stream per conversation session.
///
/// Stores are keyed by session identity instead of a mutable "current" file so
/// a cancelled run can finish closing its events without writing into a newly
/// selected conversation.
actor SessionTrajectoryRepository {
    private let directory: URL
    private var knownEventTypes: Set<String>
    private var stores: [UUID: SessionEventJSONLStore] = [:]
    private var unavailableSessions = Set<UUID>()
    private var isResetting = false

    init(
        root: URL? = nil,
        knownEventTypes: Set<String> = SessionEventVocabulary.upstreamKnown
    ) {
        if let root {
            directory = root
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Trajectories", isDirectory: true)
        }
        self.knownEventTypes = knownEventTypes
    }

    func prepare(sessionID: UUID) async throws -> SessionTrajectoryPreparation {
        let snapshot = try await store(for: sessionID).recover()
        let maximumTurn = snapshot.events.compactMap(Self.turnNumber).max() ?? 0
        let (nextTurn, overflow) = maximumTurn.addingReportingOverflow(1)
        guard !overflow else { throw SessionTrajectoryRepositoryError.turnNumberExhausted }
        return SessionTrajectoryPreparation(snapshot: snapshot, nextTurn: nextTurn)
    }

    @discardableResult
    func append(
        _ draft: SessionEventDraft,
        sessionID: UUID
    ) async throws -> SessionEvent {
        try await store(for: sessionID).append(draft)
    }

    func snapshot(
        sessionID: UUID,
        after cursor: SessionTrajectoryCursor? = nil
    ) async throws -> SessionTrajectorySnapshot {
        try await store(for: sessionID).snapshot(after: cursor)
    }

    func registerKnownEventTypes(_ eventTypes: Set<String>) async throws {
        guard !isResetting else { throw SessionTrajectoryRepositoryError.resetInProgress }
        guard !eventTypes.isEmpty else { return }
        knownEventTypes.formUnion(eventTypes)
        for store in stores.values {
            try await store.registerKnownEventTypes(eventTypes)
        }
    }

    func flush(sessionID: UUID) async throws {
        guard let store = stores[sessionID] else { return }
        try await store.flush()
    }

    func delete(sessionID: UUID) async throws {
        unavailableSessions.insert(sessionID)
        let store = stores.removeValue(forKey: sessionID)
        defer { unavailableSessions.remove(sessionID) }

        if let store {
            try await store.close()
        }
        let fileURL = fileURL(for: sessionID)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func resetAll() async throws {
        guard !isResetting else { throw SessionTrajectoryRepositoryError.resetInProgress }
        isResetting = true
        let openStores = Array(stores.values)
        stores.removeAll()
        defer { isResetting = false }

        for store in openStores {
            try await store.close()
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func store(for sessionID: UUID) throws -> SessionEventJSONLStore {
        guard !isResetting else { throw SessionTrajectoryRepositoryError.resetInProgress }
        guard !unavailableSessions.contains(sessionID) else {
            throw SessionTrajectoryRepositoryError.sessionUnavailable(sessionID)
        }
        if let existing = stores[sessionID] {
            return existing
        }
        let streamID = sessionID.uuidString.lowercased()
        let store = SessionEventJSONLStore(
            fileURL: fileURL(for: sessionID),
            streamID: streamID,
            knownEventTypes: knownEventTypes
        )
        stores[sessionID] = store
        return store
    }

    private func fileURL(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(
            sessionID.uuidString.lowercased() + ".jsonl",
            isDirectory: false
        )
    }

    private static func turnNumber(_ event: SessionEvent) -> Int? {
        event.turnStartData?.turn
            ?? event.turnEndData?.turn
            ?? event.stepData?.turn
            ?? event.assistantChunkData?.turn
            ?? event.assistantMessageData?.turn
            ?? event.toolCallData?.turn
            ?? event.toolResultData?.turn
    }
}
