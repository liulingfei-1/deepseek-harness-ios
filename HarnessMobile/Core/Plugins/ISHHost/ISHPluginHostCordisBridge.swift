import Foundation

enum ISHPluginHostRuntimeState: Sendable, Equatable {
    case stopped
    case installing
    case starting
    case running(hostVersion: String, processID: Int32?)
    case failed(String)
}

enum ISHHostedToolError: Error, Sendable, Equatable, LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executionFailed(message):
            return "iSH 插件工具执行失败：\(message)"
        }
    }
}

struct ISHHostedCordisTool: LocalAgentTool {
    private static let contributionMutationTools: Set<String> = [
        "cordis_define",
        "cordis_run",
        "cordis_stop",
        "cordis_undefine"
    ]

    let definition: ModelToolDefinition
    let risk: ToolRisk = .sideEffect

    private let sessionID: String
    private let client: ISHPluginHostClient
    private let synchronizeMobileContext: @Sendable () async throws -> Void
    private let synchronizeContributions: @Sendable () async throws -> Void

    init(
        contribution: ISHPluginHostToolContribution,
        sessionID: String,
        client: ISHPluginHostClient,
        synchronizeMobileContext: @escaping @Sendable () async throws -> Void = {},
        synchronizeContributions: @escaping @Sendable () async throws -> Void = {}
    ) {
        definition = ModelToolDefinition(
            name: contribution.name,
            description: contribution.description,
            parameters: contribution.parameters
        )
        self.sessionID = sessionID
        self.client = client
        self.synchronizeMobileContext = synchronizeMobileContext
        self.synchronizeContributions = synchronizeContributions
    }

    func validate(arguments: [String: JSONValue]) throws {
        try ISHPluginHostCredentialFirewall.validate(.object(arguments))
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "在本机 iSH 插件沙箱中执行 \(definition.name)"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await synchronizeMobileContext()
        let response = try await client.invoke(
            .tool(
                sessionId: sessionID,
                name: definition.name,
                arguments: .object(arguments)
            )
        )
        let resultText: String
        if let object = response.objectValue {
            if case .bool(true)? = object["isError"] {
                throw ISHHostedToolError.executionFailed(
                    object["value"]?.displayText
                        ?? object["error"]?.displayText
                        ?? response.displayText
                )
            }
            resultText = object["value"]?.displayText ?? response.displayText
        } else {
            resultText = response.displayText
        }
        if Self.contributionMutationTools.contains(definition.name) {
            // Wait for the native Cordis bridge to replace its contribution
            // snapshot before AgentRuntime is allowed to enter the next step.
            try await synchronizeContributions()
        }
        return resultText
    }
}

enum ISHPluginHostCordisBridge {
    static let pluginID: CordisPluginID = "ish.dynamic-contributions"

    static func definition(
        contributions: ISHPluginHostContributions,
        sessionID: String,
        client: ISHPluginHostClient,
        commandRegistry: SlashCommandRegistry? = nil,
        synchronizeMobileContext: @escaping @Sendable () async throws -> Void = {},
        synchronizeContributions: @escaping @Sendable () async throws -> Void = {}
    ) -> CordisPluginDefinition {
        let tools = contributions.tools
        let sections = contributions.prompt.sections
        let contexts = contributions.prompt.contexts
        let variables = contributions.prompt.variables
        return CordisPluginDefinition(
            id: pluginID,
            version: "host-revision-\(contributions.revision)",
            dependencies: [
                CordisAgentServiceKeys.tools.name,
                CordisAgentServiceKeys.systemPrompt.name
            ]
        ) { context in
            for contribution in tools {
                try await context.registerTool(
                    ISHHostedCordisTool(
                        contribution: contribution,
                        sessionID: sessionID,
                        client: client,
                        synchronizeMobileContext: synchronizeMobileContext,
                        synchronizeContributions: synchronizeContributions
                    )
                )
            }
            if let commandRegistry, !contributions.commands.isEmpty {
                try await context.effect("host-command-generation") {
                    var registrations: [SlashCommandRegistration] = []
                    do {
                        for command in contributions.commands {
                            let input = try command.input.map {
                                try SlashCommandInputDescriptor(hint: $0.hint)
                            }
                            let definition = try SlashCommandDefinition(
                                name: command.name,
                                description: command.description,
                                input: input,
                                // The Host command runtime has no attachment
                                // store in the mobile composition. Plain calls
                                // remain available; staged images fail closed
                                // at native admission instead of disappearing.
                                imagePolicy: .rejected,
                                recordInput: command.recordInput
                            ) { invocation in
                                try await synchronizeMobileContext()
                                let response = try await client.request(
                                    method: .commandExecute,
                                    params: .object([
                                        "sessionId": .string(sessionID),
                                        "name": .string(command.name),
                                        "commandId": .string(invocation.commandID),
                                        "rawInput": .string(invocation.parsed.rawInput)
                                    ])
                                )
                                guard let object = response.objectValue,
                                      object["ok"] == .bool(true),
                                      let value = object["value"]?.objectValue,
                                      let kind = value["kind"]?.stringValue else {
                                    let message = response.objectValue?["message"]?.displayText
                                        ?? response.displayText
                                    return .failure(.handlerFailed, text: message)
                                }
                                if kind == "error" {
                                    return .failure(
                                        .handlerFailed,
                                        text: value["text"]?.stringValue ?? "Host command failed."
                                    )
                                }
                                guard kind == "success" else {
                                    return .failure(
                                        .handlerFailed,
                                        text: "Host command returned an unknown result kind."
                                    )
                                }
                                let sequence: Int?
                                if case let .number(rawSequence)? = value["sourceEventSeq"] {
                                    sequence = Int(rawSequence)
                                } else {
                                    sequence = nil
                                }
                                return .success(
                                    text: value["text"]?.stringValue,
                                    sourceEventSequence: sequence
                                )
                            }
                            registrations.append(
                                try await commandRegistry.register(
                                    definition,
                                    scope: sessionID,
                                    origin: .host
                                )
                            )
                        }
                    } catch {
                        for registration in registrations.reversed() {
                            _ = await commandRegistry.unregister(registration)
                        }
                        throw error
                    }
                    let committedRegistrations = registrations
                    return {
                        for registration in committedRegistrations.reversed() {
                            _ = await commandRegistry.unregister(registration)
                        }
                    }
                }
            }
            for (index, contribution) in sections.enumerated() {
                try await context.promptSection(
                    CordisPromptSection(
                        name: "ish:\(contribution.name)",
                        order: 200 + index,
                        text: contribution.text
                    )
                )
            }
            for (index, contribution) in contexts.enumerated() {
                try await context.promptContext(
                    CordisPromptContextContribution(
                        name: "ish:\(contribution.name)",
                        order: 200 + index,
                        text: contribution.text
                    )
                )
            }
            for (name, value) in variables {
                try await context.promptVariable(name) { _ in
                    guard value != .null else { return nil }
                    return value.displayText
                }
            }
            try await ISHPluginHostDynamicHarnessBridge.register(
                contributions: contributions,
                sessionID: sessionID,
                client: client,
                synchronizeMobileContext: synchronizeMobileContext,
                context: context
            )
        }
    }
}
