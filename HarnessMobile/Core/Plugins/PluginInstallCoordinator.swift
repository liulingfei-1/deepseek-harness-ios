import Foundation

/// The execution backend that owns an installed plugin.
///
/// Native plugins are declarative manifests validated by the signed iOS
/// binary. iSH plugins keep their original runtime inside the phone-local
/// sandbox. The coordinator deliberately does not load executable code.
enum PluginBackend: String, Codable, Sendable, Equatable, Hashable {
    case native
    case ish
}

/// Installation scope is explicit even while the current AppModel adapters
/// install marketplace entries globally. Conversation-scoped records can be
/// activated by a future child Cordis runtime without changing identity or
/// rollback semantics.
enum PluginInstallScope: Codable, Sendable, Equatable, Hashable {
    case global
    case conversation(UUID)
}

enum PluginInstallSource: Codable, Sendable, Equatable {
    case marketplace(ISHMarketplacePluginSource)
    case preparedMarketplace(source: ISHMarketplacePluginSource, token: String)
    case native(sourceDigest: String)

    /// A prepared token is an ephemeral capability, not plugin identity. This
    /// keeps the marketplace UI and conversation install paths idempotent for
    /// the same repository/source.
    var sourceKey: String {
        switch self {
        case let .marketplace(source):
            Self.marketplaceKey(source)
        case let .preparedMarketplace(source, _):
            Self.marketplaceKey(source)
        case let .native(sourceDigest):
            "native|\(sourceDigest.lowercased())"
        }
    }

    var expectedBackend: PluginBackend? {
        if case .native = self { return .native }
        return nil
    }

    private static func marketplaceKey(_ source: ISHMarketplacePluginSource) -> String {
        [
            "marketplace",
            source.kind.rawValue,
            component(source.location),
            component(source.repositoryURL),
            component(source.repositoryKey),
            component(source.ref),
            component(source.subpath)
        ].joined(separator: "|")
    }

    private static func component(_ value: String?) -> String {
        guard let value else { return "-1:" }
        return "\(value.utf8.count):\(value)"
    }
}

struct PluginInstallRequest: Codable, Sendable, Equatable {
    let source: PluginInstallSource
    let scope: PluginInstallScope
    let requestedVersion: String?
    let replace: Bool

    init(
        source: PluginInstallSource,
        scope: PluginInstallScope = .global,
        requestedVersion: String? = nil,
        replace: Bool = false
    ) {
        self.source = source
        self.scope = scope
        self.requestedVersion = requestedVersion
        self.replace = replace
    }

    var sourceKey: String { source.sourceKey }
}

struct PluginInstallResult: Codable, Sendable, Equatable {
    let pluginID: String
    let version: String
    let scope: PluginInstallScope
    let backend: PluginBackend
    let sourceKey: String
    let enabled: Bool

    init(
        pluginID: String,
        version: String,
        scope: PluginInstallScope = .global,
        backend: PluginBackend,
        sourceKey: String,
        enabled: Bool
    ) {
        self.pluginID = pluginID
        self.version = version
        self.scope = scope
        self.backend = backend
        self.sourceKey = sourceKey
        self.enabled = enabled
    }
}

struct PluginInstallTicket: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let request: PluginInstallRequest
    fileprivate let previous: PluginInstallResult?
}

enum PluginInstallAdmission: Sendable, Equatable {
    case reuse(PluginInstallResult)
    case ticket(PluginInstallTicket)
}

enum PluginInstallCoordinatorError: LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case operationInFlight(String)
    case duplicate(pluginID: String, scope: PluginInstallScope)
    case unknown(pluginID: String, scope: PluginInstallScope)
    case transactionNotFound(UUID)
    case resultMismatch(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(reason):
            return "插件安装请求无效：\(reason)"
        case let .operationInFlight(sourceKey):
            return "插件来源正在安装：\(sourceKey)"
        case let .duplicate(pluginID, scope):
            return "插件 \(pluginID) 在作用域 \(scope.description) 已安装；更新时需要 replace=true。"
        case let .unknown(pluginID, scope):
            return "作用域 \(scope.description) 中不存在插件 \(pluginID)。"
        case let .transactionNotFound(id):
            return "插件安装事务 \(id.uuidString) 不存在或已结束。"
        case let .resultMismatch(reason):
            return "插件安装结果与请求不一致：\(reason)"
        case let .operationFailed(reason):
            return "插件后端安装失败：\(reason)"
        }
    }
}

