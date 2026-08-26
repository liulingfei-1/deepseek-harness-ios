import Foundation

enum ConversationItemStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case pending
    case active
    case paused
    case completed
    case blocked
}

struct ConversationGoal: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var status: ConversationItemStatus

    init(
        id: UUID = UUID(),
        title: String,
        status: ConversationItemStatus = .pending
    ) {
        self.id = id
        self.title = title
        self.status = status
    }
}

struct ConversationPlanStep: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var status: ConversationItemStatus

    init(
        id: UUID = UUID(),
        title: String,
        status: ConversationItemStatus = .pending
    ) {
        self.id = id
        self.title = title
        self.status = status
    }
}

struct ConversationTodoItem: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var status: ConversationItemStatus

    init(
        id: UUID = UUID(),
        title: String,
        status: ConversationItemStatus = .pending
    ) {
        self.id = id
        self.title = title
        self.status = status
    }
}

struct ConversationWorkState: Codable, Sendable, Equatable {
    var goal: ConversationGoal?
    var plan: [ConversationPlanStep]
    var todos: [ConversationTodoItem]

    init(
        goal: ConversationGoal? = nil,
        plan: [ConversationPlanStep] = [],
        todos: [ConversationTodoItem] = []
    ) {
        self.goal = goal
        self.plan = plan
        self.todos = todos
    }
}

struct ConversationCheckpoint: Sendable, Equatable {
    var messages: [AgentMessage]
    var workState: ConversationWorkState
    var controlState: ConversationControlState

    init(
        messages: [AgentMessage],
        workState: ConversationWorkState = ConversationWorkState(),
        controlState: ConversationControlState = ConversationControlState()
    ) {
        self.messages = messages
        self.workState = workState
        self.controlState = controlState
    }
}

enum ConversationSessionTitleSource: Codable, Sendable, Equatable {
    case fallback
    case provider(id: String, provider: String, model: String)
    case user
}

struct ConversationSession: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var messages: [AgentMessage]
    var workState: ConversationWorkState
    var controlState: ConversationControlState
    let createdAt: Date
    var updatedAt: Date
    var revision: Int
    var titleSource: ConversationSessionTitleSource?
    var archivedAt: Date?
    let forkedFromSessionID: UUID?

    init(
        id: UUID,
        title: String,
        messages: [AgentMessage],
        workState: ConversationWorkState,
        controlState: ConversationControlState,
        createdAt: Date,
        updatedAt: Date,
        revision: Int,
        titleSource: ConversationSessionTitleSource? = nil,
        archivedAt: Date? = nil,
        forkedFromSessionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.workState = workState
        self.controlState = controlState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.titleSource = titleSource
        self.archivedAt = archivedAt
        self.forkedFromSessionID = forkedFromSessionID
    }

    var isArchived: Bool { archivedAt != nil }

    var isResumable: Bool {
        guard let last = messages.last else { return false }
        return last.role == .user || last.role == .tool
    }

    var summary: ConversationSessionSummary {
        ConversationSessionSummary(
            id: id,
            title: title,
            messageCount: messages.lazy.filter(\.isChatVisible).count,
            createdAt: createdAt,
            updatedAt: updatedAt,
            revision: revision,
            archivedAt: archivedAt,
            forkedFromSessionID: forkedFromSessionID,
            queuedInputCount: controlState.queuedInputs.count,
            isResumable: isResumable
        )
    }
}

struct ConversationSessionSummary: Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date
    let revision: Int
    let archivedAt: Date?
    let forkedFromSessionID: UUID?
    let queuedInputCount: Int
    let isResumable: Bool

    var isArchived: Bool { archivedAt != nil }
}

struct ConversationSessionSearchResult: Sendable, Equatable, Identifiable {
    let session: ConversationSessionSummary
    let matchSnippet: String?
    let matchedMessageID: UUID?
    let titleMatched: Bool

    var id: UUID { session.id }
}

struct SessionStoreState: Sendable, Equatable {
    let activeSessionID: UUID?
    let sessions: [ConversationSession]

    var activeSession: ConversationSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }
}

