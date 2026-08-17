import Foundation

enum NativeToolEventPresentation: Equatable, Sendable {
    case workspaceRead(NativeWorkspaceReadPresentation)
    case workspaceWrite(NativeWorkspaceWritePresentation)
    case workspaceFiles(NativeWorkspaceFilesPresentation)
    case workItems(NativeWorkItemsPresentation)
    case terminal(NativeTerminalPresentation)
    case generic

    var terminalExitCode: Int? {
        guard case let .terminal(terminal) = self else { return nil }
        return terminal.exitCode
    }

    static func derive(for event: AgentToolEvent) -> NativeToolEventPresentation {
        derive(
            name: event.name,
            arguments: event.arguments,
            result: event.result,
            output: event.output,
            status: event.status
        )
    }

    static func derive(
        name: String,
        arguments: String,
        result: String?,
        output: [AgentToolOutputChunk] = [],
        status: AgentToolEventStatus = .succeeded
    ) -> NativeToolEventPresentation {
        switch name {
        case "workspace_read_text":
            return workspaceRead(arguments: arguments, result: result)
        case "workspace_write_text":
            return workspaceWrite(arguments: arguments)
        case "workspace_list_files":
            return workspaceFiles(result: result)
        case "work_state_replace_todos":
            return workItems(
                kind: .todos,
                argumentKey: "items",
                resultKey: "todos",
                arguments: arguments,
                result: result,
                status: status
            )
        case "work_state_replace_plan":
            return workItems(
                kind: .plan,
                argumentKey: "steps",
                resultKey: "plan",
                arguments: arguments,
                result: result,
                status: status
            )
        case "shell_execute":
            return terminal(
                arguments: arguments,
                result: result,
                output: output,
                status: status
            )
        case "ios_native":
            return nativeOffloadTerminal(
                arguments: arguments,
                result: result,
                output: output,
                status: status
            )
        default:
            return .generic
        }
    }
}

struct NativeToolTextLine: Identifiable, Equatable, Sendable {
    let number: Int
    let text: String
    let isTruncated: Bool

    var id: Int { number }
}

struct NativeWorkspaceReadPresentation: Equatable, Sendable {
    let path: String
    let lines: [NativeToolTextLine]
    let totalLines: Int
    let previewTruncated: Bool
    let languageHint: String?
}

struct NativeWorkspaceWritePresentation: Equatable, Sendable {
    let path: String
    let lines: [NativeToolTextLine]
    let totalLines: Int
    let previewTruncated: Bool
    let byteCount: Int
    let languageHint: String?
}

struct NativeWorkspaceFilePresentation: Identifiable, Equatable, Sendable {
    let path: String
    let size: Int64

    var id: String { path }
}

struct NativeWorkspaceFilesPresentation: Equatable, Sendable {
    let files: [NativeWorkspaceFilePresentation]
}

enum NativeWorkItemsKind: String, Equatable, Sendable {
    case todos
    case plan
}

struct NativeWorkItemPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: ConversationItemStatus
}

struct NativeWorkItemsPresentation: Equatable, Sendable {
    let kind: NativeWorkItemsKind
    let items: [NativeWorkItemPresentation]

    var completedCount: Int {
        items.count { $0.status == .completed }
    }

    var activeItems: [NativeWorkItemPresentation] {
        items.filter { $0.status == .active }
    }
}

struct NativeTerminalSegment: Identifiable, Equatable, Sendable {
    let id: Int
    let channel: AgentToolOutputChannel
    let text: String
}

struct NativeTerminalLine: Identifiable, Equatable, Sendable {
    let number: Int
    let segments: [NativeTerminalSegment]
    let isTruncated: Bool

    var id: Int { number }
}

struct NativeTerminalPresentation: Equatable, Sendable {
    let commandLines: [NativeToolTextLine]
    let commandTotalLines: Int
    let commandPreviewTruncated: Bool
    let timeoutSeconds: Int?
    let outputLines: [NativeTerminalLine]
    let totalOutputLines: Int
    let outputPreviewTruncated: Bool
    let exitCode: Int?
    let processID: Int?
    let durationMilliseconds: Int?
    let isRunning: Bool
    let status: AgentToolEventStatus

    var firstCommandLine: String {
        commandLines.first?.text ?? ""
    }

    var failedExit: Bool {
        guard !isRunning, let exitCode else { return false }
        return exitCode != 0
    }
}

private extension NativeToolEventPresentation {
    static let maximumJSONBytes = 256 * 1_024
    static let maximumPreviewLines = 256
    static let maximumPreviewLineBytes = 4 * 1_024

