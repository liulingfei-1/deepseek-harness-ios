import Foundation

private let ishNativeClientMaximumJSONSafeInteger: UInt64 = 9_007_199_254_740_991
private let ishNativeClientMaximumContributionBytes = 32 * 1_024
private let ishNativeClientMaximumContributions = 64

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
    let cards: [ISHNativeClientCardContribution]
    let references: [ISHNativeClientReferenceContribution]

    init(
        inspectors: [ISHNativeClientInspectorContribution],
        settings: [ISHNativeClientSettingsContribution],
        commands: [ISHNativeClientCommandContribution],
        cards: [ISHNativeClientCardContribution] = [],
        references: [ISHNativeClientReferenceContribution] = []
    ) {
        self.inspectors = inspectors
        self.settings = settings
        self.commands = commands
        self.cards = cards
        self.references = references
    }

    private enum CodingKeys: String, CodingKey {
        case inspectors
        case settings
        case commands
        case cards
        case references
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inspectors = try container.decodeIfPresent(
            [ISHNativeClientInspectorContribution].self,
            forKey: .inspectors
        ) ?? []
        settings = try container.decodeIfPresent(
            [ISHNativeClientSettingsContribution].self,
            forKey: .settings
        ) ?? []
        commands = try container.decodeIfPresent(
            [ISHNativeClientCommandContribution].self,
            forKey: .commands
        ) ?? []
        cards = try container.decodeIfPresent(
            [ISHNativeClientCardContribution].self,
            forKey: .cards
        ) ?? []
        references = try container.decodeIfPresent(
            [ISHNativeClientReferenceContribution].self,
            forKey: .references
        ) ?? []
    }
}

/// Schema-v2's deliberately static projection of an upstream conversation
/// view node. Executable match/start/update Definitions remain unsupported.
struct ISHNativeClientCardContribution: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let description: String?
    let order: Int
    let renderer: ISHNativeClientRenderer
    let value: JSONValue
}