actor SessionStore {
    private struct VersionProbe: Decodable {
        let version: Int
    }

    private struct LegacySnapshot: Codable {
        var version: Int
        var messages: [AgentMessage]
        var updatedAt: Date
    }

    private struct Version2Session: Codable {
        let id: UUID
        var title: String
        var messages: [AgentMessage]
        var workState: ConversationWorkState
        let createdAt: Date
        var updatedAt: Date
        var revision: Int

        var currentSession: ConversationSession {
            ConversationSession(
                id: id,
                title: title,
                messages: messages,
                workState: workState,
                controlState: ConversationControlState(),
                createdAt: createdAt,
                updatedAt: updatedAt,
                revision: revision
            )
        }
    }

    private struct Version2Snapshot: Codable {
        var version: Int
        var activeSessionID: UUID?
        var sessions: [Version2Session]
        var updatedAt: Date
    }

    private struct Version3Session: Codable {
        let id: UUID
        var title: String
        var messages: [AgentMessage]
        var workState: ConversationWorkState
        var controlState: ConversationControlState
        let createdAt: Date
        var updatedAt: Date
        var revision: Int

        var currentSession: ConversationSession {
            ConversationSession(
                id: id,
                title: title,
                messages: messages,
                workState: workState,
                controlState: controlState,
                createdAt: createdAt,
                updatedAt: updatedAt,
                revision: revision
            )
        }
    }

    private struct Version3Snapshot: Codable {
        var version: Int
        var activeSessionID: UUID?
        var sessions: [Version3Session]
        var updatedAt: Date
    }

    private struct StoreSnapshot: Codable {
        var version: Int
        var activeSessionID: UUID?
        var sessions: [ConversationSession]
        var updatedAt: Date

        static func empty(now: Date = .now) -> StoreSnapshot {
            StoreSnapshot(
                version: SessionStore.currentVersion,
                activeSessionID: nil,
                sessions: [],
                updatedAt: now
            )
        }
    }

    private static let currentVersion = 4

    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil) {
        let directory: URL
        if let root {
            directory = root
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        }
        self.directory = directory
        // Keep the legacy filename so an existing installation migrates in place.
        fileURL = directory.appendingPathComponent("current-session.json")

        let encoder = JSONEncoder()
        // Persist Date's native reference interval so its Double bit pattern
        // survives a JSON round trip. The decoder still accepts the ISO-8601
        // format written by snapshot versions 1 and 2.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSinceReferenceDate)
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self), seconds.isFinite {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }

            let value = try container.decode(String.self)
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds
            ]
            if let date = fractionalFormatter.date(from: value)
                ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported persisted date: \(value)"
            )
        }
        self.decoder = decoder
    }

    // MARK: - Backward-compatible active-session API

    func load() throws -> [AgentMessage] {
        try loadState().activeSession?.messages ?? []
    }

    func save(_ messages: [AgentMessage]) throws {
        var snapshot = try readSnapshot()
        let workState = snapshot.activeSessionID
            .flatMap { activeID in snapshot.sessions.first { $0.id == activeID }?.workState }
            ?? ConversationWorkState()
        let controlState = snapshot.activeSessionID
            .flatMap { activeID in snapshot.sessions.first { $0.id == activeID }?.controlState }
            ?? ConversationControlState()
        let checkpoint = ConversationCheckpoint(
            messages: messages,
            workState: workState,
            controlState: controlState
        )
        _ = try checkpointActiveSession(checkpoint, in: &snapshot)
        try writeSnapshot(snapshot)
    }

    /// Removes every conversation. This preserves the original single-session
    /// reset behavior; integrations that only want to clear one conversation
    /// should call `clearActiveSession()` instead.
    func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Multi-session API

    func loadState() throws -> SessionStoreState {
        let snapshot = try readSnapshot()
        return SessionStoreState(
            activeSessionID: snapshot.activeSessionID,
            sessions: snapshot.sessions
        )
    }

    func listSessions(includeArchived: Bool = true) throws -> [ConversationSessionSummary] {
        try readSnapshot().sessions
            .filter { includeArchived || !$0.isArchived }
            .map(\.summary)
    }

    func searchSessions(
        query: String,
        includeArchived: Bool = true
    ) throws -> [ConversationSessionSearchResult] {
        let normalizedQuery = Self.compactWhitespace(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return try readSnapshot().sessions
            .filter { includeArchived || !$0.isArchived }
            .compactMap { session in
                let titleMatched = Self.contains(
                    session.title,
                    query: normalizedQuery
                )
                let messageMatch = session.messages.reversed().lazy
                    .filter(\.isChatVisible)
                    .compactMap { Self.messageSearchMatch($0, query: normalizedQuery) }
                    .first
                guard titleMatched || messageMatch != nil else { return nil }
                return ConversationSessionSearchResult(
                    session: session.summary,
                    matchSnippet: messageMatch?.snippet,
                    matchedMessageID: messageMatch?.messageID,
                    titleMatched: titleMatched
                )
            }
            .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    func activeSession() throws -> ConversationSession? {
        try loadState().activeSession
    }

    func session(id: UUID) throws -> ConversationSession {
        let snapshot = try readSnapshot()
        guard let session = snapshot.sessions.first(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        return session
    }

    @discardableResult
    func createSession(
        id: UUID = UUID(),
        title: String = "新会话",
        titleSource: ConversationSessionTitleSource? = nil,
        workState: ConversationWorkState = ConversationWorkState(),
        controlState: ConversationControlState = ConversationControlState(),
        makeActive: Bool = true
    ) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        let now = Date.now
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = normalizedTitle.isEmpty ? "新会话" : normalizedTitle
        let session = ConversationSession(
            id: id,
            title: resolvedTitle,
            messages: [],
            workState: workState,
            controlState: controlState,
            createdAt: now,
            updatedAt: now,
            revision: 0,
            titleSource: titleSource ?? (resolvedTitle == "新会话" ? .fallback : .user)
        )
        snapshot.sessions.append(session)
        if makeActive || snapshot.activeSessionID == nil {
            snapshot.activeSessionID = session.id
        }
        snapshot.updatedAt = now
        try writeSnapshot(snapshot)
        return session
    }

    @discardableResult
    func switchActiveSession(to id: UUID) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        guard let session = snapshot.sessions.first(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        guard !session.isArchived else {
            throw SessionStoreError.sessionArchived(id)
        }
        snapshot.activeSessionID = id
        snapshot.updatedAt = .now
        try writeSnapshot(snapshot)
        return session
    }

    @discardableResult
    func renameSession(
        id: UUID,
        title: String,
        source: ConversationSessionTitleSource = .user
    ) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw SessionStoreError.emptyTitle
        }
        let now = Date.now
        snapshot.sessions[index].title = String(normalizedTitle.prefix(80))
        snapshot.sessions[index].titleSource = source
        snapshot.sessions[index].updatedAt = now
        snapshot.sessions[index].revision += 1
        snapshot.updatedAt = now
        try writeSnapshot(snapshot)
        return snapshot.sessions[index]
    }

    @discardableResult
    func forkSession(
        id: UUID,
        title: String? = nil,
        makeActive: Bool = true
    ) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        guard let source = snapshot.sessions.first(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }

        let now = Date.now
        let requestedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forkTitle = requestedTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            ?? Self.forkTitle(for: source.title)
        let fork = ConversationSession(
            id: UUID(),
            title: forkTitle,
            messages: Self.forkMessages(source.messages),
            workState: Self.forkWorkState(source.workState),
            controlState: Self.forkControlState(source.controlState),
            createdAt: now,
            updatedAt: now,
            revision: 0,
            forkedFromSessionID: source.id
        )
        snapshot.sessions.append(fork)
        if makeActive || snapshot.activeSessionID == nil {
            snapshot.activeSessionID = fork.id
        }
        snapshot.updatedAt = now
        try writeSnapshot(snapshot)
        return fork
    }

    @discardableResult
    func archiveSession(id: UUID) throws -> UUID? {
        var snapshot = try readSnapshot()
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        guard !snapshot.sessions[index].isArchived else {
            return snapshot.activeSessionID
        }

        let now = Date.now
        snapshot.sessions[index].archivedAt = now
        snapshot.sessions[index].revision += 1
        if snapshot.activeSessionID == id {
            snapshot.activeSessionID = snapshot.sessions
                .filter { !$0.isArchived }
                .max { $0.updatedAt < $1.updatedAt }?
                .id
        }
        snapshot.updatedAt = now
        try writeSnapshot(snapshot)
        return snapshot.activeSessionID
    }

    @discardableResult
    func restoreSession(id: UUID) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        guard snapshot.sessions[index].isArchived else {
            return snapshot.sessions[index]
        }

        snapshot.sessions[index].archivedAt = nil
        snapshot.sessions[index].revision += 1
        if snapshot.activeSessionID == nil {
            snapshot.activeSessionID = id
        }
        snapshot.updatedAt = .now
        try writeSnapshot(snapshot)
        return snapshot.sessions[index]
    }

    @discardableResult
    func deleteSession(id: UUID) throws -> UUID? {
        var snapshot = try readSnapshot()
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        snapshot.sessions.remove(at: index)
        if snapshot.activeSessionID == id {
            snapshot.activeSessionID = snapshot.sessions
                .filter { !$0.isArchived }
                .max { $0.updatedAt < $1.updatedAt }?
                .id
        }
        snapshot.updatedAt = .now
        try writeSnapshot(snapshot)
        return snapshot.activeSessionID
    }

    @discardableResult
    func checkpointActiveSession(
        _ checkpoint: ConversationCheckpoint
    ) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        let session = try checkpointActiveSession(checkpoint, in: &snapshot)
        try writeSnapshot(snapshot)
        return session
    }

    @discardableResult
    func checkpointSession(
        id: UUID,
        checkpoint: ConversationCheckpoint
    ) throws -> ConversationSession {
        var snapshot = try readSnapshot()
        let session = try apply(checkpoint, to: id, in: &snapshot)
        try writeSnapshot(snapshot)
        return session
    }

    @discardableResult
    func clearActiveSession() throws -> ConversationSession? {
        var snapshot = try readSnapshot()
        guard let activeSessionID = snapshot.activeSessionID else {
            return nil
        }
        let current = snapshot.sessions.first { $0.id == activeSessionID }
        var controlState = current?.controlState ?? ConversationControlState()
        controlState.unlockAgentPresetForBlankConversation()
        let checkpoint = ConversationCheckpoint(
            messages: [],
            workState: current?.workState ?? ConversationWorkState(),
            controlState: controlState
        )
        let session = try apply(checkpoint, to: activeSessionID, in: &snapshot)
        try writeSnapshot(snapshot)
        return session
    }

    // MARK: - Checkpoint transaction

    private func checkpointActiveSession(
        _ checkpoint: ConversationCheckpoint,
        in snapshot: inout StoreSnapshot
    ) throws -> ConversationSession {
        if let activeSessionID = snapshot.activeSessionID {
            return try apply(checkpoint, to: activeSessionID, in: &snapshot)
        }

        let now = Date.now
        var controlState = checkpoint.controlState
        if !checkpoint.messages.isEmpty {
            controlState.lockAgentPreset()
        }
        let session = ConversationSession(
            id: UUID(),
            title: "当前会话",
            messages: ConversationCompactor.repairIncompleteToolTurn(checkpoint.messages),
            workState: checkpoint.workState,
            controlState: controlState,
            createdAt: now,
            updatedAt: now,
            revision: 1
        )
        snapshot.sessions.append(session)
        snapshot.activeSessionID = session.id
        snapshot.updatedAt = now
        return session
    }

    private func apply(
        _ checkpoint: ConversationCheckpoint,
        to id: UUID,
        in snapshot: inout StoreSnapshot
    ) throws -> ConversationSession {
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        let now = Date.now
        var controlState = checkpoint.controlState
        if !checkpoint.messages.isEmpty {
            controlState.lockAgentPreset()
        }
        snapshot.sessions[index].messages = ConversationCompactor.repairIncompleteToolTurn(
            checkpoint.messages
        )
        snapshot.sessions[index].workState = checkpoint.workState
        snapshot.sessions[index].controlState = controlState
        snapshot.sessions[index].updatedAt = now
        snapshot.sessions[index].revision += 1
        snapshot.updatedAt = now
        return snapshot.sessions[index]
    }

    // MARK: - Persistence and migration

    private func readSnapshot() throws -> StoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty()
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let version = try decoder.decode(VersionProbe.self, from: data).version
        switch version {
        case 1:
            let legacy = try decoder.decode(LegacySnapshot.self, from: data)
            let repaired = ConversationCompactor.repairIncompleteToolTurn(legacy.messages)
            let session = ConversationSession(
                id: UUID(),
                title: "迁移的会话",
                messages: repaired,
                workState: ConversationWorkState(),
                controlState: ConversationControlState(),
                createdAt: legacy.updatedAt,
                updatedAt: legacy.updatedAt,
                revision: 1
            )
            let migrated = StoreSnapshot(
                version: Self.currentVersion,
                activeSessionID: session.id,
                sessions: [session],
                updatedAt: legacy.updatedAt
            )
            try writeSnapshot(migrated)
            return migrated
        case 2:
            let legacy = try decoder.decode(Version2Snapshot.self, from: data)
            let migrated = StoreSnapshot(
                version: Self.currentVersion,
                activeSessionID: legacy.activeSessionID,
                sessions: legacy.sessions.map(\.currentSession),
                updatedAt: legacy.updatedAt
            )
            var repaired = migrated
            try validateAndRepair(&repaired)
            try writeSnapshot(repaired)
            return repaired
        case 3:
            let legacy = try decoder.decode(Version3Snapshot.self, from: data)
            let migrated = StoreSnapshot(
                version: Self.currentVersion,
                activeSessionID: legacy.activeSessionID,
                sessions: legacy.sessions.map(\.currentSession),
                updatedAt: legacy.updatedAt
            )
            var repaired = migrated
            try validateAndRepair(&repaired)
            try writeSnapshot(repaired)
            return repaired
        case Self.currentVersion:
            var snapshot = try decoder.decode(StoreSnapshot.self, from: data)
            try validateAndRepair(&snapshot)
            return snapshot
        default:
            throw SessionStoreError.unsupportedVersion(version)
        }
    }

    private func validateAndRepair(_ snapshot: inout StoreSnapshot) throws {
        let ids = snapshot.sessions.map(\.id)
        guard Set(ids).count == ids.count else {
            throw SessionStoreError.corruptSnapshot
        }

        var changed = false
        let activeSession = snapshot.activeSessionID.flatMap { activeID in
            snapshot.sessions.first { $0.id == activeID }
        }
        if activeSession == nil || activeSession?.isArchived == true {
            let replacementID = snapshot.sessions
                .filter { !$0.isArchived }
                .max { $0.updatedAt < $1.updatedAt }?
                .id
            if snapshot.activeSessionID != replacementID {
                snapshot.activeSessionID = replacementID
                changed = true
            }
        }

        if snapshot.activeSessionID == nil,
           let replacementID = snapshot.sessions
               .filter({ !$0.isArchived })
               .max(by: { $0.updatedAt < $1.updatedAt })?
               .id {
            snapshot.activeSessionID = replacementID
            changed = true
        }

        for index in snapshot.sessions.indices {
            let repaired = ConversationCompactor.repairIncompleteToolTurn(
                snapshot.sessions[index].messages
            )
            if repaired != snapshot.sessions[index].messages {
                snapshot.sessions[index].messages = repaired
                snapshot.sessions[index].updatedAt = .now
                snapshot.sessions[index].revision += 1
                changed = true
            }
            if !snapshot.sessions[index].messages.isEmpty,
               !snapshot.sessions[index].controlState.isAgentPresetLocked {
                snapshot.sessions[index].controlState.lockAgentPreset()
                snapshot.sessions[index].updatedAt = .now
                snapshot.sessions[index].revision += 1
                changed = true
            }
        }

        if changed {
            snapshot.updatedAt = .now
            try writeSnapshot(snapshot)
        }
    }

    private func writeSnapshot(_ snapshot: StoreSnapshot) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: Self.protectedWritingOptions)
    }

    private static var protectedWritingOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        []
