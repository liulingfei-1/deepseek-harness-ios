import Foundation

struct FileSystemToolEnvironment: Sendable {
    let fileSystem: any HarnessFileSystem
    let actor: CordisFsActor
    let writeIntent: @Sendable (CordisFsIntentInput) async throws -> HarnessFsWriteIntent?
    let editVersion: @Sendable (CordisFsIntentInput) async throws -> HarnessFsVersion?
    let observe: @Sendable (CordisFsObservedInput) async throws -> Void

    static func guarded(
        fileSystem: any HarnessFileSystem,
        sessionID: String,
        policy: HarnessFsObservationPolicy
    ) -> Self {
        Self(
            fileSystem: fileSystem,
            actor: CordisFsActor(sessionID: sessionID),
            writeIntent: { input in
                await policy.writeIntent(for: input)
            },
            editVersion: { input in
                try await policy.editVersion(for: input)
            },
            observe: { input in
                await policy.record(input)
            }
        )
    }
}

struct WorkspaceReadImageToolValue: Sendable, Equatable {
    let path: String
    let attachment: AgentImageAttachmentRef
    let width: Int
    let height: Int
    let originalWidth: Int?
    let originalHeight: Int?

    init(
        path: String,
        attachment: AgentImageAttachmentRef,
        width: Int,
        height: Int,
        originalWidth: Int?,
        originalHeight: Int?
    ) {
        self.path = path
        self.attachment = attachment
        self.width = width
        self.height = height
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
    }

    init?(jsonValue: JSONValue?) {
        guard let root = jsonValue?.objectValue,
              let path = root["path"]?.stringValue,
              !path.isEmpty,
              let image = root["image"]?.objectValue,
              let rawID = image["attachmentId"]?.stringValue,
              let id = UUID(uuidString: rawID),
              let attachmentPath = image["attachmentPath"]?.stringValue,
              !attachmentPath.isEmpty,
              let mediaType = image["mediaType"]?.stringValue,
              mediaType.hasPrefix("image/"),
              case let .number(rawBytes)? = image["bytes"],
              case let .number(rawWidth)? = image["width"],
              case let .number(rawHeight)? = image["height"],
              rawBytes.rounded() == rawBytes,
              rawWidth.rounded() == rawWidth,
              rawHeight.rounded() == rawHeight,
              (1...Double(4 * 1_024 * 1_024)).contains(rawBytes),
              (1...8_192.0).contains(rawWidth),
              (1...8_192.0).contains(rawHeight) else {
            return nil
        }
        let original = image["originalDimensions"]?.objectValue
        self.init(
            path: path,
            attachment: AgentImageAttachmentRef(
                id: id,
                path: attachmentPath,
                mimeType: mediaType,
                byteCount: Int(rawBytes)
            ),
            width: Int(rawWidth),
            height: Int(rawHeight),
            originalWidth: original?["width"].flatMap(Self.positiveInteger),
            originalHeight: original?["height"].flatMap(Self.positiveInteger)
        )
    }

    var jsonValue: JSONValue {
        var image: [String: JSONValue] = [
            "attachmentId": .string(attachment.id.uuidString.lowercased()),
            "attachmentPath": .string(attachment.path),
            "mediaType": .string(attachment.mimeType),
            "bytes": .number(Double(attachment.byteCount)),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "name": .string(URL(fileURLWithPath: path).lastPathComponent)
        ]
        if let originalWidth, let originalHeight {
            image["originalDimensions"] = .object([
                "width": .number(Double(originalWidth)),
                "height": .number(Double(originalHeight))
            ])
        }
        return .object([
            "path": .string(path),
            "image": .object(image)
        ])
    }

    private static func positiveInteger(_ value: JSONValue) -> Int? {
        guard case let .number(raw) = value,
              raw.rounded() == raw,
              (1...Double(Int.max)).contains(raw) else { return nil }
        return Int(raw)
    }
}