/// Schema-v2's static, user-selected reference data. The Host never executes
/// this value; AppModel injects it only after an exact generation-bound mention.
struct ISHNativeClientReferenceContribution: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let description: String?
    let order: Int
    let content: String
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
    /// Whether the command accepts staged image attachments.  This is
    /// optional on the wire for backwards-compatible native-client manifests.
    let inputImages: Bool
    let order: Int
    let action: ISHNativeClientActionDescriptor

    init(
        name: String,
        description: String,
        inputHint: String?,
        inputImages: Bool = false,
        order: Int,
        action: ISHNativeClientActionDescriptor
    ) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
        self.inputImages = inputImages
        self.order = order
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputHint
        case inputImages
        case images
        case order
        case action
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        inputHint = try container.decodeIfPresent(String.self, forKey: .inputHint)
        inputImages = try container.decodeIfPresent(Bool.self, forKey: .inputImages)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .images))
            ?? false
        order = try container.decode(Int.self, forKey: .order)
        action = try container.decode(ISHNativeClientActionDescriptor.self, forKey: .action)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(inputHint, forKey: .inputHint)
        if inputImages {
            try container.encode(true, forKey: .inputImages)
        }
        try container.encode(order, forKey: .order)
        try container.encode(action, forKey: .action)
    }
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
        guard (schemaVersion == 1 && minimumRuntime == 1)
                || (schemaVersion == 2 && minimumRuntime == 2) else {
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

        guard contributions.inspectors.count
                + contributions.settings.count
                + contributions.commands.count
                + contributions.cards.count
                + contributions.references.count <= ishNativeClientMaximumContributions else {
            throw invalid("too many native client contributions")
        }
        if schemaVersion == 1,
           (!contributions.cards.isEmpty || !contributions.references.isEmpty) {
            throw invalid("schema v1 cannot declare card or reference contributions")
        }

        var cardIDs = Set<String>()
        for card in contributions.cards {
            guard cardIDs.insert(card.id).inserted,
                  Self.isIdentifier(card.id),
                  Self.isBoundedText(card.title, maximumBytes: 120),
                  Self.isOptionalBoundedText(card.description, maximumBytes: 600),
                  (-10_000...10_000).contains(card.order),
                  Self.encodedSize(card.value) <= ishNativeClientMaximumContributionBytes else {
                throw invalid("invalid card contribution")
            }
            do {
                try ISHPluginHostCredentialFirewall.validate(card.value)
            } catch {
                throw invalid("card contribution contains credentials")
            }
        }

        var referenceIDs = Set<String>()
        for reference in contributions.references {
            guard referenceIDs.insert(reference.id).inserted,
                  Self.isIdentifier(reference.id),
                  Self.isBoundedText(reference.label, maximumBytes: 120),
                  Self.isOptionalBoundedText(reference.description, maximumBytes: 600),
                  (-10_000...10_000).contains(reference.order),
                  Self.isBoundedText(
                      reference.content,
                      maximumBytes: ishNativeClientMaximumContributionBytes
                  ) else {
                throw invalid("invalid reference contribution")
            }
            do {
                try ISHPluginHostCredentialFirewall.validate(.string(reference.content))
            } catch {
                throw invalid("reference contribution contains credentials")
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
        if !plugin.contributions.cards.isEmpty { required.insert("ui.card") }
        if !plugin.contributions.references.isEmpty { required.insert("ui.reference") }
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

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumBytes
    }

    private static func isOptionalBoundedText(_ value: String?, maximumBytes: Int) -> Bool {
        value.map { isBoundedText($0, maximumBytes: maximumBytes) } ?? true
    }

    private static func encodedSize(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value).count) ?? Int.max
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

struct ISHNativeClientReferenceIdentity: Codable, Sendable, Equatable {
    let pluginId: String
    let referenceId: String
    let activationGeneration: UInt64
    let sourceDigest: String
}

struct ISHParsedNativeClientReferences: Sendable, Equatable {
    let renderedText: String
    let references: [(identity: ISHNativeClientReferenceIdentity, label: String)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderedText == rhs.renderedText
            && lhs.references.map(\.identity) == rhs.references.map(\.identity)
            && lhs.references.map(\.label) == rhs.references.map(\.label)
    }
}

enum ISHNativeClientReferenceSyntax {
    static let scheme = "dsh-native-client:"

    static func uri(
        plugin: ISHNativeClientPlugin,
        reference: ISHNativeClientReferenceContribution
    ) -> String? {
        let identity = ISHNativeClientReferenceIdentity(
            pluginId: plugin.pluginId,
            referenceId: reference.id,
            activationGeneration: plugin.activationGeneration,
            sourceDigest: plugin.sourceDigest
        )
        guard let data = try? JSONEncoder().encode(identity) else { return nil }
        return scheme + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func mention(
        plugin: ISHNativeClientPlugin,
        reference: ISHNativeClientReferenceContribution
    ) -> String? {
        guard let uri = uri(plugin: plugin, reference: reference) else { return nil }
        let label = reference.label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
        return "@[\(label)](\(uri))"
    }

    static func parse(in text: String) -> ISHParsedNativeClientReferences {
        let pattern = #"@\[((?:\\.|[^\\\]])*)\]\((dsh-native-client:[A-Za-z0-9_-]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return ISHParsedNativeClientReferences(renderedText: text, references: [])
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        var references: [(identity: ISHNativeClientReferenceIdentity, label: String)] = []
        var rendered = text
        for match in matches.reversed() {
            guard let whole = Range(match.range(at: 0), in: text),
                  let labelRange = Range(match.range(at: 1), in: text),
                  let uriRange = Range(match.range(at: 2), in: text),
                  let identity = decodeURI(String(text[uriRange])) else { continue }
            let label = String(text[labelRange]).replacingOccurrences(
                of: #"\\(.)"#,
                with: "$1",
                options: .regularExpression
            )
            references.insert((identity, label), at: 0)
            guard let renderedRange = Range(
                NSRange(whole, in: text),
                in: rendered
            ) else { continue }
            rendered.replaceSubrange(renderedRange, with: "@\(label)")
        }
        return ISHParsedNativeClientReferences(
            renderedText: rendered,
            references: references
        )
    }

    private static func decodeURI(_ uri: String) -> ISHNativeClientReferenceIdentity? {
        guard uri.hasPrefix(scheme) else { return nil }
        var payload = String(uri.dropFirst(scheme.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let identity = try? JSONDecoder().decode(
                  ISHNativeClientReferenceIdentity.self,
                  from: data
              ),
              identity.activationGeneration > 0,
              identity.activationGeneration <= ishNativeClientMaximumJSONSafeInteger,
              identity.sourceDigest.utf8.count == 64,
              identity.sourceDigest.allSatisfy(\.isHexDigit) else { return nil }
        return identity
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
