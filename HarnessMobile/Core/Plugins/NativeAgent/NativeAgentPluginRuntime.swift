import Foundation

typealias NativeAgentCompiledToolExecutor = @Sendable (
    _ plugin: NativeAgentCompiledPlugin,
    _ tool: NativeAgentCompiledTool,
    _ arguments: [String: JSONValue],
    _ onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
) async throws -> String

struct NativeAgentCompiledLocalTool: LocalAgentTool {
    let plugin: NativeAgentCompiledPlugin
    let compiledTool: NativeAgentCompiledTool
    let executor: NativeAgentCompiledToolExecutor

    var definition: ModelToolDefinition {
        ModelToolDefinition(
            name: compiledTool.name,
            description: compiledTool.description,
            parameters: compiledTool.parameters
        )
    }

    var risk: ToolRisk { compiledTool.risk }

    func validate(arguments: [String: JSONValue]) throws {
        try NativeAgentJSONSchemaValidator.validate(
            value: .object(arguments),
            schema: compiledTool.parameters
        )
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "原生插件 \(plugin.name)：\(compiledTool.description)"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["native-agent-plugin:\(plugin.id)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await executor(plugin, compiledTool, arguments) { _ in }
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try await executor(plugin, compiledTool, arguments, onOutput)
    }
}

extension NativeAgentCompiledPlugin {
    func cordisDefinition(
        executor: @escaping NativeAgentCompiledToolExecutor
    ) -> CordisPluginDefinition {
        var dependencies = Set<String>()
        if !promptSections.isEmpty {
            dependencies.insert(CordisAgentServiceKeys.systemPrompt.name)
        }
        if !tools.isEmpty {
            dependencies.insert(CordisAgentServiceKeys.tools.name)
        }
        return CordisPluginDefinition(
            id: CordisPluginID(rawValue: id),
            version: "native-agent-\(sourceDigest.prefix(12))",
            dependencies: dependencies
        ) { context in
            for (index, section) in promptSections.enumerated() {
                try await context.promptSection(
                    CordisPromptSection(
                        name: "native-agent:\(id):\(index)",
                        order: section.order,
                        text: section.text.replacingOccurrences(of: "<plugin-id>", with: id)
                    )
                )
            }
            for tool in tools {
                try await context.registerTool(
                    NativeAgentCompiledLocalTool(
                        plugin: self,
                        compiledTool: tool,
                        executor: executor
                    )
                )
            }
        }
    }
}

enum NativeAgentJSONSchemaValidator {
    static func validate(value: JSONValue, schema: JSONValue, path: String = "$") throws {
        guard case let .object(schemaObject) = schema,
              let type = schemaObject["type"]?.stringValue else {
            throw LocalToolError.invalidArguments
        }
        if let allowed = schemaObject["enum"]?.arrayValue, !allowed.contains(value) {
            throw LocalToolError.invalidArguments
        }
        switch type {
        case "object":
            guard case let .object(object) = value else { throw LocalToolError.invalidArguments }
            let properties = schemaObject["properties"]?.objectValue ?? [:]
            let required = Set(
                schemaObject["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            guard required.isSubset(of: Set(object.keys)) else {
                throw LocalToolError.invalidArguments
            }
            if schemaObject["additionalProperties"] == .bool(false) {
                guard Set(object.keys).isSubset(of: Set(properties.keys)) else {
                    throw LocalToolError.invalidArguments
                }
            }
            for (key, child) in object {
                if let childSchema = properties[key] {
                    try validate(value: child, schema: childSchema, path: "\(path).\(key)")
                }
            }
        case "array":
            guard case let .array(values) = value else { throw LocalToolError.invalidArguments }
            if let maximum = schemaObject["maxItems"]?.exactInteger,
               values.count > maximum {
                throw LocalToolError.invalidArguments
            }
            if let itemSchema = schemaObject["items"] {
                for (index, child) in values.enumerated() {
                    try validate(value: child, schema: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case "string":
            guard let string = value.stringValue else { throw LocalToolError.invalidArguments }
            if let maximum = schemaObject["maxLength"]?.exactInteger,
               string.count > maximum {
                throw LocalToolError.invalidArguments
            }
        case "integer":
            guard case let .number(number) = value,
                  number.isFinite,
                  number.rounded(.towardZero) == number else {
                throw LocalToolError.invalidArguments
            }
        case "number":
            guard case let .number(number) = value, number.isFinite else {
                throw LocalToolError.invalidArguments
            }
        case "boolean":
            guard case .bool = value else { throw LocalToolError.invalidArguments }
        case "null":
            guard case .null = value else { throw LocalToolError.invalidArguments }
        default:
            throw LocalToolError.invalidArguments
        }
    }
}

actor NativeAgentToolExecutionCollector {
    private var finalText: String?

    func consume(_ event: AgentRuntimeEvent) {
        guard case let .messagesCommitted(messages) = event else { return }
        for message in messages where !message.content.isEmpty {
            if message.role == .assistant || finalText == nil {
                finalText = message.content
            }
        }
    }

    func result() -> String? {
        finalText
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var exactInteger: Int? {
        guard case let .number(value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min),
              value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
