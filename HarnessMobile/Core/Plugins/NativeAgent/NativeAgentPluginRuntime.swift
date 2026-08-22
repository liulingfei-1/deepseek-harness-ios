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
        if !promptSections.isEmpty || !promptContexts.isEmpty {
            dependencies.insert(CordisAgentServiceKeys.systemPrompt.name)
        }
        if promptContexts.contains(where: { $0.source == .file }) {
            dependencies.insert(CordisAgentServiceKeys.fileSystem.name)
        }
        if !tools.isEmpty {
            dependencies.insert(CordisAgentServiceKeys.tools.name)
        }
        return CordisPluginDefinition(
            id: CordisPluginID(rawValue: id),
            version: "native-agent-\(sourceDigest.prefix(12))",
            dependencies: dependencies
        ) { context in
            let fileSystem: (any HarnessFileSystem)? = if promptContexts.contains(
                where: { $0.source == .file }
            ) {
                try await context.service(CordisAgentServiceKeys.fileSystem)
            } else {
                nil
            }
            for (index, section) in promptSections.enumerated() {
                try await context.promptSection(
                    CordisPromptSection(
                        name: "native-agent:\(id):\(index)",
                        order: section.order,
                        complete: section.complete == true,
                        interpolate: false,
                        text: { input in
                            runtimeText(section.text, sessionID: input.agentID.uuidString)
                        }
                    )
                )
            }
            for promptContext in promptContexts {
                try await context.promptContext(
                    CordisPromptContextContribution(
                        name: "native-agent:\(id):context:\(promptContext.name)",
                        order: promptContext.order,
                        interpolate: false,
                        text: { input in
                            try await promptContextText(
                                promptContext,
                                input: input,
                                fileSystem: fileSystem
                            )
                        }
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
            for guardRule in toolGuards {
                try await context.intercept(
                    CordisAgentLoopCheckpoints.toolsPreExecute,
                    label: "native-agent:\(id):guard:\(guardRule.label)"
                ) { execution, next in
                    let current = try await next()
                    guard guardRule.matches(execution) else { return current }
                    switch guardRule.decision {
                    case .allow:
                        return current
                    case .ask:
                        if case .deny = current { return current }
                        return .ask
                    case .deny:
                        return .deny(
                            reason: guardRule.reason ?? "原生插件策略拒绝了这次工具调用。"
                        )
                    }
                }
            }
        }
    }

    func runtimeText(_ text: String, sessionID: String) -> String {
        let pluginStorage = ".harness-mobile/native-agent-plugins/\(id)"
        let sessionStorage = "\(pluginStorage)/sessions/\(sessionID)"
        let settingsJSON = settings?.values.displayText ?? "{}"
        return text
            .replacingOccurrences(of: "<plugin-id>", with: id)
            .replacingOccurrences(of: "<session-id>", with: sessionID)
            .replacingOccurrences(of: "<plugin-storage>", with: pluginStorage)
            .replacingOccurrences(of: "<session-storage>", with: sessionStorage)
            .replacingOccurrences(of: "<settings-json>", with: settingsJSON)
    }

    private func promptContextText(
        _ context: NativeAgentPromptContext,
        input: CordisPromptAssemblyInput,
        fileSystem: (any HarnessFileSystem)?
    ) async throws -> String {
        let raw: String
        switch context.source {
        case .file:
            guard let path = context.path, let fileSystem else { return "" }
            let resolvedPath = runtimeText(path, sessionID: input.agentID.uuidString)
            let target = try await fileSystem.resolve(resolvedPath, cwd: nil)
            guard try await fileSystem.stat(target) != nil else { return "" }
            raw = try await fileSystem.readText(target)
        case .conversation:
            raw = input.messages.map {
                "\($0.role.rawValue): \($0.content)"
            }.joined(separator: "\n\n")
        case .settings:
            raw = settings?.values.displayText ?? ""
        }
        guard !raw.isEmpty else { return "" }
        let bounded = String(raw.suffix(context.maximumCharacters))
        let prefix = runtimeText(context.prefix, sessionID: input.agentID.uuidString)
        let suffix = runtimeText(context.suffix, sessionID: input.agentID.uuidString)
        return prefix + bounded + suffix
    }
}

private extension NativeAgentToolGuard {
    func matches(_ execution: CordisToolExecution) -> Bool {
        let nameMatches = toolNames.contains("*") || toolNames.contains(execution.call.name)
        let riskMatches = risks.contains { $0.rawValue == execution.risk.rawValue }
        return nameMatches || riskMatches
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
            if let minimum = schemaObject["minItems"]?.exactInteger,
               values.count < minimum {
                throw LocalToolError.invalidArguments
            }
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
            if let minimum = schemaObject["minLength"]?.exactInteger,
               string.count < minimum {
                throw LocalToolError.invalidArguments
            }
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
            try validateNumberBounds(number, schemaObject: schemaObject)
        case "number":
            guard case let .number(number) = value, number.isFinite else {
                throw LocalToolError.invalidArguments
            }
            try validateNumberBounds(number, schemaObject: schemaObject)
        case "boolean":
            guard case .bool = value else { throw LocalToolError.invalidArguments }
        case "null":
            guard case .null = value else { throw LocalToolError.invalidArguments }
        default:
            throw LocalToolError.invalidArguments
        }
    }

    private static func validateNumberBounds(
        _ number: Double,
        schemaObject: [String: JSONValue]
    ) throws {
        if let minimum = schemaObject["minimum"]?.numberValue, number < minimum {
            throw LocalToolError.invalidArguments
        }
        if let maximum = schemaObject["maximum"]?.numberValue, number > maximum {
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

    var numberValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}
