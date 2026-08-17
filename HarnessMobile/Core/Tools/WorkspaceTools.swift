import Foundation

struct WorkspaceListTool: LocalAgentTool {
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "workspace_list_files",
        description: "List UTF-8 text files in the on-device workspace, including active external folders under mounts/<name>/. The same mounts are visible to iSH at /workspace/mounts/<name>/.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "列出手机工作区和挂载目录中的文件"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let files = try await store.listFiles()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: try encoder.encode(files), encoding: .utf8) ?? "[]"
    }
}

struct WorkspaceReadTextTool: LocalAgentTool {
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "workspace_read_text",
        description: "Read one UTF-8 text file from the on-device workspace or an active external mount. Mounted paths use mounts/<name>/... . The result is sent to the configured model API as tool output.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative path returned by workspace_list_files.")
                ])
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["path"])
        _ = try arguments.requiredString("path", maximumUTF8Bytes: 512)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "读取并发送文件：\(arguments["path"]?.stringValue ?? "未知路径")"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let path = try arguments.requiredString("path", maximumUTF8Bytes: 512)
        return ["workspace:file:\(normalizedApprovalPath(path))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        return try await store.readText(
            path: arguments.requiredString("path", maximumUTF8Bytes: 512)
        )
    }
}

struct WorkspaceWriteTextTool: LocalAgentTool {
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "workspace_write_text",
        description: "Create or replace one UTF-8 text file in the on-device workspace or a read-write external mount under mounts/<name>/... . Read-only mounts reject writes.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Relative text-file path.")
                ]),
                "text": .object([
                    "type": .string("string"),
                    "description": .string("Complete UTF-8 file content.")
                ])
            ]),
            "required": .array([.string("path"), .string("text")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["path", "text"])
        _ = try arguments.requiredString("path", maximumUTF8Bytes: 512)
        _ = try arguments.requiredString(
            "text",
            maximumUTF8Bytes: 60 * 1_024,
            allowEmpty: true
        )
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let path = arguments["path"]?.stringValue ?? "未知路径"
        let bytes = arguments["text"]?.stringValue?.utf8.count ?? 0
        return "创建或覆盖本地文件：\(path)（\(bytes) 字节）"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        _ = try arguments.requiredString("path", maximumUTF8Bytes: 512)
        return ["workspace:root"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("path", maximumUTF8Bytes: 512)
        let text = try arguments.requiredString(
            "text",
            maximumUTF8Bytes: 60 * 1_024,
            allowEmpty: true
        )
        try await store.writeText(path: path, text: text)
        return JSONValue.object([
            "status": .string("written"),
            "path": .string(path)
        ]).displayText
    }
}

private func normalizedApprovalPath(_ rawPath: String) -> String {
    let isAbsolute = rawPath.hasPrefix("/")
    var components: [Substring] = []
    for component in rawPath.split(separator: "/", omittingEmptySubsequences: true) {
        switch component {
        case ".":
            continue
        case "..":
            if components.last != "..", !components.isEmpty {
                components.removeLast()
            } else {
                components.append(component)
            }
        default:
            components.append(component)
        }
    }
    let normalized = components.joined(separator: "/")
    if isAbsolute {
        return "/" + normalized
    }
    return normalized.isEmpty ? "." : normalized
}
