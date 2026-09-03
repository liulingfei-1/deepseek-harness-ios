import Foundation

enum ISHPluginHostRPCMethod: String, Codable, Sendable, CaseIterable {
    case ping
    case inventory
    case define
    case run
    case stop
    case undefine
    case contextSync = "context/sync"
    case contributions
    case commandExecute = "command/execute"
    case invoke
    case settingsDescribe = "settings/describe"
    case settingsMutate = "settings/mutate"
    case settingsUpdate = "settings/update"
    case settingsReplace = "settings/replace"
    case marketCatalog = "market/catalog"
    case pluginList = "plugin/list"
    case pluginPrepareNative = "plugin/prepare-native"
    case pluginDiscardPreparedNative = "plugin/discard-prepared-native"
    case pluginInstall = "plugin/install"
    case pluginSetEnabled = "plugin/set-enabled"
    case pluginUninstall = "plugin/uninstall"
    case pluginCacheClear = "plugin/cache-clear"
}

struct ISHPluginHostRPCRequest: Codable, Sendable, Equatable {
    let jsonrpc: String
    let id: String
    let method: ISHPluginHostRPCMethod
    let params: JSONValue

    init(id: String, method: ISHPluginHostRPCMethod, params: JSONValue = .object([:])) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct ISHPluginHostRPCResponse: Codable, Sendable, Equatable {
    let jsonrpc: String
    let id: String?
    let result: JSONValue?
    let error: ISHPluginHostRPCError?
}

struct ISHPluginHostRPCError: Codable, Sendable, Equatable {
    let code: Int
    let message: String
    let data: JSONValue?
}

enum ISHPluginHostRunMode: String, Codable, Sendable, Equatable {
    case run
    case update
}

enum ISHPluginHostInvokeTarget: String, Codable, Sendable {
    case tool
    case handler
    case service
}

struct ISHPluginHostPing: Codable, Sendable, Equatable {
    let protocolVersion: Int
    let hostVersion: String
    let runtime: String
    let dynamicDefinitionLifetime: String
    let credentialBoundary: String
    let packages: [String: String]
    let capabilities: [ISHPluginHostRPCMethod]
}

struct ISHPluginHostInventoryRequest: Codable, Sendable, Equatable {
    let sessionId: String?

    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

struct ISHPluginHostInventory: Codable, Sendable, Equatable {
    let revision: UInt64
    let entries: [ISHPluginHostInventoryEntry]
    let packages: [String: String]
}

struct ISHPluginHostInventoryEntry: Codable, Sendable, Equatable {
    let pluginId: String
    let agentId: String
    let packages: [ISHPluginHostPackageSummary]
    let currentPackageId: String?
    let nextPackageId: String?
    let activeRun: ISHPluginHostActiveRun?
    let latestRun: JSONValue?
}

struct ISHPluginHostActivationPlan: Sendable, Equatable {
    let packageID: String
    let mode: ISHPluginHostRunMode
}

extension ISHPluginHostInventoryEntry {
    /// Preferred stopped-plugin action matching the upstream runner's mode
    /// invariant: re-enter the current package with `run`, and switch to a
    /// different immutable package with `update`.
    var preferredActivationPlan: ISHPluginHostActivationPlan? {
        guard activeRun == nil else { return nil }
        if let nextPackageId,
           nextPackageId != currentPackageId,
           let plan = activationPlan(for: nextPackageId) {
            return plan
        }
        if let currentPackageId,
           let plan = activationPlan(for: currentPackageId) {
            return plan
        }
        if let nextPackageId,
           let plan = activationPlan(for: nextPackageId) {
            return plan
        }
        guard let packageID = packages.last?.packageId else { return nil }
        return activationPlan(for: packageID)
    }

