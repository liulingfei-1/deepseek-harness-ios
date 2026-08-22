import Foundation

/// Mobile projection of dsh's `tool-fs-search` caps. Search stays behind the
/// protected Harness filesystem instead of gaining a second host-path escape
/// hatch; the limits mirror the upstream inline contracts where applicable.
struct WorkspaceSearchConfiguration: Sendable {
    static let standard = WorkspaceSearchConfiguration()

    let globMaximumResults: Int
    let grepMaximumMatches: Int
    let grepMaximumLineBytes: Int
    let maximumInlineBytes: Int
    let maximumRawOutputBytes: Int
    let maximumFilesVisited: Int
    let maximumFileBytes: Int64
    let timeoutSeconds: TimeInterval

    init(
        globMaximumResults: Int = 100,
        grepMaximumMatches: Int = 250,
        grepMaximumLineBytes: Int = 2_000,
        maximumInlineBytes: Int = 56 * 1_024,
        maximumRawOutputBytes: Int = 12 * 1_024 * 1_024,
        maximumFilesVisited: Int = 20_000,
        maximumFileBytes: Int64 = Int64(WorkspaceFileSystemProvider.maximumTextBytes),
        timeoutSeconds: TimeInterval = 30
    ) {
        precondition(globMaximumResults > 0)
        precondition(grepMaximumMatches > 0)
        precondition(grepMaximumLineBytes > 0)
        precondition(maximumInlineBytes > 0)
        precondition(maximumRawOutputBytes > 0)
        precondition(maximumFilesVisited > 0)
        precondition(maximumFileBytes > 0)
        precondition(timeoutSeconds.isFinite && timeoutSeconds > 0)
        self.globMaximumResults = globMaximumResults
        self.grepMaximumMatches = grepMaximumMatches
        self.grepMaximumLineBytes = grepMaximumLineBytes
        self.maximumInlineBytes = maximumInlineBytes
        self.maximumRawOutputBytes = maximumRawOutputBytes
        self.maximumFilesVisited = maximumFilesVisited
        self.maximumFileBytes = maximumFileBytes
        self.timeoutSeconds = timeoutSeconds
    }
}

enum HarnessSearchErrorCode: String, Sendable, Equatable {
    case invalidPattern = "SEARCH_INVALID_PATTERN"
    case failed = "SEARCH_FAILED"
    case rawOutputOverflow = "SEARCH_RAW_OUTPUT_OVERFLOW"
    case aborted = "SEARCH_ABORTED"
}

struct HarnessSearchError: LocalizedError, Sendable, Equatable {
    let code: HarnessSearchErrorCode
    let message: String

    var errorDescription: String? {
        "\(code.rawValue): \(message)"
    }
}

struct WorkspaceGlobTool: LocalAgentTool {
    let environment: FileSystemToolEnvironment
    let configuration: WorkspaceSearchConfiguration

    let definition = ModelToolDefinition(
        name: "glob",
        description: "Find files in the protected on-device workspace whose paths match a glob pattern. Hidden files are included, VCS metadata directories are excluded, and a capped result reports a readable workspace file containing the complete sorted list.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Glob pattern such as **/*.swift. A pattern without a slash matches basenames at any depth.")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Optional workspace directory. Defaults to /workspace.")
                ])
            ]),
            "required": .array([.string("pattern")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["pattern", "path"])
        let pattern = try arguments.requiredString("pattern", maximumUTF8Bytes: 4 * 1_024)
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalToolError.invalidArguments
        }
        if let path = arguments["path"]?.stringValue,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.utf8.count > 4 * 1_024 {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "查找文件：\(String((arguments["pattern"]?.stringValue ?? "").prefix(96)))"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs-search:\(arguments["path"]?.stringValue ?? "/workspace")"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workspace:search:\(arguments["path"]?.stringValue ?? "/workspace")"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let pattern = try arguments.requiredString("pattern", maximumUTF8Bytes: 4 * 1_024)
        let path = arguments["path"]?.stringValue ?? "/workspace"
        do {
            let engine = WorkspaceSearchEngine(
                fileSystem: environment.fileSystem,
                configuration: configuration
            )
            let paths = try await engine.glob(pattern: pattern, path: path)
            return try await WorkspaceSearchOutput.glob(
                paths: paths,
                fileSystem: environment.fileSystem,
                configuration: configuration
            )
        } catch is CancellationError {
            throw HarnessSearchError(code: .aborted, message: "glob was cancelled before completion")
        }
    }
}