#endif
    }

    private static func forkTitle(for sourceTitle: String) -> String {
        let suffix = " 副本"
        let available = max(1, 80 - suffix.count)
        return String(sourceTitle.prefix(available)) + suffix
    }

    private static func forkMessages(_ messages: [AgentMessage]) -> [AgentMessage] {
        messages.map { message in
            AgentMessage(
                role: message.role,
                content: message.content,
                reasoning: message.reasoning,
                toolCalls: message.toolCalls,
                toolCallID: message.toolCallID,
                toolName: message.toolName,
                isToolError: message.isToolError,
                isIncomplete: message.isIncomplete,
                incompleteReason: message.incompleteReason,
                toolEvents: message.toolEvents.map(forkToolEvent),
                source: message.source,
                imageAttachments: message.imageAttachments,
                fileAttachments: message.fileAttachments,
                createdAt: message.createdAt
            )
        }
    }

    private static func forkToolEvent(_ event: AgentToolEvent) -> AgentToolEvent {
        AgentToolEvent(
            call: event.call,
            summary: event.summary,
            status: event.status,
            output: event.output.map {
                AgentToolOutputChunk(
                    channel: $0.channel,
                    text: $0.text,
                    createdAt: $0.createdAt
                )
            },
            result: event.result,
            errorMessage: event.errorMessage,
            createdAt: event.createdAt,
            startedAt: event.startedAt,
            finishedAt: event.finishedAt,
            children: event.children.map(forkToolEvent)
        )
    }

    private static func forkWorkState(_ state: ConversationWorkState) -> ConversationWorkState {
        ConversationWorkState(
            goal: state.goal.map {
                ConversationGoal(title: $0.title, status: $0.status)
            },
            plan: state.plan.map {
                ConversationPlanStep(title: $0.title, status: $0.status)
            },
            todos: state.todos.map {
                ConversationTodoItem(title: $0.title, status: $0.status)
            }
        )
    }

    private static func forkControlState(
        _ state: ConversationControlState
    ) -> ConversationControlState {
        ConversationControlState(
            interactionMode: state.interactionMode,
            permissionMode: state.permissionMode,
            agentPresetID: state.agentPresetID,
            isAgentPresetLocked: state.isAgentPresetLocked,
            modelConfiguration: state.modelConfiguration,
            contextLimitUTF8Bytes: state.contextLimitUTF8Bytes
        )
    }

    private static func messageSearchMatch(
        _ message: AgentMessage,
        query: String
    ) -> (messageID: UUID, snippet: String)? {
        for candidate in [message.content, message.reasoning].compactMap({ $0 }) {
            guard contains(candidate, query: query) else { continue }
            return (message.id, searchSnippet(candidate, query: query))
        }
        return nil
    }

    private static func contains(_ text: String, query: String) -> Bool {
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
        if text.range(of: query, options: options) != nil {
            return true
        }
        guard query.contains(" ") else { return false }
        return compactWhitespace(text).range(
            of: query,
            options: options
        ) != nil
    }

    private static func compactWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func searchSnippet(_ text: String, query: String) -> String {
        let compact = compactWhitespace(text)
        let maximumLength = 160
        guard compact.count > maximumLength else { return compact }

        let range = compact.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        )
        let matchOffset = range.map { compact.distance(from: compact.startIndex, to: $0.lowerBound) }
            ?? 0
        let startOffset = min(
            max(0, matchOffset - 48),
            max(0, compact.count - maximumLength)
        )
        let start = compact.index(compact.startIndex, offsetBy: startOffset)
        let end = compact.index(start, offsetBy: maximumLength, limitedBy: compact.endIndex)
            ?? compact.endIndex
        let prefix = start == compact.startIndex ? "" : "…"
        let suffix = end == compact.endIndex ? "" : "…"
        return prefix + String(compact[start..<end]) + suffix
    }
}