enum FileSystemToolSuite {
    static let names: Set<String> = [
        "read", "read_image", "write", "edit", "glob", "grep", "workspace_search"
    ]

    static let promptSections: [(name: String, order: Int, text: String)] = [
        (
            "tool:read",
            110,
            "Use the read tool, not shell commands such as cat, to inspect UTF-8 text files. Results include line numbers. Use offset and limit to continue reading large files."
        ),
        (
            "tool:write",
            112,
            "Use the write tool to create files or completely replace file contents. Missing parent directories are created automatically. Read an existing file before replacing it so the filesystem freshness policy can reject stale writes; a successful write or edit becomes the new freshness baseline. Prefer edit for targeted changes."
        ),
        (
            "tool:read-image",
            111,
            "Use read_image for PNG, JPEG, WebP, or GIF workspace files when image understanding is required. The image is normalized into a bounded durable attachment before its metadata is returned. Only an image-capable model route can project that attachment into a later request."
        ),
        (
            "tool:edit",
            113,
            "Use the edit tool for targeted changes to existing UTF-8 text files. It replaces literal old_string with new_string; old_string must match exactly once unless replace_all is true. Read the file first and re-read after any stale-version error."
        ),
        (
            "tool:workspace-search",
            114,
            "Use workspace_search to find text in the on-device workspace. It walks the protected workspace and mounted folders, returns matching paths and line numbers, and does not require workspace_list_files to expose hidden paths."
        ),
        (
            "tool:glob",
            103,
            "Use glob, not shell find, to discover files by path pattern. A pattern with no slash matches basenames at any depth. Results contain files only, include hidden files, exclude VCS metadata directories, and spill a complete sorted result to a readable workspace file when the inline page is capped."
        ),
        (
            "tool:grep",
            104,
            "Use grep, not shell grep or rg, to search workspace file contents with a regular expression. Results include paths and line numbers; use read on a matched file for surrounding context."
        )
    ]

    static func makeTools(
        environment: FileSystemToolEnvironment,
        imageStore: WorkspaceStore? = nil,
        searchConfiguration: WorkspaceSearchConfiguration = .standard
    ) -> [any LocalAgentTool] {
        var tools: [any LocalAgentTool] = [
            HarnessReadTool(environment: environment),
            HarnessWriteTool(environment: environment),
            HarnessEditTool(environment: environment),
            WorkspaceGlobTool(environment: environment, configuration: searchConfiguration),
            WorkspaceGrepTool(environment: environment, configuration: searchConfiguration),
            WorkspaceSearchTool(environment: environment)
        ]
        if let imageStore {
            tools.append(WorkspaceReadImageTool(environment: environment, store: imageStore))
        }
        return tools
    }
}

private struct WorkspaceReadImageTool: LocalAgentTool {
    private static let maximumSourceBytes = 20 * 1_024 * 1_024
    private static let mediaTypeByExtension = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif": "image/gif"
    ]

    let environment: FileSystemToolEnvironment
    let store: WorkspaceStore
    let definition = ModelToolDefinition(
        name: "read_image",
        description: "Read a PNG/JPEG/WebP/GIF workspace file, fully decode and normalize it into a bounded durable attachment, and return canonical attachment metadata for image-capable context projection.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Path to the image file, resolved by the protected workspace filesystem.")
                ])
            ]),
            "required": .array([.string("file_path")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["file_path"])
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        guard Self.declaredMediaType(for: path) != nil else {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "读取图片：\(String((arguments["file_path"]?.stringValue ?? "").prefix(96)))"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs-image:\(arguments["file_path"]?.stringValue ?? "")"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workspace:image:\(arguments["file_path"]?.stringValue ?? "")"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        guard let declaredMediaType = Self.declaredMediaType(for: path) else {
            throw LocalToolError.invalidArguments
        }
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard let info = try await environment.fileSystem.stat(target) else {
            throw HarnessFsError(
                code: .notFound,
                message: "cannot read \"\(target.displayPath)\" as an image: not found"
            )
        }
        guard info.type == .file else {
            throw HarnessFsError(
                code: .notRegularFile,
                message: "cannot read \"\(target.displayPath)\" as an image: not a regular file"
            )
        }
        let data = try await environment.fileSystem.readBytes(
            target,
            maximumBytes: Self.maximumSourceBytes
        )
        let admitted = try await store.stageImageWithMetadata(
            data,
            declaredMimeType: declaredMediaType
        )
        try await environment.observe(CordisFsObservedInput(
            target: target,
            observation: .present(info.version),
            actor: environment.actor
        ))
        return WorkspaceReadImageToolValue(
            path: target.displayPath,
            attachment: admitted.reference,
            width: admitted.width,
            height: admitted.height,
            originalWidth: admitted.originalWidth,
            originalHeight: admitted.originalHeight
        ).jsonValue.displayText
    }

    private static func declaredMediaType(for path: String) -> String? {
        mediaTypeByExtension[URL(fileURLWithPath: path).pathExtension.lowercased()]
    }
}