    static func workspaceRead(
        arguments: String,
        result: String?
    ) -> NativeToolEventPresentation {
        guard let arguments = jsonObject(arguments),
              let path = boundedString(arguments["path"], maximumBytes: 512),
              let result else {
            return .generic
        }
        let projection = textProjection(result)
        return .workspaceRead(
            NativeWorkspaceReadPresentation(
                path: path,
                lines: projection.lines,
                totalLines: projection.totalLines,
                previewTruncated: projection.isTruncated,
                languageHint: languageHint(for: path)
            )
        )
    }

    static func workspaceWrite(arguments: String) -> NativeToolEventPresentation {
        guard let arguments = jsonObject(arguments),
              let path = boundedString(arguments["path"], maximumBytes: 512),
              let text = boundedString(
                arguments["text"],
                maximumBytes: 60 * 1_024,
                allowEmpty: true
              ) else {
            return .generic
        }
        let projection = textProjection(text)
        return .workspaceWrite(
            NativeWorkspaceWritePresentation(
                path: path,
                lines: projection.lines,
                totalLines: projection.totalLines,
                previewTruncated: projection.isTruncated,
                byteCount: text.utf8.count,
                languageHint: languageHint(for: path)
            )
        )
    }

    static func workspaceFiles(result: String?) -> NativeToolEventPresentation {
        guard let result,
              let value = jsonValue(result),
              case let .array(entries) = value,
              entries.count <= 200 else {
            return .generic
        }

        var paths = Set<String>()
        var files: [NativeWorkspaceFilePresentation] = []
        files.reserveCapacity(entries.count)
        for entry in entries {
            guard case let .object(object) = entry,
                  let path = boundedString(object["path"], maximumBytes: 1_024),
                  paths.insert(path).inserted,
                  let size = nonnegativeInt64(object["size"]) else {
                return .generic
            }
            files.append(NativeWorkspaceFilePresentation(path: path, size: size))
        }
        return .workspaceFiles(NativeWorkspaceFilesPresentation(files: files))
    }

    static func workItems(
        kind: NativeWorkItemsKind,
        argumentKey: String,
        resultKey: String,
        arguments: String,
        result: String?,
        status: AgentToolEventStatus
    ) -> NativeToolEventPresentation {
        guard let argumentObject = jsonObject(arguments),
              let intended = parseWorkItems(argumentObject[argumentKey], source: kind.rawValue) else {
            return .generic
        }

        var items = intended
        if status == .succeeded,
           let result,
           let resultObject = jsonObject(result),
           let settled = parseWorkItems(resultObject[resultKey], source: "settled-\(kind.rawValue)") {
            items = settled
        }
        return .workItems(NativeWorkItemsPresentation(kind: kind, items: items))
    }

    static func terminal(
        arguments: String,
        result: String?,
        output: [AgentToolOutputChunk],
        status: AgentToolEventStatus
    ) -> NativeToolEventPresentation {
        guard let arguments = jsonObject(arguments),
              let command = boundedString(arguments["command"], maximumBytes: 64 * 1_024) else {
            return .generic
        }

        let resultObject = result.flatMap(jsonObject)
        let exitCode = integer(resultObject?["exit_code"], range: 0...Int(Int32.max))
        let processID = integer(resultObject?["pid"], range: 1...Int(Int32.max))
        let duration = integer(resultObject?["duration_ms"], range: 0...Int(Int32.max))
        let timeout = integer(arguments["timeout_seconds"], range: 1...3_600)

        var terminalChunks = output.map {
            NativeTerminalChunk(channel: $0.channel, text: $0.text)
        }
        if terminalChunks.allSatisfy({ $0.text.isEmpty }), let resultObject {
            terminalChunks.removeAll(keepingCapacity: true)
            if let stdout = boundedString(
                resultObject["stdout"],
                maximumBytes: 56 * 1_024,
                allowEmpty: true
            ), !stdout.isEmpty {
                terminalChunks.append(NativeTerminalChunk(channel: .stdout, text: stdout))
            }
            if let stderr = boundedString(
                resultObject["stderr"],
                maximumBytes: 56 * 1_024,
                allowEmpty: true
            ), !stderr.isEmpty {
                terminalChunks.append(NativeTerminalChunk(channel: .stderr, text: stderr))
            }
        }

        let commandProjection = textProjection(command, maximumStoredLines: 32)
        let outputProjection = terminalProjection(terminalChunks)
        let isRunning = status == .pending || status == .awaitingApproval || status == .running
        return .terminal(
            NativeTerminalPresentation(
                commandLines: commandProjection.lines,
                commandTotalLines: commandProjection.totalLines,
                commandPreviewTruncated: commandProjection.isTruncated,
                timeoutSeconds: timeout,
                outputLines: outputProjection.lines,
                totalOutputLines: outputProjection.totalLines,
                outputPreviewTruncated: outputProjection.isTruncated,
                exitCode: exitCode,
                processID: processID,
                durationMilliseconds: duration,
                isRunning: isRunning,
                status: status
            )
        )
    }