    func activationPlan(for packageID: String) -> ISHPluginHostActivationPlan? {
        guard activeRun == nil,
              let package = packages.first(where: { $0.packageId == packageID }),
              !package.hasClientHalf else { return nil }
        let mode: ISHPluginHostRunMode
        if let currentPackageId, currentPackageId != packageID {
            mode = .update
        } else {
            mode = .run
        }
        return ISHPluginHostActivationPlan(packageID: packageID, mode: mode)
    }
}

struct ISHPluginHostPackageSummary: Codable, Sendable, Equatable {
    let packageId: String
    let name: String
    let purpose: String
    let hasHostHalf: Bool
    let hasClientHalf: Bool
}

struct ISHPluginHostActiveRun: Codable, Sendable, Equatable {
    let pluginRunId: String
    let packageId: String
}

struct ISHPluginHostDefinitionSelector: Codable, Sendable, Equatable {
    let kind: String
    let idPrefix: String?
    let pluginId: String?

    static func new(idPrefix: String) -> Self {
        Self(kind: "new", idPrefix: idPrefix, pluginId: nil)
    }

    static func existing(pluginId: String) -> Self {
        Self(kind: "existing", idPrefix: nil, pluginId: pluginId)
    }
}

struct ISHPluginHostDefinitionCode: Codable, Sendable, Equatable {
    let host: String?
    let client: String?

    init(host: String? = nil, client: String? = nil) {
        self.host = host
        self.client = client
    }
}

struct ISHPluginHostDefineRequest: Codable, Sendable, Equatable {
    let sessionId: String
    let plugin: ISHPluginHostDefinitionSelector
    let name: String
    let purpose: String
    let code: ISHPluginHostDefinitionCode
}

struct ISHPluginHostDefineReceipt: Codable, Sendable, Equatable {
    let pluginId: String
    let packageId: String
    let name: String
    let purpose: String
    let hasHostHalf: Bool
    let hasClientHalf: Bool
}

struct ISHPluginHostRunRequest: Codable, Sendable, Equatable {
    let sessionId: String
    let pluginId: String
    let packageId: String
    let mode: ISHPluginHostRunMode
}

struct ISHPluginHostRunResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let status: String?
    let reason: String?
    let message: String?
    let pluginId: String?
    let packageId: String?
    let pluginRunId: String?
    let currentPackageId: String?
    let nextPackageId: String?
    let waitingFor: [String]?
}

struct ISHPluginHostPluginRequest: Codable, Sendable, Equatable {
    let sessionId: String
    let pluginId: String
}

struct ISHPluginHostStopResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let reason: String?
    let message: String?
}

struct ISHPluginHostUndefineResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let wasRunning: Bool?
    let reason: String?
    let message: String?
}

struct ISHPluginHostSkillDefinition: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let whenToUse: String?
    let invocation: MobileSkillInvocationPolicy
    let source: String
    let path: String
    let resourceBase: String
    let content: String

    init(_ definition: MobileSkillDefinition) {
        name = definition.summary.name
        description = definition.summary.description
        whenToUse = definition.summary.whenToUse
        invocation = definition.summary.invocation
        source = definition.summary.source.rawValue
        path = definition.summary.path
        resourceBase = definition.summary.resourceBase
        content = definition.content
    }
}

struct ISHPluginHostContextSyncRequest: Codable, Sendable, Equatable {
    let sessionId: String
    let startingAtSeq: UInt64
    let events: [ISHPluginHostContextEvent]
    let skills: [ISHPluginHostSkillDefinition]?
}

struct ISHPluginHostContextSyncResponse: Codable, Sendable, Equatable {
    let sessionId: String
    let appendedEvents: Int
    let totalEvents: Int
    let skillCount: Int
}

enum ISHPluginHostContextProjection {
    static func retains(_ event: SessionEvent) -> Bool {
        event.type != SessionEventVocabulary.assistantChunk
            || event.assistantChunkData?.usage != nil
    }

