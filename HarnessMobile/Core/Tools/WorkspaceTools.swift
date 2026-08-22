import Foundation

struct WorkspaceListTool: LocalAgentTool {
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "workspace_list_files",
        description: "List visible regular files in the on-device workspace, including active external folders under mounts/<name>/. File contents are not inspected here; workspace_read_text or read validates UTF-8 and can reject a listed binary file. Dot-prefixed paths such as .harness-mobile are intentionally omitted. Never use this listing as an existence check for a hidden path; probe a known hidden file directly with workspace_read_text or read and handle not-found. The same mounts are visible to iSH at /workspace/mounts/<name>/.",
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
    let environment: FileSystemToolEnvironment
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
        let path = try arguments.requiredString("path", maximumUTF8Bytes: 512)
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard let info = try await environment.fileSystem.stat(target) else {
            try await environment.observe(CordisFsObservedInput(
                target: target,
                observation: .absent,
                actor: environment.actor
            ))
            throw HarnessFsError(
                code: .notFound,
                message: "cannot read \"\(target.displayPath)\": not found"
            )
        }
        guard info.type == .file else {
            throw HarnessFsError(
                code: .notRegularFile,
                message: "cannot read \"\(target.displayPath)\": not a regular file"
            )
        }
        let text = try await environment.fileSystem.readText(target)
        try await environment.observe(CordisFsObservedInput(
            target: target,
            observation: .present(info.version),
            actor: environment.actor
        ))
        return text
    }
}

struct WorkspaceWriteTextTool: LocalAgentTool {
    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "workspace_write_text",
        description: "Create or replace one UTF-8 text file in the on-device workspace or a read-write external mount under mounts/<name>/... . Missing parent directories are created automatically. Read-only mounts reject writes.",
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
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        do {
            let intent = try await environment.writeIntent(CordisFsIntentInput(
                target: target,
                actor: environment.actor
            ))
            let outcome = try await environment.fileSystem.writeText(
                target,
                content: text,
                expected: intent
            )
            try await environment.observe(CordisFsObservedInput(
                target: target,
                observation: .present(outcome.version),
                actor: environment.actor
            ))
            return JSONValue.object([
                "status": .string("written"),
                "path": .string(target.displayPath),
                "operation": .string(outcome.operation == .create ? "create" : "update")
            ]).displayText
        } catch {
            throw remediateFileMutationError(error)
        }
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