struct WorkspaceGrepTool: LocalAgentTool {
    let environment: FileSystemToolEnvironment
    let configuration: WorkspaceSearchConfiguration

    let definition = ModelToolDefinition(
        name: "grep",
        description: "Search protected on-device workspace text files with a regular expression. Returns matching lines with line numbers, grouped by file. Hidden paths are skipped unless the requested path itself is hidden. A capped result reports a readable workspace file containing the complete result.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string("Regular expression to search for.")
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Optional workspace file or directory. Defaults to /workspace.")
                ]),
                "include": .object([
                    "type": .string("string"),
                    "description": .string("One positive glob filter, for example *.swift or *.{js,jsx}.")
                ])
            ]),
            "required": .array([.string("pattern")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["pattern", "path", "include"])
        let pattern = try arguments.requiredString("pattern", maximumUTF8Bytes: 4 * 1_024)
        guard !pattern.isEmpty else { throw LocalToolError.invalidArguments }
        if let path = arguments["path"]?.stringValue,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.utf8.count > 4 * 1_024 {
            throw LocalToolError.invalidArguments
        }
        if let include = arguments["include"]?.stringValue {
            guard try WorkspaceGlobPattern.isValidPositiveSingleGlob(include) else {
                throw LocalToolError.invalidArguments
            }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "正则搜索：\(String((arguments["pattern"]?.stringValue ?? "").prefix(96)))"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool { true }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["fs-search:\(arguments["path"]?.stringValue ?? "/workspace")"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workspace:search:\(arguments["path"]?.stringValue ?? "/workspace")"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let pattern = try arguments.requiredString("pattern", maximumUTF8Bytes: 4 * 1_024)
        let path = arguments["path"]?.stringValue ?? "/workspace"
        let include = arguments["include"]?.stringValue
        do {
            let engine = WorkspaceSearchEngine(
                fileSystem: environment.fileSystem,
                configuration: configuration
            )
            let matches = try await engine.grep(pattern: pattern, path: path, include: include)
            return try await WorkspaceSearchOutput.grep(
                matches: matches,
                fileSystem: environment.fileSystem,
                configuration: configuration
            )
        } catch is CancellationError {
            throw HarnessSearchError(code: .aborted, message: "grep was cancelled before completion")
        }
    }
}

struct WorkspaceGrepMatch: Sendable, Equatable {
    let path: String
    let lineNumber: Int
    let line: String
}

private struct WorkspaceSearchFile: Sendable {
    let target: HarnessFsTarget
    let relativePath: String
    let modifiedAt: Date?
}

private struct WorkspaceSearchBudget {
    let toolName: String
    let startedAt = Date()
    let timeoutSeconds: TimeInterval

    func check() throws {
        if Task.isCancelled {
            throw HarnessSearchError(
                code: .aborted,
                message: "\(toolName) was cancelled before completion"
            )
        }
        if Date().timeIntervalSince(startedAt) >= timeoutSeconds {
            throw HarnessSearchError(
                code: .aborted,
                message: "\(toolName) timed out after \(timeoutSeconds) seconds"
            )
        }
    }
}

private struct WorkspaceSearchEngine {
    private static let vcsDirectories = Set([".git", ".svn", ".hg", ".bzr", ".jj", ".sl"])

    let fileSystem: any HarnessFileSystem
    let configuration: WorkspaceSearchConfiguration

    func glob(pattern: String, path: String) async throws -> [String] {
        let matcher: WorkspaceGlobPattern
        do {
            matcher = try WorkspaceGlobPattern(pattern)
        } catch {
            throw HarnessSearchError(
                code: .invalidPattern,
                message: "glob pattern is invalid: \(error.localizedDescription)"
            )
        }
        let budget = WorkspaceSearchBudget(toolName: "glob", timeoutSeconds: configuration.timeoutSeconds)
        do {
            let files = try await walkFiles(path: path, includeHidden: true, budget: budget)
            var matches: [WorkspaceSearchFile] = []
            var rawBytes = 0
            for file in files where matcher.matches(file.relativePath) {
                try budget.check()
                rawBytes += file.target.displayPath.utf8.count + 1
                guard rawBytes <= configuration.maximumRawOutputBytes else {
                    throw overflow(toolName: "glob")
                }
                matches.append(file)
            }
            return matches.sorted {
                let left = $0.modifiedAt ?? .distantPast
                let right = $1.modifiedAt ?? .distantPast
                if left != right { return left > right }
                return $0.target.displayPath < $1.target.displayPath
            }.map(\.target.displayPath)
        } catch is CancellationError {
            throw HarnessSearchError(code: .aborted, message: "glob was cancelled before completion")
        }
    }

    func grep(pattern: String, path: String, include: String?) async throws -> [WorkspaceGrepMatch] {
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            throw HarnessSearchError(
                code: .invalidPattern,
                message: "grep pattern is invalid: \(error.localizedDescription)"
            )
        }
        let includeMatcher: WorkspaceGlobPattern?
        do {
            includeMatcher = try include.map(WorkspaceGlobPattern.init)
        } catch {
            throw HarnessSearchError(
                code: .invalidPattern,
                message: "grep include glob is invalid: \(error.localizedDescription)"
            )
        }
        let budget = WorkspaceSearchBudget(toolName: "grep", timeoutSeconds: configuration.timeoutSeconds)
        do {
            let files = try await walkFiles(path: path, includeHidden: false, budget: budget)
            var matches: [WorkspaceGrepMatch] = []
            var rawBytes = 0
            for file in files {
                try budget.check()
                if let includeMatcher, !includeMatcher.matches(file.relativePath) { continue }
                let text: String
                do {
                    text = try await fileSystem.readText(file.target)
                } catch let error as HarnessFsError
                    where error.code == .notText || error.code == .tooLarge || error.code == .notRegularFile {
                    continue
                }
                try budget.check()
                // Ripgrep's default text search does not emit line matches from
                // a NUL-bearing file. Invalid UTF-8 was already rejected above.
                if text.unicodeScalars.contains(where: { $0.value == 0 }) { continue }
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                if text.hasSuffix("\n"), lines.last?.isEmpty == true { lines.removeLast() }
                if lines.isEmpty { lines = [""] }
                for (index, line) in lines.enumerated() {
                    try budget.check()
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    guard expression.firstMatch(in: line, range: range) != nil else { continue }
                    let match = WorkspaceGrepMatch(
                        path: file.target.displayPath,
                        lineNumber: index + 1,
                        line: line
                    )
                    rawBytes += match.path.utf8.count + match.line.utf8.count + 40
                    guard rawBytes <= configuration.maximumRawOutputBytes else {
                        throw overflow(toolName: "grep")
                    }
                    matches.append(match)
                }
            }
            return matches
        } catch is CancellationError {
            throw HarnessSearchError(code: .aborted, message: "grep was cancelled before completion")
        }
    }

    private func walkFiles(
        path: String,
        includeHidden: Bool,
        budget: WorkspaceSearchBudget
    ) async throws -> [WorkspaceSearchFile] {
        let root = try await fileSystem.resolve(path, cwd: "/workspace")
        guard let rootInfo = try await fileSystem.stat(root) else {
            throw HarnessFsError(code: .notFound, message: "cannot search \(root.displayPath): not found")
        }
        if rootInfo.type == .file {
            return [WorkspaceSearchFile(target: root, relativePath: root.displayPath.split(separator: "/").last.map(String.init) ?? root.displayPath, modifiedAt: nil)]
        }
        guard rootInfo.type == .directory else {
            throw HarnessFsError(code: .notDirectory, message: "cannot search \(root.displayPath): not a directory or regular file")
        }

        var files: [WorkspaceSearchFile] = []
        var pending: [(target: HarnessFsTarget, relativePrefix: String)] = [(root, "")]
        var visited = 0
        while let current = pending.popLast() {
            try budget.check()
            visited += 1
            guard visited <= configuration.maximumFilesVisited else {
                throw HarnessSearchError(
                    code: .rawOutputOverflow,
                    message: "\(budget.toolName) visited more than \(configuration.maximumFilesVisited) paths; narrow path or pattern and retry"
                )
            }
            let entries = try await fileSystem.listDirectory(current.target)
            for entry in entries.reversed() {
                try budget.check()
                if Self.vcsDirectories.contains(entry.name), entry.type == .directory { continue }
                if !includeHidden, entry.name.hasPrefix(".") { continue }
                let relative = current.relativePrefix.isEmpty
                    ? entry.name
                    : "\(current.relativePrefix)/\(entry.name)"
                switch entry.type {
                case .directory:
                    pending.append((entry.target, relative))
                case .file:
                    if let size = entry.size, size > configuration.maximumFileBytes { continue }
                    files.append(WorkspaceSearchFile(
                        target: entry.target,
                        relativePath: relative,
                        modifiedAt: entry.modifiedAt
                    ))
                case .other:
                    continue
                }
            }
        }
        return files
    }

    private func overflow(toolName: String) -> HarnessSearchError {
        HarnessSearchError(
            code: .rawOutputOverflow,
            message: "\(toolName) produced more than \(configuration.maximumRawOutputBytes) bytes of result data; narrow pattern, path, or include and retry"
        )
    }
}