    static func nativeOffloadTerminal(
        arguments: String,
        result: String?,
        output: [AgentToolOutputChunk],
        status: AgentToolEventStatus
    ) -> NativeToolEventPresentation {
        guard let object = jsonObject(arguments),
              let command = boundedString(object["command"], maximumBytes: 64),
              IOSNativeOffloadTool.allowedCommands.contains(command) else {
            return .generic
        }
        let rawArguments: [String]
        if let value = object["arguments"] {
            guard case let .array(values) = value, values.count <= 64 else {
                return .generic
            }
            var parsed: [String] = []
            parsed.reserveCapacity(values.count)
            for value in values {
                guard let argument = boundedString(value, maximumBytes: 2_048, allowEmpty: true) else {
                    return .generic
                }
                parsed.append(argument)
            }
            rawArguments = parsed
        } else {
            rawArguments = []
        }

        var terminalArguments: [String: JSONValue] = [
            "command": .string(
                ([command] + rawArguments)
                    .map(displayCommandToken)
                    .joined(separator: " ")
            )
        ]
        if let timeout = object["timeout_seconds"] {
            terminalArguments["timeout_seconds"] = timeout
        }
        return terminal(
            arguments: JSONValue.object(terminalArguments).displayText,
            result: result,
            output: output,
            status: status
        )
    }

    static func displayCommandToken(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { character in
            character.isWhitespace || "'\"\\$`;&|<>()".contains(character)
        }
        guard needsQuotes else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    static func parseWorkItems(
        _ value: JSONValue?,
        source: String
    ) -> [NativeWorkItemPresentation]? {
        guard case let .array(values) = value, values.count <= 32 else { return nil }
        var items: [NativeWorkItemPresentation] = []
        items.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            guard case let .object(object) = value,
                  let title = boundedString(object["title"], maximumBytes: 512),
                  let rawStatus = object["status"]?.stringValue,
                  let status = ConversationItemStatus(rawValue: rawStatus) else {
                return nil
            }
            let suppliedID = object["id"]?.stringValue.flatMap(UUID.init(uuidString:))
            items.append(
                NativeWorkItemPresentation(
                    id: suppliedID?.uuidString.lowercased() ?? "\(source):\(index)",
                    title: title,
                    status: status
                )
            )
        }
        return items
    }

    static func jsonObject(_ text: String) -> [String: JSONValue]? {
        guard let value = jsonValue(text), case let .object(object) = value else { return nil }
        return object
    }

