import Foundation

/// A transport-neutral, append-only suffix of one canonical session log.
/// This is intentionally a data contract only; no network transport is
/// implied. The canonical JSONL store remains the local authority.
struct HarnessSyncEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    static let maximumEvents = 512
    static let maximumMetadataEntries = 32
    static let maximumMetadataValueUTF8Bytes = 512

    let schemaVersion: Int
    let sessionID: UUID
    let baseSequence: UInt64
    let events: [SessionEvent]
    let metadata: [String: String]
    let assets: [HarnessSyncAssetReference]
    let tombstones: [HarnessSyncTombstone]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, baseSequence, events, metadata, assets, tombstones
    }

    init(
        sessionID: UUID,
        baseSequence: UInt64,
        events: [SessionEvent],
        metadata: [String: String] = [:],
        assets: [HarnessSyncAssetReference] = [],
        tombstones: [HarnessSyncTombstone] = [],
        schemaVersion: Int = Self.currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HarnessSyncEnvelopeError.unsupportedSchema
        }
        guard events.count <= Self.maximumEvents else {
            throw HarnessSyncEnvelopeError.tooManyEvents
        }
        guard metadata.count <= Self.maximumMetadataEntries,
              metadata.keys.allSatisfy({ !$0.isEmpty }),
              metadata.values.allSatisfy({ $0.utf8.count <= Self.maximumMetadataValueUTF8Bytes }) else {
            throw HarnessSyncEnvelopeError.invalidMetadata
        }
        let expectedFirst = baseSequence &+ 1
        for (index, event) in events.enumerated() {
            let expected = expectedFirst &+ UInt64(index)
            guard event.seq == expected else {
                throw HarnessSyncEnvelopeError.nonContiguousSuffix
            }
            guard !Self.containsCredentialField(event.data) else {
                throw HarnessSyncEnvelopeError.secretField
            }
        }
        let tombstoneIDs = tombstones.map(\.eventID)
        guard Set(tombstoneIDs).count == tombstoneIDs.count else {
            throw HarnessSyncEnvelopeError.duplicateTombstone
        }
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.baseSequence = baseSequence
        self.events = events
        self.metadata = metadata
        self.assets = assets
        self.tombstones = tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionID: container.decode(UUID.self, forKey: .sessionID),
            baseSequence: container.decode(UInt64.self, forKey: .baseSequence),
            events: container.decode([SessionEvent].self, forKey: .events),
            metadata: container.decode([String: String].self, forKey: .metadata),
            assets: container.decode([HarnessSyncAssetReference].self, forKey: .assets),
            tombstones: container.decode([HarnessSyncTombstone].self, forKey: .tombstones),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }

    private static func containsCredentialField(_ value: JSONValue) -> Bool {
        switch value {
        case let .object(object):
            for (key, child) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if ["api_key", "apikey", "authorization", "cookie", "password", "secret", "token"].contains(normalized) {
                    return true
                }
                if containsCredentialField(child) { return true }
            }
            return false
        case let .array(array):
            return array.contains(where: containsCredentialField)
        case .string, .number, .bool, .null:
            return false
        }
    }
}

struct HarnessSyncAssetReference: Codable, Sendable, Equatable, Hashable {
    let key: String
    let relativePath: String
    let byteCount: Int
    let mimeType: String?

    private enum CodingKeys: String, CodingKey { case key, relativePath, byteCount, mimeType }

    init(key: String, relativePath: String, byteCount: Int, mimeType: String? = nil) throws {
        guard !key.isEmpty, !relativePath.isEmpty, byteCount >= 0,
              !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            throw HarnessSyncEnvelopeError.invalidAsset
        }
        self.key = key
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.mimeType = mimeType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            key: c.decode(String.self, forKey: .key),
            relativePath: c.decode(String.self, forKey: .relativePath),
            byteCount: c.decode(Int.self, forKey: .byteCount),
            mimeType: c.decodeIfPresent(String.self, forKey: .mimeType)
        )
    }
}

struct HarnessSyncTombstone: Codable, Sendable, Equatable, Hashable {
    let eventID: UInt64
    let deletedAt: Int64

    private enum CodingKeys: String, CodingKey { case eventID, deletedAt }

    init(eventID: UInt64, deletedAt: Int64) throws {
        guard eventID > 0, deletedAt >= 0 else {
            throw HarnessSyncEnvelopeError.invalidTombstone
        }
        self.eventID = eventID
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventID: c.decode(UInt64.self, forKey: .eventID),
            deletedAt: c.decode(Int64.self, forKey: .deletedAt)
        )
    }
}

enum HarnessSyncEnvelopeError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedSchema
    case tooManyEvents
    case nonContiguousSuffix
    case invalidMetadata
    case secretField
    case invalidAsset
    case invalidTombstone
    case duplicateTombstone

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "同步 envelope 版本不受支持。"
        case .tooManyEvents: "同步 event suffix 超过数量上限。"
        case .nonContiguousSuffix: "同步 event suffix 必须连续且不可重排。"
        case .invalidMetadata: "同步 metadata 超出边界。"
        case .secretField: "同步内容包含禁止传输的凭据字段。"
        case .invalidAsset: "同步 asset 引用越界或无效。"
        case .invalidTombstone: "同步 tombstone 无效。"
        case .duplicateTombstone: "同步 tombstone 不得重复。"
        }
    }
}
