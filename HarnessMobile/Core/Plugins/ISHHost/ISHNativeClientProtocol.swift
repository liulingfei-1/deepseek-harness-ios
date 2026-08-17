import Foundation

private let ishNativeClientMaximumJSONSafeInteger: UInt64 = 9_007_199_254_740_991

enum ISHNativeClientScope: String, Codable, Sendable, Equatable {
    case process
}

enum ISHNativeClientRenderer: String, Codable, Sendable, Equatable {
    case keyValue
    case markdown
}

enum ISHNativeClientEndpointKind: String, Codable, Sendable, Equatable {
    case hostService
}

enum ISHNativeClientActionKind: String, Codable, Sendable, Equatable {
    case hostTool
}

struct ISHNativeClientSnapshot: Codable, Sendable, Equatable {
    let revision: UInt64
    let scope: ISHNativeClientScope
    let plugins: [ISHNativeClientPlugin]

    static let empty = ISHNativeClientSnapshot(
        revision: 0,
        scope: .process,
        plugins: []
    )
}

struct ISHNativeClientPlugin: Codable, Sendable, Equatable, Identifiable {
    var id: String { pluginId }

    let pluginId: String
    let packageName: String
    let version: String
    let scope: ISHNativeClientScope
    let activationGeneration: UInt64
    let sourceDigest: String
    let schemaVersion: Int
    let minimumRuntime: Int
    let inject: [String]
    let immediately: Bool
    let contributions: ISHNativeClientContributions
    let endpoints: [ISHNativeClientEndpoint]
    let permissions: [String]
}

struct ISHNativeClientContributions: Codable, Sendable, Equatable {
    let inspectors: [ISHNativeClientInspectorContribution]
    let settings: [ISHNativeClientSettingsContribution]
    let commands: [ISHNativeClientCommandContribution]
}

struct ISHNativeClientInspectorContribution: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let order: Int
    let renderer: ISHNativeClientRenderer
    let endpoint: String
}

struct ISHNativeClientSettingsContribution: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let namespace: String
    let order: Int
}

struct ISHNativeClientCommandContribution: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }

    let name: String
    let description: String
    let inputHint: String?
    let order: Int
    let action: ISHNativeClientActionDescriptor
}

struct ISHNativeClientActionDescriptor: Codable, Sendable, Equatable {
    let kind: ISHNativeClientActionKind
    let name: String
    let arguments: [String: JSONValue]
    let inputKey: String?
}

struct ISHNativeClientEndpoint: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let kind: ISHNativeClientEndpointKind
    let entry: String
    let service: String
    let method: String
    let readOnly: Bool
}

struct ISHNativeClientEndpointInvocation: Sendable, Equatable {
    let pluginId: String
    let activationGeneration: UInt64
    let endpointId: String
    let arguments: [String: JSONValue]

    init(
        pluginId: String,
        activationGeneration: UInt64,
        endpointId: String,
        arguments: [String: JSONValue] = [:]
    ) {
        self.pluginId = pluginId
        self.activationGeneration = activationGeneration
        self.endpointId = endpointId
        self.arguments = arguments
    }
}

enum ISHNativeClientError: LocalizedError, Sendable, Equatable {
    case invalidManifest(pluginID: String, reason: String)
    case endpointFailed(code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidManifest(pluginID, reason):
            return "Native client manifest for \(pluginID) is invalid: \(reason)"
        case let .endpointFailed(code, message):
            if let code {
                return "Native client endpoint failed (\(code)): \(message)"
            }
            return "Native client endpoint failed: \(message)"
        }
    }
}

extension ISHNativeClientPlugin {
    func validated() throws -> Self {
        guard schemaVersion == 1, minimumRuntime == 1 else {
            throw invalid("unsupported schema or runtime")
        }
        guard scope == .process,
              activationGeneration > 0,
              activationGeneration <= ishNativeClientMaximumJSONSafeInteger,
              Self.isIdentifier(pluginId),
              sourceDigest.utf8.count == 64,
              sourceDigest.allSatisfy({ $0.isHexDigit }) else {
            throw invalid("invalid plugin identity")
        }
        guard Set(inject).count == inject.count,
              inject.allSatisfy(Self.isServiceName) else {
            throw invalid("invalid or duplicate inject service")
        }

        var endpointIDs = Set<String>()
        for endpoint in endpoints {
            guard endpointIDs.insert(endpoint.id).inserted,
                  Self.isIdentifier(endpoint.id),
                  Self.isIdentifier(endpoint.entry),
                  Self.isServiceName(endpoint.service),
                  Self.isServiceName(endpoint.method),
                  endpoint.kind == .hostService,
                  endpoint.readOnly else {
                throw invalid("invalid endpoint directory")
            }
        }

        var inspectorIDs = Set<String>()
        var referencedEndpoints = Set<String>()
        for inspector in contributions.inspectors {
            guard inspectorIDs.insert(inspector.id).inserted,
                  Self.isIdentifier(inspector.id),
                  !inspector.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  endpointIDs.contains(inspector.endpoint) else {
                throw invalid("invalid inspector contribution")
            }
            referencedEndpoints.insert(inspector.endpoint)
        }
        guard referencedEndpoints == endpointIDs else {
            throw invalid("unreferenced endpoint")
        }

        var settingsIDs = Set<String>()
        for settings in contributions.settings {
            guard settingsIDs.insert(settings.id).inserted,
                  Self.isIdentifier(settings.id),
                  Self.isServiceName(settings.namespace),
                  !settings.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("invalid settings contribution")
            }
        }