    static func jsonValue(_ text: String) -> JSONValue? {
        guard !text.isEmpty, text.utf8.count <= maximumJSONBytes else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    static func boundedString(
        _ value: JSONValue?,
        maximumBytes: Int,
        allowEmpty: Bool = false
    ) -> String? {
        guard let string = value?.stringValue,
              string.utf8.count <= maximumBytes,
              allowEmpty || !string.isEmpty else {
            return nil
        }
        return string
    }

    static func integer(_ value: JSONValue?, range: ClosedRange<Int>) -> Int? {
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= Double(range.lowerBound),
              number <= Double(range.upperBound) else {
            return nil
        }
        return Int(number)
    }

    static func nonnegativeInt64(_ value: JSONValue?) -> Int64? {
        let largestExactlyRepresentableInteger = 9_007_199_254_740_991.0
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded() == number,
              number >= 0,
              number <= largestExactlyRepresentableInteger else {
            return nil
        }
        return Int64(number)
    }

    static func languageHint(for path: String) -> String? {
        let value = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !value.isEmpty, value.utf8.count <= 16 else { return nil }
        return value
    }

    static func textProjection(
        _ text: String,
        maximumStoredLines: Int = maximumPreviewLines
    ) -> NativeTextProjection {
        let headLimit = max(1, maximumStoredLines / 2)
        let tailLimit = max(0, maximumStoredLines - headLimit)
        var head: [NativeToolTextLine] = []
        head.reserveCapacity(headLimit)
        var tail = [NativeToolTextLine?](repeating: nil, count: tailLimit)
        var tailCount = 0
        var tailCursor = 0
        var totalLines = 0
        var anyLineTruncated = false
        var current = ""
        current.reserveCapacity(128)
        var currentBytes = 0
        var currentTruncated = false
        var sawScalar = false
        var endedWithNewline = false

        func storeCurrentLine() {
            if current.last == "\r" {
                current.removeLast()
            }
            totalLines += 1
            let line = NativeToolTextLine(
                number: totalLines,
                text: current,
                isTruncated: currentTruncated
            )
            anyLineTruncated = anyLineTruncated || currentTruncated
            if head.count < headLimit {
                head.append(line)
            } else if tailLimit > 0 {
                tail[tailCursor] = line
                tailCursor = (tailCursor + 1) % tailLimit
                tailCount = min(tailCount + 1, tailLimit)
            }
            current = ""
            current.reserveCapacity(128)
            currentBytes = 0
            currentTruncated = false
        }

        for scalar in text.unicodeScalars {
            sawScalar = true
            if scalar == "\n" {
                storeCurrentLine()
                endedWithNewline = true
                continue
            }
            endedWithNewline = false
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            if currentBytes + bytes <= maximumPreviewLineBytes {
                current.unicodeScalars.append(scalar)
                currentBytes += bytes
            } else {
                currentTruncated = true
            }
        }
        if sawScalar, !endedWithNewline {
            storeCurrentLine()
        }

        let orderedTail: [NativeToolTextLine]
        if tailCount == 0 {
            orderedTail = []
        } else if tailCount < tailLimit {
            orderedTail = tail.prefix(tailCount).compactMap { $0 }
        } else {
            orderedTail = (0..<tailCount).compactMap { offset in
                tail[(tailCursor + offset) % tailLimit]
            }
        }
        let lines = head + orderedTail
        return NativeTextProjection(
            lines: lines,
            totalLines: totalLines,
            isTruncated: anyLineTruncated || lines.count < totalLines
        )
    }

    static func terminalProjection(
        _ chunks: [NativeTerminalChunk]
    ) -> NativeTerminalProjection {
        let headLimit = maximumPreviewLines / 2
        let tailLimit = maximumPreviewLines - headLimit
        var head: [NativeTerminalLine] = []
        head.reserveCapacity(headLimit)
        var tail = [NativeTerminalLine?](repeating: nil, count: tailLimit)
        var tailCount = 0
        var tailCursor = 0
        var totalLines = 0
        var anyLineTruncated = false
        var segments: [NativeTerminalSegment] = []
        var currentBytes = 0
        var currentTruncated = false
        var sawScalar = false
        var endedWithNewline = false

        func storeCurrentLine() {
            totalLines += 1
            let line = NativeTerminalLine(
                number: totalLines,
                segments: segments,
                isTruncated: currentTruncated
            )
            anyLineTruncated = anyLineTruncated || currentTruncated
            if head.count < headLimit {
                head.append(line)
            } else {
                tail[tailCursor] = line
                tailCursor = (tailCursor + 1) % tailLimit
                tailCount = min(tailCount + 1, tailLimit)
            }
            segments = []
            currentBytes = 0
            currentTruncated = false
        }

        func append(_ scalar: UnicodeScalar, channel: AgentToolOutputChannel) {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard currentBytes + bytes <= maximumPreviewLineBytes else {
                currentTruncated = true
                return
            }
            currentBytes += bytes
            if let lastIndex = segments.indices.last,
               segments[lastIndex].channel == channel {
                let previous = segments[lastIndex]
                segments[lastIndex] = NativeTerminalSegment(
                    id: previous.id,
                    channel: previous.channel,
                    text: previous.text + fragment
                )
            } else {
                segments.append(
                    NativeTerminalSegment(
                        id: segments.count,
                        channel: channel,
                        text: fragment
                    )
                )
            }
        }

        for chunk in chunks where !chunk.text.isEmpty {
            for scalar in chunk.text.unicodeScalars {
                sawScalar = true
                if scalar == "\n" {
                    storeCurrentLine()
                    endedWithNewline = true
                } else if scalar == "\r" {
                    continue
                } else {
                    endedWithNewline = false
                    append(scalar, channel: chunk.channel)
                }
            }
        }
        if sawScalar, !endedWithNewline {
            storeCurrentLine()
        }

        let orderedTail: [NativeTerminalLine]
        if tailCount == 0 {
            orderedTail = []
        } else if tailCount < tailLimit {
            orderedTail = tail.prefix(tailCount).compactMap { $0 }
        } else {
            orderedTail = (0..<tailCount).compactMap { offset in
                tail[(tailCursor + offset) % tailLimit]
            }
        }
        let lines = head + orderedTail
        return NativeTerminalProjection(
            lines: lines,
            totalLines: totalLines,
            isTruncated: anyLineTruncated || lines.count < totalLines
        )
    }
}

private struct NativeTextProjection {
    let lines: [NativeToolTextLine]
    let totalLines: Int
    let isTruncated: Bool
}

private struct NativeTerminalChunk {
    let channel: AgentToolOutputChannel
    let text: String
}

private struct NativeTerminalProjection {
    let lines: [NativeTerminalLine]
    let totalLines: Int
    let isTruncated: Bool
}