enum SessionStoreError: LocalizedError, Sendable {
    case unsupportedVersion(Int)
    case sessionNotFound(UUID)
    case sessionArchived(UUID)
    case corruptSnapshot
    case emptyTitle

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            return "不支持的会话版本：\(version)。"
        case let .sessionNotFound(id):
            return "找不到会话：\(id.uuidString)。"
        case let .sessionArchived(id):
            return "会话已归档，请先恢复：\(id.uuidString)。"
        case .corruptSnapshot:
            return "会话快照已损坏。"
        case .emptyTitle:
            return "会话标题不能为空。"
        }
    }
}

/// A durable admission queue for App Intents. It is deliberately separate from
/// conversation state: an Intent may be invoked before the SwiftUI scene and
/// AppModel have restored their session projection.
enum AppIntentInboxActionKind: String, Codable, Sendable, Equatable {
    case sendPrompt
    case openSession
    case retryLatestUserMessage
}

struct AppIntentInboxRequest: Codable, Sendable, Equatable, Identifiable {
    static let maximumPromptUTF8Bytes = 64 * 1_024

    let id: UUID
    let action: AppIntentInboxActionKind
    let sessionID: UUID?
    let prompt: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        action: AppIntentInboxActionKind,
        sessionID: UUID? = nil,
        prompt: String? = nil,
        createdAt: Date = .now
    ) throws {
        let normalizedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .sendPrompt:
            guard let normalizedPrompt,
                  !normalizedPrompt.isEmpty,
                  normalizedPrompt.utf8.count <= Self.maximumPromptUTF8Bytes else {
                throw AppIntentInboxError.invalidRequest
            }
        case .openSession, .retryLatestUserMessage:
            guard sessionID != nil, normalizedPrompt == nil else {
                throw AppIntentInboxError.invalidRequest
            }
        }
        self.id = id
        self.action = action
        self.sessionID = sessionID
        self.prompt = normalizedPrompt
        self.createdAt = createdAt
    }
}