private struct WorkspaceGlobPattern {
    private let expressions: [NSRegularExpression]
    private let matchesBasename: Bool

    init(_ pattern: String) throws {
        let expanded = try Self.expandBraces(pattern)
        guard !expanded.isEmpty, expanded.count <= 64 else {
            throw HarnessSearchError(code: .invalidPattern, message: "glob expands to too many alternatives")
        }
        self.expressions = try expanded.map {
            try NSRegularExpression(pattern: "^\(Self.regexBody(for: $0))$")
        }
        self.matchesBasename = !pattern.contains("/")
    }

    func matches(_ relativePath: String) -> Bool {
        let candidate = matchesBasename
            ? relativePath.split(separator: "/").last.map(String.init) ?? relativePath
            : relativePath
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return expressions.contains { $0.firstMatch(in: candidate, range: range) != nil }
    }

    static func isValidPositiveSingleGlob(_ pattern: String) throws -> Bool {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !pattern.hasPrefix("!") else { return false }
        var depth = 0
        for character in pattern {
            if character == "{" { depth += 1 }
            else if character == "}" { depth = max(0, depth - 1) }
            else if character == ",", depth == 0 { return false }
        }
        _ = try WorkspaceGlobPattern(pattern)
        return true
    }

    private static func regexBody(for pattern: String) -> String {
        let characters = Array(pattern)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    while index + 1 < characters.count, characters[index + 1] == "*" { index += 1 }
                    if index + 1 < characters.count, characters[index + 1] == "/" {
                        result += "(?:.*/)?"
                        index += 1
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case "[":
                if let end = characters[(index + 1)...].firstIndex(of: "]") {
                    var contents = String(characters[(index + 1)..<end])
                    if contents.hasPrefix("!") { contents = "^" + contents.dropFirst() }
                    result += "[\(contents)]"
                    index = end
                } else {
                    result += "\\["
                }
            case "\\":
                if index + 1 < characters.count {
                    index += 1
                    result += NSRegularExpression.escapedPattern(for: String(characters[index]))
                } else {
                    result += "\\\\"
                }
            default:
                result += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return result
    }

    private static func expandBraces(_ pattern: String) throws -> [String] {
        let characters = Array(pattern)
        guard let open = characters.firstIndex(of: "{") else { return [pattern] }
        var depth = 0
        var close: Int?
        for index in open..<characters.count {
            if characters[index] == "{" { depth += 1 }
            if characters[index] == "}" {
                depth -= 1
                if depth == 0 {
                    close = index
                    break
                }
            }
        }
        guard let close else { return [pattern] }
        let inside = characters[(open + 1)..<close]
        var alternatives: [String] = []
        var segment = ""
        depth = 0
        for character in inside {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == ",", depth == 0 {
                alternatives.append(segment)
                segment = ""
            } else {
                segment.append(character)
            }
        }
        alternatives.append(segment)
        guard alternatives.count > 1 else { return [pattern] }
        let prefix = String(characters[..<open])
        let suffix = String(characters[(close + 1)...])
        var result: [String] = []
        for alternative in alternatives {
            result.append(contentsOf: try expandBraces(prefix + alternative + suffix))
            guard result.count <= 64 else {
                throw HarnessSearchError(code: .invalidPattern, message: "glob expands to too many alternatives")
            }
        }
        return result
    }
}

private enum WorkspaceSearchOutput {
    static func glob(
        paths: [String],
        fileSystem: any HarnessFileSystem,
        configuration: WorkspaceSearchConfiguration
    ) async throws -> String {
        guard !paths.isEmpty else { return "No files found" }
        let full = paths.joined(separator: "\n")
        let needsSpill = paths.count > configuration.globMaximumResults
            || full.utf8.count > configuration.maximumInlineBytes
        guard needsSpill else { return full }
        let spill = try? await ToolResultSpillStore(
            fileSystem: fileSystem,
            maximumBytes: configuration.maximumRawOutputBytes
        ).save(full, suggestedName: "glob-results.txt")
        let recovery = recoveryText(kind: "sorted result", spill: spill)
        var shown: [String] = []
        for path in paths.prefix(configuration.globMaximumResults) {
            let candidate = shown + [path]
            let footer = "(Showing \(candidate.count) of \(paths.count) paths. \(recovery))"
            if (candidate.joined(separator: "\n") + "\n\n" + footer).utf8.count
                > configuration.maximumInlineBytes { break }
            shown = candidate
        }
        let footer = "(Showing \(shown.count) of \(paths.count) paths. \(recovery))"
        return boundedJoin(body: shown.joined(separator: "\n"), footer: footer, maximumBytes: configuration.maximumInlineBytes)
    }

