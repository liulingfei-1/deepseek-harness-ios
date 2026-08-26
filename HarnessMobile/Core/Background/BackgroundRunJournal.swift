import Foundation

/// The small, durable record needed to explain what happened to a run across
/// force-quit or a cold launch. It intentionally contains no prompt, key,
/// tool arguments, tool output, or model output.
enum BackgroundRunJournalPhase: String, Codable, Sendable, Equatable {
    case preparing
    case running
    case cancelling
    case succeeded
    case cancelled
    case failed
    case interrupted
    case disposed

    var isTerminal: Bool {
        switch self {
        case .succeeded, .cancelled, .failed, .interrupted, .disposed:
            true
        case .preparing, .running, .cancelling:
            false
        }
    }
}

struct BackgroundRunJournalEntry: Codable, Sendable, Equatable, Identifiable {
    let identity: RunIdentity
    var phase: BackgroundRunJournalPhase
    var lastDurableSequence: UInt64
    var continuedProcessingRequestIdentifier: String?
    var finiteBackgroundLeaseActive: Bool
    var continuedProcessingActive: Bool
    var audioKeepAliveActive: Bool
    var locationKeepAliveActive: Bool
    var liveActivityActive: Bool
    var updatedAt: Date

    var id: RunIdentity { identity }

    init(
        identity: RunIdentity,
        phase: BackgroundRunJournalPhase,
        lastDurableSequence: UInt64 = 0,
        continuedProcessingRequestIdentifier: String? = nil,
        finiteBackgroundLeaseActive: Bool = false,
        continuedProcessingActive: Bool = false,
        audioKeepAliveActive: Bool = false,
        locationKeepAliveActive: Bool = false,
        liveActivityActive: Bool = false,
        updatedAt: Date = .now
    ) {
        self.identity = identity
        self.phase = phase
        self.lastDurableSequence = lastDurableSequence
        self.continuedProcessingRequestIdentifier = continuedProcessingRequestIdentifier
        self.finiteBackgroundLeaseActive = finiteBackgroundLeaseActive
        self.continuedProcessingActive = continuedProcessingActive
        self.audioKeepAliveActive = audioKeepAliveActive
        self.locationKeepAliveActive = locationKeepAliveActive
        self.liveActivityActive = liveActivityActive
        self.updatedAt = updatedAt
    }

    func terminalized(
        phase: BackgroundRunJournalPhase,
        now: Date = .now
    ) -> Self {
        var copy = self
        copy.phase = phase
        copy.continuedProcessingRequestIdentifier = nil
        copy.finiteBackgroundLeaseActive = false
        copy.continuedProcessingActive = false
        copy.audioKeepAliveActive = false
        copy.locationKeepAliveActive = false
        copy.liveActivityActive = false
        copy.updatedAt = now
        return copy
    }
}

struct BackgroundRunJournalAudit: Sendable, Equatable {
    let interruptedRunIDs: [UUID]
    let clearedRequestIdentifiers: [String]

    var didCleanOrphans: Bool {
        !interruptedRunIDs.isEmpty || !clearedRequestIdentifiers.isEmpty
    }
}

enum BackgroundRunJournalError: Error, Sendable, Equatable {
    case invalidTerminalPhase(BackgroundRunJournalPhase)
    case unreadableJournal
}

/// Actor-isolated, application-support journal. A failed write is surfaced to
/// the caller; it is never silently converted into a successful recovery.
actor BackgroundRunJournal {
    private struct Envelope: Codable, Sendable, Equatable {
        let version: Int
        var entries: [BackgroundRunJournalEntry]
    }

    let fileURL: URL
    private var entries: [RunIdentity: BackgroundRunJournalEntry] = [:]
    private var loaded = false

    init(fileURL: URL = BackgroundRunJournal.applicationURL()) {
        self.fileURL = fileURL
    }

    static func applicationURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Background", isDirectory: true)
            .appendingPathComponent("run-journal-v1.json", isDirectory: false)
    }

    func load() throws -> [BackgroundRunJournalEntry] {
        try ensureLoaded()
        return entries.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    func upsert(_ entry: BackgroundRunJournalEntry) throws {
        try ensureLoaded()
        entries[entry.identity] = entry
        try persist()
    }

    func markTerminal(
        identity: RunIdentity,
        phase: BackgroundRunJournalPhase,
        lastDurableSequence: UInt64? = nil,
        now: Date = .now
    ) throws {
        guard phase.isTerminal else {
            throw BackgroundRunJournalError.invalidTerminalPhase(phase)
        }
        try ensureLoaded()
        if let existing = entries[identity] {
            var terminal = existing.terminalized(phase: phase, now: now)
            if let lastDurableSequence {
                terminal.lastDurableSequence = lastDurableSequence
            }
            entries[identity] = terminal
        } else {
            entries[identity] = BackgroundRunJournalEntry(
                identity: identity,
                phase: phase,
                updatedAt: now
            )
        }
        try persist()
    }

    /// Cold launch and foreground audits are deliberately identical and
    /// idempotent. They close only non-terminal descriptors; they never start
    /// an Agent loop or replay a tool operation.
    func auditOnLaunch(now: Date = .now) throws -> BackgroundRunJournalAudit {
        try audit(now: now)
    }

    func auditOnForeground(now: Date = .now) throws -> BackgroundRunJournalAudit {
        try audit(now: now)
    }

    private func audit(now: Date) throws -> BackgroundRunJournalAudit {
        try ensureLoaded()
        var interrupted: [UUID] = []
        var cleared: [String] = []
        for (identity, entry) in entries {
            guard !entry.phase.isTerminal else { continue }
            if let request = entry.continuedProcessingRequestIdentifier {
                cleared.append(request)
            }
            entries[identity] = entry.terminalized(phase: .interrupted, now: now)
            interrupted.append(identity.runID)
        }
        guard !interrupted.isEmpty else {
            return BackgroundRunJournalAudit(
                interruptedRunIDs: [],
                clearedRequestIdentifiers: []
            )
        }
        try persist()
        return BackgroundRunJournalAudit(
            interruptedRunIDs: interrupted.sorted { $0.uuidString < $1.uuidString },
            clearedRequestIdentifiers: cleared.sorted()
        )
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version == 1 else {
            throw BackgroundRunJournalError.unreadableJournal
        }
        entries = Dictionary(uniqueKeysWithValues: envelope.entries.map { ($0.identity, $0) })
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            Envelope(version: 1, entries: entries.values.sorted { $0.identity.runID.uuidString < $1.identity.runID.uuidString })
        )
#if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: fileURL, options: .atomic)
#endif
    }
}
