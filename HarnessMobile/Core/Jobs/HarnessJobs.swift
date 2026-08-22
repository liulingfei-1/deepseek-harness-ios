import Foundation

enum HarnessJobStatus: String, Codable, Sendable, Equatable {
    case running
    case stopping
    case completed
    case killed
    case failed

    var isTerminal: Bool {
        switch self {
        case .running, .stopping:
            false
        case .completed, .killed, .failed:
            true
        }
    }
}

struct HarnessJobSnapshot: Codable, Sendable, Equatable {
    let id: String
    let kind: String
    let label: String
    let outputLimitBytes: Int?
    let ownerSession: String?
    let status: HarnessJobStatus
    let detail: String?
    let startedAt: Int64
    let finishedAt: Int64?
    let reported: Bool
}

struct HarnessJobRead: Sendable, Equatable {
    let text: String
    let snapshot: HarnessJobSnapshot
}

struct HarnessJobCompletionNotice: Codable, Sendable, Equatable {
    let id: String
    let ownerSession: String
    let kind: String
    let label: String
    let status: HarnessJobStatus
    let detail: String?
    let finishedAt: Int64

    var text: String {
        let detailText = detail.map { ", \($0)" } ?? ""
        return "background job \(id) (\(kind): \(label)) finished "
            + "[status: \(status.rawValue)\(detailText)]. Read its output with job_output."
    }
}

struct HarnessJobOutcome: Sendable, Equatable {
    let status: HarnessJobStatus
    let detail: String?
    let output: String?

    init(
        status: HarnessJobStatus,
        detail: String? = nil,
        output: String? = nil
    ) {
        precondition(status.isTerminal)
        self.status = status
        self.detail = detail
        self.output = output
    }
}

/// Durable identity for a continuable child Agent. A background job represents
/// only one activation; this record survives completion and app relaunch so a
/// later `send_message` can wake the same SessionStore conversation.
struct HarnessSubagentSnapshot: Codable, Sendable, Equatable {
    let id: String
    let parentSession: String
    let label: String
    let model: String?
    let providerBundleID: AgentProviderBundleID?
    let contextMode: LocalSubagentContextMode
    let delegationDepth: Int
    let maximumDepth: Int
    let persona: String?
    let toolFilter: LocalSubagentToolFilter?
    let reportDelivery: LocalSubagentReportDelivery
    let hasChildren: Bool
    let status: HarnessJobStatus
    let activeJobID: String?
    let lastJobID: String?
    let createdAt: Int64
    let updatedAt: Int64
}

typealias HarnessJobOutputEmitter = @Sendable (String) async -> Void
typealias HarnessJobOperation = @Sendable (
    _ emit: @escaping HarnessJobOutputEmitter
) async throws -> HarnessJobOutcome

enum HarnessJobError: LocalizedError, Sendable, Equatable {
    case invalidKind
    case invalidLabel
    case invalidOutputLimit
    case invalidTimeout
    case unknownJob(String)
    case foreignJob(String)
    case capacityReached(limit: Int)
    case unknownSubagent(String)
    case subagentBusy(String)
    case invalidSubagentDepth
    case subagentDepthExceeded(depth: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case .invalidKind:
            "invalid job kind: expected a non-empty string"
        case .invalidLabel:
            "invalid job label: expected a non-empty string"
        case .invalidOutputLimit:
            "invalid output limit: expected a positive integer"
        case .invalidTimeout:
            "invalid wait timeout: expected positive milliseconds"
        case let .unknownJob(id):
            "unknown job \(id)"
        case let .foreignJob(id):
            "job \(id) belongs to another session"
        case let .capacityReached(limit):
            "background job limit reached for this session (limit: \(limit)); stop an unneeded job or wait for one to finish"
        case let .unknownSubagent(id):
            "unknown subagent \(id)"
        case let .subagentBusy(id):
            "subagent \(id) already has an active turn"
        case .invalidSubagentDepth:
            "subagent depth must be a non-negative integer"
        case let .subagentDepthExceeded(depth, maximum):
            "subagent depth \(depth) exceeds the configured maximum \(maximum)"
        }
    }
}