    /// Token-sized assistant deltas are recoverable from assistant/message and
    /// can number in the tens of thousands during a long run. Keep finalized
    /// surface events and usage while preventing post-run Host synchronization
    /// from holding the conversation in a running state for many seconds.
    static func events(from events: [SessionEvent]) -> [ISHPluginHostContextEvent] {
        let retained = events.filter(retains)
        let projectedSequenceBySource = Dictionary(
            uniqueKeysWithValues: retained.enumerated().map { index, event in
                (event.seq, UInt64(index))
            }
        )

        return retained.enumerated().map { index, event in
            let projectedSequence = UInt64(index)
            let sourceEventSeqs = event.sourceEventSeqs?.compactMap {
                projectedSequenceBySource[$0]
            }.filter { $0 < projectedSequence }

            let surfaceOp: SessionSurfaceOperation?
            switch event.surfaceOp {
            case .append:
                surfaceOp = .append
            case let .replace(start, end):
                let projectedRange = retained.compactMap { candidate -> UInt64? in
                    guard (start...end).contains(candidate.seq) else { return nil }
                    return projectedSequenceBySource[candidate.seq]
                }.filter { $0 < projectedSequence }
                if let first = projectedRange.first, let last = projectedRange.last {
                    surfaceOp = .replace(start: first, end: last)
                } else {
                    // The entire replacement target consisted of discarded
                    // token deltas, so there is no Host surface range to replace.
                    surfaceOp = .append
                }
            case nil:
                surfaceOp = nil
            }

            return ISHPluginHostContextEvent(
                type: event.type,
                seq: projectedSequence,
                time: event.time,
                data: event.data,
                ignorable: event.ignorable,
                sourceEventSeqs: sourceEventSeqs?.isEmpty == false ? sourceEventSeqs : nil,
                surfaceOp: surfaceOp
            )
        }
    }
}

/// A compact, contiguously sequenced view of the native trajectory. Its
/// sequence belongs to the Plugin Host stream, while SessionEvent.seq remains
/// the immutable identity in the lossless native JSONL log.
struct ISHPluginHostContextEvent: Codable, Sendable, Equatable {
    let type: String
    let seq: UInt64
    let time: Int64
    let data: JSONValue
    let ignorable: Bool?
    let sourceEventSeqs: [UInt64]?
    let surfaceOp: SessionSurfaceOperation?
}

struct ISHPluginHostContributionsRequest: Codable, Sendable, Equatable {
    let sessionId: String?

    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

struct ISHPluginHostContributions: Codable, Sendable, Equatable {
    let revision: UInt64
    let scope: String
    let tools: [ISHPluginHostToolContribution]
    let commands: [ISHPluginHostCommandContribution]
    let prompt: ISHPluginHostPromptContributions
    let handlers: [ISHPluginHostHandlerContribution]
    let services: [ISHPluginHostServiceContribution]

    init(
        revision: UInt64,
        scope: String,
        tools: [ISHPluginHostToolContribution],
        commands: [ISHPluginHostCommandContribution] = [],
        prompt: ISHPluginHostPromptContributions,
        handlers: [ISHPluginHostHandlerContribution] = [],
        services: [ISHPluginHostServiceContribution] = []
    ) {
        self.revision = revision
        self.scope = scope
        self.tools = tools
        self.commands = commands
        self.prompt = prompt
        self.handlers = handlers
        self.services = services
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case scope
        case tools
        case commands
        case prompt
        case handlers
        case services
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(UInt64.self, forKey: .revision)
        scope = try container.decode(String.self, forKey: .scope)
        tools = try container.decode([ISHPluginHostToolContribution].self, forKey: .tools)
        commands = try container.decodeIfPresent(
            [ISHPluginHostCommandContribution].self,
            forKey: .commands
        ) ?? []
        prompt = try container.decode(ISHPluginHostPromptContributions.self, forKey: .prompt)
        handlers = try container.decodeIfPresent(
            [ISHPluginHostHandlerContribution].self,
            forKey: .handlers
        ) ?? []
        services = try container.decodeIfPresent(
            [ISHPluginHostServiceContribution].self,
            forKey: .services
        ) ?? []
    }
}

struct ISHPluginHostHandlerContribution: Codable, Sendable, Equatable, Hashable {
    let pluginId: String
    let pluginRunId: String
    let method: String
}

struct ISHPluginHostServiceContribution: Codable, Sendable, Equatable, Hashable {
    let pluginId: String
    let pluginRunId: String
    let name: String
    let methods: [String]
}

struct ISHPluginHostToolContribution: Codable, Sendable, Equatable {
    let name: String
    let description: String
    let parameters: JSONValue
}

struct ISHPluginHostCommandContribution: Codable, Sendable, Equatable {
    struct Input: Codable, Sendable, Equatable {
        let hint: String
        let images: Bool?
    }

