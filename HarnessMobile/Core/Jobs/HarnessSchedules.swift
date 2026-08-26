import Foundation

extension Notification.Name {
    static let harnessScheduleStoreDidMutate = Notification.Name(
        "HarnessMobile.HarnessScheduleStore.didMutate"
    )
}

enum HarnessScheduleStatus: String, Codable, Sendable, Equatable {
    case pending
    case claimed
    case completed
    case cancelled
}

struct HarnessScheduleSnapshot: Codable, Sendable, Equatable {
    let id: String
    let ownerSession: String
    let label: String
    let prompt: String
    let runAt: Int64
    let createdAt: Int64
    let status: HarnessScheduleStatus
    let claimOwner: String?
    let claimedAt: Int64?
    let leaseUntil: Int64?
    let attempt: Int
    let lastError: String?

    init(
        id: String,
        ownerSession: String,
        label: String,
        prompt: String,
        runAt: Int64,
        createdAt: Int64,
        status: HarnessScheduleStatus,
        claimOwner: String? = nil,
        claimedAt: Int64? = nil,
        leaseUntil: Int64? = nil,
        attempt: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.ownerSession = ownerSession
        self.label = label
        self.prompt = prompt
        self.runAt = runAt
        self.createdAt = createdAt
        self.status = status
        self.claimOwner = claimOwner
        self.claimedAt = claimedAt
        self.leaseUntil = leaseUntil
        self.attempt = attempt
        self.lastError = lastError
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerSession, label, prompt, runAt, createdAt, status
        case claimOwner, claimedAt, leaseUntil, attempt, lastError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        ownerSession = try values.decode(String.self, forKey: .ownerSession)
        label = try values.decode(String.self, forKey: .label)
        prompt = try values.decode(String.self, forKey: .prompt)
        runAt = try values.decode(Int64.self, forKey: .runAt)
        createdAt = try values.decode(Int64.self, forKey: .createdAt)
        status = try values.decode(HarnessScheduleStatus.self, forKey: .status)
        claimOwner = try values.decodeIfPresent(String.self, forKey: .claimOwner)
        claimedAt = try values.decodeIfPresent(Int64.self, forKey: .claimedAt)
        leaseUntil = try values.decodeIfPresent(Int64.self, forKey: .leaseUntil)
        attempt = try values.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
    }
}

enum HarnessScheduleError: LocalizedError, Sendable, Equatable {
    case invalidPrompt
    case invalidLabel
    case invalidRunAt
    case unknownSchedule(String)
    case foreignSchedule(String)
    case invalidClaimOwner

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: "schedule prompt must be a non-empty string"
        case .invalidLabel: "schedule label must be a non-empty string"
        case .invalidRunAt: "schedule run_at must be a future epoch timestamp in milliseconds"
        case let .unknownSchedule(id): "unknown schedule \(id)"
        case let .foreignSchedule(id): "schedule \(id) belongs to another session"
        case .invalidClaimOwner: "schedule claim owner must be a non-empty string"
        }
    }
}

protocol HarnessScheduleManaging: Sendable {
    func create(ownerSession: String, label: String, prompt: String, runAt: Int64) async throws -> HarnessScheduleSnapshot
    func list(ownerSession: String) async -> [HarnessScheduleSnapshot]
    func delete(id: String, ownerSession: String) async throws -> HarnessScheduleSnapshot
    /// Atomically claims due schedules. The caller is responsible for starting
    /// the new local Agent turn and recording its trajectory.
    func claimDue(now: Int64?, limit: Int, owner: String) async -> [HarnessScheduleSnapshot]
    func acknowledge(id: String, owner: String) async throws
    func requeue(id: String, owner: String, reason: String?) async throws
    func reclaimExpired(now: Int64?) async -> [HarnessScheduleSnapshot]
    /// Earliest pending schedule across all sessions, used to set the next
    /// system wake-up without exposing private schedule records to the UI.
    func nextPendingRunAt() async -> Int64?
}