private struct WorkspaceSearchTool: LocalAgentTool {
    private static let maximumQueryBytes = 4 * 1_024
    private static let maximumResults = 100
    private static let maximumFilesVisited = 2_000
    private static let maximumFileBytes = 512 * 1_024

    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "workspace_search",
        description: "Search UTF-8 text files in the protected on-device workspace and mounted folders. Returns matching paths, line numbers, and bounded excerpts without requiring a separate directory listing.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Literal text to find. Case sensitivity is controlled by case_sensitive.")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Optional workspace directory or file. Defaults to /workspace.")
                ]),
                "case_sensitive": .object([
                    "type": .string("boolean"),
                    "description": .string("Whether matching should preserve case. Defaults to false.")
                ]),
                "include_hidden": .object([
                    "type": .string("boolean"),
                    "description": .string("Include dot-prefixed paths. Defaults to true because hidden Harness state can be meaningful.")
                ]),
                "max_results": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(maximumResults)),
                    "description": .string("Maximum matching lines to return. Defaults to 50.")
                ])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([
            "query", "path", "case_sensitive", "include_hidden", "max_results"
        ])
        let query = try arguments.requiredString("query", maximumUTF8Bytes: Self.maximumQueryBytes)
        guard !query.isEmpty else { throw LocalToolError.invalidArguments }
        if let value = arguments["case_sensitive"], Self.bool(value) == nil {
            throw LocalToolError.invalidArguments
        }
        if let value = arguments["include_hidden"], Self.bool(value) == nil {
            throw LocalToolError.invalidArguments
        }
        if let value = arguments["max_results"] {
            _ = try Self.integer(value, range: 1...Self.maximumResults)
        }
        if let path = arguments["path"]?.stringValue,
           path.utf8.count > 4 * 1_024 {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "搜索工作区：\(String((arguments["query"]?.stringValue ?? "").prefix(72)))"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs-search:\(arguments["path"]?.stringValue ?? "/workspace")"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workspace:search:\(arguments["path"]?.stringValue ?? "/workspace")"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let query = try arguments.requiredString(
            "query",
            maximumUTF8Bytes: Self.maximumQueryBytes
        )
        let path = arguments["path"]?.stringValue ?? "/workspace"
        let caseSensitive = arguments["case_sensitive"].flatMap(Self.bool) ?? false
        let includeHidden = arguments["include_hidden"].flatMap(Self.bool) ?? true
        let resultLimit = try Self.integer(
            arguments["max_results"],
            defaultValue: 50,
            range: 1...Self.maximumResults
        )
        let root = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard let _ = try await environment.fileSystem.stat(root) else {
            throw HarnessFsError(code: .notFound, message: "cannot search \(root.displayPath): not found")
        }

        struct Match: Sendable {
            let path: String
            let line: Int
            let excerpt: String
        }
        var matches: [Match] = []
        var pending: [HarnessFsTarget] = [root]
        var visited = 0
        while let target = pending.popLast(), visited < Self.maximumFilesVisited,
              matches.count < resultLimit {
            visited += 1
            guard let info = try await environment.fileSystem.stat(target) else { continue }
            if info.type == .directory {
                let entries = try await environment.fileSystem.listDirectory(target)
                for entry in entries.reversed() {
                    if !includeHidden, entry.name.hasPrefix(".") { continue }
                    guard entry.type == .directory || entry.type == .file else { continue }
                    pending.append(entry.target)
                }
                continue
            }
            guard info.type == .file,
                  (info.size ?? 0) <= Self.maximumFileBytes else { continue }
            let text: String
            do {
                text = try await environment.fileSystem.readText(target)
            } catch let error as HarnessFsError where error.code == .notText || error.code == .tooLarge {
                continue
            }
            let needle = caseSensitive ? query : query.lowercased()
            for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }).enumerated() {
                let line = String(rawLine).trimmingCharacters(in: .newlines)
                let haystack = caseSensitive ? line : line.lowercased()
                guard haystack.contains(needle) else { continue }
                matches.append(Match(
                    path: target.displayPath,
                    line: index + 1,
                    excerpt: String(line.prefix(400))
                ))
                if matches.count >= resultLimit { break }
            }
        }
        let values = matches.map { match in
            JSONValue.object([
                "path": .string(match.path),
                "line": .number(Double(match.line)),
                "excerpt": .string(match.excerpt)
            ])
        }
        return JSONValue.object([
            "query": .string(query),
            "root": .string(root.displayPath),
            "matches": .array(values),
            "truncated": .bool(matches.count >= resultLimit || visited >= Self.maximumFilesVisited),
            "files_visited": .number(Double(visited))
        ]).displayText
    }

    private static func bool(_ value: JSONValue) -> Bool? {
        guard case let .bool(result) = value else { return nil }
        return result
    }

    private static func integer(
        _ value: JSONValue?,
        defaultValue: Int? = nil,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value else {
            if let defaultValue { return defaultValue }
            throw LocalToolError.invalidArguments
        }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw LocalToolError.invalidArguments
        }
        let integer = Int(number)
        guard range.contains(integer) else { throw LocalToolError.invalidArguments }
        return integer
    }
}