    let name: String
    let description: String
    let input: Input?
    let recordInput: Bool

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case input
        case recordInput
    }

    init(
        name: String,
        description: String,
        input: Input? = nil,
        recordInput: Bool = true
    ) {
        self.name = name
        self.description = description
        self.input = input
        self.recordInput = recordInput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        input = try container.decodeIfPresent(Input.self, forKey: .input)
        recordInput = try container.decodeIfPresent(Bool.self, forKey: .recordInput) ?? true
    }
}

struct ISHPluginHostPromptContributions: Codable, Sendable, Equatable {
    let sections: [ISHPluginHostPromptTextContribution]
    let contexts: [ISHPluginHostPromptTextContribution]
    let variables: [String: JSONValue]
}

struct ISHPluginHostPromptTextContribution: Codable, Sendable, Equatable {
    let name: String
    let text: String
}

enum ISHPluginSettingsApplies: String, Codable, Sendable, Equatable {
    case live
    case restart
}

struct ISHPluginSettingsSecret: Codable, Sendable, Equatable, Hashable {
    let path: [String]
    let set: Bool
}

struct ISHPluginSettingsNamespace: Codable, Sendable, Equatable, Identifiable {
    var id: String { ns }

    let ns: String
    let schema: JSONValue?
    let value: JSONValue
    let base: JSONValue?
    let user: JSONValue?
    let revision: Int
    let applies: ISHPluginSettingsApplies
    let secrets: [ISHPluginSettingsSecret]
    let editable: Bool
    let unsupportedReason: String?
}

struct ISHPluginSettingsSnapshot: Codable, Sendable, Equatable {
    let writable: Bool
    let hasDocument: Bool
    let namespaces: [ISHPluginSettingsNamespace]
}

enum ISHPluginSettingsMutationKind: String, Codable, Sendable, Equatable {
    case set
    case unset
}

struct ISHPluginSettingsPathOperation: Codable, Sendable, Equatable {
    let op: ISHPluginSettingsMutationKind
    let path: [String]
    let value: JSONValue?

    static func set(path: [String], value: JSONValue) -> Self {
        Self(op: .set, path: path, value: value)
    }

    static func unset(path: [String]) -> Self {
        Self(op: .unset, path: path, value: nil)
    }
}

struct ISHPluginSettingsMutateRequest: Codable, Sendable, Equatable {
    let ns: String
    let ops: [ISHPluginSettingsPathOperation]
    let expectedRevision: Int
}

struct ISHPluginSettingsUpdateRequest: Codable, Sendable, Equatable {
    let ns: String
    let patch: [String: JSONValue]
    let expectedRevision: Int
}

struct ISHPluginSettingsReplaceRequest: Codable, Sendable, Equatable {
    let ns: String
    let section: [String: JSONValue]
    let expectedRevision: Int
}

struct ISHPluginSettingsConflict: Sendable, Equatable {
    let namespace: String
    let expectedRevision: Int
    let actualRevision: Int?
}

enum ISHMarketplaceCompatibility: String, Codable, Sendable, Equatable {
    case supported
    case review
    case unsupported
}

enum ISHPluginMarketplaceErrorPolicy {
    static func isCancellation(
        _ error: Error,
        taskIsCancelled: Bool = Task.isCancelled
    ) -> Bool {
        if taskIsCancelled || error is CancellationError {
            return true
        }
        let cocoaError = error as NSError
        if cocoaError.domain == "Swift.CancellationError" {
            return true
        }
        if cocoaError.domain == NSURLErrorDomain,
           cocoaError.code == URLError.cancelled.rawValue {
            return true
        }
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.Code.userCancelled.rawValue
    }

