import Foundation

/// Runtime capability snapshot used by model pickers and child-agent routing.
/// ModelDiscoveryCache owns disk TTL; this actor owns the current in-process
/// view so a provider refresh is immediately visible without rebuilding UI.
struct ProviderCapabilitySnapshot: Codable, Sendable, Equatable {
    let profileID: String
    let providerID: ModelProviderID
    let catalog: ModelCatalogSnapshot
    let reasoningModes: [ReasoningMode]
    let refreshedAt: Date
}

actor ProviderCapabilityCache {
    private static let maximumBytes = 4 * 1_024 * 1_024
    private let storageURL: URL?
    private var snapshots: [String: ProviderCapabilitySnapshot] = [:]

    init(storageURL: URL? = ProviderCapabilityCache.defaultStorageURL()) {
        self.storageURL = storageURL
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              data.count <= Self.maximumBytes else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(
            [String: ProviderCapabilitySnapshot].self,
            from: data
        ) else { return }
        snapshots = decoded.filter { key, value in
            !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && key == value.profileID
        }
    }

    func update(profileID: String, snapshot: ModelCatalogSnapshot) {
        snapshots[profileID] = ProviderCapabilitySnapshot(
            profileID: profileID,
            providerID: snapshot.providerID,
            catalog: snapshot,
            reasoningModes: ReasoningMode.supportedModes(for: snapshot.providerID),
            refreshedAt: snapshot.fetchedAt ?? Date()
        )
        persist()
    }

    func snapshot(profileID: String) -> ProviderCapabilitySnapshot? {
        snapshots[profileID]
    }

    func remove(profileID: String) {
        snapshots.removeValue(forKey: profileID)
        persist()
    }

    func removeAll() {
        snapshots.removeAll()
        persist()
    }

    private func persist() {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshots),
              data.count <= Self.maximumBytes else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // Capability persistence is auxiliary; a failed write must not
            // make a successful provider refresh fail.
        }
    }

    private static func defaultStorageURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("HarnessMobile/ProviderCapabilities/snapshots.json")
    }
}
