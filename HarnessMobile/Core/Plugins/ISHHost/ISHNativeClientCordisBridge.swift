import Foundation

struct ISHNativeClientSynchronizationFailure: Sendable, Equatable, Identifiable {
    var id: String { pluginID }

    let pluginID: String
    let message: String
}

enum ISHNativeClientRegistryError: LocalizedError, Sendable, Equatable {
    case duplicatePlugin(String)

    var errorDescription: String? {
        switch self {
        case let .duplicatePlugin(pluginID):
            return "Native client plugin \(pluginID) already owns an active generation."
        }
    }
}

private struct ISHNativeClientRegistryToken: Sendable, Equatable {
    let pluginID: String
    let activationID: UUID
}

actor ISHNativeClientContributionRegistry {
    private struct ActivePlugin: Sendable {
        let activationID: UUID
        let plugin: ISHNativeClientPlugin
    }

    private var active: [String: ActivePlugin] = [:]

    fileprivate func activate(
        _ plugin: ISHNativeClientPlugin
    ) throws -> ISHNativeClientRegistryToken {
        guard active[plugin.pluginId] == nil else {
            throw ISHNativeClientRegistryError.duplicatePlugin(plugin.pluginId)
        }
        let activationID = UUID()
        active[plugin.pluginId] = ActivePlugin(
            activationID: activationID,
            plugin: plugin
        )
        return ISHNativeClientRegistryToken(
            pluginID: plugin.pluginId,
            activationID: activationID
        )
    }

    fileprivate func deactivate(_ token: ISHNativeClientRegistryToken) {
        guard active[token.pluginID]?.activationID == token.activationID else { return }
        active.removeValue(forKey: token.pluginID)
    }

    func plugins() -> [ISHNativeClientPlugin] {
        active.values.map(\.plugin).sorted { $0.pluginId < $1.pluginId }
    }

    func plugin(id: String) -> ISHNativeClientPlugin? {
        active[id]?.plugin
    }
}

private struct ISHNativeClientActivation: Sendable {
    let registry: ISHNativeClientContributionRegistry
    let registryToken: ISHNativeClientRegistryToken
    let commandRegistry: SlashCommandRegistry
    let commandRegistrations: [SlashCommandRegistration]

    func dispose() async {
        for registration in commandRegistrations.reversed() {
            _ = await commandRegistry.unregister(registration)
        }
        await registry.deactivate(registryToken)
    }
}

enum ISHNativeClientCordisBridge {
    private static let pluginIDPrefix = "ish.native-client."

    static func cordisPluginID(for pluginID: String) -> CordisPluginID {
        CordisPluginID(rawValue: pluginIDPrefix + pluginID)
    }

    static func isManaged(_ pluginID: CordisPluginID) -> Bool {
        pluginID.rawValue.hasPrefix(pluginIDPrefix)
    }

    static func definition(
        plugin: ISHNativeClientPlugin,
        sessionID: String,
        client: ISHPluginHostClient,
        registry: ISHNativeClientContributionRegistry,
        commandRegistry: SlashCommandRegistry
    ) -> CordisPluginDefinition {
        let cordisID = cordisPluginID(for: plugin.pluginId)
        return CordisPluginDefinition(
            id: cordisID,
            version: "\(plugin.version)+native.\(plugin.activationGeneration).\(plugin.sourceDigest.prefix(12))"
        ) { context in
            try await context.effect("native-client-generation") {
                let activation = try await activate(
                    plugin: plugin,
                    sessionID: sessionID,
                    client: client,
                    registry: registry,
                    commandRegistry: commandRegistry
                )
                return {
                    await activation.dispose()
                }
            }
        }
    }

    private static func activate(
        plugin: ISHNativeClientPlugin,
        sessionID: String,
        client: ISHPluginHostClient,
        registry: ISHNativeClientContributionRegistry,
        commandRegistry: SlashCommandRegistry
    ) async throws -> ISHNativeClientActivation {
        let validated = try plugin.validated()
        var registrations: [SlashCommandRegistration] = []
        do {
            for command in validated.contributions.commands {
                let input = try command.inputHint.map(SlashCommandInputDescriptor.init(hint:))
                let definition = try SlashCommandDefinition(
                    name: command.name,
                    description: command.description,
                    input: input,
                    recordInput: false
                ) { invocation in
                    var arguments = command.action.arguments
                    if let inputKey = command.action.inputKey {
                        arguments[inputKey] = .string(invocation.parsed.trimmedInput)
                    }
                    let response = try await client.invoke(
                        .tool(
                            sessionId: sessionID,
                            name: command.action.name,
                            arguments: .object(arguments),
                            callId: invocation.commandID
                        )
                    )
                    if response.objectValue?["isError"] == .bool(true) {
                        throw ISHHostedToolError.executionFailed(
                            response.objectValue?["value"]?.displayText
                                ?? response.objectValue?["error"]?.displayText
                                ?? response.displayText
                        )
                    }
                    return .success(
                        text: response.objectValue?["value"]?.displayText ?? response.displayText
                    )
                }
                registrations.append(try await commandRegistry.register(definition))
            }
            let token = try await registry.activate(validated)
            return ISHNativeClientActivation(
                registry: registry,
                registryToken: token,
                commandRegistry: commandRegistry,
                commandRegistrations: registrations
            )
        } catch {
            for registration in registrations.reversed() {
                _ = await commandRegistry.unregister(registration)
            }
            throw error
        }
    }
}