    static func message(
        for error: Error,
        taskIsCancelled: Bool = Task.isCancelled
    ) -> String? {
        guard !isCancellation(error, taskIsCancelled: taskIsCancelled) else { return nil }

        // The Node host deliberately returns a small, stable error code for
        // network failures. Keep the raw transport wording out of the UI and
        // give the user an actionable message instead. The host still keeps
        // the original diagnostic in its trace/diagnostics channel.
        if case let ISHPluginHostError.remote(code, message, data) = error,
           code == -32_010 {
            let reason = data?.objectValue?["reason"]?.stringValue?.lowercased() ?? ""
            let normalized = message.lowercased()
            if reason == "download-failed"
                || normalized.contains("fetch failed")
                || normalized.contains("getaddrinfo")
                || normalized.contains("enotfound")
                || normalized.contains("eai_again")
                || normalized.contains("network is unreachable") {
                return "插件目录暂时无法连接，已自动刷新 iSH DNS；请确认 iSH 网络已开启后重试。"
            }
            let detail = HarnessTraceRedactor.string(message, maximumUTF8Bytes: 800)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch reason {
            case "missing-entrypoint":
                return "插件包不完整，缺少发布时声明的构建文件：\(detail)"
            case "npm-install-failed":
                return "插件依赖安装失败：\(detail)"
            case "startup-failed":
                return "插件 Host 初始化失败：\(detail)"
            case "invalid-manifest", "invalid-patch", "unsupported-patch", "missing-package":
                return "插件兼容性校验未通过：\(detail)"
            default:
                return detail.isEmpty ? "插件操作未完成，请导出诊断日志。" : "插件操作失败：\(detail)"
            }
        }

        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "社区插件操作未完成，请稍后重试。" : message
    }

    static func shouldRefreshGuestDNSAndRetry(_ error: Error) -> Bool {
        guard case let ISHPluginHostError.remote(code, message, data) = error,
              code == -32_010 else { return false }
        let reason = data?.objectValue?["reason"]?.stringValue?.lowercased() ?? ""
        if reason == "download-failed" {
            return true
        }
        let normalized = message.lowercased()
        return [
            "fetch failed",
            "getaddrinfo",
            "enotfound",
            "eai_again",
            "network is unreachable"
        ].contains { normalized.contains($0) }
    }
}

struct ISHMarketplaceCatalogRequest: Codable, Sendable, Equatable {
    let forceRefresh: Bool

    init(forceRefresh: Bool = false) {
        self.forceRefresh = forceRefresh
    }
}

struct ISHMarketplaceCatalog: Codable, Sendable, Equatable {
    let sourceURL: String
    let fetchedAt: String
    let stale: Bool
    let items: [ISHMarketplaceCatalogItem]
}

/// Desktop parity (D-010): installs default to loading the package into the
/// local host runtime (the desktop behavior); native manifest compilation is
/// an explicit opt-in that some catalog entries may still prefer.
enum ISHMarketplaceInstallPreference: String, Codable, Sendable, Equatable {
    case hostLoad = "host-load"
    case nativeCompile = "native-compile"
}

/// Installation is native-first for every catalog entry. The value is a
/// conservative catalog hint; the source snapshot and signed Swift validator
/// remain authoritative at install time.
enum ISHMarketplaceNativeInstallStrategy: String, Codable, Sendable, Equatable {
    case nativeFirst = "native-first"
    case nativeInstalled = "native-installed"
    case ishFallback = "ish-fallback"
    case ishRequired = "ish-required"

    var title: String {
        switch self {
        case .nativeFirst: "原生优先"
        case .nativeInstalled: "已原生安装"
        case .ishFallback: "iSH 回退"
        case .ishRequired: "仅 iSH"
        }
    }

