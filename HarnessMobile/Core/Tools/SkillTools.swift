import Foundation

struct SkillLoadTool: LocalAgentTool {
    let registry: MobileSkillRegistry

    let definition = ModelToolDefinition(
        name: "skill",
        description: "Load the full instructions for an available on-device Skill. Call this with the exact name from the session skill catalog before acting on a task that names or clearly matches that Skill.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "name": .object([
                    "type": .string("string"),
                    "description": .string("Exact Skill name from the available-skills catalog.")
                ])
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["name"])
        let name = try arguments.requiredString("name", maximumUTF8Bytes: 128)
        guard MobileSkillRegistry.isValidName(name) else {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "加载本机 Skill：\(arguments["name"]?.stringValue ?? "未知")"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let name = try arguments.requiredString("name", maximumUTF8Bytes: 128)
        return ["workspace:skill:\(name)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let name = try arguments.requiredString("name", maximumUTF8Bytes: 128)
        let skill = try await registry.definition(named: name)
        guard skill.summary.invocation.modelInvocable else {
            throw MobileSkillError.modelInvocationDisabled(name)
        }
        return JSONValue.object([
            "name": .string(skill.summary.name),
            "provider": .string("workspace"),
            "source": .string(skill.summary.source.rawValue),
            "resourceBase": .object([
                "kind": .string("directory"),
                "path": .string(skill.summary.resourceBase)
            ]),
            "content": .string(MobileSkillRegistry.renderContent(skill))
        ]).displayText
    }
}