private struct HarnessReadTool: LocalAgentTool {
    private static let defaultLineLimit = 2_000
    private static let maximumLineLength = 2_000
    private static let maximumOutputBytes = 50 * 1_024
    private static let streamingThresholdBytes = 10 * 1_024 * 1_024

    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "read",
        description: "Read a line-numbered window from a UTF-8 text file in the on-device DeepSeek Harness workspace. Paths may be relative to /workspace; mounted folders are under /workspace/mounts/<name>.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace path to read, for example README.md or /workspace/mounts/Project/file.txt.")
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "description": .string("Optional 1-based first line. Defaults to 1.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(defaultLineLimit)),
                    "description": .string("Optional number of lines. Defaults to and is capped at 2000.")
                ])
            ]),
            "required": .array([.string("file_path")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["file_path", "offset", "limit"])
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidField(field: "file_path", reason: "必须是非空路径")
        }
        _ = try Self.integer(
            arguments["offset"],
            field: "offset",
            defaultValue: 1,
            range: 1...Int.max
        )
        _ = try Self.integer(
            arguments["limit"],
            field: "limit",
            defaultValue: Self.defaultLineLimit,
            range: 1...Self.defaultLineLimit
        )
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "读取 \(arguments["file_path"]?.stringValue ?? "文件")"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        true
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs:\(try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        let offset = try Self.integer(
            arguments["offset"],
            field: "offset",
            defaultValue: 1,
            range: 1...Int.max
        )
        let limit = try Self.integer(
            arguments["limit"],
            field: "limit",
            defaultValue: Self.defaultLineLimit,
            range: 1...Self.defaultLineLimit
        )
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        guard let info = try await environment.fileSystem.stat(target) else {
            try await observe(target, .absent)
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

        let window: FileReadWindow
        if info.size == nil || info.size! >= Self.streamingThresholdBytes {
            window = try await FileReadWindow.build(
                chunks: try await environment.fileSystem.streamText(target),
                path: target.displayPath,
                offset: offset,
                limit: limit,
                maximumLineLength: Self.maximumLineLength,
                maximumOutputBytes: Self.maximumOutputBytes
            )
        } else {
            window = try FileReadWindow.build(
                text: try await environment.fileSystem.readText(target),
                path: target.displayPath,
                offset: offset,
                limit: limit,
                maximumLineLength: Self.maximumLineLength,
                maximumOutputBytes: Self.maximumOutputBytes
            )
        }
        try await observe(target, .present(info.version))
        return window.rendered
    }

    private func observe(_ target: HarnessFsTarget, _ observation: HarnessFsObservation) async throws {
        try await environment.observe(
            CordisFsObservedInput(
                target: target,
                observation: observation,
                actor: environment.actor
            )
        )
    }

    private static func integer(
        _ value: JSONValue?,
        field: String,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw LocalToolError.invalidField(field: field, reason: "必须是正整数")
        }
        let integer = Int(number)
        guard range.contains(integer) else {
            throw LocalToolError.invalidField(
                field: field,
                reason: "必须在 \(range.lowerBound)...\(range.upperBound) 范围内"
            )
        }
        return integer
    }
}