actor ISHNativeClientCordisCoordinator {
    private struct Identity: Sendable, Equatable {
        let activationGeneration: UInt64
        let sourceDigest: String
        let sessionID: String
    }

    private let runtime: CordisPluginRuntime
    private let registry: ISHNativeClientContributionRegistry
    private let commandRegistry: SlashCommandRegistry
    private var identities: [CordisPluginID: Identity] = [:]

    init(
        runtime: CordisPluginRuntime,
        registry: ISHNativeClientContributionRegistry,
        commandRegistry: SlashCommandRegistry
    ) {
        self.runtime = runtime
        self.registry = registry
        self.commandRegistry = commandRegistry
    }

    func synchronize(
        _ snapshot: ISHNativeClientSnapshot,
        sessionID: String,
        client: ISHPluginHostClient
    ) async -> [ISHNativeClientSynchronizationFailure] {
        var failures: [ISHNativeClientSynchronizationFailure] = []
        guard snapshot.scope == .process else {
            return [
                ISHNativeClientSynchronizationFailure(
                    pluginID: "native-client-directory",
                    message: "Unsupported native client scope \(snapshot.scope.rawValue)."
                )
            ]
        }

        var desired: [CordisPluginID: ISHNativeClientPlugin] = [:]
        var duplicateIDs = Set<CordisPluginID>()
        for plugin in snapshot.plugins {
            let cordisID = ISHNativeClientCordisBridge.cordisPluginID(for: plugin.pluginId)
            if duplicateIDs.contains(cordisID) {
                continue
            }
            if desired.removeValue(forKey: cordisID) != nil {
                duplicateIDs.insert(cordisID)
                failures.append(
                    ISHNativeClientSynchronizationFailure(
                        pluginID: plugin.pluginId,
                        message: "Duplicate plugin id in native contribution directory."
                    )
                )
            } else {
                desired[cordisID] = plugin
            }
        }

        let installed = await runtime.snapshots()
        let managedInstalled = installed.filter { ISHNativeClientCordisBridge.isManaged($0.id) }
        for current in managedInstalled
        where desired[current.id] == nil && !duplicateIDs.contains(current.id) {
            do {
                _ = try await runtime.uninstall(current.id)
                identities.removeValue(forKey: current.id)
            } catch {
                failures.append(failure(pluginID: current.id.rawValue, error: error))
            }
        }

        for cordisID in desired.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let plugin = desired[cordisID] else { continue }
            let identity = Identity(
                activationGeneration: plugin.activationGeneration,
                sourceDigest: plugin.sourceDigest,
                sessionID: sessionID
            )
            let currentSnapshot = try? await runtime.snapshot(for: cordisID)
            if identities[cordisID] == identity, currentSnapshot?.state == .active {
                continue
            }
            let definition = ISHNativeClientCordisBridge.definition(
                plugin: plugin,
                sessionID: sessionID,
                client: client,
                registry: registry,
                commandRegistry: commandRegistry
            )
            do {
                let result: CordisPluginSnapshot
                if currentSnapshot == nil {
                    result = try await runtime.install(definition)
                } else {
                    result = try await runtime.replace(cordisID, with: definition)
                }
                guard result.state == .active else {
                    failures.append(
                        ISHNativeClientSynchronizationFailure(
                            pluginID: plugin.pluginId,
                            message: result.error ?? "Native client activation did not become active."
                        )
                    )
                    continue
                }
                identities[cordisID] = identity
            } catch {
                failures.append(failure(pluginID: plugin.pluginId, error: error))
            }
        }
        return failures.sorted { $0.pluginID < $1.pluginID }
    }

    func removeAll() async {
        let installed = await runtime.snapshots()
            .filter { ISHNativeClientCordisBridge.isManaged($0.id) }
        for snapshot in installed {
            _ = try? await runtime.uninstall(snapshot.id)
        }
        identities.removeAll(keepingCapacity: false)
    }

    private func failure(
        pluginID: String,
        error: Error
    ) -> ISHNativeClientSynchronizationFailure {
        ISHNativeClientSynchronizationFailure(
            pluginID: pluginID,
            message: error.localizedDescription
        )
    }
}