protocol HarnessJobManaging: Sendable {
    func start(
        kind: String,
        label: String,
        ownerSession: String?,
        outputLimitBytes: Int?,
        operation: @escaping HarnessJobOperation
    ) async throws -> String
    func list(ownerSession: String?) async -> [HarnessJobSnapshot]
    func get(id: String, ownerSession: String?) async throws -> HarnessJobSnapshot
    func read(id: String, ownerSession: String?) async throws -> HarnessJobRead
    func kill(
        id: String,
        ownerSession: String?,
        reason: String?
    ) async throws -> HarnessJobKillResult
    func wait(
        id: String,
        timeoutMilliseconds: Int,
        ownerSession: String?
    ) async throws -> HarnessJobSnapshot
    func cancelAll(ownerSession: String?, reason: String) async
    /// Atomically claim every pending completion notice for one exact owner.
    /// Claiming affects notification only; terminal final output remains
    /// idempotently readable through `read`.
    func claimCompletionNotices(ownerSession: String) async -> [HarnessJobCompletionNotice]
    /// Acknowledge a claimed completion only after the destination session has
    /// durably accepted it. Claims are leased so a crash between claim and
    /// delivery can be recovered on the next launch.
    func acknowledgeCompletionNotice(id: String, ownerSession: String) async
    /// Returns a claimed notice to the pending queue when delivery failed.
    /// This is intentionally idempotent so a crash or cold-launch race cannot
    /// permanently lose a completion event.
    func requeueCompletionNotice(id: String, ownerSession: String) async
    func registerSubagent(
        id: String,
        parentSession: String,
        label: String,
        model: String?,
        providerBundleID: AgentProviderBundleID?,
        contextMode: LocalSubagentContextMode,
        persona: String?,
        toolFilter: LocalSubagentToolFilter?,
        reportDelivery: LocalSubagentReportDelivery,
        maximumDepth: Int
    ) async throws -> HarnessSubagentSnapshot
    func startSubagentActivation(
        id: String,
        operation: @escaping HarnessJobOperation
    ) async throws -> String
    func subagent(id: String, requesterSession: String) async throws -> HarnessSubagentSnapshot
    func listSubagents(rootSession: String, descendants: Bool) async -> [HarnessSubagentSnapshot]
    /// Returns the durable child records from the root's direct child through
    /// `sessionID`. A root conversation (which has no subagent record) returns
    /// an empty array. The projection is read-only and cycle-safe so UI
    /// navigation never needs to infer ancestry from the flattened tree.
    func subagentLineage(sessionID: String) async -> [HarnessSubagentSnapshot]
    func delegationDepth(sessionID: String) async -> Int
    func interruptSubagent(
        id: String,
        requesterSession: String,
        reason: String?
    ) async throws -> HarnessJobKillResult
}

extension HarnessJobManaging {
    func registerSubagent(
        id: String,
        parentSession: String,
        label: String,
        model: String?,
        providerBundleID: AgentProviderBundleID?
    ) async throws -> HarnessSubagentSnapshot {
        try await registerSubagent(
            id: id,
            parentSession: parentSession,
            label: label,
            model: model,
            providerBundleID: providerBundleID,
            contextMode: .fresh,
            persona: nil,
            toolFilter: nil,
            reportDelivery: .wakeup,
            maximumDepth: 3
        )
    }

    func registerSubagent(
        id: String,
        parentSession: String,
        label: String,
        model: String?
    ) async throws -> HarnessSubagentSnapshot {
        try await registerSubagent(
            id: id,
            parentSession: parentSession,
            label: label,
            model: model,
            providerBundleID: nil,
            contextMode: .fresh,
            persona: nil,
            toolFilter: nil,
            reportDelivery: .wakeup,
            maximumDepth: 3
        )
    }
}

enum HarnessJobKillResult: String, Sendable, Equatable {
    case requested
    case alreadyFinished
}

