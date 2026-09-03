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
    case syncBaseUnavailable(UInt64)
    case syncBaseMismatch(expected: UInt64, actual: UInt64)
    case syncAssetsUnsupported
    case syncTombstonesUnsupported

    var errorDescription: String? {
        switch self {
        case let .sessionUnavailable(sessionID):
            return "会话轨迹 \(sessionID.uuidString) 正在关闭。"
        case .resetInProgress:
            return "会话轨迹正在重置。"
        case .turnNumberExhausted:
            return "会话 Turn 编号已达到上限。"
        case let .syncBaseUnavailable(baseSequence):
            return "本地轨迹中不存在同步基线 \(baseSequence)。"
        case let .syncBaseMismatch(expected, actual):
            return "同步 suffix 基线冲突：本地期待 \(expected)，收到 \(actual)。"
        case .syncAssetsUnsupported:
            return "当前 canonical event log 尚不接纳同步 asset 引用。"
        case .syncTombstonesUnsupported:
            return "当前 append-only canonical event log 尚不接纳同步 tombstone。"
        }
    }
}

/// Owns one append-only DSH-compatible stream per conversation session.
///
/// Stores are keyed by session identity instead of a mutable "current" file so
/// a cancelled run can finish closing its events without writing into a newly
/// selected conversation.
actor SessionTrajectoryRepository: SessionPersistence {
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
        let sessionStore = try store(for: sessionID)
        try await sessionStore.flush()
        let snapshot = try await sessionStore.recover()
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

    func persistenceSnapshot(sessionID: UUID) async throws -> SessionPersistenceSnapshot {
        let snapshot = try await store(for: sessionID).snapshot(after: nil)
        return SessionPersistenceSnapshot(
            snapshot: snapshot,
            revision: try await store(for: sessionID).persistenceRevision()
        )
    }

    /// Reads the complete persisted stream on demand. The live AppModel keeps
    /// only a bounded UI tail so long streaming sessions do not retain every
    /// delta in SwiftUI state; exports and forensic diagnostics can still get
    /// the lossless JSONL history explicitly.
    func allEvents(sessionID: UUID) async throws -> [SessionEvent] {
        try await store(for: sessionID).allEvents()
    }

    /// Exports a bounded, immutable suffix from the durable canonical JSONL
    /// stream. The caller supplies the last sequence already acknowledged by
    /// its peer; `UInt64.max` represents the virtual position before seq 0.
    func makeSyncEnvelope(
        sessionID: UUID,
        baseSequence: UInt64,
        metadata: [String: String] = [:]
    ) async throws -> HarnessSyncEnvelope {
        let sessionStore = try store(for: sessionID)
        let events = try await sessionStore.allEvents()
        let firstSequence = baseSequence &+ 1
        let suffix: [SessionEvent]

        if events.isEmpty, firstSequence == 0 {
            suffix = []
        } else if let lastSequence = events.last?.seq,
                  firstSequence == lastSequence &+ 1 {
            suffix = []
        } else if let start = events.firstIndex(where: { $0.seq == firstSequence }) {
            suffix = Array(events[start...].prefix(HarnessSyncEnvelope.maximumEvents))
        } else {
            throw SessionTrajectoryRepositoryError.syncBaseUnavailable(baseSequence)
        }

        return try HarnessSyncEnvelope(
            sessionID: sessionID,
            baseSequence: baseSequence,
            events: suffix,
            metadata: metadata
        )
    }

    /// Admits only a remote suffix that starts exactly at this durable log's
    /// next sequence. This prevents LWW replacement, reordering, and mutation
    /// of already accepted history. Asset copying and tombstone reconciliation
    /// need separate, explicit policies and are rejected until then.
    @discardableResult
    func admitSyncEnvelope(_ envelope: HarnessSyncEnvelope) async throws -> [SessionEvent] {
        guard envelope.assets.isEmpty else {
            throw SessionTrajectoryRepositoryError.syncAssetsUnsupported
        }
        guard envelope.tombstones.isEmpty else {
            throw SessionTrajectoryRepositoryError.syncTombstonesUnsupported
        }

        let sessionStore = try store(for: envelope.sessionID)
        try await sessionStore.flush()
        let localNextSequence = try await sessionStore.persistenceRevision().nextSequence
        let incomingFirstSequence = envelope.baseSequence &+ 1
        guard localNextSequence == incomingFirstSequence else {
            throw SessionTrajectoryRepositoryError.syncBaseMismatch(
                expected: localNextSequence,
                actual: incomingFirstSequence
            )
        }

        let admitted = try await sessionStore.append(envelope.events)
        try await sessionStore.flush()
        return admitted
    }

    func replacementRangeForSurfacePrefix(
        count: Int,
        sessionID: UUID
    ) async throws -> ClosedRange<UInt64>? {
        let events = try await store(for: sessionID).allEvents()
        return SessionTrajectoryConversationProjection.replacementRangeForPrefix(
            count: count,
            events: events
        )
    }

    func persistedEvents(
        sessionID: UUID,
        matching shouldRetain: @Sendable (SessionEvent) -> Bool
    ) async throws -> [SessionEvent] {
        try await store(for: sessionID).persistedEvents(matching: shouldRetain)
    }

    func page(
        sessionID: UUID,
        before sequence: UInt64,
        limit: Int,
        matching shouldRetain: @Sendable (SessionEvent) -> Bool
    ) async throws -> [SessionEvent] {
        try await store(for: sessionID).persistedEventPage(
            before: sequence,
            limit: limit,
            matching: shouldRetain
        )
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

    func listSessionIDs() async throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard url.pathExtension == "jsonl" else { return nil }
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0 else {
                return nil
            }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }.sorted { $0.uuidString < $1.uuidString }
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

enum SessionLogDeliveryError: Error, LocalizedError, Sendable, Equatable {
    case emptyAcknowledgement
    case rejected(status: Int)
    case invalidAcknowledgement

    var errorDescription: String? {
        switch self {
        case .emptyAcknowledgement: "Session log 服务端未确认任何 cursor。"
        case let .rejected(status): "Session log 上传被服务端拒绝（HTTP \(status)）。"
        case .invalidAcknowledgement: "Session log 服务端确认 cursor 无效。"
        }
    }
}

/// Delivers durable session suffixes using the upstream DeepSeek field shape.
/// The transport is injected so callers can bind it to the audited provider
/// HTTP client; no implicit network request is created by this type.
actor SessionLogDeliveryCoordinator {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let persistence: SessionTrajectoryRepository
    private let watermarkURL: URL
    private let transport: Transport
    private var watermarks: [String: UInt64]

    init(
        persistence: SessionTrajectoryRepository,
        watermarkURL: URL,
        transport: @escaping Transport
    ) {
        self.persistence = persistence
        self.watermarkURL = watermarkURL
        self.transport = transport
        if let data = try? Data(contentsOf: watermarkURL),
           let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data) {
            watermarks = decoded
        } else {
            watermarks = [:]
        }
    }

    func watermark(sessionID: UUID) -> UInt64? {
        watermarks[sessionID.uuidString.lowercased()]
    }

    @discardableResult
    func deliver(sessionID: UUID, endpoint: URL, apiKey: String? = nil) async throws -> UInt64? {
        let key = sessionID.uuidString.lowercased()
        let base = watermarks[key] ?? UInt64.max
        let envelope = try await persistence.makeSyncEnvelope(
            sessionID: sessionID,
            baseSequence: base,
            metadata: ["transport": "session-log-deepseek"]
        )
        guard !envelope.events.isEmpty else { return nil }

        let events = try envelope.events.map { event -> JSONValue in
            let data = try JSONEncoder().encode(event)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        let payload: JSONValue = .object([
            "session_id": .string(sessionID.uuidString),
            "base_sequence": .number(Double(envelope.baseSequence)),
            "events": .array(events)
        ])
        let body = try JSONEncoder().encode(payload)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw SessionLogDeliveryError.rejected(status: response.statusCode)
        }
        let accepted = Self.acceptedCursor(from: data) ?? envelope.events.last?.seq
        guard let accepted, accepted >= envelope.events.last!.seq else {
            throw SessionLogDeliveryError.invalidAcknowledgement
        }
        watermarks[key] = accepted
        try persistWatermarks()
        return accepted
    }

    private func persistWatermarks() throws {
        let data = try JSONEncoder().encode(watermarks)
        try FileManager.default.createDirectory(
            at: watermarkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: watermarkURL, options: .atomic)
    }

    private static func acceptedCursor(from data: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["accepted_cursor"] ?? object["accepted_sequence"],
              let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0,
              value.rounded(.down) == value,
              value <= Double(UInt64.max) else { return nil }
        return UInt64(value)
    }
}