    var iconName: String {
        switch self {
        case .nativeFirst, .nativeInstalled: "iphone"
        case .ishFallback: "arrow.triangle.2.circlepath"
        case .ishRequired: "shippingbox"
        }
    }
}

struct ISHMarketplaceCatalogItem: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let repositoryURL: String
    let repositoryKey: String
    let description: String
    let category: String
    let compatibility: ISHMarketplaceCompatibility
    let unsupportedReason: String?
    let installed: Bool
    let installedPluginID: String?
    let installedVersion: String?
    let nativeInstallStrategy: ISHMarketplaceNativeInstallStrategy?

    init(
        id: String,
        name: String,
        repositoryURL: String,
        repositoryKey: String,
        description: String,
        category: String,
        compatibility: ISHMarketplaceCompatibility,
        unsupportedReason: String?,
        installed: Bool,
        installedPluginID: String?,
        installedVersion: String?,
        nativeInstallStrategy: ISHMarketplaceNativeInstallStrategy? = nil
    ) {
        self.id = id
        self.name = name
        self.repositoryURL = repositoryURL
        self.repositoryKey = repositoryKey
        self.description = description
        self.category = category
        self.compatibility = compatibility
        self.unsupportedReason = unsupportedReason
        self.installed = installed
        self.installedPluginID = installedPluginID
        self.installedVersion = installedVersion
        self.nativeInstallStrategy = nativeInstallStrategy
    }

    enum CodingKeys: String, CodingKey {
        case id, name, repositoryURL, repositoryKey, description, category
        case compatibility, unsupportedReason, installed, installedPluginID
        case installedVersion, nativeInstallStrategy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            repositoryURL: try container.decode(String.self, forKey: .repositoryURL),
            repositoryKey: try container.decode(String.self, forKey: .repositoryKey),
            description: try container.decode(String.self, forKey: .description),
            category: try container.decode(String.self, forKey: .category),
            compatibility: try container.decode(ISHMarketplaceCompatibility.self, forKey: .compatibility),
            unsupportedReason: try container.decodeIfPresent(String.self, forKey: .unsupportedReason),
            installed: try container.decode(Bool.self, forKey: .installed),
            installedPluginID: try container.decodeIfPresent(String.self, forKey: .installedPluginID),
            installedVersion: try container.decodeIfPresent(String.self, forKey: .installedVersion),
            nativeInstallStrategy: try container.decodeIfPresent(ISHMarketplaceNativeInstallStrategy.self, forKey: .nativeInstallStrategy)
        )
    }
}

enum ISHMarketplacePluginSourceKind: String, Codable, Sendable, Equatable {
    case market
    case github
    case localZip
}

struct ISHMarketplacePluginSource: Codable, Sendable, Equatable {
    let kind: ISHMarketplacePluginSourceKind
    let location: String
    let repositoryURL: String?
    let repositoryKey: String?
    let ref: String?
    let subpath: String?

    init(kind: ISHMarketplacePluginSourceKind, location: String) {
        self.kind = kind
        self.location = location
        repositoryURL = nil
        repositoryKey = nil
        ref = nil
        subpath = nil
    }
}

struct ISHMarketplacePluginInstallRequest: Codable, Sendable, Equatable {
    let source: ISHMarketplacePluginSource
    let replace: Bool
    let preparedToken: String?

    init(
        source: ISHMarketplacePluginSource,
        replace: Bool = false,
        preparedToken: String? = nil
    ) {
        self.source = source
        self.replace = replace
        self.preparedToken = preparedToken
    }
}

struct ISHMarketplacePluginPrepareNativeRequest: Codable, Sendable, Equatable {
    let source: ISHMarketplacePluginSource
}

struct ISHMarketplacePluginPrepareNativeResponse: Codable, Sendable, Equatable {
    let preparedToken: String
    let nativeCandidate: NativeAgentPluginSourceSnapshot?
}

struct ISHMarketplacePluginDiscardPreparedNativeRequest: Codable, Sendable, Equatable {
    let preparedToken: String
}

struct ISHMarketplacePluginDiscardPreparedNativeResponse: Codable, Sendable, Equatable {
    let ok: Bool
}

