import Foundation

struct LocalToolRegistry: Sendable {
    private let tools: [String: any LocalAgentTool]

    init(tools: [any LocalAgentTool]) {
        self.tools = Dictionary(uniqueKeysWithValues: tools.map {
            ($0.definition.name, $0)
        })
    }

    var definitions: [ModelToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    func definitions(allowedBy permissionMode: ToolPermissionMode) -> [ModelToolDefinition] {
        tools.values
            .filter { permissionMode.decision(for: $0.risk) != .deny }
            .map(\.definition)
            .sorted { $0.name < $1.name }
    }

    func tool(named name: String) -> (any LocalAgentTool)? {
        tools[name]
    }
}
