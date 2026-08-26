import Foundation

/// The only data contract shared by the containing app and its Share
/// Extension.  It deliberately has no provider, credential, environment,
/// session, or tool fields: a share is user content waiting for the normal
/// composer path, never a second way to start an Agent.
enum ShareHandoffItemKind: String, Codable, Sendable, Equatable {
    case text
    case url
    case image
    case file
}

struct ShareHandoffDraft: Sendable, Equatable {
    let kind: ShareHandoffItemKind
    let inlineValue: String?
    let data: Data?
    let displayName: String?
    let mimeType: String?

    static func text(_ value: String) -> ShareHandoffDraft {
        ShareHandoffDraft(
            kind: .text,
            inlineValue: value,
            data: nil,
            displayName: nil,
            mimeType: "text/plain"
        )
    }

    static func url(_ value: String) -> ShareHandoffDraft {
        ShareHandoffDraft(
            kind: .url,
            inlineValue: value,
            data: nil,
            displayName: nil,
            mimeType: "text/uri-list"
        )
    }

    static func attachment(
        kind: ShareHandoffItemKind,
        data: Data,
        displayName: String,
        mimeType: String
    ) -> ShareHandoffDraft {
        ShareHandoffDraft(
            kind: kind,
            inlineValue: nil,
            data: data,
            displayName: displayName,
            mimeType: mimeType
        )
    }
}

struct ShareHandoffItem: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: ShareHandoffItemKind
    let inlineValue: String?
    let payloadReference: String?
    let displayName: String?
    let mimeType: String?
    let byteCount: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case inlineValue
        case payloadReference
        case displayName
        case mimeType
        case byteCount
    }
}

struct ShareHandoffEnvelope: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let items: [ShareHandoffItem]
    let totalByteCount: Int

    init(
        id: UUID,
        createdAt: Date,
        items: [ShareHandoffItem],
        totalByteCount: Int,
        schemaVersion: Int = ShareHandoffEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.items = items
        self.totalByteCount = totalByteCount
    }
}

struct ShareHandoffClaim: Sendable, Equatable {
    let envelope: ShareHandoffEnvelope
    let payloads: [UUID: Data]
}

enum ShareHandoffError: LocalizedError, Sendable, Equatable {
    case appGroupUnavailable
    case invalidEnvelope
    case unsupportedType(String)
    case emptyShare
    case tooManyItems(Int)
    case itemTooLarge(Int)
    case totalTooLarge(Int)
    case queueFull
    case expired
    case claimNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "共享扩展暂不可用：App Group 容器未配置。"
        case .invalidEnvelope:
            "共享内容信封无效，已安全丢弃。"
        case let .unsupportedType(type):
            "共享内容类型不受支持：\(type)。"
        case .emptyShare:
            "没有可接收的共享内容。"
        case let .tooManyItems(limit):
            "共享内容最多支持 \(limit) 项。"
        case let .itemTooLarge(limit):
            "共享单项超过 \(limit) 字节上限。"
        case let .totalTooLarge(limit):
            "共享内容总大小超过 \(limit) 字节上限。"
        case .queueFull:
            "共享内容队列已满，请先打开 Harness 再继续分享。"
        case .expired:
            "共享内容已过期，请重新分享。"
        case let .claimNotFound(id):
            "找不到共享内容 \(id.uuidString)。"
        }
    }
}

