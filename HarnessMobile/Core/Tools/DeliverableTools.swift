import Foundation

/// File- and diff-shaped results used by the native UI and trajectory
/// inspector. The payload is intentionally bounded; the workspace path is the
/// durable source of truth for previews and sharing.
enum DeliverableToolSuite {
    static let names: Set<String> = ["workspace_diff", "deliverable_write"]

    static let promptSections: [(name: String, order: Int, text: String)] = [
        (
            "tool:deliverables",
            115,
            "Use workspace_diff before replacing an existing file when the user needs to review changes. Use deliverable_write for a finished artifact; it writes only inside the protected on-device workspace and returns a bounded preview plus a canonical path suitable for Files preview or sharing."
        )
    ]

    static func makeTools(environment: FileSystemToolEnvironment) -> [any LocalAgentTool] {
        [
            WorkspaceDiffTool(environment: environment),
            DeliverableWriteTool(environment: environment)
        ]
    }
}

private struct WorkspaceDiffTool: LocalAgentTool {
    private static let maximumPathBytes = 4 * 1_024
    private static let maximumContentBytes = 256 * 1_024
    private static let maximumLines = 4_000
    private static let maximumDiffBytes = 96 * 1_024

    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "workspace_diff",
        description: "Compare proposed UTF-8 text with a protected on-device workspace file and return a bounded unified diff. A missing file is treated as an empty file. This is read-only and does not modify the workspace.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace path to compare.")
                ]),
                "proposed_content": .object([
                    "type": .string("string"),
                    "description": .string("Complete proposed UTF-8 content.")
                ])
            ]),
            "required": .array([.string("file_path"), .string("proposed_content")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["file_path", "proposed_content"])
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments
        }
        _ = try arguments.requiredString("proposed_content", maximumUTF8Bytes: Self.maximumContentBytes, allowEmpty: true)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "比较文件差异：\(arguments["file_path"]?.stringValue ?? "文件")"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs-diff:\(try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes)
        let proposed = try arguments.requiredString("proposed_content", maximumUTF8Bytes: Self.maximumContentBytes, allowEmpty: true)
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        let current: String
        var observedVersion: HarnessFsVersion?
        if let info = try await environment.fileSystem.stat(target) {
            guard info.type == .file else {
                throw HarnessFsError(code: .notRegularFile, message: "cannot diff \"\(target.displayPath)\": not a regular file")
            }
            current = try await environment.fileSystem.readText(target)
            observedVersion = info.version
        } else {
            current = ""
            observedVersion = nil
        }
        if let observedVersion {
            try await environment.observe(CordisFsObservedInput(
                target: target,
                observation: .present(observedVersion),
                actor: environment.actor
            ))
        } else {
            try await environment.observe(CordisFsObservedInput(
                target: target,
                observation: .absent,
                actor: environment.actor
            ))
        }
        let result = UnifiedTextDiff.make(
            old: current,
            new: proposed,
            oldPath: target.displayPath,
            newPath: target.displayPath,
            maximumLines: Self.maximumLines,
            maximumBytes: Self.maximumDiffBytes
        )
        return JSONValue.object([
            "kind": .string("diff"),
            "path": .string(target.displayPath),
            "changed": .bool(result.added > 0 || result.removed > 0),
            "added": .number(Double(result.added)),
            "removed": .number(Double(result.removed)),
            "truncated": .bool(result.truncated),
            "diff": .string(result.text)
        ]).displayText
    }
}

