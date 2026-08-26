import Foundation
import SQLite3

/// A disposable, device-local query projection derived from canonical
/// SessionEvent JSONL. It is deliberately not part of the write path.
struct SessionQuerySessionRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let createdAt: Int64
    let updatedAt: Int64
    let indexedThroughSequence: UInt64
    let eventCount: Int
    let searchableEventCount: Int
}

struct SessionQueryEventRecord: Codable, Sendable, Equatable, Identifiable {
    let sessionID: UUID
    let seq: UInt64
    let type: String
    let time: Int64
    let surface: String
    let text: String

    var id: String {
        "\(sessionID.uuidString.lowercased()):\(seq)"
    }
}

struct SessionQuerySessionHit: Codable, Sendable, Equatable, Identifiable {
    let session: SessionQuerySessionRecord
    let matchCount: Int
    let matchedEventSequence: UInt64
    let snippet: String

    var id: UUID { session.id }
}

struct SessionQueryEventHit: Codable, Sendable, Equatable, Identifiable {
    let event: SessionQueryEventRecord
    let snippet: String

    var id: String { event.id }
}

struct SessionQueryRebuildStats: Codable, Sendable, Equatable {
    let sessionsIndexed: Int
    let eventsIndexed: Int
    let sessionsRemoved: Int
}

enum SessionQueryReadModelError: Error, Sendable, Equatable, LocalizedError {
    case invalidQuery
    case invalidLimit
    case foreignDatabase
    case unsupportedSchema(Int)
    case unstableSource(UUID)
    case sqlite(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "会话搜索词不能为空或包含不可用字符。"
        case .invalidLimit:
            return "会话查询 limit 必须是 1 到 1000 的整数。"
        case .foreignDatabase:
            return "会话查询数据库属于其他功能，已拒绝覆盖。"
        case let .unsupportedSchema(version):
            return "会话查询数据库 schema \(version) 不受当前版本支持。"
        case let .unstableSource(sessionID):
            return "会话 \(sessionID.uuidString) 在建立查询索引时持续变化，已停止本次索引。"
        case let .sqlite(code, message):
            return "会话查询 SQLite 错误 \(code)：\(message)"
        }
    }
}