extension HarnessScheduleManaging {
    func claimDue(now: Int64?, limit: Int) async -> [HarnessScheduleSnapshot] {
        await claimDue(now: now, limit: limit, owner: "system")
    }
}

actor HarnessScheduleStore: HarnessScheduleManaging {
    private static let claimLeaseMilliseconds: Int64 = 2 * 60 * 1_000
    private struct State: Codable {
        var version: Int = 1
        var schedules: [HarnessScheduleSnapshot] = []
    }

    private let url: URL
    private var state: State

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        let loaded = Self.load(from: self.url)
        let now = Self.nowMilliseconds()
        var recovered = loaded
        recovered.schedules = loaded.schedules.map { schedule in
            guard schedule.status == .claimed,
                  schedule.leaseUntil == nil || schedule.leaseUntil! <= now else {
                return schedule
            }
            return HarnessScheduleSnapshot(
                id: schedule.id, ownerSession: schedule.ownerSession,
                label: schedule.label, prompt: schedule.prompt,
                runAt: schedule.runAt, createdAt: schedule.createdAt,
                status: .pending, attempt: schedule.attempt,
                lastError: "claim lease expired during launch"
            )
        }
        self.state = recovered
        if recovered.schedules != loaded.schedules {
            Self.persist(recovered, to: self.url)
        }
    }

    func create(ownerSession: String, label: String, prompt: String, runAt: Int64) throws -> HarnessScheduleSnapshot {
        let owner = ownerSession.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !normalizedPrompt.isEmpty, normalizedPrompt.utf8.count <= 64 * 1_024 else {
            throw HarnessScheduleError.invalidPrompt
        }
        guard !normalizedLabel.isEmpty, normalizedLabel.utf8.count <= 512 else {
            throw HarnessScheduleError.invalidLabel
        }
        guard runAt > Self.nowMilliseconds() else { throw HarnessScheduleError.invalidRunAt }
        let now = Self.nowMilliseconds()
        let snapshot = HarnessScheduleSnapshot(
            id: UUID().uuidString.lowercased(),
            ownerSession: owner,
            label: normalizedLabel,
            prompt: normalizedPrompt,
            runAt: runAt,
            createdAt: now,
                status: .pending,
                attempt: 0
        )
        state.schedules.append(snapshot)
        persist()
        return snapshot
    }

    func list(ownerSession: String) -> [HarnessScheduleSnapshot] {
        let owner = ownerSession.lowercased()
        return state.schedules
            .filter { $0.ownerSession == owner && $0.status == .pending }
            .sorted { $0.runAt == $1.runAt ? $0.createdAt < $1.createdAt : $0.runAt < $1.runAt }
    }

    func delete(id: String, ownerSession: String) throws -> HarnessScheduleSnapshot {
        let normalizedID = id.lowercased()
        guard let index = state.schedules.firstIndex(where: { $0.id == normalizedID }) else {
            throw HarnessScheduleError.unknownSchedule(normalizedID)
        }
        let current = state.schedules[index]
        guard current.ownerSession == ownerSession.lowercased() else {
            throw HarnessScheduleError.foreignSchedule(normalizedID)
        }
        guard current.status == .pending else { return current }
        let cancelled = HarnessScheduleSnapshot(
            id: current.id, ownerSession: current.ownerSession, label: current.label,
            prompt: current.prompt, runAt: current.runAt, createdAt: current.createdAt,
            status: .cancelled,
            claimOwner: nil,
            claimedAt: nil,
            leaseUntil: nil,
            attempt: current.attempt,
            lastError: current.lastError
        )
        state.schedules[index] = cancelled
        persist()
        return cancelled
    }

    func claimDue(now: Int64? = nil, limit: Int = 16, owner: String = "system") -> [HarnessScheduleSnapshot] {
        guard limit > 0 else { return [] }
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty else { return [] }
        let effectiveNow = now ?? Self.nowMilliseconds()
        _ = reclaimExpired(now: effectiveNow)
        var claimed: [HarnessScheduleSnapshot] = []
        for index in state.schedules.indices {
            guard claimed.count < limit else { break }
            let current = state.schedules[index]
            guard current.status == .pending, current.runAt <= effectiveNow else { continue }
            let value = HarnessScheduleSnapshot(
                id: current.id, ownerSession: current.ownerSession, label: current.label,
                prompt: current.prompt, runAt: current.runAt, createdAt: current.createdAt,
                status: .claimed,
                claimOwner: normalizedOwner,
                claimedAt: effectiveNow,
                leaseUntil: effectiveNow + Self.claimLeaseMilliseconds,
                attempt: current.attempt + 1,
                lastError: nil
            )
            state.schedules[index] = value
            claimed.append(value)
        }
        if !claimed.isEmpty { persist() }
        return claimed
    }

    func acknowledge(id: String, owner: String) throws {
        let normalizedID = id.lowercased()
        guard let index = state.schedules.firstIndex(where: { $0.id == normalizedID }) else {
            throw HarnessScheduleError.unknownSchedule(normalizedID)
        }
        let current = state.schedules[index]
        guard current.claimOwner == owner, current.status == .claimed else {
            throw HarnessScheduleError.foreignSchedule(normalizedID)
        }
        state.schedules[index] = HarnessScheduleSnapshot(
            id: current.id, ownerSession: current.ownerSession, label: current.label,
            prompt: current.prompt, runAt: current.runAt, createdAt: current.createdAt,
            status: .completed, attempt: current.attempt, lastError: current.lastError
        )
        persist()
    }

    func requeue(id: String, owner: String, reason: String? = nil) throws {
        let normalizedID = id.lowercased()
        guard let index = state.schedules.firstIndex(where: { $0.id == normalizedID }) else {
            throw HarnessScheduleError.unknownSchedule(normalizedID)
        }
        let current = state.schedules[index]
        guard current.claimOwner == owner, current.status == .claimed else {
            throw HarnessScheduleError.foreignSchedule(normalizedID)
        }
        state.schedules[index] = HarnessScheduleSnapshot(
            id: current.id, ownerSession: current.ownerSession, label: current.label,
            prompt: current.prompt, runAt: current.runAt, createdAt: current.createdAt,
            status: .pending, attempt: current.attempt,
            lastError: reason.map { String($0.prefix(512)) }
        )
        persist()
    }

    @discardableResult
    func reclaimExpired(now: Int64? = nil) -> [HarnessScheduleSnapshot] {
        let effectiveNow = now ?? Self.nowMilliseconds()
        var reclaimed: [HarnessScheduleSnapshot] = []
        for index in state.schedules.indices {
            let current = state.schedules[index]
            guard current.status == .claimed,
                  current.leaseUntil == nil || current.leaseUntil! <= effectiveNow else {
                continue
            }
            let value = HarnessScheduleSnapshot(
                id: current.id, ownerSession: current.ownerSession, label: current.label,
                prompt: current.prompt, runAt: current.runAt, createdAt: current.createdAt,
                status: .pending, attempt: current.attempt,
                lastError: "claim lease expired"
            )
            state.schedules[index] = value
            reclaimed.append(value)
        }
        if !reclaimed.isEmpty { persist() }
        return reclaimed
    }

    func nextPendingRunAt() -> Int64? {
        state.schedules
            .filter { $0.status == .pending }
            .map(\.runAt)
            .min()
    }

    private func persist() {
        Self.persist(state, to: url)
        NotificationCenter.default.post(name: .harnessScheduleStoreDidMutate, object: nil)
    }

    private static func persist(_ state: State, to url: URL) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.sorted.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // A scheduling operation remains usable in-memory if persistence is
            // temporarily unavailable; the next mutation retries the write.
        }
    }

    private static func load(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(State.self, from: data),
              value.version == 1 else { return State() }
        return value
    }

    private static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("HarnessMobile/schedules.json", isDirectory: false)
    }

    private static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