enum ISHMarketplacePluginState: String, Codable, Sendable, Equatable {
    case enabled
    case disabled
    case failed
}

struct ISHMarketplacePlugin: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let license: String?
    let source: ISHMarketplacePluginSource
    let enabled: Bool
    let state: ISHMarketplacePluginState
    let installedAt: String
    let updatedAt: String
    let entryCount: Int
    let lastError: String?
}

struct ISHMarketplacePluginList: Codable, Sendable, Equatable {
    let revision: UInt64
    let plugins: [ISHMarketplacePlugin]
}

struct ISHMarketplacePluginInstallResponse: Codable, Sendable, Equatable {
    let plugin: ISHMarketplacePlugin
}

struct ISHMarketplacePluginSetEnabledRequest: Codable, Sendable, Equatable {
    let id: String
    let enabled: Bool
}

struct ISHMarketplacePluginMutationResponse: Codable, Sendable, Equatable {
    let plugin: ISHMarketplacePlugin
}

struct ISHMarketplacePluginUninstallRequest: Codable, Sendable, Equatable {
    let id: String
}

struct ISHMarketplacePluginUninstallResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let id: String
}

struct ISHMarketplaceCacheClearRequest: Codable, Sendable, Equatable {
    let includeNpm: Bool

    init(includeNpm: Bool = false) {
        self.includeNpm = includeNpm
    }
}

struct ISHMarketplaceCacheClearResponse: Codable, Sendable, Equatable {
    let ok: Bool
    let removedFiles: Int
}

struct ISHPluginHostInvokeRequest: Codable, Sendable, Equatable {
    let target: ISHPluginHostInvokeTarget
    let sessionId: String?
    let name: String?
    let service: String?
    let pluginId: String?
    let pluginRunId: String?
    let method: String?
    let arguments: JSONValue
    let callId: String?

    static func tool(
        sessionId: String,
        name: String,
        arguments: JSONValue,
        callId: String? = nil
    ) -> Self {
        Self(
            target: .tool,
            sessionId: sessionId,
            name: name,
            service: nil,
            pluginId: nil,
            pluginRunId: nil,
            method: nil,
            arguments: arguments,
            callId: callId
        )
    }

    static func handler(
        sessionId: String? = nil,
        pluginId: String,
        pluginRunId: String,
        method: String,
        arguments: JSONValue
    ) -> Self {
        Self(
            target: .handler,
            sessionId: sessionId,
            name: nil,
            service: nil,
            pluginId: pluginId,
            pluginRunId: pluginRunId,
            method: method,
            arguments: arguments,
            callId: nil
        )
    }

    static func service(
        sessionId: String,
        pluginId: String,
        pluginRunId: String,
        name: String,
        method: String,
        arguments: JSONValue
    ) -> Self {
        Self(
            target: .service,
            sessionId: sessionId,
            name: nil,
            service: name,
            pluginId: pluginId,
            pluginRunId: pluginRunId,
            method: method,
            arguments: arguments,
            callId: nil
        )
    }
}

struct ISHPluginHostInstallManifest: Codable, Sendable, Equatable {
    struct Package: Codable, Sendable, Equatable {
        let name: String
        let version: String
        let integrity: String
    }

    let schemaVersion: Int
    let hostVersion: String
    let protocolVersion: Int
    let entrypoint: String
    let primaryRegistry: URL
    let mirrors: [URL]
    let packages: [Package]
}