/// SQLite FTS5 read model for session listing and search.
///
/// The actor owns one connection and one derived database path. External
/// writers are unsupported; canonical JSONL remains the only source of truth.
actor SessionQueryReadModel {
    static let schemaVersion = 1
    private static let applicationID: Int32 = 0x4453484D
    private static let defaultLimit = 100
    private static let maximumLimit = 1_000

    private let databaseURL: URL
    // SQLite's C pointer is confined to this actor. `nonisolated(unsafe)` is
    // required only so Swift 6 can release it from the actor's nonisolated
    // destructor; all operational access remains actor-isolated.
    nonisolated(unsafe) private var database: OpaquePointer?
    private var isClosed = false

    init(root: URL? = nil) {
        if let root {
            databaseURL = root
        } else {
            databaseURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("SessionQuery", isDirectory: true)
            .appendingPathComponent("session-query.sqlite")
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    /// Incrementally refresh one session. Only the suffix after the durable
    /// watermark is inserted when the existing projection is structurally
    /// complete; a rewind or mismatch forces a session-local rebuild.
    func refresh(
        sessionID: UUID,
        persistence: any SessionPersistence
    ) async throws {
        try ensureOpen()
        let observation = try await stableObservation(
            sessionID: sessionID,
            persistence: persistence
        )
        try transact {
            if observation.events.isEmpty {
                try deleteSessionRows(sessionID: sessionID)
                return
            }
            let existing = try existingSessionMetadata(sessionID: sessionID)
            let shouldRebuild: Bool
            if let existing {
                let storedEventRows = try eventRowCount(sessionID: sessionID)
                shouldRebuild = existing.revision > observation.revision.nextSequence
                    || existing.eventCount > observation.events.count
                    || existing.eventCount != storedEventRows
                    || existing.eventCount > Int(existing.revision)
                    || (existing.revision == observation.revision.nextSequence
                        && existing.eventCount != observation.events.count)
            } else {
                shouldRebuild = true
            }
            let eventsToInsert: ArraySlice<IndexedEvent>
            if shouldRebuild {
                try deleteSessionRows(sessionID: sessionID)
                eventsToInsert = observation.indexedEvents[...]
            } else {
                let watermark = existing?.revision ?? 0
                eventsToInsert = observation.indexedEvents.dropFirst(Int(watermark))
            }
            for event in eventsToInsert {
                try insert(event: event, sessionID: sessionID)
            }
            try updateSurface(sessionID: sessionID, events: observation.indexedEvents)
            try upsertSession(
                sessionID: sessionID,
                title: observation.title,
                createdAt: observation.createdAt,
                updatedAt: observation.updatedAt,
                revision: observation.revision.nextSequence,
                eventCount: observation.events.count,
                searchableEventCount: observation.indexedEvents.reduce(into: 0) {
                    if !$1.text.isEmpty { $0 += 1 }
                }
            )
        }
    }

    /// Rebuilds the complete disposable projection from currently listed
    /// canonical streams and removes rows for deleted streams.
    func rebuild(
        persistence: any SessionPersistence
    ) async throws -> SessionQueryRebuildStats {
        try ensureOpen()
        let sessionIDs = try await persistence.listSessionIDs()
        var indexedSessions = 0
        var indexedEvents = 0
        for sessionID in sessionIDs {
            try await refresh(sessionID: sessionID, persistence: persistence)
            indexedSessions += 1
            indexedEvents += (try sessionRecord(sessionID: sessionID)?.eventCount ?? 0)
        }
        let liveIDs = Set(sessionIDs.map { $0.uuidString.lowercased() })
        let storedIDs = try allSessionIDs()
        let staleIDs = storedIDs.filter { !liveIDs.contains($0) }
        if !staleIDs.isEmpty {
            try transact {
                for id in staleIDs {
                    try deleteSessionRows(sessionIDString: id)
                }
            }
        }
        return SessionQueryRebuildStats(
            sessionsIndexed: indexedSessions,
            eventsIndexed: indexedEvents,
            sessionsRemoved: staleIDs.count
        )
    }

    func remove(sessionID: UUID) throws {
        try ensureOpen()
        try transact {
            try deleteSessionRows(sessionID: sessionID)
        }
    }

    func listSessions(limit: Int = SessionQueryReadModel.defaultLimit) throws -> [SessionQuerySessionRecord] {
        try ensureOpen()
        let boundedLimit = try validatedLimit(limit)
        let statement = try prepare("""
            SELECT session_id, title, created_at, updated_at, revision,
                   event_count, searchable_event_count
            FROM query_sessions
            ORDER BY updated_at DESC, session_id ASC
            LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        bindInt(statement, index: 1, value: boundedLimit)
        var result: [SessionQuerySessionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(try decodeSession(statement))
        }
        return result
    }

    func searchSessions(
        query: String,
        limit: Int = SessionQueryReadModel.defaultLimit
    ) throws -> [SessionQuerySessionHit] {
        try ensureOpen()
        let normalized = try normalizedQuery(query)
        let boundedLimit = try validatedLimit(limit)
        let statement = try prepare("""
            SELECT e.session_id, COUNT(*) AS match_count,
                   MAX(e.seq) AS matched_seq
            FROM query_events_fts f
            JOIN query_events e
              ON e.session_id = f.session_id AND e.seq = f.seq
            WHERE query_events_fts MATCH ?
            GROUP BY e.session_id
            ORDER BY matched_seq DESC, e.session_id ASC
            LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: ftsPhrase(normalized))
        bindInt(statement, index: 2, value: boundedLimit)
        var result: [SessionQuerySessionHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = try uuidFromColumn(statement, index: 0)
            let count = Int(sqlite3_column_int(statement, 1))
            let sequence = UInt64(sqlite3_column_int64(statement, 2))
            guard let session = try sessionRecord(sessionID: sessionID),
                  let event = try eventRow(sessionID: sessionID, seq: sequence) else {
                continue
            }
            result.append(
                SessionQuerySessionHit(
                    session: session,
                    matchCount: count,
                    matchedEventSequence: sequence,
                    snippet: makeSnippet(event.text, query: normalized)
                )
            )
        }
        return result
    }

    func searchEvents(
        sessionID: UUID,
        query: String,
        limit: Int = SessionQueryReadModel.defaultLimit
    ) throws -> [SessionQueryEventHit] {
        try ensureOpen()
        let normalized = try normalizedQuery(query)
        let boundedLimit = try validatedLimit(limit)
        let statement = try prepare("""
            SELECT e.session_id, e.seq, e.type, e.time, e.surface, e.text
            FROM query_events_fts f
            JOIN query_events e
              ON e.session_id = f.session_id AND e.seq = f.seq
            WHERE query_events_fts MATCH ? AND e.session_id = ?
            ORDER BY e.seq ASC
            LIMIT ?
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: ftsPhrase(normalized))
        bindText(statement, index: 2, value: sessionID.uuidString.lowercased())
        bindInt(statement, index: 3, value: boundedLimit)
        var result: [SessionQueryEventHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let event = try decodeEvent(statement)
            result.append(
                SessionQueryEventHit(
                    event: event,
                    snippet: makeSnippet(event.text, query: normalized)
                )
            )
        }
        return result
    }

    func indexedRevision(sessionID: UUID) throws -> UInt64? {
        try ensureOpen()
        return try sessionRecord(sessionID: sessionID)?.indexedThroughSequence
    }

    /// Drops all derived rows without touching canonical trajectory files.
    func reset() throws {
        try ensureOpen()
        try transact {
            try exec("DELETE FROM query_events_fts")
            try exec("DELETE FROM query_events")
            try exec("DELETE FROM query_sessions")
        }
    }

    func close() throws {
        guard !isClosed else { return }
        guard let database else {
            isClosed = true
            return
        }
        guard sqlite3_close(database) == SQLITE_OK else {
            throw sqliteError()
        }
        self.database = nil
        isClosed = true
    }

    // MARK: - Observation and projection

    private struct Observation: Sendable {
        let events: [SessionEvent]
        let indexedEvents: [IndexedEvent]
        let revision: SessionPersistenceRevision
        let title: String
        let createdAt: Int64
        let updatedAt: Int64
    }

    private struct IndexedEvent: Sendable {
        let event: SessionEvent
        let text: String
        let surface: String
    }

    private struct ExistingSession {
        let revision: UInt64
        let eventCount: Int
    }

    private func stableObservation(
        sessionID: UUID,
        persistence: any SessionPersistence
    ) async throws -> Observation {
        for _ in 0..<2 {
            let events = try await persistence.allEvents(sessionID: sessionID)
            let snapshot = try await persistence.persistenceSnapshot(sessionID: sessionID)
            guard snapshot.revision.nextSequence == UInt64(events.count) else {
                continue
            }
            let indexedEvents = project(events)
            let times = events.map(\.time)
            return Observation(
                events: events,
                indexedEvents: indexedEvents,
                revision: snapshot.revision,
                title: title(from: events),
                createdAt: times.min() ?? 0,
                updatedAt: times.max() ?? 0
            )
        }
        throw SessionQueryReadModelError.unstableSource(sessionID)
    }

    private func project(_ events: [SessionEvent]) -> [IndexedEvent] {
        var activeSequences = Set(events.map(\.seq))
        for event in events {
            if case let .replace(start, end) = event.surfaceOp {
                activeSequences.subtract(start...end)
            }
        }
        return events.map { event in
            IndexedEvent(
                event: event,
                text: searchableText(event),
                surface: activeSequences.contains(event.seq) ? "current" : "shadowed"
            )
        }
    }

    private func searchableText(_ event: SessionEvent) -> String {
        switch event.type {
        case SessionEventVocabulary.userMessage:
            return contentText(event.data.objectValue?["content"])
        case SessionEventVocabulary.assistantMessage:
            return contentText(event.data.objectValue?["message"]?.objectValue?["content"])
        case SessionEventVocabulary.toolCall:
            return joined([
                event.toolCallData?.name ?? "",
                event.toolCallData?.arguments ?? ""
            ])
        case SessionEventVocabulary.toolResult:
            return joined([
                contentText(event.toolResultData?.message.objectValue?["content"]),
                event.toolResultData?.error?.objectValue?["name"]?.stringValue ?? "",
                event.toolResultData?.error?.objectValue?["code"]?.stringValue ?? ""
            ])
        case "todo/write":
            return joined(todoText(event.data))
        case SessionEventVocabulary.turnEnd:
            return event.data.objectValue?["reason"]?.objectValue?["kind"]?.stringValue ?? ""
        default:
            return ""
        }
    }

    private func contentText(_ value: JSONValue?) -> String {
        guard case let .array(blocks)? = value else { return "" }
        return joined(blocks.flatMap { block -> [String] in
            guard let object = block.objectValue,
                  let type = object["type"]?.stringValue else { return [] }
            switch type {
            case "text":
                return [object["text"]?.stringValue ?? ""]
            case "tool-call":
                return [
                    object["name"]?.stringValue ?? "",
                    object["arguments"]?.stringValue ?? ""
                ]
            case "tool-result":
                return [contentText(object["content"])]
            default:
                return []
            }
        })
    }

    private func todoText(_ value: JSONValue) -> [String] {
        guard case let .object(object) = value,
              case let .array(todos)? = object["todos"] else { return [] }
        return todos.flatMap { (todo: JSONValue) -> [String] in
            guard let item = todo.objectValue else { return [] }
            return [
                item["status"]?.stringValue ?? "",
                item["content"]?.stringValue ?? item["title"]?.stringValue ?? ""
            ]
        }
    }

    private func title(from events: [SessionEvent]) -> String {
        if let explicit = events.reversed().first(where: {
            $0.type == "session/title"
        })?.data.objectValue?["title"]?.stringValue {
            return explicit
        }
        for event in events where event.type == SessionEventVocabulary.userMessage {
            let firstMessage = contentText(event.data.objectValue?["content"])
            if !firstMessage.isEmpty {
                return String(firstMessage.prefix(80))
            }
        }
        return "新会话"
    }

    private func joined(_ values: [String]) -> String {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - SQLite schema and writes

    private func ensureOpen() throws {
        guard !isClosed else { throw SessionEventLogError.closed }
        guard database == nil else { return }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SessionQueryReadModelError.sqlite(code: SQLITE_CANTOPEN, message: message)
        }
        database = handle
        do {
            let applicationID = try pragmaInt("application_id")
            let version = try pragmaInt("user_version")
            let tables = try userTables()
            if applicationID != 0 && applicationID != Int(Self.applicationID) {
                throw SessionQueryReadModelError.foreignDatabase
            }
            if applicationID == 0 && !tables.isEmpty {
                throw SessionQueryReadModelError.foreignDatabase
            }
            if applicationID == Int(Self.applicationID) && version != Self.schemaVersion {
                try dropSchema()
            }
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
            try exec("PRAGMA application_id = \(Self.applicationID)")
            try exec("""
                CREATE TABLE IF NOT EXISTS query_sessions (
                    session_id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    revision INTEGER NOT NULL,
                    event_count INTEGER NOT NULL,
                    searchable_event_count INTEGER NOT NULL
                ) WITHOUT ROWID
            """)
            try exec("""
                CREATE TABLE IF NOT EXISTS query_events (
                    session_id TEXT NOT NULL,
                    seq INTEGER NOT NULL,
                    type TEXT NOT NULL,
                    time INTEGER NOT NULL,
                    surface TEXT NOT NULL,
                    text TEXT NOT NULL,
                    PRIMARY KEY (session_id, seq)
                ) WITHOUT ROWID
            """)
            try exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS query_events_fts USING fts5(
                    text,
                    session_id UNINDEXED,
                    seq UNINDEXED,
                    tokenize = 'unicode61'
                )
            """)
            try exec("CREATE INDEX IF NOT EXISTS query_events_time ON query_events(time DESC)")
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    private func dropSchema() throws {
        try exec("DROP TABLE IF EXISTS query_events_fts")
        try exec("DROP TABLE IF EXISTS query_events")
        try exec("DROP TABLE IF EXISTS query_sessions")
        try exec("PRAGMA user_version = 0")
    }

    private func upsertSession(
        sessionID: UUID,
        title: String,
        createdAt: Int64,
        updatedAt: Int64,
        revision: UInt64,
        eventCount: Int,
        searchableEventCount: Int
    ) throws {
        let statement = try prepare("""
            INSERT INTO query_sessions
              (session_id, title, created_at, updated_at, revision,
               event_count, searchable_event_count)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(session_id) DO UPDATE SET
              title = excluded.title,
              created_at = excluded.created_at,
              updated_at = excluded.updated_at,
              revision = excluded.revision,
              event_count = excluded.event_count,
              searchable_event_count = excluded.searchable_event_count
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: sessionID.uuidString.lowercased())
        bindText(statement, index: 2, value: title)
        bindInt64(statement, index: 3, value: createdAt)
        bindInt64(statement, index: 4, value: updatedAt)
        bindInt64(statement, index: 5, value: Int64(revision))
        bindInt(statement, index: 6, value: eventCount)
        bindInt(statement, index: 7, value: searchableEventCount)
        try stepDone(statement)
    }

    private func insert(event: IndexedEvent, sessionID: UUID) throws {
        let statement = try prepare("""
            INSERT OR REPLACE INTO query_events
              (session_id, seq, type, time, surface, text)
            VALUES (?, ?, ?, ?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: sessionID.uuidString.lowercased())
        bindInt64(statement, index: 2, value: Int64(event.event.seq))
        bindText(statement, index: 3, value: event.event.type)
        bindInt64(statement, index: 4, value: event.event.time)
        bindText(statement, index: 5, value: event.surface)
        bindText(statement, index: 6, value: event.text)
        try stepDone(statement)

        let fts = try prepare("""
            INSERT INTO query_events_fts (text, session_id, seq)
            VALUES (?, ?, ?)
        """)
        defer { sqlite3_finalize(fts) }
        bindText(fts, index: 1, value: event.text)
        bindText(fts, index: 2, value: sessionID.uuidString.lowercased())
        bindInt64(fts, index: 3, value: Int64(event.event.seq))
        try stepDone(fts)
    }

    private func updateSurface(sessionID: UUID, events: [IndexedEvent]) throws {
        let statement = try prepare("""
            UPDATE query_events SET surface = ?
            WHERE session_id = ? AND seq = ?
        """)
        defer { sqlite3_finalize(statement) }
        for event in events {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bindText(statement, index: 1, value: event.surface)
            bindText(statement, index: 2, value: sessionID.uuidString.lowercased())
            bindInt64(statement, index: 3, value: Int64(event.event.seq))
            try stepDone(statement)
        }
    }

    private func deleteSessionRows(sessionID: UUID) throws {
        try deleteSessionRows(sessionIDString: sessionID.uuidString.lowercased())
    }

    private func deleteSessionRows(sessionIDString: String) throws {
        let deleteFTS = try prepare("DELETE FROM query_events_fts WHERE session_id = ?")
        defer { sqlite3_finalize(deleteFTS) }
        bindText(deleteFTS, index: 1, value: sessionIDString)
        try stepDone(deleteFTS)

        let deleteEvents = try prepare("DELETE FROM query_events WHERE session_id = ?")
        defer { sqlite3_finalize(deleteEvents) }
        bindText(deleteEvents, index: 1, value: sessionIDString)
        try stepDone(deleteEvents)

        let deleteSession = try prepare("DELETE FROM query_sessions WHERE session_id = ?")
        defer { sqlite3_finalize(deleteSession) }
        bindText(deleteSession, index: 1, value: sessionIDString)
        try stepDone(deleteSession)
    }

    private func existingSessionMetadata(sessionID: UUID) throws -> ExistingSession? {
        let statement = try prepare("""
            SELECT revision, event_count FROM query_sessions WHERE session_id = ?
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: sessionID.uuidString.lowercased())
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ExistingSession(
            revision: UInt64(sqlite3_column_int64(statement, 0)),
            eventCount: Int(sqlite3_column_int(statement, 1))
        )
    }

    private func eventRowCount(sessionID: UUID) throws -> Int {
        let statement = try prepare("""
            SELECT COUNT(*) FROM query_events WHERE session_id = ?
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: sessionID.uuidString.lowercased())
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func eventRow(sessionID: UUID, seq: UInt64) throws -> SessionQueryEventRecord? {
        let statement = try prepare("""
            SELECT session_id, seq, type, time, surface, text
            FROM query_events WHERE session_id = ? AND seq = ?
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: sessionID.uuidString.lowercased())
        bindInt64(statement, index: 2, value: Int64(seq))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeEvent(statement)
    }

    private func allSessionIDs() throws -> [String] {
        let statement = try prepare("SELECT session_id FROM query_sessions")
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(stringFromColumn(statement, index: 0))
        }
        return values
    }

    // MARK: - SQLite helpers

    private func transact(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            _ = try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String) throws {
        guard let database else {
            throw SessionQueryReadModelError.sqlite(code: SQLITE_MISUSE, message: "database is closed")
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message: String
            if let errorPointer {
                message = String(cString: errorPointer)
            } else {
                message = String(cString: sqlite3_errmsg(database))
            }
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SessionQueryReadModelError.sqlite(code: result, message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else {
            throw SessionQueryReadModelError.sqlite(code: SQLITE_MISUSE, message: "database is closed")
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(code: result)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(code: result) }
    }

    private func sqliteError(code: Int32? = nil) -> SessionQueryReadModelError {
        let actualCode = code ?? database.map(sqlite3_errcode) ?? SQLITE_MISUSE
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
        return .sqlite(code: actualCode, message: message)
    }

    private func pragmaInt(_ name: String) throws -> Int32 {
        let statement = try prepare("PRAGMA \(name)")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError() }
        return sqlite3_column_int(statement, 0)
    }

    private func userTables() throws -> [String] {
        let statement = try prepare("""
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
        """)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(stringFromColumn(statement, index: 0))
        }
        return result
    }

    private func validatedLimit(_ limit: Int) throws -> Int {
        guard (1...Self.maximumLimit).contains(limit) else {
            throw SessionQueryReadModelError.invalidLimit
        }
        return limit
    }

    private func normalizedQuery(_ query: String) throws -> String {
        let normalized = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty, !normalized.contains("\0") else {
            throw SessionQueryReadModelError.invalidQuery
        }
        return normalized
    }

    private func ftsPhrase(_ query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func makeSnippet(_ text: String, query: String) -> String {
        let lowerText = text.lowercased()
        let lowerQuery = query.lowercased()
        guard let range = lowerText.range(of: lowerQuery) else {
            return String(text.prefix(240))
        }
        let start = max(text.distance(from: text.startIndex, to: range.lowerBound) - 100, 0)
        let end = min(start + 240, text.count)
        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: end)
        return String(text[startIndex..<endIndex])
    }

    private func bindText(_ statement: OpaquePointer, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, nil)
    }

    private func bindInt(_ statement: OpaquePointer, index: Int32, value: Int) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func bindInt64(_ statement: OpaquePointer, index: Int32, value: Int64) {
        sqlite3_bind_int64(statement, index, value)
    }

    private func stringFromColumn(_ statement: OpaquePointer, index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func uuidFromColumn(_ statement: OpaquePointer, index: Int32) throws -> UUID {
        guard let value = UUID(uuidString: stringFromColumn(statement, index: index)) else {
            throw SessionQueryReadModelError.sqlite(
                code: SQLITE_CORRUPT,
                message: "invalid session id in query index"
            )
        }
        return value
    }

    private func decodeSession(_ statement: OpaquePointer) throws -> SessionQuerySessionRecord {
        SessionQuerySessionRecord(
            id: try uuidFromColumn(statement, index: 0),
            title: stringFromColumn(statement, index: 1),
            createdAt: sqlite3_column_int64(statement, 2),
            updatedAt: sqlite3_column_int64(statement, 3),
            indexedThroughSequence: UInt64(sqlite3_column_int64(statement, 4)),
            eventCount: Int(sqlite3_column_int(statement, 5)),
            searchableEventCount: Int(sqlite3_column_int(statement, 6))
        )
    }

    private func sessionRecord(sessionID: UUID) throws -> SessionQuerySessionRecord? {
        let statement = try prepare("""
            SELECT session_id, title, created_at, updated_at, revision,
                   event_count, searchable_event_count
            FROM query_sessions WHERE session_id = ?
        """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, value: sessionID.uuidString.lowercased())
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeSession(statement)
    }

    private func decodeEvent(_ statement: OpaquePointer) throws -> SessionQueryEventRecord {
        SessionQueryEventRecord(
            sessionID: try uuidFromColumn(statement, index: 0),
            seq: UInt64(sqlite3_column_int64(statement, 1)),
            type: stringFromColumn(statement, index: 2),
            time: sqlite3_column_int64(statement, 3),
            surface: stringFromColumn(statement, index: 4),
            text: stringFromColumn(statement, index: 5)
        )
    }
}
