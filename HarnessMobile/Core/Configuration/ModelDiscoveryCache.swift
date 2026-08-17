import CryptoKit
import Foundation

struct ModelDiscoveryCacheKey: Sendable, Equatable, Hashable {
    let providerID: ModelProviderID
    let endpoint: URL
    let credentialPartition: String

    init(providerID: ModelProviderID, endpoint: URL, apiKey: String?) {
        self.providerID = providerID
        self.endpoint = endpoint
        let normalizedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedKey.isEmpty {
            credentialPartition = "anonymous"
        } else {
            credentialPartition = Self.sha256(normalizedKey)
        }
    }

    fileprivate var fileName: String {
        Self.sha256(
            providerID.rawValue
                + "\u{0}"
                + endpoint.absoluteString
                + "\u{0}"
                + credentialPartition
        ) + ".json"
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ModelDiscoveryCacheEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let adapterSchemaVersion: Int
    let providerID: ModelProviderID
    let endpoint: String
    let fetchedAt: Date
    let models: [ProviderModel]
}

actor ModelDiscoveryCache {
    private static let maximumCacheBytes = 4 * 1_024 * 1_024
    private static let maximumModelCount = 10_000
    private let directoryURL: URL
    private let timeToLive: TimeInterval
    private let now: @Sendable () -> Date

    init(
        directoryURL: URL? = nil,
        timeToLive: TimeInterval = 24 * 60 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL()
        self.timeToLive = timeToLive
        self.now = now
    }

    func load(
        key: ModelDiscoveryCacheKey,
        adapterSchemaVersion: Int
    ) -> ModelCatalogSnapshot? {
        let fileURL = directoryURL.appendingPathComponent(key.fileName, isDirectory: false)
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= Self.maximumCacheBytes,
              let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maximumCacheBytes else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let currentDate = now()
        guard let envelope = try? decoder.decode(ModelDiscoveryCacheEnvelope.self, from: data),
              envelope.schemaVersion == ModelDiscoveryCacheEnvelope.currentSchemaVersion,
              envelope.adapterSchemaVersion == adapterSchemaVersion,
              envelope.providerID == key.providerID,
              envelope.endpoint == key.endpoint.absoluteString,
              envelope.models.count <= Self.maximumModelCount,
              envelope.models.allSatisfy(Self.isValidModel),
              envelope.fetchedAt <= currentDate.addingTimeInterval(5 * 60),
              currentDate.timeIntervalSince(envelope.fetchedAt) <= timeToLive else {
            return nil
        }

        return ModelCatalogSnapshot(
            providerID: envelope.providerID,
            source: .cache,
            catalogVersion: "remote-models-v\(adapterSchemaVersion)",
            fetchedAt: envelope.fetchedAt,
            models: envelope.models
        )
    }

    func store(
        key: ModelDiscoveryCacheKey,
        adapterSchemaVersion: Int,
        fetchedAt: Date,
        models: [ProviderModel]
    ) throws {
        guard models.count <= Self.maximumModelCount,
              models.allSatisfy(Self.isValidModel) else {
            throw ModelDiscoveryCacheError.invalidModels
        }
        let envelope = ModelDiscoveryCacheEnvelope(
            schemaVersion: ModelDiscoveryCacheEnvelope.currentSchemaVersion,
            adapterSchemaVersion: adapterSchemaVersion,
            providerID: key.providerID,
            endpoint: key.endpoint.absoluteString,
            fetchedAt: fetchedAt,
            models: models
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumCacheBytes else {
            throw ModelDiscoveryCacheError.cacheTooLarge
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try data.write(
            to: directoryURL.appendingPathComponent(key.fileName, isDirectory: false),
            options: .atomic
        )
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private static func defaultDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(
            "HarnessMobile/ModelDiscovery",
            isDirectory: true
        )
    }

    private static func isValidModel(_ model: ProviderModel) -> Bool {
        let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 512 else { return false }
        if let name = model.name, name.utf8.count > 512 { return false }
        if let contextWindow = model.contextWindow, contextWindow <= 0 { return false }
        if let maxOutputTokens = model.maxOutputTokens, maxOutputTokens <= 0 { return false }
        return true
    }
}

enum ModelDiscoveryCacheError: LocalizedError, Sendable {
    case invalidModels
    case cacheTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidModels:
            return "模型发现缓存包含无效模型数据。"
        case .cacheTooLarge:
            return "模型发现缓存超过 4 MiB 上限。"
        }
    }
}
