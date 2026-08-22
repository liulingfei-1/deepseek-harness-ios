import Foundation

/// Feedback is persisted independently from the message transcript. The
/// message's `feedback` field remains a compatibility projection for older
/// snapshots and the native message menu.
struct MessageFeedbackSidecarRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let messageID: UUID
    var rating: MessageFeedbackRating?
    var note: String?
    let createdAt: Date
    var updatedAt: Date
    /// Per-record optimistic-concurrency revision. It is intentionally an
    /// integer, so clients can carry it across process launches.
    var revision: Int

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        messageID: UUID,
        rating: MessageFeedbackRating? = nil,
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        revision: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.messageID = messageID
        self.rating = rating
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
    }

    var isEmpty: Bool { rating == nil && note == nil }
}

enum MessageFeedbackSidecarError: LocalizedError, Sendable, Equatable {
    case revisionConflict(expected: Int, actual: Int)
    case missingRating

    var errorDescription: String? {
        switch self {
        case let .revisionConflict(expected, actual):
            return "反馈已在其他位置更新（期望 revision \(expected)，当前为 \(actual)）。请重新读取后再修改。"
        case .missingRating:
            return "请先对该消息点赞或点踩，再添加反馈备注。"
        }
    }
}

/// Small append-and-rewrite sidecar. Feedback is bounded by message count and
/// is independent from the session JSON, so a feedback write cannot rewrite a
/// long transcript or lose a concurrent transcript update.
actor MessageFeedbackSidecarStore {
    private struct Snapshot: Codable {
        var version: Int
        var records: [MessageFeedbackSidecarRecord]
    }

    private static let currentVersion = 1
    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil) {
        directory = root ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Feedback", isDirectory: true)
        fileURL = directory.appendingPathComponent("feedback-sidecar.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func record(sessionID: UUID, messageID: UUID) throws -> MessageFeedbackSidecarRecord? {
        try readSnapshot().records.first {
            $0.sessionID == sessionID && $0.messageID == messageID
        }
    }

    func records(sessionID: UUID) throws -> [MessageFeedbackSidecarRecord] {
        try readSnapshot().records.filter { $0.sessionID == sessionID }
    }

    /// Projects/migrates legacy embedded feedback and returns a message array
    /// suitable for the UI. The returned messages never become the sidecar's
    /// source of truth after this call.
    func project(
        sessionID: UUID,
        messages: [AgentMessage]
    ) throws -> [AgentMessage] {
        var snapshot = try readSnapshot()
        var changed = false
        var projected = messages
        for index in projected.indices where projected[index].role == .assistant {
            let message = projected[index]
            let existingIndex = snapshot.records.firstIndex {
                $0.sessionID == sessionID && $0.messageID == message.id
            }
            if let existingIndex {
                let record = snapshot.records[existingIndex]
                projected[index].feedback = record.rating.map {
                    MessageFeedback(
                        rating: $0,
                        note: record.note,
                        version: record.id,
                        createdAt: record.createdAt,
                        updatedAt: record.updatedAt
                    )
                }
            } else if let legacy = message.feedback {
                snapshot.records.append(
                    MessageFeedbackSidecarRecord(
                        id: legacy.version,
                        sessionID: sessionID,
                        messageID: message.id,
                        rating: legacy.rating,
                        note: legacy.note,
                        createdAt: legacy.createdAt,
                        updatedAt: legacy.updatedAt,
                        revision: 1
                    )
                )
                changed = true
            }
        }
        if changed { try writeSnapshot(snapshot) }
        return projected
    }

    func setRating(
        sessionID: UUID,
        messageID: UUID,
        rating: MessageFeedbackRating,
        expectedRevision: Int? = nil
    ) throws -> MessageFeedbackSidecarRecord {
        try mutate(sessionID: sessionID, messageID: messageID, expectedRevision: expectedRevision) { record in
            record.rating = rating
        }
    }

    func updateNote(
        sessionID: UUID,
        messageID: UUID,
        note: String?,
        expectedRevision: Int? = nil
    ) throws -> MessageFeedbackSidecarRecord {
        try mutate(sessionID: sessionID, messageID: messageID, expectedRevision: expectedRevision) { record in
            guard record.rating != nil else { throw MessageFeedbackSidecarError.missingRating }
            record.note = note
        }
    }

    /// Clearing keeps a tombstone record, preserving identity and revision so
    /// a stale client cannot recreate feedback after a newer clear.
    func clear(
        sessionID: UUID,
        messageID: UUID,
        expectedRevision: Int? = nil
    ) throws -> MessageFeedbackSidecarRecord {
        try mutate(sessionID: sessionID, messageID: messageID, expectedRevision: expectedRevision) { record in
            record.rating = nil
            record.note = nil
        }
    }

    private func mutate(
        sessionID: UUID,
        messageID: UUID,
        expectedRevision: Int?,
        _ body: (inout MessageFeedbackSidecarRecord) throws -> Void
    ) throws -> MessageFeedbackSidecarRecord {
        var snapshot = try readSnapshot()
        let index = snapshot.records.firstIndex {
            $0.sessionID == sessionID && $0.messageID == messageID
        }
        var record = index.map { snapshot.records[$0] }
            ?? MessageFeedbackSidecarRecord(sessionID: sessionID, messageID: messageID)
        if let expectedRevision, expectedRevision != record.revision {
            throw MessageFeedbackSidecarError.revisionConflict(
                expected: expectedRevision,
                actual: record.revision
            )
        }
        try body(&record)
        record.revision += 1
        record.updatedAt = .now
        if let index {
            snapshot.records[index] = record
        } else {
            snapshot.records.append(record)
        }
        try writeSnapshot(snapshot)
        return record
    }

    private func readSnapshot() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Snapshot(version: Self.currentVersion, records: [])
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard snapshot.version <= Self.currentVersion else {
                return Snapshot(version: Self.currentVersion, records: [])
            }
            return snapshot
        } catch {
            // A corrupt feedback sidecar must not prevent the transcript from
            // loading. Preserve the file for diagnostics and start empty.
            return Snapshot(version: Self.currentVersion, records: [])
        }
    }

    private func writeSnapshot(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        let temporary = fileURL.appendingPathExtension("tmp-(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}
