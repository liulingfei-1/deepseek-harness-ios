import Foundation

/// Read-only projections of the durable session event log. These tools are
/// intentionally backed by SessionTrajectoryRepository rather than a second
/// in-memory transcript so an Agent sees the same append-only source as the UI.
enum SessionTrajectoryToolSupport {
    static let maximumLimit = 100
    static let defaultLimit = 25

    static func sessionUUID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw LocalToolError.invalidArguments
        }
        return id
    }

    static func limit(_ arguments: [String: JSONValue]) throws -> Int {
        guard let value = arguments["limit"] else { return defaultLimit }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= 1,
              number <= Double(maximumLimit) else {
            throw LocalToolError.invalidArguments
        }
        return Int(number)
    }

    static func types(_ arguments: [String: JSONValue]) throws -> Set<String>? {
        guard let value = arguments["types"] else { return nil }
        guard case let .array(values) = value else { throw LocalToolError.invalidArguments }
        let types = values.compactMap(\.stringValue)
        guard types.count == values.count,
              !types.isEmpty,
              types.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw LocalToolError.invalidArguments
        }
        return Set(types)
    }

    static func cursor(_ value: String?, streamID: String) throws -> SessionTrajectoryCursor? {
        guard let value, !value.isEmpty else { return nil }
        guard let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(SessionTrajectoryCursor.self, from: data),
              cursor.streamID == streamID else {
            throw LocalToolError.invalidArguments
        }
        return cursor
    }

    static func encodedCursor(_ cursor: SessionTrajectoryCursor) -> String {
        guard let data = try? JSONEncoder().encode(cursor) else { return "" }
        return data.base64EncodedString()
    }

    static func projected(_ event: SessionEvent) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string(event.type),
            "seq": .number(Double(event.seq)),
            "time": .number(Double(event.time)),
            "data": HarnessTraceRedactor.json(event.data, maximumDepth: 6)
        ]
        if let ignorable = event.ignorable { object["ignorable"] = .bool(ignorable) }
        if let sourceEventSeqs = event.sourceEventSeqs {
            object["sourceEventSeqs"] = .array(sourceEventSeqs.map { .number(Double($0)) })
        }
        if let surfaceOp = event.surfaceOp,
           let data = try? JSONEncoder().encode(surfaceOp),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            object["surfaceOp"] = HarnessTraceRedactor.json(value, maximumDepth: 3)
        }
        return .object(object)
    }

    static func output(_ value: JSONValue) -> String {
        guard case .string = value else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(value),
                  let text = String(data: data, encoding: .utf8) else {
                return "null"
            }
            return text
        }
        return value.displayText
    }

    static func searchableText(_ event: SessionEvent) -> String {
        let value = projected(event)
        return value.displayText.lowercased()
    }
}

struct SessionTraceTool: LocalAgentTool {
    let repository: SessionTrajectoryRepository
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "session_trace",
        description: "Read a paginated, credential-redacted tail of this Agent session's append-only trajectory. Use the returned next_cursor to continue without rereading earlier events.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "cursor": .object(["type": .string("string"), "description": .string("Opaque cursor returned by a previous call.")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
                "types": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["cursor", "limit", "types"])
        if let cursor = arguments["cursor"]?.stringValue, cursor.utf8.count > 4096 { throw LocalToolError.invalidArguments }
        _ = try SessionTrajectoryToolSupport.limit(arguments)
        _ = try SessionTrajectoryToolSupport.types(arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String { "读取会话轨迹" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session-trajectory:(sessionID)"] }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session:read:(sessionID)"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try SessionTrajectoryToolSupport.sessionUUID(sessionID)
        let streamID = id.uuidString.lowercased()
        let cursor = try SessionTrajectoryToolSupport.cursor(arguments["cursor"]?.stringValue, streamID: streamID)
        let types = try SessionTrajectoryToolSupport.types(arguments)
        let limit = try SessionTrajectoryToolSupport.limit(arguments)
        let snapshot = try await repository.snapshot(sessionID: id, after: cursor)
        let events = snapshot.events.filter { types == nil || types!.contains($0.type) }
        let page = Array(events.prefix(limit))
        let nextSequence: UInt64
        if let last = page.last {
            nextSequence = last.seq + 1
        } else {
            nextSequence = snapshot.cursor.nextSequence
        }
        let next = SessionTrajectoryCursor(streamID: snapshot.streamID, nextSequence: nextSequence)
        return SessionTrajectoryToolSupport.output(.object([
            "session_id": .string(sessionID),
            "events": .array(page.map(SessionTrajectoryToolSupport.projected)),
            "next_cursor": .string(SessionTrajectoryToolSupport.encodedCursor(next)),
            "has_more": .bool(nextSequence < snapshot.cursor.nextSequence),
            "from_sequence": .number(Double(snapshot.fromSequence)),
            "to_sequence": .number(Double(nextSequence))
        ]))
    }
}