    static func grep(
        matches: [WorkspaceGrepMatch],
        fileSystem: any HarnessFileSystem,
        configuration: WorkspaceSearchConfiguration
    ) async throws -> String {
        guard !matches.isEmpty else { return "No matches found" }
        let full = "Found \(matches.count) \(matches.count == 1 ? "match" : "matches")\n\n" + formatGrep(matches)
        let retained = Array(matches.prefix(configuration.grepMaximumMatches)).map {
            WorkspaceGrepMatch(
                path: $0.path,
                lineNumber: $0.lineNumber,
                line: previewLine($0.line, maximumBytes: configuration.grepMaximumLineBytes)
            )
        }
        let inline = "Found \(matches.count) \(matches.count == 1 ? "match" : "matches")\n\n" + formatGrep(retained)
        let previewsChanged = zip(retained, matches).contains { pair in
            pair.0.line != pair.1.line
        }
        let needsSpill = retained.count < matches.count
            || previewsChanged
            || inline.utf8.count > configuration.maximumInlineBytes
        guard needsSpill else { return inline }
        let spill = try? await ToolResultSpillStore(
            fileSystem: fileSystem,
            maximumBytes: configuration.maximumRawOutputBytes
        ).save(full, suggestedName: "grep-results.txt")
        let recovery = recoveryText(kind: "grep result", spill: spill)
        var shown: [WorkspaceGrepMatch] = []
        for match in retained {
            let candidate = shown + [match]
            let header = "Found \(candidate.count) of \(matches.count) matches"
            let body = header + "\n\n" + formatGrep(candidate)
            let footer = "(\(recovery))"
            guard (body + "\n\n" + footer).utf8.count <= configuration.maximumInlineBytes else {
                break
            }
            shown = candidate
        }
        let header = "Found \(shown.count) of \(matches.count) matches"
        let body = shown.isEmpty ? header : header + "\n\n" + formatGrep(shown)
        return boundedJoin(
            body: body,
            footer: "(\(recovery))",
            maximumBytes: configuration.maximumInlineBytes
        )
    }