actor HarnessJobRegistry: HarnessJobManaging {
    private struct Record {
        let id: String
        let kind: String
        let label: String
        let outputLimitBytes: Int?
        let ownerSession: String?
        var status: HarnessJobStatus
        var detail: String?
        var finalOutput: String?
        let startedAt: Int64
        var finishedAt: Int64?
        var reported: Bool
        var completionClaimedAt: Int64?
        var pendingOutput: String
        var task: Task<Void, Never>?
    }

    private struct PersistedState: Codable {
        let version: Int
        let counters: [String: Int]
        let registrationOrder: [String]
        let records: [PersistedRecord]
        let subagents: [PersistedSubagentRecord]?
        /// Stable insertion order for the durable child-Agent directory.
        ///
        /// This was added after the original v1 state format. Keep it
        /// optional so existing installations can still be restored; when it
        /// is absent the loader derives a deterministic order below.
        let subagentRegistrationOrder: [String]?
    }

    private struct PersistedSubagentRecord: Codable {
        let id: String
        let parentSession: String
        let label: String
        let model: String?
        let providerBundleID: AgentProviderBundleID?
        let contextMode: LocalSubagentContextMode?
        let delegationDepth: Int?
        let maximumDepth: Int?
        let persona: String?
        let toolFilter: LocalSubagentToolFilter?
        let reportDelivery: LocalSubagentReportDelivery?
        let status: HarnessJobStatus
        let activeJobID: String?
        let lastJobID: String?
        let createdAt: Int64
        let updatedAt: Int64
    }

    private struct SubagentRecord {
        let id: String
        let parentSession: String
        let label: String
        let model: String?
        let providerBundleID: AgentProviderBundleID?
        let contextMode: LocalSubagentContextMode
        let delegationDepth: Int
        let maximumDepth: Int
        let persona: String?
        let toolFilter: LocalSubagentToolFilter?
        let reportDelivery: LocalSubagentReportDelivery
        var status: HarnessJobStatus
        var activeJobID: String?
        var lastJobID: String?
        let createdAt: Int64
        var updatedAt: Int64
    }

    private struct PersistedRecord: Codable {
        let id: String
        let kind: String
        let label: String
        let outputLimitBytes: Int?
        let ownerSession: String?
        let status: HarnessJobStatus
        let detail: String?
        let finalOutput: String?
        let startedAt: Int64
        let finishedAt: Int64?
        let reported: Bool
        let completionClaimedAt: Int64?
        let pendingOutput: String
    }

    private static let defaultOutputLimitBytes = 112 * 1_024
    private let maxConcurrentJobsPerOwner: Int
    private let persistenceURL: URL?
    private var counters: [String: Int] = [:]
    private var records: [String: Record] = [:]
    private var registrationOrder: [String] = []
    private var subagentRegistrationOrder: [String] = []
    private var subagents: [String: SubagentRecord] = [:]
    private var persistenceTask: Task<Void, Never>?
    private static let completionClaimLeaseMilliseconds: Int64 = 30_000

    init(
        maxConcurrentJobsPerOwner: Int = 10,
        persistenceURL: URL? = nil
    ) {
        precondition(maxConcurrentJobsPerOwner > 0)
        self.maxConcurrentJobsPerOwner = maxConcurrentJobsPerOwner
        self.persistenceURL = persistenceURL
        var restoredCounters: [String: Int] = [:]
        var restoredRecords: [String: Record] = [:]
        var restoredOrder: [String] = []
        var restoredSubagentOrder: [String] = []
        var restoredSubagents: [String: SubagentRecord] = [:]
        if let persistenceURL,
           let state = Self.loadPersistedState(from: persistenceURL) {
            restoredCounters = state.counters
            restoredOrder = state.registrationOrder
            restoredSubagentOrder = state.subagentRegistrationOrder ?? []
            let recoveredAt = Self.nowMilliseconds()
            for persisted in state.records {
                let wasActive = !persisted.status.isTerminal
                restoredRecords[persisted.id] = Record(
                    id: persisted.id,
                    kind: persisted.kind,
                    label: persisted.label,
                    outputLimitBytes: persisted.outputLimitBytes,
                    ownerSession: persisted.ownerSession,
                    status: wasActive ? .failed : persisted.status,
                    detail: wasActive
                        ? "interrupted by app restart; this operation cannot resume automatically"
                        : persisted.detail,
                    finalOutput: persisted.finalOutput,
                    startedAt: persisted.startedAt,
                    finishedAt: wasActive ? recoveredAt : persisted.finishedAt,
                    // A completion claim is never trusted across a process
                    // restart. The destination may not have committed it.
                    reported: wasActive ? false : persisted.reported,
                    completionClaimedAt: nil,
                    pendingOutput: persisted.pendingOutput,
                    task: nil
                )
            }
            restoredOrder = restoredOrder.filter { restoredRecords[$0] != nil }
            let missingIDs = restoredRecords.keys.filter { !restoredOrder.contains($0) }.sorted()
            restoredOrder.append(contentsOf: missingIDs)
            let persistedSubagents = state.subagents ?? []
            let persistedSubagentsByID = Dictionary(
                uniqueKeysWithValues: persistedSubagents.map { ($0.id, $0) }
            )
            for persisted in persistedSubagents {
                let activeJob = persisted.activeJobID.flatMap { restoredRecords[$0] }
                let wasActive = activeJob.map { !$0.status.isTerminal } ?? false
                restoredSubagents[persisted.id] = SubagentRecord(
                    id: persisted.id,
                    parentSession: persisted.parentSession,
                    label: persisted.label,
                    model: persisted.model,
                    providerBundleID: persisted.providerBundleID,
                    contextMode: persisted.contextMode ?? .fresh,
                    delegationDepth: persisted.delegationDepth
                        ?? Self.legacyDelegationDepth(
                            of: persisted.id,
                            records: persistedSubagentsByID
                        ),
                    maximumDepth: persisted.maximumDepth ?? 3,
                    persona: persisted.persona,
                    toolFilter: persisted.toolFilter,
                    reportDelivery: persisted.reportDelivery ?? .wakeup,
                    status: wasActive ? .failed : (activeJob?.status ?? persisted.status),
                    activeJobID: nil,
                    lastJobID: persisted.activeJobID ?? persisted.lastJobID,
                    createdAt: persisted.createdAt,
                    updatedAt: wasActive ? recoveredAt : persisted.updatedAt
                )
            }
            // Older v1 files did not persist the child-Agent insertion order.
            // Derive one deterministically, and always include any malformed
            // or newly added records so the directory cannot silently lose a
            // node after a cold restore.
            if restoredSubagentOrder.isEmpty {
                restoredSubagentOrder = (state.subagents ?? [])
                    .sorted {
                        $0.createdAt == $1.createdAt
                            ? $0.id < $1.id
                            : $0.createdAt < $1.createdAt
                    }
                    .map(\.id)
            }
            restoredSubagentOrder = restoredSubagentOrder.filter {
                restoredSubagents[$0] != nil
            }
            let missingSubagentIDs = restoredSubagents.keys
                .filter { !restoredSubagentOrder.contains($0) }
                .sorted()
            restoredSubagentOrder.append(contentsOf: missingSubagentIDs)
            try? Self.writePersistedState(
                Self.persistedState(
                    counters: restoredCounters,
                    registrationOrder: restoredOrder,
                    records: restoredRecords,
                    subagents: restoredSubagents,
                    subagentRegistrationOrder: restoredSubagentOrder
                ),
                to: persistenceURL
            )
        }
        self.counters = restoredCounters
        self.records = restoredRecords
        self.registrationOrder = restoredOrder
        self.subagents = restoredSubagents
        self.subagentRegistrationOrder = restoredSubagentOrder
    }

    static func applicationPersistenceURL() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("HarnessMobile", isDirectory: true)
        .appendingPathComponent("Jobs", isDirectory: true)
        .appendingPathComponent("jobs-v1.json", isDirectory: false)
    }

    func start(
        kind: String,
        label: String,
        ownerSession: String?,
        outputLimitBytes: Int? = nil,
        operation: @escaping HarnessJobOperation
    ) throws -> String {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKind.isEmpty else { throw HarnessJobError.invalidKind }
        guard !normalizedLabel.isEmpty else { throw HarnessJobError.invalidLabel }
        if let outputLimitBytes, outputLimitBytes <= 0 {
            throw HarnessJobError.invalidOutputLimit
        }
        let activeCount = records.values.filter {
            $0.ownerSession == ownerSession && !$0.status.isTerminal
        }.count
        guard activeCount < maxConcurrentJobsPerOwner else {
            throw HarnessJobError.capacityReached(limit: maxConcurrentJobsPerOwner)
        }

        let next = (counters[normalizedKind] ?? 0) + 1
        counters[normalizedKind] = next
        let id = "\(normalizedKind)-\(next)"
        records[id] = Record(
            id: id,
            kind: normalizedKind,
            label: normalizedLabel,
            outputLimitBytes: outputLimitBytes,
            ownerSession: ownerSession,
            status: .running,
            detail: nil,
            finalOutput: nil,
            startedAt: Self.nowMilliseconds(),
            finishedAt: nil,
            reported: false,
            completionClaimedAt: nil,
            pendingOutput: "",
            task: nil
        )
        registrationOrder.append(id)

        let task = Task { [registry = self] in
            let outcome: HarnessJobOutcome
            do {
                try Task.checkCancellation()
                outcome = try await operation { text in
                    await registry.appendOutput(id: id, text: text)
                }
            } catch is CancellationError {
                outcome = HarnessJobOutcome(status: .killed, detail: "cancelled")
            } catch let error as ISHSandboxError where error == .cancelled {
                outcome = HarnessJobOutcome(status: .killed, detail: "cancelled")
            } catch {
                outcome = HarnessJobOutcome(
                    status: .failed,
                    detail: error.localizedDescription
                )
            }
            await registry.settle(id: id, outcome: outcome)
        }
        records[id]?.task = task
        persistNow()
        return id
    }

    func list(ownerSession: String?) -> [HarnessJobSnapshot] {
        registrationOrder.compactMap { id in
            guard let record = records[id], Self.canAccess(record, ownerSession: ownerSession) else {
                return nil
            }
            return Self.snapshot(record)
        }
    }

    func get(id: String, ownerSession: String?) throws -> HarnessJobSnapshot {
        let record = try authorizedRecord(id: id, ownerSession: ownerSession)
        return Self.snapshot(record)
    }

    func read(id: String, ownerSession: String?) throws -> HarnessJobRead {
        var record = try authorizedRecord(id: id, ownerSession: ownerSession)
        let text: String
        if !record.pendingOutput.isEmpty {
            text = record.pendingOutput
                + (record.status.isTerminal
                    ? Self.finalOutputSuffix(
                        record.finalOutput,
                        alreadyIncludedIn: record.pendingOutput
                    )
                    : "")
            record.pendingOutput = ""
        } else if record.status.isTerminal, record.finalOutput != nil {
            text = record.finalOutput ?? ""
        } else {
            text = ""
        }
        if record.status.isTerminal {
            record.reported = true
            record.completionClaimedAt = nil
        }
        records[id] = record
        persistNow()
        return HarnessJobRead(text: text, snapshot: Self.snapshot(record))
    }

    func kill(
        id: String,
        ownerSession: String?,
        reason _: String? = nil
    ) throws -> HarnessJobKillResult {
        var record = try authorizedRecord(id: id, ownerSession: ownerSession)
        if record.status.isTerminal {
            record.reported = true
            record.completionClaimedAt = nil
            records[id] = record
            persistNow()
            return .alreadyFinished
        }
        record.task?.cancel()
        record.status = .stopping
        record.reported = true
        records[id] = record
        persistNow()
        return .requested
    }

    func wait(
        id: String,
        timeoutMilliseconds: Int,
        ownerSession: String?
    ) async throws -> HarnessJobSnapshot {
        guard timeoutMilliseconds > 0 else { throw HarnessJobError.invalidTimeout }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while true {
            try Task.checkCancellation()
            let record = try authorizedRecord(id: id, ownerSession: ownerSession)
            if record.status.isTerminal {
                // Waiting observes completion but does not acknowledge delivery.
                // The parent may still need to claim the durable completion
                // notice, including after a cold restore between wait and
                // report delivery. `read`/explicit acknowledgement consumes it.
                return Self.snapshot(record)
            }
            guard clock.now < deadline else { return Self.snapshot(record) }
            let remaining = clock.now.duration(to: deadline)
            try await Task.sleep(for: min(remaining, .milliseconds(100)))
        }
    }

    func cancelAll(ownerSession: String?, reason: String) {
        for id in registrationOrder {
            guard var record = records[id],
                  record.ownerSession == ownerSession,
                  !record.status.isTerminal else { continue }
            record.task?.cancel()
            record.status = .stopping
            record.reported = true
            record.completionClaimedAt = nil
            record.detail = reason
            records[id] = record
        }
        persistNow()
    }

    func claimCompletionNotices(ownerSession: String) -> [HarnessJobCompletionNotice] {
        var notices: [HarnessJobCompletionNotice] = []
        for id in registrationOrder {
            guard var record = records[id],
                  record.ownerSession == ownerSession,
                  record.status.isTerminal,
                  !record.reported,
                  record.completionClaimedAt == nil
                    || Self.nowMilliseconds() - (record.completionClaimedAt ?? 0)
                        >= Self.completionClaimLeaseMilliseconds,
                  let finishedAt = record.finishedAt else { continue }
            record.completionClaimedAt = Self.nowMilliseconds()
            records[id] = record
            notices.append(HarnessJobCompletionNotice(
                id: record.id,
                ownerSession: ownerSession,
                kind: record.kind,
                label: record.label,
                status: record.status,
                detail: record.detail,
                finishedAt: finishedAt
            ))
        }
        if !notices.isEmpty { persistNow() }
        return notices
    }

    func acknowledgeCompletionNotice(id: String, ownerSession: String) {
        guard var record = records[id],
              record.ownerSession == ownerSession,
              record.status.isTerminal else { return }
        record.reported = true
        record.completionClaimedAt = nil
        records[id] = record
        persistNow()
    }

    func requeueCompletionNotice(id: String, ownerSession: String) {
        guard var record = records[id],
              record.ownerSession == ownerSession,
              record.status.isTerminal else { return }
        record.reported = false
        record.completionClaimedAt = nil
        records[id] = record
        persistNow()
    }

    func registerSubagent(
        id: String,
        parentSession: String,
        label: String,
        model: String?,
        providerBundleID: AgentProviderBundleID? = nil,
        contextMode: LocalSubagentContextMode = .fresh,
        persona: String? = nil,
        toolFilter: LocalSubagentToolFilter? = nil,
        reportDelivery: LocalSubagentReportDelivery = .wakeup,
        maximumDepth: Int = 3
    ) throws -> HarnessSubagentSnapshot {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedParent = parentSession.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, !normalizedParent.isEmpty else { throw HarnessJobError.invalidKind }
        guard !normalizedLabel.isEmpty else { throw HarnessJobError.invalidLabel }
        guard (0...64).contains(maximumDepth) else {
            throw HarnessJobError.invalidSubagentDepth
        }
        guard normalizedID != normalizedParent else {
            throw HarnessJobError.invalidSubagentDepth
        }
        if let existing = subagents[normalizedID] {
            guard existing.parentSession == normalizedParent else {
                throw HarnessJobError.foreignJob(normalizedID)
            }
            return subagentSnapshot(existing)
        }
        let depth = (subagents[normalizedParent]?.delegationDepth ?? 0) + 1
        guard depth <= maximumDepth else {
            throw HarnessJobError.subagentDepthExceeded(depth: depth, maximum: maximumDepth)
        }
        let now = Self.nowMilliseconds()
        let record = SubagentRecord(
            id: normalizedID,
            parentSession: normalizedParent,
            label: normalizedLabel,
            model: model,
            providerBundleID: providerBundleID,
            contextMode: contextMode,
            delegationDepth: depth,
            maximumDepth: maximumDepth,
            persona: persona,
            toolFilter: toolFilter,
            reportDelivery: reportDelivery,
            status: .completed,
            activeJobID: nil,
            lastJobID: nil,
            createdAt: now,
            updatedAt: now
        )
        subagents[normalizedID] = record
        subagentRegistrationOrder.append(normalizedID)
        persistNow()
        return subagentSnapshot(record)
    }

    func startSubagentActivation(
        id: String,
        operation: @escaping HarnessJobOperation
    ) throws -> String {
        let normalizedID = id.lowercased()
        guard var child = subagents[normalizedID] else {
            throw HarnessJobError.unknownSubagent(normalizedID)
        }
        if let activeJobID = child.activeJobID,
           let active = records[activeJobID],
           !active.status.isTerminal {
            throw HarnessJobError.subagentBusy(normalizedID)
        }
        let jobID = try start(
            kind: "subagent",
            label: child.label,
            ownerSession: child.parentSession,
            outputLimitBytes: 112 * 1_024,
            operation: operation
        )
        child.status = .running
        child.activeJobID = jobID
        child.lastJobID = jobID
        child.updatedAt = Self.nowMilliseconds()
        subagents[normalizedID] = child
        persistNow()
        return jobID
    }

    func subagent(id: String, requesterSession: String) throws -> HarnessSubagentSnapshot {
        let normalizedID = id.lowercased()
        guard let child = subagents[normalizedID] else {
            throw HarnessJobError.unknownSubagent(normalizedID)
        }
        guard Self.isDescendant(child.id, of: requesterSession.lowercased(), in: subagents) else {
            throw HarnessJobError.foreignJob(normalizedID)
        }
        return subagentSnapshot(child)
    }

    func listSubagents(rootSession: String, descendants: Bool) -> [HarnessSubagentSnapshot] {
        let root = rootSession.lowercased()
        let registrationRanks = Dictionary(
            uniqueKeysWithValues: subagentRegistrationOrder.enumerated().map { ($1, $0) }
        )
        let siblingOrder: (SubagentRecord, SubagentRecord) -> Bool = { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            // Registration order is the only tie-breaker that survives a
            // same-millisecond registration. Fall back to the stable ID for
            // records imported from an older state file.
            let leftRank = registrationRanks[left.id] ?? .max
            let rightRank = registrationRanks[right.id] ?? .max
            return leftRank == rightRank ? left.id < right.id : leftRank < rightRank
        }
        var childrenByParent: [String: [SubagentRecord]] = [:]
        for child in subagents.values {
            childrenByParent[child.parentSession, default: []].append(child)
        }
        guard descendants else {
            return (childrenByParent[root] ?? [])
                .sorted(by: siblingOrder)
                .map { subagentSnapshot($0) }
        }

        // Enumerate the subtree in deterministic preorder. This keeps every
        // parent immediately before its descendants, even when registrations
        // share the same millisecond timestamp (the old flat sort could emit
        // a grandchild before its parent).
        var result: [HarnessSubagentSnapshot] = []
        var visited = Set<String>()
        func visit(_ parent: String) {
            let children = (childrenByParent[parent] ?? []).sorted(by: siblingOrder)
            for child in children where visited.insert(child.id).inserted {
                result.append(subagentSnapshot(child))
                visit(child.id)
            }
        }
        visit(root)
        return result
    }

    func subagentLineage(sessionID: String) -> [HarnessSubagentSnapshot] {
        var lineage: [HarnessSubagentSnapshot] = []
        var cursor = sessionID.lowercased()
        var visited = Set<String>()

        while visited.insert(cursor).inserted,
              let record = subagents[cursor] {
            lineage.append(subagentSnapshot(record))
            cursor = record.parentSession
        }
        return lineage.reversed()
    }

    func delegationDepth(sessionID: String) -> Int {
        subagents[sessionID.lowercased()]?.delegationDepth ?? 0
    }

    func interruptSubagent(
        id: String,
        requesterSession: String,
        reason: String?
    ) throws -> HarnessJobKillResult {
        let child = try authorizedSubagent(id: id, requesterSession: requesterSession)
        guard let activeJobID = child.activeJobID else { return .alreadyFinished }
        return try kill(id: activeJobID, ownerSession: child.parentSession, reason: reason)
    }

    private func appendOutput(id: String, text: String) {
        guard !text.isEmpty, var record = records[id], !record.status.isTerminal else { return }
        let limit = record.outputLimitBytes ?? Self.defaultOutputLimitBytes
        record.pendingOutput = Self.boundedTail(
            record.pendingOutput + text,
            maximumBytes: limit
        )
        records[id] = record
        schedulePersist()
    }

    private func settle(id: String, outcome: HarnessJobOutcome) {
        guard var record = records[id], !record.status.isTerminal else { return }
        record.status = outcome.status
        record.reported = false
        record.completionClaimedAt = nil
        record.detail = outcome.detail
        if let output = outcome.output {
            let limit = record.outputLimitBytes ?? Self.defaultOutputLimitBytes
            let bounded = Self.boundedTail(output, maximumBytes: limit)
            record.finalOutput = bounded
            if bounded != output {
                let suffix = "final output exceeded (limit) bytes and was tail-truncated"
                record.detail = [record.detail, suffix]
                    .compactMap { $0 }
                    .joined(separator: "; ")
            }
        } else {
            record.finalOutput = nil
        }
        record.finishedAt = Self.nowMilliseconds()
        record.task = nil
        records[id] = record
        if let childID = subagents.first(where: { $0.value.activeJobID == id })?.key,
           var child = subagents[childID] {
            child.status = outcome.status
            child.activeJobID = nil
            child.lastJobID = id
            child.updatedAt = record.finishedAt ?? Self.nowMilliseconds()
            subagents[childID] = child
        }
        persistNow()
    }

    private func authorizedSubagent(
        id: String,
        requesterSession: String
    ) throws -> SubagentRecord {
        let normalizedID = id.lowercased()
        guard let child = subagents[normalizedID] else {
            throw HarnessJobError.unknownSubagent(normalizedID)
        }
        guard Self.isDescendant(child.id, of: requesterSession.lowercased(), in: subagents) else {
            throw HarnessJobError.foreignJob(normalizedID)
        }
        return child
    }

    private static func isDescendant(
        _ childID: String,
        of ancestorID: String,
        in records: [String: SubagentRecord]
    ) -> Bool {
        var cursor = records[childID]?.parentSession
        var visited = Set<String>()
        while let current = cursor, visited.insert(current).inserted {
            if current == ancestorID { return true }
            cursor = records[current]?.parentSession
        }
        return false
    }

    private func subagentSnapshot(_ record: SubagentRecord) -> HarnessSubagentSnapshot {
        HarnessSubagentSnapshot(
            id: record.id,
            parentSession: record.parentSession,
            label: record.label,
            model: record.model,
            providerBundleID: record.providerBundleID,
            contextMode: record.contextMode,
            delegationDepth: record.delegationDepth,
            maximumDepth: record.maximumDepth,
            persona: record.persona,
            toolFilter: record.toolFilter,
            reportDelivery: record.reportDelivery,
            hasChildren: subagents.values.contains { $0.parentSession == record.id },
            status: record.status,
            activeJobID: record.activeJobID,
            lastJobID: record.lastJobID,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt
        )
    }

    private func authorizedRecord(
        id: String,
        ownerSession: String?
    ) throws -> Record {
        guard let record = records[id] else { throw HarnessJobError.unknownJob(id) }
        guard Self.canAccess(record, ownerSession: ownerSession) else {
            throw HarnessJobError.foreignJob(id)
        }
        return record
    }

    private static func canAccess(_ record: Record, ownerSession: String?) -> Bool {
        record.ownerSession == nil || record.ownerSession == ownerSession
    }

    private static func snapshot(_ record: Record) -> HarnessJobSnapshot {
        HarnessJobSnapshot(
            id: record.id,
            kind: record.kind,
            label: record.label,
            outputLimitBytes: record.outputLimitBytes,
            ownerSession: record.ownerSession,
            status: record.status,
            detail: record.detail,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            reported: record.reported
        )
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    private static func boundedTail(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let marker = "[earlier output truncated]\n"
        let budget = max(0, maximumBytes - marker.utf8.count)
        var result = ""
        var used = 0
        for scalar in text.unicodeScalars.reversed() {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard used + bytes <= budget else { break }
            result.unicodeScalars.insert(scalar, at: result.unicodeScalars.startIndex)
            used += bytes
        }
        return marker + result
    }

    private static func finalOutputSuffix(
        _ finalOutput: String?,
        alreadyIncludedIn pendingOutput: String
    ) -> String {
        guard let finalOutput,
              !finalOutput.isEmpty,
              !pendingOutput.contains(finalOutput) else { return "" }
        let separator = pendingOutput.hasSuffix("\n") ? "" : "\n"
        return separator + finalOutput
    }

    private func schedulePersist() {
        guard persistenceURL != nil else { return }
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.persistNow()
        }
    }

    private func persistNow() {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard let persistenceURL else { return }
        let state = Self.persistedState(
            counters: counters,
            registrationOrder: registrationOrder,
            records: records,
            subagents: subagents,
            subagentRegistrationOrder: subagentRegistrationOrder
        )
        try? Self.writePersistedState(state, to: persistenceURL)
    }

    private static func persistedState(
        counters: [String: Int],
        registrationOrder: [String],
        records: [String: Record],
        subagents: [String: SubagentRecord],
        subagentRegistrationOrder: [String]
    ) -> PersistedState {
        PersistedState(
            version: 1,
            counters: counters,
            registrationOrder: registrationOrder,
            records: registrationOrder.compactMap { id in
                guard let record = records[id] else { return nil }
                return PersistedRecord(
                    id: record.id,
                    kind: record.kind,
                    label: record.label,
                    outputLimitBytes: record.outputLimitBytes,
                    ownerSession: record.ownerSession,
                    status: record.status,
                    detail: record.detail,
                    finalOutput: record.finalOutput,
                    startedAt: record.startedAt,
                    finishedAt: record.finishedAt,
                    reported: record.reported,
                    completionClaimedAt: record.completionClaimedAt,
                    pendingOutput: record.pendingOutput
                )
            },
            subagents: subagents.values.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
            }.map {
                PersistedSubagentRecord(
                    id: $0.id,
                    parentSession: $0.parentSession,
                    label: $0.label,
                    model: $0.model,
                    providerBundleID: $0.providerBundleID,
                    contextMode: $0.contextMode,
                    delegationDepth: $0.delegationDepth,
                    maximumDepth: $0.maximumDepth,
                    persona: $0.persona,
                    toolFilter: $0.toolFilter,
                    reportDelivery: $0.reportDelivery,
                    status: $0.status,
                    activeJobID: $0.activeJobID,
                    lastJobID: $0.lastJobID,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            },
            subagentRegistrationOrder: subagentRegistrationOrder
        )
    }

    private static func loadPersistedState(from url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 1 else { return nil }
        return state
    }

    private static func legacyDelegationDepth(
        of id: String,
        records: [String: PersistedSubagentRecord]
    ) -> Int {
        var depth = 0
        var cursor: String? = id
        var visited = Set<String>()
        while let current = cursor,
              let record = records[current],
              visited.insert(current).inserted {
            depth += 1
            cursor = records[record.parentSession] == nil ? nil : record.parentSession
        }
        return max(1, depth)
    }

    private static func writePersistedState(_ state: PersistedState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
#endif
    }
}

enum HarnessJobsCordisPlugin {
    static func definition(
        registry: any HarnessJobManaging,
        id: CordisPluginID = "core.local-jobs",
        version: String = "1"
    ) -> CordisPluginDefinition {
        CordisPluginDefinition(
            id: id,
            version: version,
            provides: [CordisAgentServiceKeys.jobs.name]
        ) { context in
            try await context.provide(CordisAgentServiceKeys.jobs, value: registry)
        }
    }
}
