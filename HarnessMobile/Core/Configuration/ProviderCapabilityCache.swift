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
    private var snapshots: [String: ProviderCapabilitySnapshot] = [:]

    func update(profileID: String, snapshot: ModelCatalogSnapshot) {
        snapshots[profileID] = ProviderCapabilitySnapshot(
            profileID: profileID,
            providerID: snapshot.providerID,
            catalog: snapshot,
            reasoningModes: ReasoningMode.supportedModes(for: snapshot.providerID),
            refreshedAt: snapshot.fetchedAt ?? Date()
        )
    }

    func snapshot(profileID: String) -> ProviderCapabilitySnapshot? {
        snapshots[profileID]
    }

    func remove(profileID: String) {
        snapshots.removeValue(forKey: profileID)
    }

    func removeAll() {
        snapshots.removeAll()
    }
}