private struct HarnessWriteTool: LocalAgentTool {
    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "write",
        description: "Create a UTF-8 text file or completely replace one in the on-device workspace. Missing parent directories are created automatically. Existing files must be read first and unchanged since that read; each successful write or edit refreshes the observed version for subsequent mutations.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace path to create or replace.")
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("Complete UTF-8 file content.")
                ])
            ]),
            "required": .array([.string("file_path"), .string("content")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["file_path", "content"])
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidField(field: "file_path", reason: "必须是非空路径")
        }
        _ = try arguments.requiredString(
            "content",
            maximumUTF8Bytes: WorkspaceFileSystemProvider.maximumTextBytes,
            allowEmpty: true
        )
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "写入 \(arguments["file_path"]?.stringValue ?? "文件")"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs:\(try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        let content = try arguments.requiredString(
            "content",
            maximumUTF8Bytes: WorkspaceFileSystemProvider.maximumTextBytes,
            allowEmpty: true
        )
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        let input = CordisFsIntentInput(target: target, actor: environment.actor)
        do {
            let intent = try await environment.writeIntent(input)
            let outcome = try await environment.fileSystem.writeText(
                target,
                content: content,
                expected: intent
            )
            try await environment.observe(
                CordisFsObservedInput(
                    target: target,
                    observation: .present(outcome.version),
                    actor: environment.actor
                )
            )
            let operation = outcome.operation == .create ? "Created file" : "Updated file"
            return "<path>\(target.displayPath)</path>\n<type>file</type>\n<content>\n\(operation)\n</content>"
        } catch {
            throw remediateFileMutationError(error)
        }
    }
}