actor AppIntentInboxStore {
    private struct Snapshot: Codable {
        var version: Int
        var pending: [AppIntentInboxRequest]
        var consumedRequestIDs: Set<UUID>
        var runningSessionIDs: Set<UUID>

        static let empty = Snapshot(
            version: AppIntentInboxStore.currentVersion,
            pending: [],
            consumedRequestIDs: [],
            runningSessionIDs: []
        )
    }

    static let currentVersion = 1
    static let maximumPendingRequests = 64

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = AppIntentInboxStore.applicationSupportURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("app-intent-inbox.json")
    }

    /// Returns false for an already-seen id, making a Shortcuts retry safe to
    /// repeat without injecting a second prompt.
    @discardableResult
    func enqueue(_ request: AppIntentInboxRequest) throws -> Bool {
        var snapshot = try load()
        guard !snapshot.consumedRequestIDs.contains(request.id),
              !snapshot.pending.contains(where: { $0.id == request.id }) else {
            return false
        }
        guard snapshot.pending.count < Self.maximumPendingRequests else {
            throw AppIntentInboxError.queueFull
        }
        snapshot.pending.append(request)
        try save(snapshot)
        return true
    }

    /// Consumption is persisted before an AppModel action is dispatched. This
    /// gives cold launches at-most-once admission; a user can explicitly retry
    /// a failed action with a new request id instead of duplicating a prompt.
    func consumeNext() throws -> AppIntentInboxRequest? {
        var snapshot = try load()
        guard !snapshot.pending.isEmpty else { return nil }
        let request = snapshot.pending.removeFirst()
        snapshot.consumedRequestIDs.insert(request.id)
        try save(snapshot)
        return request
    }

    func updateRunningSessions(_ sessionIDs: Set<UUID>) throws {
        var snapshot = try load()
        guard snapshot.runningSessionIDs != sessionIDs else { return }
        snapshot.runningSessionIDs = sessionIDs
        try save(snapshot)
    }

    func isSessionRunning(_ sessionID: UUID) throws -> Bool {
        try load().runningSessionIDs.contains(sessionID)
    }

    func pendingRequests() throws -> [AppIntentInboxRequest] {
        try load().pending
    }

    private func load() throws -> Snapshot {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.version == Self.currentVersion else {
                throw AppIntentInboxError.unsupportedVersion(snapshot.version)
            }
            return snapshot
        } catch let error as AppIntentInboxError {
            throw error
        } catch {
            throw AppIntentInboxError.unreadableStore
        }
    }

    private func save(_ snapshot: Snapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
#if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: fileURL.path)
#endif
    }
}

enum AppIntentInboxError: LocalizedError, Sendable, Equatable {
    case invalidRequest
    case queueFull
    case unsupportedVersion(Int)
    case unreadableStore

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "App Intent 请求无效。"
        case .queueFull:
            "App Intent 请求队列已满。"
        case let .unsupportedVersion(version):
            "不支持的 App Intent 收件箱版本：\(version)。"
        case .unreadableStore:
            "App Intent 收件箱无法读取。"
        }
    }
}