extension PluginInstallScope: CustomStringConvertible {
    var description: String {
        switch self {
        case .global: return "global"
        case let .conversation(id): return "conversation:\(id.uuidString)"
        }
    }
}

/// Single owner for marketplace/native installation identity and lifecycle.
///
/// Backend work remains supplied by the caller, so this actor can coordinate
/// both the UI and conversation paths without coupling Core to AppModel or to
/// the iSH transport. Metadata is committed only after the backend operation
/// returns a validated result.
actor PluginInstallCoordinator {
    private struct RecordKey: Hashable, Sendable {
        let pluginID: String
        let scope: PluginInstallScope
    }

    private struct SourceScopeKey: Hashable, Sendable {
        let sourceKey: String
        let scope: PluginInstallScope
    }

    private var records: [RecordKey: PluginInstallResult] = [:]
    private var activeTransactions: [UUID: PluginInstallTicket] = [:]
    private var activeSourceKeys: Set<SourceScopeKey> = []

    init(records: [PluginInstallResult] = []) {
        // Normalize legacy snapshots that may contain more than one plugin
        // ID for the same source/scope. The last record is the authoritative
        // one, and the source invariant is restored before any transaction.
        for record in records {
            let key = RecordKey(pluginID: record.pluginID, scope: record.scope)
            let duplicateKeys = self.records.compactMap { existingKey, existing in
                existing.scope == record.scope &&
                    existing.sourceKey == record.sourceKey &&
                    existingKey != key ? existingKey : nil
            }
            for duplicateKey in duplicateKeys {
                self.records.removeValue(forKey: duplicateKey)
            }
            self.records[key] = record
        }
    }

    /// Starts an install or returns an existing matching record. The returned
    /// ticket must be committed or aborted by the caller.
    func begin(_ request: PluginInstallRequest) throws -> PluginInstallAdmission {
        try validate(request)

        if let existing = records.values.first(where: {
            $0.scope == request.scope && $0.sourceKey == request.sourceKey
        }) {
            if request.requestedVersion == nil || existing.version == request.requestedVersion {
                return .reuse(existing)
            }
            guard request.replace else {
                throw PluginInstallCoordinatorError.duplicate(
                    pluginID: existing.pluginID,
                    scope: request.scope
                )
            }
        }

        let sourceScopeKey = SourceScopeKey(
            sourceKey: request.sourceKey,
            scope: request.scope
        )
        guard !activeSourceKeys.contains(sourceScopeKey) else {
            throw PluginInstallCoordinatorError.operationInFlight(request.sourceKey)
        }

        let ticket = PluginInstallTicket(
            id: UUID(),
            request: request,
            previous: records.values.first(where: {
                $0.scope == request.scope && $0.sourceKey == request.sourceKey
            })
        )
        activeTransactions[ticket.id] = ticket
        activeSourceKeys.insert(sourceScopeKey)
        return .ticket(ticket)
    }

    /// Commits a backend result and replaces the prior record atomically.
    func commit(_ ticket: PluginInstallTicket, result: PluginInstallResult) throws {
        guard let active = activeTransactions[ticket.id], active == ticket else {
            throw PluginInstallCoordinatorError.transactionNotFound(ticket.id)
        }
        try validate(result, for: active.request)

        let key = RecordKey(pluginID: result.pluginID, scope: result.scope)
        if let existing = records[key],
           !(existing.sourceKey == result.sourceKey && existing.version == result.version),
           !active.request.replace {
            throw PluginInstallCoordinatorError.duplicate(
                pluginID: result.pluginID,
                scope: result.scope
            )
        }

        // A replacement can legitimately return a different backend plugin
        // ID. Remove every stale record for this source/scope before writing
        // the new identity, while leaving unrelated plugins untouched.
        let staleSourceKeys = records.compactMap { existingKey, existing in
            existing.scope == result.scope &&
                existing.sourceKey == result.sourceKey &&
                existingKey != key ? existingKey : nil
        }
        for staleSourceKey in staleSourceKeys {
            records.removeValue(forKey: staleSourceKey)
        }
        records[key] = result
        activeTransactions.removeValue(forKey: ticket.id)
        activeSourceKeys.remove(
            SourceScopeKey(sourceKey: active.request.sourceKey, scope: active.request.scope)
        )
    }

    func abort(_ ticket: PluginInstallTicket) {
        guard let active = activeTransactions.removeValue(forKey: ticket.id) else { return }
        activeSourceKeys.remove(
            SourceScopeKey(sourceKey: active.request.sourceKey, scope: active.request.scope)
        )
    }

    /// Runs a backend operation inside a transaction. Rollback is invoked for
    /// both operation and commit failures, while the previous record remains
    /// untouched until commit succeeds.
    func install(
        _ request: PluginInstallRequest,
        operation: @escaping @Sendable () async throws -> PluginInstallResult,
        rollback: @escaping @Sendable () async -> Void = {}
    ) async throws -> PluginInstallResult {
        switch try begin(request) {
        case let .reuse(existing):
            return existing
        case let .ticket(ticket):
            let operationResult: Result<PluginInstallResult, Error>
            do {
                operationResult = .success(try await operation())
            } catch {
                operationResult = .failure(error)
            }

            switch operationResult {
            case let .success(result):
                do {
                    try commit(ticket, result: result)
                    return result
                } catch {
                    await rollback()
                    abort(ticket)
                    throw error
                }
            case let .failure(error):
                await rollback()
                abort(ticket)
                throw error
            }
        }
    }

    func setEnabled(
        pluginID: String,
        scope: PluginInstallScope = .global,
        enabled: Bool
    ) throws -> PluginInstallResult {
        let key = RecordKey(pluginID: pluginID, scope: scope)
        guard let existing = records[key] else {
            throw PluginInstallCoordinatorError.unknown(pluginID: pluginID, scope: scope)
        }
        let updated = PluginInstallResult(
            pluginID: existing.pluginID,
            version: existing.version,
            scope: existing.scope,
            backend: existing.backend,
            sourceKey: existing.sourceKey,
            enabled: enabled
        )
        records[key] = updated
        return updated
    }

    @discardableResult
    func uninstall(
        pluginID: String,
        scope: PluginInstallScope = .global
    ) throws -> PluginInstallResult {
        let key = RecordKey(pluginID: pluginID, scope: scope)
        guard let existing = records.removeValue(forKey: key) else {
            throw PluginInstallCoordinatorError.unknown(pluginID: pluginID, scope: scope)
        }
        return existing
    }

    /// Imports backend inventory discovered before the coordinator was
    /// created (for example, records loaded from disk at app launch).
    func adopt(_ result: PluginInstallResult, replace: Bool = true) throws {
        try validate(result)
        let key = RecordKey(pluginID: result.pluginID, scope: result.scope)
        let sameSourceRecords = records.filter { _, existing in
            existing.scope == result.scope && existing.sourceKey == result.sourceKey
        }
        if !replace {
            if let existing = sameSourceRecords.values.first,
               !(existing.pluginID == result.pluginID && existing.version == result.version) {
                throw PluginInstallCoordinatorError.duplicate(
                    pluginID: existing.pluginID,
                    scope: existing.scope
                )
            }
            if let existing = records[key],
               !(existing.sourceKey == result.sourceKey && existing.version == result.version) {
                throw PluginInstallCoordinatorError.duplicate(
                    pluginID: result.pluginID,
                    scope: result.scope
                )
            }
        } else {
            // Inventory adoption is authoritative for a source/scope. This
            // also repairs old snapshots where a replacement changed IDs.
            for (existingKey, _) in sameSourceRecords where existingKey != key {
                records.removeValue(forKey: existingKey)
            }
        }
        records[key] = result
    }

    /// Reconciles an authoritative inventory for selected backends. This is
    /// intentionally separate from `adopt`: callers must only use it after a
    /// successful, complete backend inventory response. A transient Host
    /// failure must never be represented as an empty authoritative list.
    @discardableResult
    func reconcileGlobalInventory(
        _ inventory: [PluginInstallResult],
        authoritativeBackends: Set<PluginBackend> = [.ish]
    ) throws -> [PluginInstallResult] {
        for result in inventory {
            try validate(result)
            guard result.scope == .global else {
                throw PluginInstallCoordinatorError.resultMismatch(
                    "全局库存不能包含会话作用域记录。"
                )
            }
        }

        let authoritativeKeys = Set(
            inventory
                .filter { authoritativeBackends.contains($0.backend) }
                .map { RecordKey(pluginID: $0.pluginID, scope: .global) }
        )

        for result in inventory {
            try adopt(result)
        }

        var stale: [RecordKey] = []
        for (key, existing) in records {
            guard existing.scope == .global,
                  authoritativeBackends.contains(existing.backend),
                  !authoritativeKeys.contains(key) else {
                continue
            }
            stale.append(key)
        }
        let staleResults = stale.compactMap { records[$0] }
        for staleKey in stale {
            records.removeValue(forKey: staleKey)
        }
        return staleResults
    }

    func record(
        pluginID: String,
        scope: PluginInstallScope = .global
    ) -> PluginInstallResult? {
        records[RecordKey(pluginID: pluginID, scope: scope)]
    }

    func isAvailable(
        pluginID: String,
        in scope: PluginInstallScope
    ) -> Bool {
        if records[RecordKey(pluginID: pluginID, scope: scope)] != nil { return true }
        guard scope != .global else { return false }
        return records[RecordKey(pluginID: pluginID, scope: .global)] != nil
    }

    func snapshots() -> [PluginInstallResult] {
        records.values.sorted {
            if $0.pluginID != $1.pluginID { return $0.pluginID < $1.pluginID }
            return $0.scope.description < $1.scope.description
        }
    }

    private func validate(_ request: PluginInstallRequest) throws {
        guard request.sourceKey.utf8.count <= 4_096,
              !request.sourceKey.isEmpty else {
            throw PluginInstallCoordinatorError.invalidRequest("来源标识为空。")
        }
        if let requestedVersion = request.requestedVersion {
            guard !requestedVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  requestedVersion.utf8.count <= 80 else {
                throw PluginInstallCoordinatorError.invalidRequest("版本号不合法。")
            }
        }
        switch request.source {
        case let .marketplace(source), let .preparedMarketplace(source, token: _):
            guard !source.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  source.location.utf8.count <= 2_048 else {
                throw PluginInstallCoordinatorError.invalidRequest("市场来源位置不合法。")
            }
            guard !source.location.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw PluginInstallCoordinatorError.invalidRequest("市场来源不能包含控制字符。")
            }
        case let .native(sourceDigest):
            guard sourceDigest.utf8.count == 64,
                  sourceDigest.allSatisfy(\.isHexDigit) else {
                throw PluginInstallCoordinatorError.invalidRequest("原生插件来源摘要必须是 64 位十六进制值。")
            }
        }
    }

    private func validate(
        _ result: PluginInstallResult,
        for request: PluginInstallRequest? = nil
    ) throws {
        guard !result.pluginID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.pluginID.utf8.count <= 256 else {
            throw PluginInstallCoordinatorError.resultMismatch("插件 ID 不合法。")
        }
        guard !result.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.version.utf8.count <= 80 else {
            throw PluginInstallCoordinatorError.resultMismatch("插件版本不合法。")
        }
        if let request {
            guard result.scope == request.scope else {
                throw PluginInstallCoordinatorError.resultMismatch("作用域不匹配。")
            }
            guard result.sourceKey == request.sourceKey else {
                throw PluginInstallCoordinatorError.resultMismatch("来源标识不匹配。")
            }
            if let requestedVersion = request.requestedVersion,
               result.version != requestedVersion {
                throw PluginInstallCoordinatorError.resultMismatch("版本不匹配。")
            }
            if let expectedBackend = request.source.expectedBackend,
               result.backend != expectedBackend {
                throw PluginInstallCoordinatorError.resultMismatch("执行后端不匹配。")
            }
        } else if result.sourceKey.isEmpty {
            throw PluginInstallCoordinatorError.resultMismatch("来源标识为空。")
        }
    }
}