/// A crash-safe FIFO handoff in the App Group container.
///
/// Publishing is a directory rename from `staging` into `inbox`. Consuming
/// first renames an inbox directory into `processing`; a process death leaves
/// that directory available to the next launch. The main app acknowledges the
/// ID only after WorkspaceStore has admitted the complete batch.
actor ShareHandoffStore {
    static let appGroupID = "group.com.llf.harnessmobile.share"
    static let maximumItems = 8
    static let maximumInlineUTF8Bytes = 16 * 1_024
    static let maximumItemBytes = 64 * 1_024 * 1_024
    static let maximumTotalBytes = 64 * 1_024 * 1_024
    static let maximumQueuedEnvelopes = 16
    static let maximumQueuedBytes = 128 * 1_024 * 1_024
    static let handoffTTL: TimeInterval = 5 * 60

    private static let envelopeFilename = "envelope.json"
    private static let consumedFilename = "consumed.json"
    private static let inboxName = "Inbox"
    private static let processingName = "Processing"
    private static let stagingName = "Staging"

    private struct ConsumedRecord: Codable, Sendable, Equatable {
        let id: UUID
        let consumedAt: Date
    }

    private let root: URL?
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root.standardizedFileURL
        } else {
            self.root = fileManager
                .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
                .appendingPathComponent("HarnessShareHandoff", isDirectory: true)
                .standardizedFileURL
        }
    }

    var isAvailable: Bool { root != nil }

    /// Writes one independent envelope. No UserDefaults slot is used, so a
    /// second share cannot overwrite the first one.
    @discardableResult
    func enqueue(_ drafts: [ShareHandoffDraft], now: Date = .now) throws -> UUID {
        let root = try requireRoot()
        let admitted = try makeItems(from: drafts)
        try ensureDirectories(at: root)
        try pruneExpired(now: now)

        let existing = try envelopeDirectories(in: inboxURL(root))
            + envelopeDirectories(in: processingURL(root))
        guard existing.count < Self.maximumQueuedEnvelopes else {
            throw ShareHandoffError.queueFull
        }
        let existingBytes = try existing.reduce(into: 0) { total, directory in
            total += try directoryByteCount(directory)
        }
        let incomingBytes = admitted.reduce(0) { $0 + $1.byteCount }
        guard existingBytes + incomingBytes <= Self.maximumQueuedBytes else {
            throw ShareHandoffError.queueFull
        }

        let id = UUID()
        let staging = stagingURL(root).appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: staging.appendingPathComponent("payloads", isDirectory: true),
            withIntermediateDirectories: true
        )
        do {
            var items: [ShareHandoffItem] = []
            for item in admitted {
                if let data = item.data {
                    let payloadName = "\(item.id.uuidString.lowercased()).data"
                    let payloadRelativePath = "payloads/\(payloadName)"
                    let payloadURL = staging.appendingPathComponent(payloadRelativePath)
                    try data.write(to: payloadURL, options: Self.protectedWritingOptions)
                    items.append(
                        ShareHandoffItem(
                            id: item.id,
                            kind: item.kind,
                            inlineValue: nil,
                            payloadReference: payloadRelativePath,
                            displayName: item.displayName,
                            mimeType: item.mimeType,
                            byteCount: item.byteCount
                        )
                    )
                } else {
                    items.append(
                        ShareHandoffItem(
                            id: item.id,
                            kind: item.kind,
                            inlineValue: item.inlineValue,
                            payloadReference: nil,
                            displayName: nil,
                            mimeType: item.mimeType,
                            byteCount: item.byteCount
                        )
                    )
                }
            }
            let envelope = ShareHandoffEnvelope(
                id: id,
                createdAt: now,
                items: items,
                totalByteCount: items.reduce(0) { $0 + $1.byteCount }
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(envelope).write(
                to: staging.appendingPathComponent(Self.envelopeFilename),
                options: Self.protectedWritingOptions
            )
            let finalURL = inboxURL(root).appendingPathComponent(id.uuidString, isDirectory: true)
            try fileManager.moveItem(at: staging, to: finalURL)
            return id
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Returns the oldest claim. A claim in Processing is always resumed
    /// before a new Inbox entry, which makes force-close recovery deterministic.
    func claimNext(now: Date = .now) throws -> ShareHandoffClaim? {
        let root = try requireRoot()
        try ensureDirectories(at: root)
        try pruneExpired(now: now)

        var candidates = try envelopeDirectories(in: processingURL(root))
        if candidates.isEmpty {
            candidates = sortedEnvelopeDirectories(
                try envelopeDirectories(in: inboxURL(root))
            )
            guard let first = candidates.first else { return nil }
            let processing = processingURL(root).appendingPathComponent(
                first.lastPathComponent,
                isDirectory: true
            )
            try fileManager.moveItem(at: first, to: processing)
            candidates = [processing]
        } else {
            candidates = sortedEnvelopeDirectories(candidates)
        }

        for directory in candidates {
            guard let envelope = try loadEnvelope(at: directory) else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            if try isConsumed(envelope.id, root: root) {
                try? fileManager.removeItem(at: directory)
                continue
            }
            guard now.timeIntervalSince(envelope.createdAt) < Self.handoffTTL else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            do {
                let payloads = try loadPayloads(envelope, directory: directory)
                return ShareHandoffClaim(envelope: envelope, payloads: payloads)
            } catch {
                // A malformed or partially copied handoff must not block later
                // valid shares. The extension only publishes after the atomic
                // rename, so this is a fail-closed rejection path.
                try? fileManager.removeItem(at: directory)
            }
        }
        return nil
    }

    func complete(_ envelopeID: UUID, now: Date = .now) throws {
        let root = try requireRoot()
        let processing = processingURL(root).appendingPathComponent(
            envelopeID.uuidString,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: processing.path) else {
            if try isConsumed(envelopeID, root: root) { return }
            throw ShareHandoffError.claimNotFound(envelopeID)
        }
        var consumed = try loadConsumed(root: root)
        if !consumed.contains(where: { $0.id == envelopeID }) {
            consumed.append(ConsumedRecord(id: envelopeID, consumedAt: now))
            consumed = Array(consumed.suffix(512))
            try saveConsumed(consumed, root: root)
        }
        try? fileManager.removeItem(at: processing)
    }

    func reject(_ envelopeID: UUID) throws {
        let root = try requireRoot()
        let processing = processingURL(root).appendingPathComponent(
            envelopeID.uuidString,
            isDirectory: true
        )
        try? fileManager.removeItem(at: processing)
    }

    /// Test and diagnostics projection; it contains IDs/counts only.
    func pendingEnvelopeIDs() throws -> [UUID] {
        let root = try requireRoot()
        try ensureDirectories(at: root)
        let urls = try envelopeDirectories(in: inboxURL(root))
            + envelopeDirectories(in: processingURL(root))
        return urls.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    private struct AdmittedDraft {
        let id = UUID()
        let kind: ShareHandoffItemKind
        let inlineValue: String?
        let data: Data?
        let displayName: String?
        let mimeType: String?
        let byteCount: Int
    }

    private func makeItems(from drafts: [ShareHandoffDraft]) throws -> [AdmittedDraft] {
        guard !drafts.isEmpty else { throw ShareHandoffError.emptyShare }
        guard drafts.count <= Self.maximumItems else {
            throw ShareHandoffError.tooManyItems(Self.maximumItems)
        }
        var total = 0
        let items = try drafts.map { draft -> AdmittedDraft in
            switch draft.kind {
            case .text, .url:
                guard let value = draft.inlineValue,
                      !value.isEmpty,
                      !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
                    throw ShareHandoffError.invalidEnvelope
                }
                let byteCount = value.utf8.count
                guard byteCount <= Self.maximumInlineUTF8Bytes else {
                    throw ShareHandoffError.itemTooLarge(Self.maximumInlineUTF8Bytes)
                }
                total += byteCount
                return AdmittedDraft(
                    kind: draft.kind,
                    inlineValue: value,
                    data: nil,
                    displayName: nil,
                    mimeType: draft.mimeType,
                    byteCount: byteCount
                )
            case .image, .file:
                guard let data = draft.data, !data.isEmpty else {
                    throw ShareHandoffError.invalidEnvelope
                }
                guard data.count <= Self.maximumItemBytes else {
                    throw ShareHandoffError.itemTooLarge(Self.maximumItemBytes)
                }
                guard let mimeType = draft.mimeType,
                      Self.allowedMimeTypes.contains(mimeType.lowercased()) else {
                    throw ShareHandoffError.unsupportedType(draft.mimeType ?? "unknown")
                }
                let displayName = Self.sanitizeDisplayName(draft.displayName ?? "shared-item")
                total += data.count
                guard total <= Self.maximumTotalBytes else {
                    throw ShareHandoffError.totalTooLarge(Self.maximumTotalBytes)
                }
                return AdmittedDraft(
                    kind: draft.kind,
                    inlineValue: nil,
                    data: data,
                    displayName: displayName,
                    mimeType: mimeType.lowercased(),
                    byteCount: data.count
                )
            }
        }
        guard total <= Self.maximumTotalBytes else {
            throw ShareHandoffError.totalTooLarge(Self.maximumTotalBytes)
        }
        return items
    }

    private func loadEnvelope(at directory: URL) throws -> ShareHandoffEnvelope? {
        let url = directory.appendingPathComponent(Self.envelopeFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(ShareHandoffEnvelope.self, from: Data(contentsOf: url))
        let calculatedByteCount = envelope.items.reduce(0, { $0 + $1.byteCount })
        guard envelope.schemaVersion == ShareHandoffEnvelope.currentSchemaVersion,
              envelope.items.count > 0,
              envelope.items.count <= Self.maximumItems,
              envelope.totalByteCount == calculatedByteCount,
              envelope.totalByteCount <= Self.maximumTotalBytes else {
            throw ShareHandoffError.invalidEnvelope
        }
        for item in envelope.items {
            switch item.kind {
            case .text, .url:
                guard item.payloadReference == nil,
                      let value = item.inlineValue,
                      value.utf8.count == item.byteCount,
                      item.byteCount <= Self.maximumInlineUTF8Bytes else {
                    throw ShareHandoffError.invalidEnvelope
                }
            case .image, .file:
                guard item.inlineValue == nil,
                      let reference = item.payloadReference,
                      Self.isSafePayloadReference(reference),
                      item.byteCount > 0,
                      item.byteCount <= Self.maximumItemBytes,
                      let mimeType = item.mimeType,
                      Self.allowedMimeTypes.contains(mimeType.lowercased()) else {
                    throw ShareHandoffError.invalidEnvelope
                }
            }
        }
        return envelope
    }

    private func loadPayloads(
        _ envelope: ShareHandoffEnvelope,
        directory: URL
    ) throws -> [UUID: Data] {
        var result: [UUID: Data] = [:]
        for item in envelope.items {
            guard let reference = item.payloadReference else { continue }
            let url = directory.appendingPathComponent(reference).standardizedFileURL
            guard Self.isContained(url, in: directory),
                  fileManager.fileExists(atPath: url.path) else {
                throw ShareHandoffError.invalidEnvelope
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == item.byteCount else {
                throw ShareHandoffError.invalidEnvelope
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == item.byteCount else { throw ShareHandoffError.invalidEnvelope }
            result[item.id] = data
        }
        return result
    }

    private func pruneExpired(now: Date) throws {
        guard let root else { return }
        for directory in try envelopeDirectories(in: inboxURL(root))
            + envelopeDirectories(in: processingURL(root)) {
            guard let envelope = try? loadEnvelope(at: directory) else { continue }
            if now.timeIntervalSince(envelope.createdAt) >= Self.handoffTTL {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private func ensureDirectories(at root: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in [Self.inboxName, Self.processingName, Self.stagingName] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func envelopeDirectories(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && UUID(uuidString: url.lastPathComponent) != nil
        }
    }

    private func sortedEnvelopeDirectories(_ directories: [URL]) -> [URL] {
        directories.sorted { lhs, rhs in
            let left = try? loadEnvelope(at: lhs)
            let right = try? loadEnvelope(at: rhs)
            switch (left?.createdAt, right?.createdAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate < rightDate
            default:
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
        }
    }

    private func directoryByteCount(_ directory: URL) throws -> Int {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize {
                total += fileSize
            }
        }
        return total
    }

    private func loadConsumed(root: URL) throws -> [ConsumedRecord] {
        let url = root.appendingPathComponent(Self.consumedFilename)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ConsumedRecord].self, from: Data(contentsOf: url))
    }

    private func saveConsumed(_ records: [ConsumedRecord], root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(
            to: root.appendingPathComponent(Self.consumedFilename),
            options: Self.protectedWritingOptions
        )
    }

    private func isConsumed(_ id: UUID, root: URL) throws -> Bool {
        try loadConsumed(root: root).contains(where: { $0.id == id })
    }

    private func requireRoot() throws -> URL {
        guard let root else { throw ShareHandoffError.appGroupUnavailable }
        return root
    }

    private func inboxURL(_ root: URL) -> URL {
        root.appendingPathComponent(Self.inboxName, isDirectory: true)
    }

    private func processingURL(_ root: URL) -> URL {
        root.appendingPathComponent(Self.processingName, isDirectory: true)
    }

    private func stagingURL(_ root: URL) -> URL {
        root.appendingPathComponent(Self.stagingName, isDirectory: true)
    }

    private static let allowedMimeTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic",
        "application/pdf",
        "audio/mpeg", "audio/wav", "audio/mp4",
        "video/mp4", "video/quicktime"
    ]

    private static func sanitizeDisplayName(_ value: String) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
        let cleaned = leaf
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "shared-item" : cleaned).prefix(120))
    }

    private static func isSafePayloadReference(_ value: String) -> Bool {
        value.hasPrefix("payloads/")
            && !value.contains("..")
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
            && value.split(separator: "/").count == 2
    }

    private static func isContained(_ url: URL, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static var protectedWritingOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }
}