enum ISHPluginHostError: LocalizedError, Sendable, Equatable {
    case unavailable
    case invalidState(String)
    case invalidProtocol(String)
    case frameTooLarge(maximumBytes: Int)
    case requestTooLarge(maximumBytes: Int)
    case credentialsForbidden
    case transportRejectedWrite
    case transportExited(code: Int, errorCode: Int)
    case timedOut(method: ISHPluginHostRPCMethod)
    case remote(code: Int, message: String, data: JSONValue?)
    case resourceMissing(String)
    case invalidRegistryURL(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The on-device iSH plugin host is unavailable in this build."
        case let .invalidState(message), let .invalidProtocol(message):
            return message
        case let .frameTooLarge(maximumBytes):
            return "The plugin host emitted an NDJSON frame larger than \(maximumBytes) bytes."
        case let .requestTooLarge(maximumBytes):
            return "The plugin host request is larger than the \(maximumBytes)-byte stdin queue limit."
        case .credentialsForbidden:
            return "Provider credentials are not allowed to enter the on-device plugin host."
        case .transportRejectedWrite:
            return "The iSH process rejected the plugin host stdin write."
        case let .transportExited(code, errorCode):
            return "The iSH plugin host exited (code \(code), bridge error \(errorCode))."
        case let .timedOut(method):
            return "The plugin host did not answer \(method.rawValue) before the request deadline."
        case let .remote(code, message, _):
            return "Plugin host RPC error \(code): \(message)"
        case let .resourceMissing(name):
            return "The bundled plugin host resource \(name) is missing."
        case let .invalidRegistryURL(value):
            return "The npm registry URL is not an allowed HTTPS endpoint: \(value)"
        case let .installationFailed(message):
            return "The on-device plugin host installation failed: \(message)"
        }
    }
}

extension ISHPluginHostError {
    var settingsConflict: ISHPluginSettingsConflict? {
        guard case let .remote(code, _, data) = self,
              code == -32_012,
              let object = data?.objectValue,
              object["reason"]?.stringValue == "settings-conflict",
              let namespace = object["ns"]?.stringValue,
              let expectedRevision = object["expectedRevision"]?.exactInteger else {
            return nil
        }
        return ISHPluginSettingsConflict(
            namespace: namespace,
            expectedRevision: expectedRevision,
            actualRevision: object["actualRevision"]?.exactInteger
        )
    }
}

private extension JSONValue {
    var exactInteger: Int? {
        guard case let .number(value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else {
            return nil
        }
        return Int(value)
    }
}

enum ISHPluginHostCredentialFirewall {
    private static let forbiddenKeyFragments = [
        "apikey",
        "authorization",
        "accesstoken",
        "refreshtoken",
        "secretkey",
        "clientsecret",
        "password"
    ]

    static func validate(_ value: JSONValue) throws {
        guard !containsCredential(value) else {
            throw ISHPluginHostError.credentialsForbidden
        }
    }

    static func containsCredential(_ value: JSONValue) -> Bool {
        switch value {
        case let .string(text):
            return containsCredentialPattern(text)
        case let .object(object):
            for (key, child) in object {
                let normalizedKey = key.lowercased().filter(\.isLetter)
                if forbiddenKeyFragments.contains(where: normalizedKey.contains) {
                    return true
                }
                if containsCredential(child) {
                    return true
                }
            }
            return false
        case let .array(values):
            return values.contains(where: containsCredential)
        case .number, .bool, .null:
            return false
        }
    }

    private static func containsCredentialPattern(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        var bearerSearchStart = lowercased.startIndex
        while let bearer = lowercased.range(
            of: "bearer ",
            range: bearerSearchStart..<lowercased.endIndex
        ) {
            var index = bearer.upperBound
            var count = 0
            while index < lowercased.endIndex {
                let character = lowercased[index]
                guard character.isLetter || character.isNumber || character == "_" || character == "-" else {
                    break
                }
                count += 1
                index = lowercased.index(after: index)
            }
            if count >= 12 {
                return true
            }
            bearerSearchStart = bearer.upperBound
        }

        var searchStart = text.startIndex
        while let prefix = text.range(of: "sk-", range: searchStart..<text.endIndex) {
            var index = prefix.upperBound
            var count = 0
            while index < text.endIndex {
                let character = text[index]
                guard character.isLetter || character.isNumber || character == "_" || character == "-" else {
                    break
                }
                count += 1
                index = text.index(after: index)
            }
            if count >= 12 {
                return true
            }
            searchStart = prefix.upperBound
        }
        return false
    }
}
