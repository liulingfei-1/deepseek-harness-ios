import Foundation

/// Narrow lifecycle seam used by the recovery coordinator. Keeping it smaller
/// than the JSON-RPC client makes update/restart semantics deterministic in
/// tests and avoids teaching the coordinator about transport details.
protocol ISHPluginHostDynamicLifecycleClient: Sendable {
    func define(_ request: ISHPluginHostDefineRequest) async throws -> ISHPluginHostDefineReceipt
    func run(_ request: ISHPluginHostRunRequest) async throws -> ISHPluginHostRunResponse
}

extension ISHPluginHostClient: ISHPluginHostDynamicLifecycleClient {}

enum ISHPluginHostDefinitionRecoveryPolicy: Sendable, Equatable {
    /// Source remains in native process memory and may be defined again after
    /// the iSH Node process restarts. This is not cold-launch persistence.
    case replayAfterProcessRestart
    /// Source cannot safely be retained or reconstructed. Recovery reports the
    /// reason instead of pretending the old Fiber is still active.
    case unavailable(reason: String)
}

/// Native-owned source envelope for one dynamic Host Package. Snapshots never
/// expose `code`; provider credentials are not part of this type.
struct ISHPluginHostRecoverableDefinition: Sendable, Equatable {
    let logicalID: String
    let idPrefix: String
    let sessionID: String
    let name: String
    let purpose: String
    let code: ISHPluginHostDefinitionCode
    let recoveryPolicy: ISHPluginHostDefinitionRecoveryPolicy

    init(
        logicalID: String,
        idPrefix: String,
        sessionID: String,
        name: String,
        purpose: String,
        code: ISHPluginHostDefinitionCode,
        recoveryPolicy: ISHPluginHostDefinitionRecoveryPolicy = .replayAfterProcessRestart
    ) {
        self.logicalID = logicalID
        self.idPrefix = idPrefix
        self.sessionID = sessionID
        self.name = name
        self.purpose = purpose
        self.code = code
        self.recoveryPolicy = recoveryPolicy
    }

    fileprivate func request(
        selector: ISHPluginHostDefinitionSelector
    ) -> ISHPluginHostDefineRequest {
        ISHPluginHostDefineRequest(
            sessionId: sessionID,
            plugin: selector,
            name: name,
            purpose: purpose,
            code: code
        )
    }
}

enum ISHPluginHostDynamicDefinitionState: String, Sendable, Equatable {
    case active
    /// The last transport outcome was ambiguous. The bridge must be rebuilt
    /// from fresh Host inventory before advertising this definition again.
    case recoveryRequired
    case unrecoverable
}

struct ISHPluginHostDynamicDefinitionSnapshot: Sendable, Equatable {
    let logicalID: String
    let name: String
    let pluginID: String?
    let packageID: String?
    let state: ISHPluginHostDynamicDefinitionState
    let detail: String?
}

enum ISHPluginHostDefinitionRecoveryOutcome: Sendable, Equatable {
    case replayed(logicalID: String, pluginID: String, packageID: String)
    case unrecoverable(logicalID: String, reason: String)
    case failed(logicalID: String, error: String)
}

struct ISHPluginHostDefinitionRecoveryReport: Sendable, Equatable {
    let outcomes: [ISHPluginHostDefinitionRecoveryOutcome]

    var recoveredCount: Int {
        outcomes.reduce(into: 0) { count, outcome in
            if case .replayed = outcome { count += 1 }
        }
    }
}

enum ISHPluginHostDynamicLifecycleError: LocalizedError, Sendable, Equatable {
    case invalidDefinition(String)
    case duplicateDefinition(String)
    case unknownDefinition(String)
    case activationRejected(logicalID: String, message: String)
    case replacementRolledBack(logicalID: String, message: String)
    case rollbackFailed(logicalID: String, replacementError: String, rollbackError: String)
    case replacementOutcomeUnknown(logicalID: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .invalidDefinition(id):
            "Invalid dynamic definition: \(id)"
        case let .duplicateDefinition(id):
            "Dynamic definition \(id) is already registered."
        case let .unknownDefinition(id):
            "Dynamic definition \(id) is not registered."
        case let .activationRejected(id, message):
            "Dynamic definition \(id) did not activate: \(message)"
        case let .replacementRolledBack(id, message):
            "Dynamic definition \(id) replacement failed and the previous Package was reactivated: \(message)"
        case let .rollbackFailed(id, replacementError, rollbackError):
            "Dynamic definition \(id) replacement failed (\(replacementError)); previous Package recovery also failed (\(rollbackError))."
        case let .replacementOutcomeUnknown(id, message):
            "Dynamic definition \(id) replacement outcome is unknown and requires fresh Host inventory: \(message)"
        }
    }
}