    private static func formatGrep(_ matches: [WorkspaceGrepMatch]) -> String {
        var order: [String] = []
        var groups: [String: [WorkspaceGrepMatch]] = [:]
        for match in matches {
            if groups[match.path] == nil { order.append(match.path) }
            groups[match.path, default: []].append(match)
        }
        return order.map { path in
            let lines = groups[path, default: []].map { "Line \($0.lineNumber): \($0.line)" }
            return ([path] + lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func recoveryText(kind: String, spill: ToolResultSpillReference?) -> String {
        guard let spill else {
            return "The complete result could not be saved; narrow pattern, path, or include to see more."
        }
        return "Full \(kind) stored at: \(spill.locator) (\(spill.bytes) bytes). Use read with this path to inspect it."
    }

    private static func boundedJoin(body: String, footer: String, maximumBytes: Int) -> String {
        let separator = body.isEmpty ? "" : "\n\n"
        let reserved = separator.utf8.count + footer.utf8.count
        guard reserved <= maximumBytes else {
            return utf8Prefix(footer, maximumBytes: maximumBytes)
        }
        return utf8Prefix(body, maximumBytes: maximumBytes - reserved) + separator + footer
    }

    private static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            guard used + value.utf8.count <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
            used += value.utf8.count
        }
        return result
    }

    private static func previewLine(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let marker = " (line truncated)"
        guard marker.utf8.count < maximumBytes else {
            return utf8Prefix(text, maximumBytes: maximumBytes)
        }
        return utf8Prefix(text, maximumBytes: maximumBytes - marker.utf8.count) + marker
    }
}
