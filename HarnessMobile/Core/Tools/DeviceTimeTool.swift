import Foundation

struct DeviceTimeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "device_time",
        description: "Return the iPhone's current local date, time, time zone, and locale.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "读取本机当前时间"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        try validate(arguments: arguments)
        return true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let formatter = ISO8601DateFormatter()
        return JSONValue.object([
            "iso8601": .string(formatter.string(from: .now)),
            "timeZone": .string(TimeZone.current.identifier),
            "locale": .string(Locale.current.identifier)
        ]).displayText
    }
}