/// Adds the transaction and restart policy that the upstream dynamic runner
/// intentionally does not provide. Each definition is isolated: a failed
/// replay or rollback changes only that logical entry.
actor ISHPluginHostDynamicLifecycleCoordinator {
    private struct ActivePackage: Sendable, Equatable {
        let pluginID: String
        let packageID: String
    }

    private struct Record: Sendable, Equatable {
        var source: ISHPluginHostRecoverableDefinition
        var active: ActivePackage?
        var state: ISHPluginHostDynamicDefinitionState
        var detail: String?
    }

    private let client: any ISHPluginHostDynamicLifecycleClient
    private var records: [String: Record] = [:]

    init(client: any ISHPluginHostDynamicLifecycleClient) {
        self.client = client
    }

    @discardableResult
    func install(
        _ source: ISHPluginHostRecoverableDefinition
    ) async throws -> ISHPluginHostDynamicDefinitionSnapshot {
        try Self.validate(source)
        guard records[source.logicalID] == nil else {
            throw ISHPluginHostDynamicLifecycleError.duplicateDefinition(source.logicalID)
        }

        let receipt = try await client.define(
            source.request(selector: .new(idPrefix: source.idPrefix))
        )
        let response = try await client.run(
            ISHPluginHostRunRequest(
                sessionId: source.sessionID,
                pluginId: receipt.pluginId,
                packageId: receipt.packageId,
                mode: .run
            )
        )
        guard response.ok else {
            throw ISHPluginHostDynamicLifecycleError.activationRejected(
                logicalID: source.logicalID,
                message: Self.failureMessage(response)
            )
        }
        records[source.logicalID] = Record(
            source: source,
            active: ActivePackage(pluginID: receipt.pluginId, packageID: receipt.packageId),
            state: .active,
            detail: nil
        )
        return try snapshot(for: source.logicalID)
    }

    /// Define the candidate without disturbing the old Fiber, then ask the
    /// upstream runner to update. An explicit activation rejection triggers a
    /// separate official `run` of the retained old Package. Transport errors
    /// are not replayed because the update outcome is ambiguous.
    @discardableResult
    func replace(
        _ logicalID: String,
        with source: ISHPluginHostRecoverableDefinition
    ) async throws -> ISHPluginHostDynamicDefinitionSnapshot {
        try Self.validate(source)
        guard source.logicalID == logicalID else {
            throw ISHPluginHostDynamicLifecycleError.invalidDefinition(source.logicalID)
        }
        guard var current = records[logicalID], let old = current.active else {
            throw ISHPluginHostDynamicLifecycleError.unknownDefinition(logicalID)
        }

        let receipt = try await client.define(
            source.request(selector: .existing(pluginId: old.pluginID))
        )
        guard receipt.pluginId == old.pluginID else {
            throw ISHPluginHostDynamicLifecycleError.activationRejected(
                logicalID: logicalID,
                message: "Host returned a different plugin identity."
            )
        }

        let update: ISHPluginHostRunResponse
        do {
            update = try await client.run(
                ISHPluginHostRunRequest(
                    sessionId: source.sessionID,
                    pluginId: old.pluginID,
                    packageId: receipt.packageId,
                    mode: .update
                )
            )
        } catch {
            current.state = .recoveryRequired
            current.detail = error.localizedDescription
            records[logicalID] = current
            throw ISHPluginHostDynamicLifecycleError.replacementOutcomeUnknown(
                logicalID: logicalID,
                message: error.localizedDescription
            )
        }

        guard !update.ok else {
            current.source = source
            current.active = ActivePackage(pluginID: old.pluginID, packageID: receipt.packageId)
            current.state = .active
            current.detail = nil
            records[logicalID] = current
            return try snapshot(for: logicalID)
        }

        let replacementError = Self.failureMessage(update)
        do {
            let rollback = try await client.run(
                ISHPluginHostRunRequest(
                    sessionId: current.source.sessionID,
                    pluginId: old.pluginID,
                    packageId: old.packageID,
                    mode: .run
                )
            )
            guard rollback.ok else {
                throw ISHPluginHostDynamicLifecycleError.activationRejected(
                    logicalID: logicalID,
                    message: Self.failureMessage(rollback)
                )
            }
            current.state = .active
            current.detail = nil
            records[logicalID] = current
            throw ISHPluginHostDynamicLifecycleError.replacementRolledBack(
                logicalID: logicalID,
                message: replacementError
            )
        } catch let error as ISHPluginHostDynamicLifecycleError {
            if case .replacementRolledBack = error { throw error }
            current.state = .recoveryRequired
            current.detail = error.localizedDescription
            records[logicalID] = current
            throw ISHPluginHostDynamicLifecycleError.rollbackFailed(
                logicalID: logicalID,
                replacementError: replacementError,
                rollbackError: error.localizedDescription
            )
        } catch {
            current.state = .recoveryRequired
            current.detail = error.localizedDescription
            records[logicalID] = current
            throw ISHPluginHostDynamicLifecycleError.rollbackFailed(
                logicalID: logicalID,
                replacementError: replacementError,
                rollbackError: error.localizedDescription
            )
        }
    }

    /// Call only after a confirmed Host process restart. Replay continues after
    /// individual failures, so one broken self-generated plugin cannot prevent
    /// healthy definitions from returning.
    func recoverAfterHostRestart() async -> ISHPluginHostDefinitionRecoveryReport {
        var outcomes: [ISHPluginHostDefinitionRecoveryOutcome] = []
        for logicalID in records.keys.sorted() {
            guard var record = records[logicalID] else { continue }
            record.active = nil
            switch record.source.recoveryPolicy {
            case .replayAfterProcessRestart:
                do {
                    let receipt = try await client.define(
                        record.source.request(selector: .new(idPrefix: record.source.idPrefix))
                    )
                    let response = try await client.run(
                        ISHPluginHostRunRequest(
                            sessionId: record.source.sessionID,
                            pluginId: receipt.pluginId,
                            packageId: receipt.packageId,
                            mode: .run
                        )
                    )
                    guard response.ok else {
                        throw ISHPluginHostDynamicLifecycleError.activationRejected(
                            logicalID: logicalID,
                            message: Self.failureMessage(response)
                        )
                    }
                    record.active = ActivePackage(
                        pluginID: receipt.pluginId,
                        packageID: receipt.packageId
                    )
                    record.state = .active
                    record.detail = nil
                    outcomes.append(.replayed(
                        logicalID: logicalID,
                        pluginID: receipt.pluginId,
                        packageID: receipt.packageId
                    ))
                } catch {
                    record.state = .recoveryRequired
                    record.detail = error.localizedDescription
                    outcomes.append(.failed(
                        logicalID: logicalID,
                        error: error.localizedDescription
                    ))
                }
            case let .unavailable(reason):
                record.state = .unrecoverable
                record.detail = reason
                outcomes.append(.unrecoverable(logicalID: logicalID, reason: reason))
            }
            records[logicalID] = record
        }
        return ISHPluginHostDefinitionRecoveryReport(outcomes: outcomes)
    }

    func snapshots() -> [ISHPluginHostDynamicDefinitionSnapshot] {
        records.keys.sorted().compactMap { try? snapshot(for: $0) }
    }

    private func snapshot(for logicalID: String) throws -> ISHPluginHostDynamicDefinitionSnapshot {
        guard let record = records[logicalID] else {
            throw ISHPluginHostDynamicLifecycleError.unknownDefinition(logicalID)
        }
        return ISHPluginHostDynamicDefinitionSnapshot(
            logicalID: logicalID,
            name: record.source.name,
            pluginID: record.active?.pluginID,
            packageID: record.active?.packageID,
            state: record.state,
            detail: record.detail
        )
    }

    private static func validate(_ source: ISHPluginHostRecoverableDefinition) throws {
        let fields = [source.logicalID, source.idPrefix, source.sessionID, source.name]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              source.logicalID.utf8.count <= 128,
              source.idPrefix.utf8.count <= 64,
              source.sessionID.utf8.count <= 256,
              source.name.utf8.count <= 256,
              source.purpose.utf8.count <= 4_096,
              source.code.host?.utf8.count ?? 0 <= 512 * 1_024,
              source.code.client?.utf8.count ?? 0 <= 512 * 1_024,
              source.code.host != nil || source.code.client != nil else {
            throw ISHPluginHostDynamicLifecycleError.invalidDefinition(source.logicalID)
        }
    }

    private static func failureMessage(_ response: ISHPluginHostRunResponse) -> String {
        let text = response.message ?? response.reason ?? response.status ?? "activation rejected"
        return String(text.prefix(2_048))
    }
}
