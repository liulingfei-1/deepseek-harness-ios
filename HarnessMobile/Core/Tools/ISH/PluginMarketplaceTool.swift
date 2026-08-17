import Foundation

/// The marketplace operations that are safe to expose to the on-device Agent.
/// Source preparation stays in the iSH Host, native adaptation is attempted by
/// the configured phone Agent, and npm/Cordis installation is only a fallback.
struct PluginMarketplaceToolRequest: Sendable, Equatable {
    enum Action: String, Sendable, Equatable {
        case catalog
        case list
        case install
        case enable
        case disable
        case uninstall
        case clearCache = "clear_cache"
    }

    let action: Action
    let sourceKind: ISHMarketplacePluginSourceKind?
    let location: String?
    let id: String?
    let replace: Bool
    let forceRefresh: Bool
    let includeNPM: Bool
    let query: String?
    let offset: Int
    let limit: Int

    var source: ISHMarketplacePluginSource? {
        guard let sourceKind, let location else { return nil }
        return ISHMarketplacePluginSource(kind: sourceKind, location: location)
    }
}

typealias PluginMarketplaceToolExecutor = @MainActor @Sendable (
    PluginMarketplaceToolRequest
) async throws -> String

struct PluginMarketplaceTool: LocalAgentTool {
    private static let allowedKeys: Set<String> = [
        "action", "source_kind", "location", "id", "replace",
        "force_refresh", "include_npm", "query", "offset", "limit"
    ]