        var commandNames = Set<String>()
        for command in contributions.commands {
            guard commandNames.insert(command.name).inserted,
                  SlashCommandParser.isValidName(command.name),
                  !command.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  command.action.kind == .hostTool,
                  Self.isServiceName(command.action.name),
                  (command.inputHint == nil) == (command.action.inputKey == nil) else {
                throw invalid("invalid command contribution")
            }
            if let inputKey = command.action.inputKey {
                guard Self.isIdentifier(inputKey) else {
                    throw invalid("invalid command input key")
                }
            }
            do {
                try ISHPluginHostCredentialFirewall.validate(.object(command.action.arguments))
            } catch {
                throw invalid("command arguments contain credentials")
            }
        }

        let requiredPermissions = Self.requiredPermissions(for: self)
        guard Set(permissions) == requiredPermissions,
              Set(permissions).count == permissions.count else {
            throw invalid("permission set does not match contributions")
        }
        return self
    }

    private func invalid(_ reason: String) -> ISHNativeClientError {
        .invalidManifest(pluginID: pluginId, reason: reason)
    }

    private static func requiredPermissions(for plugin: Self) -> Set<String> {
        var required = Set<String>()
        if !plugin.contributions.inspectors.isEmpty { required.insert("ui.inspector") }
        if !plugin.contributions.settings.isEmpty { required.insert("ui.settings-link") }
        if !plugin.contributions.commands.isEmpty { required.insert("ui.command") }
        for inspector in plugin.contributions.inspectors {
            guard let endpoint = plugin.endpoints.first(where: { $0.id == inspector.endpoint }) else {
                continue
            }
            required.insert("host.service:\(endpoint.service).\(endpoint.method)")
        }
        for settings in plugin.contributions.settings {
            required.insert("settings.read:\(settings.namespace)")
        }
        for command in plugin.contributions.commands {
            required.insert("host.tool:\(command.action.name)")
        }
        return required
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= 128,
              Self.isASCIIAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            Self.isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }

    private static func isServiceName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= 128,
              Self.isASCIIAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            Self.isASCIIAlphaNumeric($0)
                || $0 == 0x2D
                || $0 == 0x2E
                || $0 == 0x2F
                || $0 == 0x5F
        }
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }
}

extension ISHPluginHostClient {
    func nativeClientContributions(
        sessionId: String? = nil
    ) async throws -> ISHNativeClientSnapshot {
        var params: [String: JSONValue] = [:]
        if let sessionId {
            params["sessionId"] = .string(sessionId)
        }
        let result = try await request(method: .contributions, params: .object(params))
        guard let nativeClient = result.objectValue?["nativeClient"] else {
            return .empty
        }
        return try Self.decodeNativeClient(ISHNativeClientSnapshot.self, from: nativeClient)
    }

    func invokeNativeClientEndpoint(
        _ invocation: ISHNativeClientEndpointInvocation
    ) async throws -> JSONValue {
        guard invocation.activationGeneration > 0,
              invocation.activationGeneration <= ishNativeClientMaximumJSONSafeInteger else {
            throw ISHNativeClientError.invalidManifest(
                pluginID: invocation.pluginId,
                reason: "activation generation exceeds JSON safe integer range"
            )
        }
        let arguments = JSONValue.object(invocation.arguments)
        try ISHPluginHostCredentialFirewall.validate(arguments)
        let response = try await request(
            method: .invoke,
            params: .object([
                "target": .string("nativeClientEndpoint"),
                "pluginId": .string(invocation.pluginId),
                "activationGeneration": .number(Double(invocation.activationGeneration)),
                "endpointId": .string(invocation.endpointId),
                "arguments": arguments
            ])
        )
        try ISHPluginHostCredentialFirewall.validate(response)
        guard let object = response.objectValue,
              object["ok"] == .bool(true) else {
            throw ISHNativeClientError.endpointFailed(
                code: response.objectValue?["code"]?.stringValue,
                message: response.objectValue?["message"]?.displayText ?? response.displayText
            )
        }
        return object["value"] ?? .null
    }

    private static func decodeNativeClient<Value: Decodable>(
        _ type: Value.Type,
        from value: JSONValue
    ) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}
