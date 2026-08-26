import Foundation

/// Opaque source-qualified revision for one canonical session event stream.
/// Consumers compare it for equality; they do not derive ordering or inspect
/// storage counters as business state.
struct SessionPersistenceRevision: Codable, Sendable, Equatable, Hashable {
    let streamID: String
    let nextSequence: UInt64
    let recoveredTornTail: Bool
}

struct SessionPersistenceSnapshot: Codable, Sendable, Equatable {
    let snapshot: SessionTrajectorySnapshot
    let revision: SessionPersistenceRevision
}

/// Device-local persistence capability for the append-only SessionEvent log.
/// The seam deliberately excludes SessionStore's derived JSON snapshot: event
/// history remains the single durable source and projections read from it.
protocol SessionPersistence: Sendable {
    func prepare(sessionID: UUID) async throws -> SessionTrajectoryPreparation
    func append(_ draft: SessionEventDraft, sessionID: UUID) async throws -> SessionEvent
    func snapshot(
        sessionID: UUID,
        after cursor: SessionTrajectoryCursor?
    ) async throws -> SessionTrajectorySnapshot
    func persistenceSnapshot(sessionID: UUID) async throws -> SessionPersistenceSnapshot
    func allEvents(sessionID: UUID) async throws -> [SessionEvent]
    func replacementRangeForSurfacePrefix(
        count: Int,
        sessionID: UUID
    ) async throws -> ClosedRange<UInt64>?
    func persistedEvents(
        sessionID: UUID,
        matching shouldRetain: @Sendable @escaping (SessionEvent) -> Bool
    ) async throws -> [SessionEvent]
    func page(
        sessionID: UUID,
        before sequence: UInt64,
        limit: Int,
        matching shouldRetain: @Sendable @escaping (SessionEvent) -> Bool
    ) async throws -> [SessionEvent]
    func registerKnownEventTypes(_ eventTypes: Set<String>) async throws
    func flush(sessionID: UUID) async throws
    func listSessionIDs() async throws -> [UUID]
    func delete(sessionID: UUID) async throws
    func resetAll() async throws
}

extension SessionPersistence {
    func snapshot(sessionID: UUID) async throws -> SessionTrajectorySnapshot {
        try await snapshot(sessionID: sessionID, after: nil)
    }
}
