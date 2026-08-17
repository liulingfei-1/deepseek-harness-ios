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
    private let synchronizeContributions: @Sendable () async throws -> Void

    init(
        contribution: ISHPluginHostToolContribution,
        sessionID: String,
        client: ISHPluginHostClient,
        synchronizeContributions: @escaping @Sendable () async throws -> Void = {}
    ) {
        definition = ModelToolDefinition(
            name: contribution.name,
            description: contribution.description,
            parameters: contribution.parameters
        )
        self.sessionID = sessionID
        self.client = client
        self.synchronizeContributions = synchronizeContributions
    }

    func validate(arguments: [String: JSONValue]) throws {
        try ISHPluginHostCredentialFirewall.validate(.object(arguments))
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "在本机 iSH 插件沙箱中执行 \(definition.name)"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
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
                        synchronizeContributions: synchronizeContributions
                    )
                )
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
                context: context
            )
        }
    }
}