private struct HarnessEditTool: LocalAgentTool {
    let environment: FileSystemToolEnvironment
    let definition = ModelToolDefinition(
        name: "edit",
        description: "Apply an atomic literal replacement to an existing UTF-8 text file in the on-device workspace. The file must be read first and remain unchanged.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "file_path": .object([
                    "type": .string("string"),
                    "description": .string("Workspace path to edit.")
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string("Non-empty literal text to replace exactly.")
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string("Literal replacement text. Empty deletes the match.")
                ]),
                "replace_all": .object([
                    "type": .string("boolean"),
                    "description": .string("Replace every match. Defaults to false; otherwise old_string must match exactly once.")
                ])
            ]),
            "required": .array([
                .string("file_path"),
                .string("old_string"),
                .string("new_string")
            ]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["file_path", "old_string", "new_string", "replace_all"])
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        let oldString = try arguments.requiredString(
            "old_string",
            maximumUTF8Bytes: WorkspaceFileSystemProvider.maximumTextBytes
        )
        let newString = try arguments.requiredString(
            "new_string",
            maximumUTF8Bytes: WorkspaceFileSystemProvider.maximumTextBytes,
            allowEmpty: true
        )
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !oldString.isEmpty else {
            throw LocalToolError.invalidField(
                field: path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "file_path" : "old_string",
                reason: "必须是非空字符串"
            )
        }
        guard oldString != newString else {
            throw LocalToolError.invalidField(
                field: "new_string",
                reason: "必须与 old_string 不同"
            )
        }
        if let replaceAll = arguments["replace_all"], boolValue(replaceAll) == nil {
            throw LocalToolError.invalidField(field: "replace_all", reason: "必须是布尔值")
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "编辑 \(arguments["file_path"]?.stringValue ?? "文件")"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs:\(try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024))"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4 * 1_024)
        let target = try await environment.fileSystem.resolve(path, cwd: "/workspace")
        let input = CordisFsIntentInput(target: target, actor: environment.actor)
        do {
            let version = try await environment.editVersion(input)
            let replaceAll = arguments["replace_all"].flatMap(boolValue) ?? false
            let outcome = try await environment.fileSystem.editText(
                target,
                edit: HarnessFsEditRequest(
                    oldString: try arguments.requiredString(
                        "old_string",
                        maximumUTF8Bytes: WorkspaceFileSystemProvider.maximumTextBytes
                    ),
                    newString: try arguments.requiredString(
                        "new_string",
                        maximumUTF8Bytes: WorkspaceFileSystemProvider.maximumTextBytes,
                        allowEmpty: true
                    ),
                    replaceAll: replaceAll
                ),
                expectedVersion: version
            )
            try await environment.observe(
                CordisFsObservedInput(
                    target: target,
                    observation: .present(outcome.version),
                    actor: environment.actor
                )
            )
            return replaceAll
                ? "The file \(target.displayPath) has been updated. All occurrences were successfully replaced."
                : "The file \(target.displayPath) has been updated successfully."
        } catch {
            throw remediateFileMutationError(error)
        }
    }
}

private func boolValue(_ value: JSONValue) -> Bool? {
    guard case let .bool(result) = value else { return nil }
    return result
}

func remediateFileMutationError(_ error: Error) -> Error {
    guard let fsError = error as? HarnessFsError else { return error }
    switch fsError.code {
    case .staleVersion:
        return HarnessFsError(
            code: fsError.code,
            message: fsError.message + " - re-read the file, then retry"
        )
    case .notObserved:
        return HarnessFsError(
            code: fsError.code,
            message: fsError.message + " - read the file, then retry"
        )
    default:
        return fsError
    }
}

private struct FileReadWindow {
    let rendered: String

    private struct SelectedLine {
        let number: Int
        let text: String
    }

    private struct Accumulator {
        var lines: [SelectedLine] = []
        var totalLines = 0
        var outputBytes = 0
        var truncatedByBytes = false

        mutating func consume(
            _ rawLine: String,
            offset: Int,
            limit: Int,
            maximumLineLength: Int,
            maximumOutputBytes: Int
        ) {
            totalLines += 1
            guard !truncatedByBytes,
                  totalLines >= offset,
                  lines.count < limit else { return }
            let text = rawLine.count > maximumLineLength
                ? String(rawLine.prefix(maximumLineLength))
                    + "... (line truncated to \(maximumLineLength) chars)"
                : rawLine
            let bytes = text.utf8.count + (lines.isEmpty ? 0 : 1)
            guard outputBytes + bytes <= maximumOutputBytes else {
                truncatedByBytes = true
                return
            }
            outputBytes += bytes
            lines.append(SelectedLine(number: totalLines, text: text))
        }
    }

