import Foundation

extension Notification.Name {
    static let harnessScheduleStoreDidMutate = Notification.Name(
        "HarnessMobile.HarnessScheduleStore.didMutate"
    )
}

enum HarnessScheduleStatus: String, Codable, Sendable, Equatable {
    case pending
    case claimed
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
}

enum HarnessScheduleError: LocalizedError, Sendable, Equatable {
    case invalidPrompt
    case invalidLabel
    case invalidRunAt
    case unknownSchedule(String)
    case foreignSchedule(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: "schedule prompt must be a non-empty string"
        case .invalidLabel: "schedule label must be a non-empty string"
        case .invalidRunAt: "schedule run_at must be a future epoch timestamp in milliseconds"
        case let .unknownSchedule(id): "unknown schedule \(id)"
        case let .foreignSchedule(id): "schedule \(id) belongs to another session"
        }
    }
}

protocol HarnessScheduleManaging: Sendable {
    func create(ownerSession: String, label: String, prompt: String, runAt: Int64) async throws -> HarnessScheduleSnapshot
    func list(ownerSession: String) async -> [HarnessScheduleSnapshot]
    func delete(id: String, ownerSession: String) async throws -> HarnessScheduleSnapshot
    /// Atomically claims due schedules. The caller is responsible for starting
    /// the new local Agent turn and recording its trajectory.
    func claimDue(now: Int64?, limit: Int) async -> [HarnessScheduleSnapshot]
    /// Earliest pending schedule across all sessions, used to set the next
    /// system wake-up without exposing private schedule records to the UI.
    func nextPendingRunAt() async -> Int64?
}

actor HarnessScheduleStore: HarnessScheduleManaging {
    private struct State: Codable {
        var version: Int = 1
        var schedules: [HarnessScheduleSnapshot] = []
    }

    private let url: URL
    private var state: State

    init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        self.state = Self.load(from: self.url)
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
            status: .pending
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
            status: .cancelled
        )
        state.schedules[index] = cancelled
        persist()
        return cancelled
    }

    func claimDue(now: Int64? = nil, limit: Int = 16) -> [HarnessScheduleSnapshot] {
        guard limit > 0 else { return [] }
        let effectiveNow = now ?? Self.nowMilliseconds()
        var claimed: [HarnessScheduleSnapshot] = []
        for index in state.schedules.indices {
            guard claimed.count < limit else { break }
            let current = state.schedules[index]
            guard current.status == .pending, current.runAt <= effectiveNow else { continue }
            let value = HarnessScheduleSnapshot(
                id: current.id, ownerSession: current.ownerSession, label: current.label,
                prompt: current.prompt, runAt: current.runAt, createdAt: current.createdAt,
                status: .claimed
            )
            state.schedules[index] = value
            claimed.append(value)
        }
        if !claimed.isEmpty { persist() }
        return claimed
    }

    func nextPendingRunAt() -> Int64? {
        state.schedules
            .filter { $0.status == .pending }
            .map(\.runAt)
            .min()
    }

    private func persist() {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.sorted.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            // A scheduling operation remains usable in-memory if persistence is
            // temporarily unavailable; the next mutation retries the write.
        }
        NotificationCenter.default.post(name: .harnessScheduleStoreDidMutate, object: nil)
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
