import Foundation

struct SettingsStore {
    private let defaults: UserDefaults
    private let legacyConfigurationKey = "agent.configuration.v1"
    private let providerDirectoryKey = "model.provider-directory.v1"
    private let toolApprovalGrantsKey = "tool.approval-grants.v1"
    private let defaultAgentPresetKey = "agent.default-preset.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AgentConfiguration {
        if let profile = loadProviderDirectory().directory.activeProfile {
            return profile.configuration()
        }
        return loadLegacyConfiguration() ?? AgentConfiguration()
    }

    func save(_ configuration: AgentConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        defaults.set(data, forKey: legacyConfigurationKey)
    }

    func loadProviderDirectory() -> ProviderProfileDirectoryLoadResult {
        if let data = defaults.data(forKey: providerDirectoryKey),
           let directory = try? JSONDecoder().decode(ProviderProfileDirectory.self, from: data),
           let validated = try? directory.validated() {
            return ProviderProfileDirectoryLoadResult(
                directory: validated,
                legacyConfiguration: nil
            )
        }

        if let legacyConfiguration = loadLegacyConfiguration() {
            return ProviderProfileDirectoryLoadResult(
                directory: .migrating(legacyConfiguration),
                legacyConfiguration: legacyConfiguration
            )
        }

        return ProviderProfileDirectoryLoadResult(
            directory: .initial(),
            legacyConfiguration: nil
        )
    }

    func save(_ directory: ProviderProfileDirectory) throws {
        let validated = try directory.validated()
        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: providerDirectoryKey)
        defaults.removeObject(forKey: legacyConfigurationKey)
    }

    func loadToolApprovalGrants() -> [ToolApprovalGrant] {
        guard let data = defaults.data(forKey: toolApprovalGrantsKey),
              let decoded = try? JSONDecoder().decode([ToolApprovalGrant].self, from: data) else {
            return []
        }

        var scopes = Set<ToolApprovalScope>()
        return decoded
            .compactMap { try? $0.validated() }
            .sorted { lhs, rhs in
                if lhs.grantedAt != rhs.grantedAt {
                    return lhs.grantedAt > rhs.grantedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .filter { scopes.insert($0.scope).inserted }
            .prefix(ToolApprovalGrant.maximumStoredGrants)
            .map { $0 }
    }

    func saveToolApprovalGrants(_ grants: [ToolApprovalGrant]) throws {
        guard grants.count <= ToolApprovalGrant.maximumStoredGrants else {
            throw ToolApprovalScopeError.tooManyGrants
        }
        let validated = try grants.map { try $0.validated() }
        guard Set(validated.map(\.scope)).count == validated.count else {
            throw ToolApprovalScopeError.invalidResource
        }
        defaults.set(
            try JSONEncoder().encode(validated),
            forKey: toolApprovalGrantsKey
        )
    }

    func clearToolApprovalGrants() {
        defaults.removeObject(forKey: toolApprovalGrantsKey)
    }

    func loadDefaultAgentPresetID() -> String {
        guard let id = defaults.string(forKey: defaultAgentPresetKey),
              AgentPresetIdentifier.isValid(id) else {
            return AgentPresetRegistry.defaultID
        }
        return id
    }

    func saveDefaultAgentPresetID(_ id: String) throws {
        guard AgentPresetIdentifier.isValid(id) else {
            throw AgentPresetError.invalidID(id)
        }
        defaults.set(id, forKey: defaultAgentPresetKey)
    }

    func clear() {
        defaults.removeObject(forKey: legacyConfigurationKey)
        defaults.removeObject(forKey: providerDirectoryKey)
        defaults.removeObject(forKey: defaultAgentPresetKey)
    }

    private func loadLegacyConfiguration() -> AgentConfiguration? {
        guard let data = defaults.data(forKey: legacyConfigurationKey) else { return nil }
        return try? JSONDecoder().decode(AgentConfiguration.self, from: data)
    }
}

struct ProviderProfileDirectoryLoadResult: Sendable, Equatable {
    let directory: ProviderProfileDirectory
    let legacyConfiguration: AgentConfiguration?
}
