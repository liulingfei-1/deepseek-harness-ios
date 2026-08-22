import Foundation

/// On-device migration of DeepSeek Harness' Minimal-preset editor. All paths
/// stay inside `/workspace` (including mounted folders) and mutations share the
/// same observation policy as `read`, `write`, and `edit`.
struct StrReplaceEditorTool: LocalAgentTool {
    static let maximumOutputCharacters = 16_000
    static let clippedNotice = "<response clipped><NOTE>To save on context only part of this file has been shown to you. You should retry this tool after you have searched inside the file with `grep -n` in order to find the line numbers of what you are looking for.</NOTE>"

    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "str_replace_editor",
        description: """
        Custom editing tool for viewing, creating and editing files in the on-device /workspace sandbox.
        * State is persistent across command calls and discussions with the user.
        * If path is a file, view displays line-numbered content. If path is a directory, view lists non-hidden files and directories up to 2 levels deep.
        * create never overwrites an existing path.
        * Long view output is clipped and marked with <response clipped>.
        * old_str must match exactly once; include enough surrounding whitespace and lines to make it unique.
        """,
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "enum": .array(["view", "create", "str_replace", "insert"].map(JSONValue.string)),
                    "description": .string("One of view, create, str_replace, or insert.")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path inside /workspace, for example /workspace/Sources/App.swift.")
                ]),
                "file_text": .object([
                    "type": .string("string"),
                    "description": .string("Required by create; complete file content.")
                ]),
                "insert_line": .object([
                    "type": .string("integer"),
                    "description": .string("Required by insert; zero-based insertion boundary (0 inserts before the first line).")
                ]),
                "new_str": .object([
                    "type": .string("string"),
                    "description": .string("Replacement text for str_replace, or required insertion text for insert.")
                ]),
                "old_str": .object([
                    "type": .string("string"),
                    "description": .string("Required unique literal text for str_replace.")
                ]),
                "view_range": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")]),
                    "description": .string("Optional one-based [start, end] for a file; end -1 means EOF.")
                ])
            ]),
            "required": .array([.string("command"), .string("path")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([
            "command", "path", "file_text", "insert_line", "new_str", "old_str", "view_range"
        ])
        let command = try parsedCommand(arguments)
        _ = try parsedPath(arguments)
        switch command {
        case "view":
            if arguments["view_range"] != nil { _ = try parsedViewRange(arguments) }
        case "create":
            guard arguments["file_text"]?.stringValue != nil else {
                throw LocalToolError.missingArgument("file_text")
            }
        case "str_replace":
            guard let old = arguments["old_str"]?.stringValue else {
                throw LocalToolError.missingArgument("old_str")
            }
            guard !old.isEmpty else {
                throw LocalToolError.invalidField(field: "old_str", reason: "必须是非空字符串")
            }
            if let value = arguments["new_str"], value.stringValue == nil {
                throw LocalToolError.invalidField(field: "new_str", reason: "必须是字符串")
            }
        case "insert":
            _ = try parsedInsertLine(arguments)
            guard arguments["new_str"]?.stringValue != nil else {
                throw LocalToolError.missingArgument("new_str")
            }
        default:
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let command = arguments["command"]?.stringValue ?? "editor"
        let path = arguments["path"]?.stringValue ?? "/workspace"
        return "\(command) \(path)"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs:\(try parsedPath(arguments))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let command = try parsedCommand(arguments)
        let path = try parsedPath(arguments)
        switch command {
        case "view":
            return try await view(path: path, viewRange: try parsedViewRange(arguments))
        case "create":
            return try await create(path: path, content: arguments["file_text"]?.stringValue ?? "")
        case "str_replace":
            return try await replace(
                path: path,
                oldString: arguments["old_str"]?.stringValue ?? "",
                newString: arguments["new_str"]?.stringValue ?? ""
            )
        case "insert":
            return try await insert(
                path: path,
                line: try parsedInsertLine(arguments),
                text: arguments["new_str"]?.stringValue ?? ""
            )
        default:
            throw LocalToolError.invalidArguments
        }
    }

    private func view(path: String, viewRange: [Int]?) async throws -> String {
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard let info = try await environment.fileSystem.stat(target) else {
            try await observe(target, .absent)
            throw HarnessFsError(
                code: .notFound,
                message: "The path \(target.displayPath) does not exist. Please provide a valid path."
            )
        }
        if info.type == .directory {
            guard viewRange == nil else {
                throw LocalToolError.invalidField(
                    field: "view_range",
                    reason: "path 指向目录时不允许使用"
                )
            }
            return try await directoryView(target)
        }
        guard info.type == .file else {
            throw HarnessFsError(
                code: .notRegularFile,
                message: "cannot view \"\(target.displayPath)\": not a regular file or directory"
            )
        }
        let content = try await environment.fileSystem.readText(target)
        try await observe(target, .present(info.version))
        return try Self.fileView(path: target.displayPath, content: content, viewRange: viewRange)
    }

    private func directoryView(_ root: HarnessFsTarget) async throws -> String {
        var rows = ["d\t\(root.displayPath)"]
        func visit(_ directory: HarnessFsTarget, depth: Int) async throws {
            let entries = try await environment.fileSystem.listDirectory(directory)
            for entry in entries where Self.visibleDirectoryEntry(entry) {
                let marker = entry.type == .directory ? "d" : entry.type == .file ? "f" : "?"
                rows.append("\(marker)\t\(entry.target.displayPath)")
                if entry.type == .directory, depth < 2 {
                    try await visit(entry.target, depth: depth + 1)
                }
            }
        }
        try await visit(root, depth: 1)
        rows.sort { Self.codepointLess($0.pathColumn, $1.pathColumn) }
        let listing = Self.clipped(rows.joined(separator: "\n") + "\n")
        return "Here're the files and directories up to 2 levels deep in \(root.displayPath), excluding hidden items, node_modules, and Python cache directories:\n\(listing)\n"
    }

    private func create(path: String, content: String) async throws -> String {
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard try await environment.fileSystem.stat(target) == nil else {
            throw HarnessFsError(
                code: .staleVersion,
                message: "File already exists at: \(target.displayPath). Cannot overwrite files using command `create`."
            )
        }
        let intent = try await environment.writeIntent(CordisFsIntentInput(
            target: target,
            actor: environment.actor
        ))
        do {
            let outcome = try await environment.fileSystem.writeText(
                target,
                content: content,
                expected: intent ?? .createIfAbsent
            )
            try await observe(target, .present(outcome.version))
            return "New file created successfully at: \(target.displayPath)"
        } catch {
            throw remediateFileMutationError(error)
        }
    }

    private func replace(path: String, oldString: String, newString: String) async throws -> String {
        let (target, info, before) = try await existingFile(path: path, command: "str_replace")
        let offsets = Self.matchOffsets(in: before, search: oldString)
        guard !offsets.isEmpty else {
            throw HarnessFsError(
                code: .editNotFound,
                message: "No replacement was performed, old_str `\(oldString)` did not appear verbatim in \(target.displayPath)."
            )
        }
        guard offsets.count == 1 else {
            let lines = Self.lineNumbers(in: before, offsets: offsets)
            throw HarnessFsError(
                code: .ambiguousEdit,
                message: "No replacement was performed. Multiple occurrences of old_str `\(oldString)` in lines [\(lines.map(String.init).joined(separator: ", "))]. Please ensure it is unique"
            )
        }
        try await observe(target, .present(info.version))
        do {
            let expected = try await environment.editVersion(CordisFsIntentInput(
                target: target,
                actor: environment.actor
            ))
            let outcome = try await environment.fileSystem.editText(
                target,
                edit: HarnessFsEditRequest(
                    oldString: oldString,
                    newString: newString,
                    replaceAll: false
                ),
                expectedVersion: expected ?? info.version
            )
            try await observe(target, .present(outcome.version))
            return "The file \(target.displayPath) has been edited successfully."
        } catch {
            throw remediateFileMutationError(error)
        }
    }

    private func insert(path: String, line: Int, text: String) async throws -> String {
        let (target, info, before) = try await existingFile(path: path, command: "insert")
        let lines = Self.linesLikeJavaScript(before)
        guard (0...lines.count).contains(line) else {
            throw LocalToolError.invalidField(
                field: "insert_line",
                reason: "\(line) 不在 0...\(lines.count) 范围内"
            )
        }
        let insertion = Self.linesLikeJavaScript(text)
        let after = Array(lines[..<line]) + insertion + Array(lines[line...])
        try await observe(target, .present(info.version))
        do {
            let expected = try await environment.writeIntent(CordisFsIntentInput(
                target: target,
                actor: environment.actor
            ))
            let outcome = try await environment.fileSystem.writeText(
                target,
                content: after.joined(separator: "\n"),
                expected: expected ?? .replaceIfVersion(info.version)
            )
            try await observe(target, .present(outcome.version))
            return "The file \(target.displayPath) has been edited successfully."
        } catch {
            throw remediateFileMutationError(error)
        }
    }

    private func existingFile(
        path: String,
        command: String
    ) async throws -> (HarnessFsTarget, HarnessFsInfo, String) {
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard let info = try await environment.fileSystem.stat(target) else {
            try await observe(target, .absent)
            throw HarnessFsError(
                code: .notFound,
                message: "The path \(target.displayPath) does not exist. Please provide a valid path."
            )
        }
        guard info.type == .file else {
            throw HarnessFsError(
                code: .notRegularFile,
                message: "The path \(target.displayPath) is a directory and only the `view` command can be used on directories"
            )
        }
        return (target, info, try await environment.fileSystem.readText(target))
    }

    private func observe(_ target: HarnessFsTarget, _ observation: HarnessFsObservation) async throws {
        try await environment.observe(CordisFsObservedInput(
            target: target,
            observation: observation,
            actor: environment.actor
        ))
    }

    private func parsedCommand(_ arguments: [String: JSONValue]) throws -> String {
        guard let command = arguments["command"]?.stringValue,
              ["view", "create", "str_replace", "insert"].contains(command) else {
            throw LocalToolError.invalidEnumValue(
                field: "command",
                value: arguments["command"]?.stringValue,
                allowed: ["view", "create", "str_replace", "insert"]
            )
        }
        return command
    }

    private func parsedPath(_ arguments: [String: JSONValue]) throws -> String {
        let path = try arguments.requiredString("path", maximumUTF8Bytes: 4 * 1_024)
        guard path == "/workspace" || path.hasPrefix("/workspace/") else {
            throw LocalToolError.invalidField(
                field: "path",
                reason: "必须是 /workspace 内的绝对路径"
            )
        }
        return path
    }

    private func parsedInsertLine(_ arguments: [String: JSONValue]) throws -> Int {
        guard case let .number(raw)? = arguments["insert_line"],
              raw.isFinite,
              raw.rounded() == raw,
              raw >= 0,
              raw <= Double(Int.max) else {
            if arguments["insert_line"] == nil { throw LocalToolError.missingArgument("insert_line") }
            throw LocalToolError.invalidField(field: "insert_line", reason: "必须是非负整数")
        }
        return Int(raw)
    }

    private func parsedViewRange(_ arguments: [String: JSONValue]) throws -> [Int]? {
        guard let value = arguments["view_range"] else { return nil }
        guard case let .array(values) = value, values.count == 2 else {
            throw LocalToolError.invalidField(field: "view_range", reason: "必须包含两个整数")
        }
        return try values.map { value in
            guard case let .number(raw) = value,
                  raw.isFinite,
                  raw.rounded() == raw,
                  raw >= Double(Int.min),
                  raw <= Double(Int.max) else {
                throw LocalToolError.invalidField(field: "view_range", reason: "必须包含两个整数")
            }
            return Int(raw)
        }
    }

    private static func fileView(path: String, content: String, viewRange: [Int]?) throws -> String {
        let allLines = linesLikeJavaScript(content)
        var initial = 1
        var final: Int? = nil
        var lines = allLines
        var prompt = "Here's the content of \(path) with line numbers (which has a total of \(allLines.count) lines)"
        if let viewRange {
            initial = viewRange[0]
            final = viewRange[1]
            guard (1...allLines.count).contains(initial) else {
                throw LocalToolError.invalidField(
                    field: "view_range",
                    reason: "起始行 \(initial) 不在 1...\(allLines.count) 范围内"
                )
            }
            guard final == -1 || (final ?? -1) >= initial else {
                throw LocalToolError.invalidField(field: "view_range", reason: "结束行必须为 -1 或不小于起始行")
            }
            if let final, final != -1 {
                guard final <= allLines.count else {
                    throw LocalToolError.invalidField(
                        field: "view_range",
                        reason: "结束行 \(final) 超过总行数 \(allLines.count)"
                    )
                }
                lines = Array(allLines[(initial - 1)..<final])
            } else {
                lines = Array(allLines[(initial - 1)...])
            }
            prompt += " with view_range=[\(initial), \(final ?? -1)]"
        }
        let numbered = lines.enumerated().map { index, line in
            String(format: "%6d  %@", initial + index, line)
        }.joined(separator: "\n")
        return clipped("\(prompt):\n\(numbered)\n")
    }

    private static func linesLikeJavaScript(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func clipped(_ content: String) -> String {
        guard content.count > maximumOutputCharacters else { return content }
        return String(content.prefix(maximumOutputCharacters)) + clippedNotice
    }

    private static func visibleDirectoryEntry(_ entry: HarnessFsDirectoryEntry) -> Bool {
        !entry.name.hasPrefix(".")
            && entry.name != "node_modules"
            && entry.name != "__pycache__"
    }

    private static func codepointLess(_ left: String, _ right: String) -> Bool {
        left.unicodeScalars.lexicographicallyPrecedes(right.unicodeScalars) { $0.value < $1.value }
    }

    private static func matchOffsets(in content: String, search: String) -> [String.Index] {
        var result: [String.Index] = []
        var cursor = content.startIndex
        while cursor <= content.endIndex,
              let range = content.range(of: search, range: cursor..<content.endIndex) {
            result.append(range.lowerBound)
            cursor = range.upperBound
        }
        return result
    }

    private static func lineNumbers(in content: String, offsets: [String.Index]) -> [Int] {
        offsets.map { offset in
            content[..<offset].reduce(into: 1) { line, character in
                if character == "\n" { line += 1 }
            }
        }
    }
}

private extension String {
    var pathColumn: String {
        guard let tab = firstIndex(of: "\t") else { return self }
        return String(self[index(after: tab)...])
    }
}