    let definition = ModelToolDefinition(
        name: "plugin_marketplace",
        description: "Manage Cordis and Agent-compiled native plugins on this iPhone. Query the catalog or installed list, install/update a market or GitHub plugin, enable/disable/uninstall it, or clear the local cache. Every install first downloads a bounded source snapshot on the phone and asks the configured phone Agent to compile it into a Swift-validated declarative native tool manifest. Only sources the Agent marks unadaptable, manifests rejected by native validation, or packages without usable source fall back to the on-device iSH/Cordis runtime. Provider API keys never enter the plugin host. Local ZIP import remains available from the Plugins screen, where iOS stages the file safely.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([
                        "catalog", "list", "install", "enable", "disable",
                        "uninstall", "clear_cache"
                    ].map(JSONValue.string)),
                    "description": .string("Operation to perform.")
                ]),
                "source_kind": .object([
                    "type": .string("string"),
                    "enum": .array(["market", "github"].map(JSONValue.string)),
                    "description": .string("Required for install. market and github use a credential-free HTTPS GitHub repository URL.")
                ]),
                "location": .object([
                    "type": .string("string"),
                    "maxLength": .number(2_048),
                    "description": .string("GitHub repository URL, optionally with /tree/<branch>/<folder>.")
                ]),
                "id": .object([
                    "type": .string("string"),
                    "maxLength": .number(128),
                    "description": .string("Installed plugin id for enable, disable, or uninstall.")
                ]),
                "replace": .object([
                    "type": .string("boolean"),
                    "description": .string("For install, replace an existing plugin with the same identity.")
                ]),
                "force_refresh": .object([
                    "type": .string("boolean"),
                    "description": .string("For catalog, bypass the local market cache.")
                ]),
                "include_npm": .object([
                    "type": .string("boolean"),
                    "description": .string("For clear_cache, also remove the local npm cache.")
                ]),
                "query": .object([
                    "type": .string("string"),
                    "maxLength": .number(256),
                    "description": .string("For catalog, optional case-insensitive search across name, description, category, and repository.")
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .number(0),
                    "maximum": .number(1_000_000),
                    "description": .string("For catalog, zero-based result offset. Defaults to 0.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(25),
                    "description": .string("For catalog, page size. Defaults to 20 and cannot exceed 25.")
                ])
            ]),
            "required": .array([.string("action")]),
            "additionalProperties": .bool(false)
        ])
    )

    let risk: ToolRisk = .sideEffect
    private let executor: PluginMarketplaceToolExecutor

    init(executor: PluginMarketplaceToolExecutor? = nil) {
        self.executor = executor ?? { _ in
            throw LocalToolError.pluginDenied("本机插件 Host 尚未接入当前运行时。")
        }
    }

    func validate(arguments: [String: JSONValue]) throws {
        _ = try request(from: arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        guard let request = try? request(from: arguments) else {
            return "管理本机 Cordis 插件"
        }
        switch request.action {
        case .catalog: return "查询本机插件市场目录"
        case .list: return "列出本机已安装插件"
        case .install:
            return "在手机上安装或自动原生编译插件：\(request.location ?? "未知来源")"
        case .enable: return "在手机上启用插件：\(request.id ?? "未知插件")"
        case .disable: return "在手机上停用插件：\(request.id ?? "未知插件")"
        case .uninstall: return "在手机上卸载插件：\(request.id ?? "未知插件")"
        case .clearCache: return "清理本机插件市场缓存"
        }
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        _ = try request(from: arguments)
        return ["ish-plugin-marketplace"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let request = try request(from: arguments)
        return try await executor(request)
    }

    private func request(from arguments: [String: JSONValue]) throws -> PluginMarketplaceToolRequest {
        try arguments.requireOnlyKeys(Self.allowedKeys)
        let actionValue = try arguments.requiredString("action", maximumUTF8Bytes: 32)
        guard let action = PluginMarketplaceToolRequest.Action(rawValue: actionValue) else {
            throw LocalToolError.invalidArguments
        }

        let sourceKind: ISHMarketplacePluginSourceKind?
        if let raw = arguments["source_kind"] {
            guard let value = raw.stringValue?.lowercased() else {
                throw LocalToolError.invalidArguments
            }
            switch value {
            case "market": sourceKind = .market
            case "github": sourceKind = .github
            default: throw LocalToolError.invalidArguments
            }
        } else {
            sourceKind = nil
        }

        let location = try optionalString(
            arguments["location"],
            maximumUTF8Bytes: 2_048
        )
        let id = try optionalString(arguments["id"], maximumUTF8Bytes: 128)
        let replace = try optionalBool(arguments["replace"])
        let forceRefresh = try optionalBool(arguments["force_refresh"])
        let includeNPM = try optionalBool(arguments["include_npm"])
        let query = try optionalString(arguments["query"], maximumUTF8Bytes: 256)
        let offset = try optionalInteger(
            arguments["offset"],
            defaultValue: 0,
            range: 0...1_000_000
        )
        let limit = try optionalInteger(arguments["limit"], defaultValue: 20, range: 1...25)

        switch action {
        case .install:
            guard sourceKind != nil, let location, !location.isEmpty else {
                throw LocalToolError.missingArgument("source_kind/location")
            }
        case .enable, .disable, .uninstall:
            guard let id, !id.isEmpty else {
                throw LocalToolError.missingArgument("id")
            }
        case .catalog, .list, .clearCache:
            break
        }

        return PluginMarketplaceToolRequest(
            action: action,
            sourceKind: sourceKind,
            location: location,
            id: id,
            replace: replace,
            forceRefresh: forceRefresh,
            includeNPM: includeNPM,
            query: query,
            offset: offset,
            limit: limit
        )
    }

    private func optionalString(
        _ value: JSONValue?,
        maximumUTF8Bytes: Int
    ) throws -> String? {
        guard let value else { return nil }
        guard let string = value.stringValue,
              string.utf8.count <= maximumUTF8Bytes,
              !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalToolError.invalidArguments
        }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalBool(_ value: JSONValue?) throws -> Bool {
        guard let value else { return false }
        guard case let .bool(result) = value else {
            throw LocalToolError.invalidArguments
        }
        return result
    }

    private func optionalInteger(
        _ value: JSONValue?,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(range.lowerBound),
              number <= Double(range.upperBound) else {
            throw LocalToolError.invalidArguments
        }
        return Int(number)
    }
}
