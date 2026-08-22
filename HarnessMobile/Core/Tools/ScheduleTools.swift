import Foundation

enum ScheduleToolSuite {
    static let names: Set<String> = ["schedule_create", "schedule_list", "schedule_delete"]
    static let promptSection = CordisPromptSection(
        name: "tool:schedules",
        order: 107,
        text: "Use schedule_create only for a future local Agent turn. Schedules are persisted on this iPhone; they do not use a remote executor. Use schedule_list or schedule_delete to manage pending schedules."
    )

    static func makeTools(store: any HarnessScheduleManaging, ownerSession: String) -> [any LocalAgentTool] {
        [ScheduleCreateTool(store: store, ownerSession: ownerSession), ScheduleListTool(store: store, ownerSession: ownerSession), ScheduleDeleteTool(store: store, ownerSession: ownerSession)]
    }
}

private enum ScheduleToolSupport {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.sorted.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
    static func runAt(_ arguments: [String: JSONValue]) throws -> Int64 {
        guard case let .number(value) = arguments["run_at"], value.isFinite, value.rounded() == value,
              value >= 0, value <= Double(Int64.max) else { throw HarnessScheduleError.invalidRunAt }
        return Int64(value)
    }
}

private struct ScheduleCreateTool: LocalAgentTool {
    let store: any HarnessScheduleManaging
    let ownerSession: String
    let definition = ModelToolDefinition(name: "schedule_create", description: "Persist a future local Agent turn on this iPhone. run_at is an epoch timestamp in milliseconds; the app will claim it when background execution is available.", parameters: .object([
        "type": .string("object"), "properties": .object([
            "label": .object(["type": .string("string")]),
            "prompt": .object(["type": .string("string")]),
            "run_at": .object(["type": .string("integer"), "description": .string("Future Unix epoch milliseconds.")])
        ]), "required": .array([.string("prompt"), .string("run_at")]), "additionalProperties": .bool(false)
    ]))
    let risk: ToolRisk = .sideEffect
    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys(["label", "prompt", "run_at"]); _ = try arguments.requiredString("prompt", maximumUTF8Bytes: 64 * 1_024); _ = try ScheduleToolSupport.runAt(arguments) }
    func summary(arguments: [String: JSONValue]) -> String { "创建本机定时 Agent 任务" }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { ["schedules:\(ownerSession)"] }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["schedule:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let label = arguments["label"]?.stringValue ?? "scheduled Agent turn"
        let value = try await store.create(ownerSession: ownerSession, label: label, prompt: arguments.requiredString("prompt", maximumUTF8Bytes: 64 * 1_024), runAt: try ScheduleToolSupport.runAt(arguments))
        return try ScheduleToolSupport.json(value)
    }
}

private struct ScheduleListTool: LocalAgentTool {
    let store: any HarnessScheduleManaging
    let ownerSession: String
    let definition = ModelToolDefinition(name: "schedule_list", description: "List pending local Agent schedules for this session.", parameters: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
    let risk: ToolRisk = .localState
    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys([]) }
    func summary(arguments: [String: JSONValue]) -> String { "查看本机定时任务" }
    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }
    func execute(arguments: [String: JSONValue]) async throws -> String { try validate(arguments: arguments); return try ScheduleToolSupport.json(await store.list(ownerSession: ownerSession)) }
}

private struct ScheduleDeleteTool: LocalAgentTool {
    let store: any HarnessScheduleManaging
    let ownerSession: String
    let definition = ModelToolDefinition(name: "schedule_delete", description: "Cancel one pending local Agent schedule by id.", parameters: .object(["type": .string("object"), "properties": .object(["id": .object(["type": .string("string")])]), "required": .array([.string("id")]), "additionalProperties": .bool(false)]))
    let risk: ToolRisk = .sideEffect
    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys(["id"]); _ = try arguments.requiredString("id", maximumUTF8Bytes: 128) }
    func summary(arguments: [String: JSONValue]) -> String { "取消本机定时任务" }
    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> { ["schedules:\(ownerSession)"] }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["schedule:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String { try validate(arguments: arguments); return try ScheduleToolSupport.json(await store.delete(id: arguments.requiredString("id", maximumUTF8Bytes: 128), ownerSession: ownerSession)) }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return encoder }
}