struct SessionSearchTool: LocalAgentTool {
    let repository: SessionTrajectoryRepository
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "session_search",
        description: "Search this Agent session's durable trajectory by event type or redacted payload text. Results are bounded and use an opaque cursor for pagination.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string"), "description": .string("Case-insensitive text to find in event type or payload.")]),
                "cursor": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)]),
                "types": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["query", "cursor", "limit", "types"])
        let query = try arguments.requiredString("query", maximumUTF8Bytes: 2 * 1024)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalToolError.invalidArguments }
        if let cursor = arguments["cursor"]?.stringValue, cursor.utf8.count > 4096 { throw LocalToolError.invalidArguments }
        _ = try SessionTrajectoryToolSupport.limit(arguments)
        _ = try SessionTrajectoryToolSupport.types(arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String { "搜索会话轨迹" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session-trajectory:(sessionID)"] }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session:read:(sessionID)"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try SessionTrajectoryToolSupport.sessionUUID(sessionID)
        let streamID = id.uuidString.lowercased()
        let cursor = try SessionTrajectoryToolSupport.cursor(arguments["cursor"]?.stringValue, streamID: streamID)
        let types = try SessionTrajectoryToolSupport.types(arguments)
        let query = try arguments.requiredString("query", maximumUTF8Bytes: 2 * 1024).lowercased()
        let limit = try SessionTrajectoryToolSupport.limit(arguments)
        let snapshot = try await repository.snapshot(sessionID: id, after: cursor)
        let matches = snapshot.events.filter { event in
            (types == nil || types!.contains(event.type)) && SessionTrajectoryToolSupport.searchableText(event).contains(query)
        }
        let page = Array(matches.prefix(limit))
        let nextSequence = page.last.map { $0.seq + 1 } ?? snapshot.cursor.nextSequence
        let next = SessionTrajectoryCursor(streamID: snapshot.streamID, nextSequence: nextSequence)
        return SessionTrajectoryToolSupport.output(.object([
            "session_id": .string(sessionID),
            "query": .string(query),
            "matches": .array(page.map(SessionTrajectoryToolSupport.projected)),
            "next_cursor": .string(SessionTrajectoryToolSupport.encodedCursor(next)),
            "has_more": .bool(nextSequence < snapshot.cursor.nextSequence)
        ]))
    }
}

struct SessionEventGetTool: LocalAgentTool {
    let repository: SessionTrajectoryRepository
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "session_event_get",
        description: "Read one exact event from this Agent session by its durable sequence number. The payload is redacted and bounded.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object(["seq": .object(["type": .string("integer"), "minimum": .number(0)])]),
            "required": .array([.string("seq")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["seq"])
        guard case let .number(value)? = arguments["seq"], value.isFinite, value.rounded() == value, value >= 0 else {
            throw LocalToolError.invalidArguments
        }
    }
    func summary(arguments: [String: JSONValue]) -> String { "读取轨迹事件" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session-trajectory:(sessionID)"] }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session:read:(sessionID)"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try SessionTrajectoryToolSupport.sessionUUID(sessionID)
        guard case let .number(value) = arguments["seq"], let sequence = UInt64(exactly: value) else { throw LocalToolError.invalidArguments }
        let event = try await repository.allEvents(sessionID: id).first { $0.seq == sequence }
        guard let event else {
            return SessionTrajectoryToolSupport.output(.object(["session_id": .string(sessionID), "found": .bool(false), "seq": .number(Double(sequence))]))
        }
        return SessionTrajectoryToolSupport.output(.object(["session_id": .string(sessionID), "found": .bool(true), "event": SessionTrajectoryToolSupport.projected(event)]))
    }
}

struct SessionEventTypesTool: LocalAgentTool {
    let repository: SessionTrajectoryRepository
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "session_event_types",
        description: "List event types present in this Agent session and their counts. Useful before filtering session_trace.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys([]) }
    func summary(arguments: [String: JSONValue]) -> String { "统计轨迹事件类型" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session-trajectory:(sessionID)"] }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["session:read:(sessionID)"] }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try SessionTrajectoryToolSupport.sessionUUID(sessionID)
        var counts: [String: Int] = [:]
        for event in try await repository.allEvents(sessionID: id) { counts[event.type, default: 0] += 1 }
        let output = counts.keys.sorted().reduce(into: [String: JSONValue]()) { result, key in
            result[key] = .number(Double(counts[key] ?? 0))
        }
        return SessionTrajectoryToolSupport.output(.object([
            "session_id": .string(sessionID),
            "counts": .object(output),
            "total": .number(Double(counts.values.reduce(0, +)))
        ]))
    }
}

enum SessionTrajectoryToolSuite {
    static let names: Set<String> = ["session_search", "session_trace", "session_event_get", "session_event_types"]

    static func makeTools(repository: SessionTrajectoryRepository, sessionID: String) -> [any LocalAgentTool] {
        [
            SessionSearchTool(repository: repository, sessionID: sessionID),
            SessionTraceTool(repository: repository, sessionID: sessionID),
            SessionEventGetTool(repository: repository, sessionID: sessionID),
            SessionEventTypesTool(repository: repository, sessionID: sessionID)
        ]
    }
}