    static func build(
        text: String,
        path: String,
        offset: Int,
        limit: Int,
        maximumLineLength: Int,
        maximumOutputBytes: Int
    ) throws -> Self {
        var accumulator = Accumulator()
        var lineBuffer = ""
        consume(
            chunk: text,
            accumulator: &accumulator,
            lineBuffer: &lineBuffer,
            offset: offset,
            limit: limit,
            maximumLineLength: maximumLineLength,
            maximumOutputBytes: maximumOutputBytes
        )
        finishPendingLine(
            accumulator: &accumulator,
            lineBuffer: &lineBuffer,
            offset: offset,
            limit: limit,
            maximumLineLength: maximumLineLength,
            maximumOutputBytes: maximumOutputBytes
        )
        return try render(accumulator, path: path, offset: offset)
    }

    static func build(
        chunks: AsyncThrowingStream<String, Error>,
        path: String,
        offset: Int,
        limit: Int,
        maximumLineLength: Int,
        maximumOutputBytes: Int
    ) async throws -> Self {
        var accumulator = Accumulator()
        var lineBuffer = ""
        for try await chunk in chunks {
            try Task.checkCancellation()
            consume(
                chunk: chunk,
                accumulator: &accumulator,
                lineBuffer: &lineBuffer,
                offset: offset,
                limit: limit,
                maximumLineLength: maximumLineLength,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        finishPendingLine(
            accumulator: &accumulator,
            lineBuffer: &lineBuffer,
            offset: offset,
            limit: limit,
            maximumLineLength: maximumLineLength,
            maximumOutputBytes: maximumOutputBytes
        )
        return try render(accumulator, path: path, offset: offset)
    }

    private static func consume(
        chunk: String,
        accumulator: inout Accumulator,
        lineBuffer: inout String,
        offset: Int,
        limit: Int,
        maximumLineLength: Int,
        maximumOutputBytes: Int
    ) {
        for character in chunk {
            if character == "\n" {
                let raw = lineBuffer.hasSuffix("\r") ? String(lineBuffer.dropLast()) : lineBuffer
                accumulator.consume(
                    raw,
                    offset: offset,
                    limit: limit,
                    maximumLineLength: maximumLineLength,
                    maximumOutputBytes: maximumOutputBytes
                )
                lineBuffer.removeAll(keepingCapacity: true)
            } else if lineBuffer.count <= maximumLineLength {
                lineBuffer.append(character)
            }
        }
    }

    private static func finishPendingLine(
        accumulator: inout Accumulator,
        lineBuffer: inout String,
        offset: Int,
        limit: Int,
        maximumLineLength: Int,
        maximumOutputBytes: Int
    ) {
        guard !lineBuffer.isEmpty else { return }
        accumulator.consume(
            lineBuffer,
            offset: offset,
            limit: limit,
            maximumLineLength: maximumLineLength,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private static func render(
        _ accumulator: Accumulator,
        path: String,
        offset: Int
    ) throws -> Self {
        guard accumulator.truncatedByBytes
                || offset <= accumulator.totalLines
                || (accumulator.totalLines == 0 && offset == 1) else {
            throw HarnessFsError(
                code: .notFound,
                message: "offset \(offset) is out of range for \"\(path)\" (\(accumulator.totalLines) lines)"
            )
        }
        let endLine = accumulator.lines.last?.number ?? max(0, offset - 1)
        let footer: String
        if accumulator.truncatedByBytes {
            footer = "(Output capped. Showing lines \(offset)-\(endLine). Use offset=\(endLine + 1) to continue.)"
        } else if endLine < accumulator.totalLines {
            footer = "(Showing lines \(offset)-\(endLine) of \(accumulator.totalLines). Use offset=\(endLine + 1) to continue.)"
        } else {
            footer = "(End of file - total \(accumulator.totalLines) lines)"
        }
        let renderedLines = accumulator.lines.map { "\($0.number): \($0.text)" }
        let body = renderedLines.isEmpty
            ? footer
            : renderedLines.joined(separator: "\n") + "\n\n" + footer
        return Self(rendered: "<path>\(path)</path>\n<type>file</type>\n<content>\n\(body)\n</content>")
    }
}