private struct DeliverableWriteTool: LocalAgentTool {
    private static let maximumPathBytes = 4 * 1_024
    private static let maximumContentBytes = 256 * 1_024
    private static let maximumPreviewBytes = 4 * 1_024

    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "deliverable_write",
        description: "Write a finished UTF-8 artifact into the protected on-device workspace and return structured metadata for native preview and sharing. Existing files use the same freshness baseline as write/edit.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace-relative artifact path, for example deliverables/report.md.")
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("Complete UTF-8 artifact content.")
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Optional human-readable title.")
                ])
            ]),
            "required": .array([.string("file_path"), .string("content")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["file_path", "content", "title"])
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments
        }
        _ = try arguments.requiredString("content", maximumUTF8Bytes: Self.maximumContentBytes, allowEmpty: true)
        if let title = arguments["title"]?.stringValue, title.utf8.count > 512 {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "生成交付物：\(arguments["file_path"]?.stringValue ?? "文件")"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs:\(try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes))"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workspace:deliverable:\(try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: Self.maximumPathBytes)
        let content = try arguments.requiredString("content", maximumUTF8Bytes: Self.maximumContentBytes, allowEmpty: true)
        let title = arguments["title"]?.stringValue
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        let info = try await environment.fileSystem.stat(target)
        let expected = try await environment.writeIntent(CordisFsIntentInput(target: target, actor: environment.actor))
        let outcome = try await environment.fileSystem.writeText(target, content: content, expected: expected)
        try await environment.observe(CordisFsObservedInput(
            target: target,
            observation: .present(outcome.version),
            actor: environment.actor
        ))
        let preview = prefixUTF8(content, maximumBytes: Self.maximumPreviewBytes)
        var value: [String: JSONValue] = [
            "kind": .string("deliverable"),
            "path": .string(target.displayPath),
            "bytes": .number(Double(content.utf8.count)),
            "lines": .number(Double(content.split(whereSeparator: { $0 == "\n" }).count)),
            "preview": .string(preview),
            "preview_truncated": .bool(preview.utf8.count < content.utf8.count),
            "created": .bool(info == nil),
            "shareable": .bool(true)
        ]
        if let title, !title.isEmpty { value["title"] = .string(title) }
        return JSONValue.object(value).displayText
    }

    private func prefixUTF8(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = String.UnicodeScalarView()
        result.reserveCapacity(maximumBytes)
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard usedBytes + scalarBytes <= maximumBytes else { break }
            result.append(scalar)
            usedBytes += scalarBytes
        }
        return String(result)
    }
}

private enum UnifiedTextDiff {
    struct Result: Sendable {
        let text: String
        let added: Int
        let removed: Int
        let truncated: Bool
    }

    private enum Edit { case equal(String), add(String), remove(String) }

    static func make(
        old: String,
        new: String,
        oldPath: String,
        newPath: String,
        maximumLines: Int,
        maximumBytes: Int
    ) -> Result {
        let oldLines = old.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).map(String.init)
        let newLines = new.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).map(String.init)
        let n = min(oldLines.count, maximumLines)
        let m = min(newLines.count, maximumLines)
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = oldLines[i] == newLines[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var edits: [Edit] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n && j < m && oldLines[i] == newLines[j] {
                edits.append(.equal(oldLines[i])); i += 1; j += 1
            } else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
                edits.append(.add(newLines[j])); j += 1
            } else if i < n {
                edits.append(.remove(oldLines[i])); i += 1
            }
        }
        var body = "--- \(oldPath)\n+++ \(newPath)\n"
        var added = 0, removed = 0, bytes = body.utf8.count
        var truncated = oldLines.count > maximumLines || newLines.count > maximumLines
        for edit in edits {
            let prefix: String
            switch edit {
            case .equal: prefix = " "
            case .add: prefix = "+"; added += 1
            case .remove: prefix = "-"; removed += 1
            }
            let value: String
            switch edit {
            case let .equal(v), let .add(v), let .remove(v):
                value = v
            }
            let line = prefix + value + "\n"
            let lineBytes = line.utf8.count
            if bytes + lineBytes > maximumBytes { truncated = true; break }
            body += line; bytes += lineBytes
        }
        if truncated { body += "… diff truncated; use the workspace path for the complete artifact.\n" }
        return Result(text: body, added: added, removed: removed, truncated: truncated)
    }
}
