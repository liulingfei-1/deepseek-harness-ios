import Foundation

struct ISHPluginHostInstallation: Sendable, Equatable {
    let directoryURL: URL
    let manifest: ISHPluginHostInstallManifest
    let installedDependenciesNow: Bool
}

actor ISHPluginHostInstaller {
    static let shared = ISHPluginHostInstaller()

    private struct InstallStamp: Codable, Equatable {
        let hostVersion: String
        let protocolVersion: Int
    }

    private static let resourceNames = [
        "host.mjs",
        "marketplace.mjs",
        "manifest.json",
        "package.json",
        "package-lock.json",
        "install.sh"
    ]

    private let coordinator: ISHSandboxCoordinator
    private let fileManager: FileManager

    init(
        coordinator: ISHSandboxCoordinator = .shared,
        fileManager: FileManager = .default
    ) {
        self.coordinator = coordinator
        self.fileManager = fileManager
    }

    func installIfNeeded(
        workspaceURL: URL,
        bundle: Bundle = .main,
        registryURL: URL? = nil,
        mirrorURL: URL? = nil
    ) async throws -> ISHPluginHostInstallation {
        let target = workspaceURL
            .appendingPathComponent(".harness-mobile", isDirectory: true)
            .appendingPathComponent("plugin-host", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try stageResources(from: bundle, to: target)

        let manifestURL = target.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            ISHPluginHostInstallManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let selectedRegistry = try validatedRegistryURL(registryURL ?? manifest.primaryRegistry)
        let selectedMirror = try mirrorURL.map(validatedRegistryURL)
        let stampURL = target.appendingPathComponent(".install-stamp.json")
        let expectedStamp = InstallStamp(
            hostVersion: manifest.hostVersion,
            protocolVersion: manifest.protocolVersion
        )
        if dependenciesMatch(manifest, in: target),
           let stampData = try? Data(contentsOf: stampURL),
           let stamp = try? JSONDecoder().decode(InstallStamp.self, from: stampData),
           stamp == expectedStamp {
            return ISHPluginHostInstallation(
                directoryURL: target,
                manifest: manifest,
                installedDependenciesNow: false
            )
        }

        let networkLease = await coordinator.beginTemporaryGuestNetworkAccess()
        do {
            var command = "cd /workspace/.harness-mobile/plugin-host && sh ./install.sh --registry "
                + shellQuote(selectedRegistry.absoluteString)
            if let selectedMirror {
                command += " --mirror " + shellQuote(selectedMirror.absoluteString)
            }
            let result = try await coordinator.execute(
                sessionID: "ish-plugin-host-installer",
                command: command,
                workspaceURL: workspaceURL,
                timeout: 1_800,
                maximumOutputBytes: 512 * 1_024,
                policy: ISHSandboxExecutionPolicy(
                    mode: .dangerFullAccess,
                    workspaceRoot: workspaceURL
                )
            )
            guard result.exitCode == 0 else {
                throw ISHPluginHostError.installationFailed(result.combinedOutput)
            }
            let stampData = try JSONEncoder().encode(expectedStamp)
            try stampData.write(to: stampURL, options: .atomic)
        } catch {
            await coordinator.endTemporaryGuestNetworkAccess(networkLease)
            throw error
        }
        await coordinator.endTemporaryGuestNetworkAccess(networkLease)

        return ISHPluginHostInstallation(
            directoryURL: target,
            manifest: manifest,
            installedDependenciesNow: true
        )
    }

    private func dependenciesMatch(
        _ manifest: ISHPluginHostInstallManifest,
        in target: URL
    ) -> Bool {
        manifest.packages.allSatisfy { package in
            let packageURL = package.name
                .split(separator: "/")
                .reduce(target.appendingPathComponent("node_modules", isDirectory: true)) {
                    $0.appendingPathComponent(String($1), isDirectory: true)
                }
                .appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: packageURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["name"] as? String == package.name,
                  object["version"] as? String == package.version else {
                return false
            }
            return true
        }
    }

    private func stageResources(from bundle: Bundle, to target: URL) throws {
        for name in Self.resourceNames {
            guard let source = resourceURL(named: name, in: bundle) else {
                throw ISHPluginHostError.resourceMissing(name)
            }
            let destination = target.appendingPathComponent(name)
            if let sourceData = try? Data(contentsOf: source),
               let destinationData = try? Data(contentsOf: destination),
               sourceData == destinationData {
                continue
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func resourceURL(named name: String, in bundle: Bundle) -> URL? {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let resourceName = parts[0]
        let extensionName = parts.count == 2 ? parts[1] : nil
        return bundle.url(
            forResource: resourceName,
            withExtension: extensionName,
            subdirectory: "PluginHost"
        ) ?? bundle.url(forResource: resourceName, withExtension: extensionName)
    }

    private func validatedRegistryURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw ISHPluginHostError.invalidRegistryURL(url.absoluteString)
        }
        return url
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
