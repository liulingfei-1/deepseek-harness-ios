import Foundation

/// Provider-bundle lifecycle and model catalog discovery are UI-facing
/// coordination only. Keeping them outside `AppModel.swift` lets an AI (or a
/// human) work on provider installation without loading the conversation loop,
/// plugin runtime, or trajectory projection.
@MainActor
extension AppModel {
    func setProviderBundleEnabled(_ id: AgentProviderBundleID, enabled: Bool) throws {
        guard providerBundles.contains(where: { $0.id == id }) else { return }
        if enabled, providerBundleInstallStatuses[id]?.phase != .installed {
            throw AgentProviderBundleValidationError.notInstalled
        }
        var next = providerBundles
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].enabled = enabled
        try providerBundleStore.save(next)
        providerBundles = next
    }

    func providerBundle(_ id: AgentProviderBundleID) -> AgentProviderBundle? {
        providerBundles.first { $0.id == id }
    }

    func providerBundleInstallStatus(
        _ id: AgentProviderBundleID
    ) -> AgentProviderBundleInstallStatus {
        providerBundleInstallStatuses[id] ?? .unknown(id)
    }

    func refreshProviderBundleInstallStatuses() async {
        let workspaceURL: URL
        do {
            workspaceURL = try await workspaceStore.rootURL()
        } catch {
            for id in AgentProviderBundleID.allCases {
                providerBundleInstallStatuses[id] = AgentProviderBundleInstallStatus(
                    bundleID: id,
                    phase: .failed,
                    message: error.localizedDescription,
                    installedVersion: nil,
                    didInstall: false
                )
            }
            return
        }
        for id in AgentProviderBundleID.allCases {
            guard providerBundleInstallTasks[id] == nil else { continue }
            _ = await providerBundleInstaller.inspect(
                id,
                workspaceURL: workspaceURL,
                onEvent: Self.providerBundleInstallObserver(for: self)
            )
        }
    }

    func startProviderBundleInstall(
        _ id: AgentProviderBundleID,
        reinstall: Bool = false
    ) {
        guard providerBundleInstallTasks[id] == nil else { return }
        providerBundleInstallTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.providerBundleInstallTasks[id] = nil }
            do {
                let workspaceURL = try await self.workspaceStore.rootURL()
                _ = try await self.providerBundleInstaller.install(
                    id,
                    workspaceURL: workspaceURL,
                    reinstall: reinstall,
                    onEvent: Self.providerBundleInstallObserver(for: self)
                )
            } catch is CancellationError {
                // The installer publishes a durable cancellation/rollback
                // status before it returns cancellation to this UI task.
            } catch {
                let current = self.providerBundleInstallStatus(id)
                if current.phase != .failed {
                    self.providerBundleInstallStatuses[id] = AgentProviderBundleInstallStatus(
                        bundleID: id,
                        phase: .failed,
                        message: error.localizedDescription,
                        installedVersion: nil,
                        didInstall: false
                    )
                }
            }
        }
    }

    func cancelProviderBundleInstall(_ id: AgentProviderBundleID) {
        providerBundleInstallTasks[id]?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.providerBundleInstaller.cancel(
                id,
                onEvent: Self.providerBundleInstallObserver(for: self)
            )
        }
    }

    private static func providerBundleInstallObserver(
        for model: AppModel
    ) -> AgentProviderBundleInstallObserver {
        { [weak model] status in
            await MainActor.run {
                model?.providerBundleInstallStatuses[status.bundleID] = status
            }
        }
    }

    func discoverModels(
        for configuration: AgentConfiguration,
        temporaryAPIKey: String? = nil,
        forceRefresh: Bool = false
    ) async throws -> ModelCatalogSnapshot {
        let trustedOrigin = try configuration.credentialOrigin()
        let normalizedTemporaryKey = temporaryAPIKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey: String?
        if let normalizedTemporaryKey, !normalizedTemporaryKey.isEmpty {
            apiKey = normalizedTemporaryKey
        } else {
            apiKey = try await self.apiKey(for: configuration)
        }

        return try await modelCatalogDiscoverer.discoverModels(
            ModelDiscoveryRequest(
                configuration: configuration,
                apiKey: apiKey,
                trustedOrigin: trustedOrigin,
                forceRefresh: forceRefresh
            )
        )
    }
}
