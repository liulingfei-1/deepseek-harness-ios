import Foundation

enum NativeSearchKind: String, Equatable, Sendable {
    case workspace
    case glob
    case grep
}

struct NativeSearchMatchPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let line: Int?
    let excerpt: String?
}

struct NativeSearchPresentation: Equatable, Sendable {
    let kind: NativeSearchKind
    let query: String
    let root: String?
    let matches: [NativeSearchMatchPresentation]
    let totalCount: Int
    let filesVisited: Int?
    let truncated: Bool
    let spillLocator: String?
}

enum NativeWebKind: String, Equatable, Sendable {
    case search
    case fetch
}

struct NativeWebSourcePresentation: Identifiable, Equatable, Sendable {
    let id: String
    let rank: Int
    let query: String
    let provider: String
    let title: String
    let url: String
    let snippet: String
}

struct NativeWebPresentation: Equatable, Sendable {
    let kind: NativeWebKind
    let queries: [String]
    let sources: [NativeWebSourcePresentation]
    let url: String?
    let statusCode: Int?
    let bodyKind: String?
    let contentPreview: String?
    let resultCount: Int
    let truncated: Bool
}

enum NativeJobKind: String, Equatable, Sendable {
    case output
    case list
    case kill
}

struct NativeJobEntryPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let status: String
    let label: String
}

struct NativeJobPresentation: Equatable, Sendable {
    let kind: NativeJobKind
    let jobID: String?
    let status: String?
    let detail: String?
    let entries: [NativeJobEntryPresentation]
    let outputPreview: String
    let totalLines: Int
    let truncated: Bool
}

extension NativeToolEventPresentation {
    static func search(
        name: String,
        arguments: String,
        result: String?
    ) -> NativeToolEventPresentation {
        switch name {
        case "workspace_search":
            return workspaceSearch(arguments: arguments, result: result)
        case "glob":
            return globSearch(arguments: arguments, result: result)
        case "grep":
            return grepSearch(arguments: arguments, result: result)
        default:
            return .generic
        }
    }

    static func web(
        name: String,
        arguments: String,
        result: String?
    ) -> NativeToolEventPresentation {
        switch name {
        case "web_search":
            return webSearch(result: result)
        case "web_fetch":
            return webFetch(arguments: arguments, result: result)
        default:
            return .generic
        }
    }

    static func job(
        name: String,
        arguments: String,
        result: String?,
        status eventStatus: AgentToolEventStatus
    ) -> NativeToolEventPresentation {
        switch name {
        case "job_output":
            return jobOutput(arguments: arguments, result: result)
        case "job_list":
            return jobList(result: result)
        case "job_kill":
            return jobKill(arguments: arguments, result: result, eventStatus: eventStatus)
        default:
            return .generic
        }
    }
}

private extension NativeToolEventPresentation {
    static let cardMaximumInputBytes = 256 * 1_024
    static let cardMaximumRows = 120
    static let cardMaximumPathBytes = 1_024
    static let cardMaximumTextBytes = 32 * 1_024

    static func workspaceSearch(arguments: String, result: String?) -> NativeToolEventPresentation {
        guard let result,
              let object = cardJSONObject(result),
              let query = cardString(object["query"], maximumBytes: 4 * 1_024),
              let root = cardString(object["root"], maximumBytes: cardMaximumPathBytes),
              case let .array(values)? = object["matches"],
              values.count <= cardMaximumRows,
              let truncated = cardBool(object["truncated"]),
              let filesVisited = cardInteger(object["files_visited"], minimum: 0) else {
            return .generic
        }

        var matches: [NativeSearchMatchPresentation] = []
        for (index, value) in values.enumerated() {
            guard let entry = value.objectValue,
                  let path = cardString(entry["path"], maximumBytes: cardMaximumPathBytes),
                  let line = cardInteger(entry["line"], minimum: 1),
                  let excerpt = cardString(entry["excerpt"], maximumBytes: 4 * 1_024, allowEmpty: true) else {
                return .generic
            }
            matches.append(.init(
                id: "workspace:\(index):\(path):\(line)",
                path: path,
                line: line,
                excerpt: excerpt
            ))
        }
        let argumentRoot = cardJSONObject(arguments).flatMap {
            cardString($0["path"], maximumBytes: cardMaximumPathBytes)
        }
        return .search(.init(
            kind: .workspace,
            query: query,
            root: argumentRoot ?? root,
            matches: matches,
            totalCount: matches.count,
            filesVisited: filesVisited,
            truncated: truncated,
            spillLocator: nil
        ))
    }

    static func globSearch(arguments: String, result: String?) -> NativeToolEventPresentation {
        guard let object = cardJSONObject(arguments),
              let pattern = cardString(object["pattern"], maximumBytes: 4 * 1_024),
              let result,
              result.utf8.count <= 96 * 1_024 else {
            return .generic
        }
        let root = cardString(object["path"], maximumBytes: cardMaximumPathBytes)
        if result == "No files found" {
            return .search(.init(
                kind: .glob, query: pattern, root: root, matches: [], totalCount: 0,
                filesVisited: nil, truncated: false, spillLocator: nil
            ))
        }

        let lines = result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var totalCount: Int?
        var spillLocator: String?
        var paths: [String] = []
        for line in lines {
            if line.hasPrefix("(Showing ") {
                totalCount = firstCapturedInteger(in: line, pattern: #"Showing \d+ of (\d+) paths"#)
                spillLocator = firstCapturedString(in: line, pattern: #"stored at: ([^\s]+) \("#)
                continue
            }
            guard line.utf8.count <= cardMaximumPathBytes else { return .generic }
            paths.append(line)
        }
        guard paths.count <= cardMaximumRows else { return .generic }
        let matches = paths.enumerated().map { index, path in
            NativeSearchMatchPresentation(id: "glob:\(index):\(path)", path: path, line: nil, excerpt: nil)
        }
        let total = totalCount ?? paths.count
        return .search(.init(
            kind: .glob,
            query: pattern,
            root: root,
            matches: matches,
            totalCount: total,
            filesVisited: nil,
            truncated: total > paths.count || spillLocator != nil,
            spillLocator: spillLocator
        ))
    }

    static func grepSearch(arguments: String, result: String?) -> NativeToolEventPresentation {
        guard let object = cardJSONObject(arguments),
              let pattern = cardString(object["pattern"], maximumBytes: 4 * 1_024),
              let result,
              result.utf8.count <= 96 * 1_024 else {
            return .generic
        }
        let root = cardString(object["path"], maximumBytes: cardMaximumPathBytes)
        if result == "No matches found" {
            return .search(.init(
                kind: .grep, query: pattern, root: root, matches: [], totalCount: 0,
                filesVisited: nil, truncated: false, spillLocator: nil
            ))
        }

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, header.hasPrefix("Found ") else { return .generic }
        let total = firstCapturedInteger(in: header, pattern: #"Found (?:\d+ of )?(\d+) match(?:es)?"#)
        guard let total else { return .generic }
        let spillLocator = firstCapturedString(in: result, pattern: #"stored at: ([^\s]+) \("#)
        var currentPath: String?
        var matches: [NativeSearchMatchPresentation] = []
        for line in lines.dropFirst() {
            if line.isEmpty || line.hasPrefix("(") { continue }
            if let number = firstCapturedInteger(in: line, pattern: #"^Line (\d+):"#) {
                guard let currentPath else { return .generic }
                let marker = "Line \(number): "
                let excerpt = line.hasPrefix(marker) ? String(line.dropFirst(marker.count)) : ""
                guard excerpt.utf8.count <= 4 * 1_024, matches.count < cardMaximumRows else {
                    return .generic
                }
                matches.append(.init(
                    id: "grep:\(matches.count):\(currentPath):\(number)",
                    path: currentPath,
                    line: number,
                    excerpt: excerpt
                ))
            } else {
                guard line.utf8.count <= cardMaximumPathBytes else { return .generic }
                currentPath = line
            }
        }
        guard !matches.isEmpty || total == 0 else { return .generic }
        return .search(.init(
            kind: .grep,
            query: pattern,
            root: root,
            matches: matches,
            totalCount: total,
            filesVisited: nil,
            truncated: total > matches.count || spillLocator != nil,
            spillLocator: spillLocator
        ))
    }

    static func webSearch(result: String?) -> NativeToolEventPresentation {
        guard let result,
              let object = cardJSONObject(result),
              case let .array(queryValues)? = object["queries"],
              queryValues.count <= 4,
              case let .array(sourceValues)? = object["sources"],
              sourceValues.count <= 32,
              let resultCount = cardInteger(object["source_count"], minimum: 0),
              let truncated = cardBool(object["truncated"]) else {
            return .generic
        }
        let queries = queryValues.compactMap {
            cardString($0, maximumBytes: 2 * 1_024)
        }
        guard queries.count == queryValues.count else { return .generic }
        var sources: [NativeWebSourcePresentation] = []
        for (index, value) in sourceValues.enumerated() {
            guard let entry = value.objectValue,
                  let query = cardString(entry["query"], maximumBytes: 2 * 1_024),
                  let provider = cardString(entry["provider"], maximumBytes: 256),
                  let title = cardString(entry["title"], maximumBytes: 2 * 1_024),
                  let url = cardString(entry["url"], maximumBytes: 4 * 1_024),
                  let snippet = cardString(entry["snippet"], maximumBytes: 8 * 1_024, allowEmpty: true) else {
                return .generic
            }
            sources.append(.init(
                id: "web:\(index):\(url)", rank: index + 1, query: query,
                provider: provider, title: title, url: url, snippet: snippet
            ))
        }
        return .web(.init(
            kind: .search, queries: queries, sources: sources, url: nil,
            statusCode: nil, bodyKind: nil, contentPreview: nil,
            resultCount: resultCount, truncated: truncated || resultCount > sources.count
        ))
    }

    static func webFetch(arguments: String, result: String?) -> NativeToolEventPresentation {
        guard let result,
              let object = cardJSONObject(result),
              let url = cardString(object["url"], maximumBytes: 4 * 1_024),
              let statusCode = cardInteger(object["statusCode"], minimum: 100),
              let body = object["body"]?.objectValue,
              let kind = cardString(body["kind"], maximumBytes: 32),
              let content = body["content"]?.stringValue,
              let sourceTruncated = cardBool(object["truncated"]) else {
            return .generic
        }
        let preview = utf8Prefix(content, maximumBytes: cardMaximumTextBytes)
        let requestedURL = cardJSONObject(arguments).flatMap {
            cardString($0["url"], maximumBytes: 4 * 1_024)
        }
        return .web(.init(
            kind: .fetch, queries: [], sources: [], url: requestedURL ?? url,
            statusCode: statusCode, bodyKind: kind, contentPreview: preview,
            resultCount: 1,
            truncated: sourceTruncated || preview.utf8.count < content.utf8.count
        ))
    }

    static func jobOutput(arguments: String, result: String?) -> NativeToolEventPresentation {
        guard let object = cardJSONObject(arguments),
              let jobID = cardString(object["job_id"], maximumBytes: 256),
              let result,
              result.utf8.count <= cardMaximumInputBytes else {
            return .generic
        }
        var lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if result.hasSuffix("\n"), lines.last?.isEmpty == true { lines.removeLast() }
        var jobStatus: String?
        var detail: String?
        if let last = lines.last,
           let parsed = parseJobStatusLine(last) {
            jobStatus = parsed.status
            detail = parsed.detail
            lines.removeLast()
        }
        guard jobStatus != nil else { return .generic }
        let output = lines.joined(separator: "\n")
        let preview = utf8Prefix(output, maximumBytes: cardMaximumTextBytes)
        return .job(.init(
            kind: .output, jobID: jobID, status: jobStatus, detail: detail,
            entries: [], outputPreview: preview, totalLines: lines.count,
            truncated: preview.utf8.count < output.utf8.count
        ))
    }

    static func jobList(result: String?) -> NativeToolEventPresentation {
        guard let result, result.utf8.count <= cardMaximumInputBytes else { return .generic }
        if result == "(no background jobs)" {
            return .job(.init(
                kind: .list, jobID: nil, status: nil, detail: nil, entries: [],
                outputPreview: "", totalLines: 0, truncated: false
            ))
        }
        let lines = result.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count <= cardMaximumRows else { return .generic }
        var entries: [NativeJobEntryPresentation] = []
        for line in lines {
            guard let kindStart = line.range(of: " ["),
                  let kindEnd = line.range(of: "] ", range: kindStart.upperBound..<line.endIndex),
                  let labelStart = line.range(of: " - ", range: kindEnd.upperBound..<line.endIndex) else {
                return .generic
            }
            let id = String(line[..<kindStart.lowerBound])
            let kind = String(line[kindStart.upperBound..<kindEnd.lowerBound])
            let status = String(line[kindEnd.upperBound..<labelStart.lowerBound])
            let label = String(line[labelStart.upperBound...])
            guard !id.isEmpty, !kind.isEmpty, !status.isEmpty,
                  id.utf8.count <= 256, kind.utf8.count <= 128,
                  status.utf8.count <= 64, label.utf8.count <= 2 * 1_024 else {
                return .generic
            }
            entries.append(.init(id: id, kind: kind, status: status, label: label))
        }
        return .job(.init(
            kind: .list, jobID: nil, status: nil, detail: nil, entries: entries,
            outputPreview: "", totalLines: entries.count, truncated: false
        ))
    }

    static func jobKill(
        arguments: String,
        result: String?,
        eventStatus: AgentToolEventStatus
    ) -> NativeToolEventPresentation {
        guard let object = cardJSONObject(arguments),
              let jobID = cardString(object["job_id"], maximumBytes: 256) else {
            return .generic
        }
        let output = result.map { utf8Prefix($0, maximumBytes: 4 * 1_024) } ?? ""
        let parsed = result.flatMap { text in
            firstCapturedString(in: text, pattern: #"\[status: ([^\],]+)"#)
        }
        let status = parsed ?? (eventStatus == .succeeded ? "stopping" : eventStatus.rawValue)
        return .job(.init(
            kind: .kill, jobID: jobID, status: status, detail: nil, entries: [],
            outputPreview: output, totalLines: output.isEmpty ? 0 : 1, truncated: false
        ))
    }

    static func cardJSONObject(_ text: String) -> [String: JSONValue]? {
        guard !text.isEmpty, text.utf8.count <= cardMaximumInputBytes,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              case let .object(object) = value else { return nil }
        return object
    }

    static func cardString(
        _ value: JSONValue?,
        maximumBytes: Int,
        allowEmpty: Bool = false
    ) -> String? {
        guard let string = value?.stringValue,
              string.utf8.count <= maximumBytes,
              allowEmpty || !string.isEmpty else { return nil }
        return string
    }

    static func cardInteger(_ value: JSONValue?, minimum: Int) -> Int? {
        guard case let .number(number)? = value,
              number.isFinite, number.rounded() == number,
              number >= Double(minimum), number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    static func cardBool(_ value: JSONValue?) -> Bool? {
        guard case let .bool(value)? = value else { return nil }
        return value
    }

    static func firstCapturedInteger(in text: String, pattern: String) -> Int? {
        firstCapturedString(in: text, pattern: pattern).flatMap(Int.init)
    }

    static func firstCapturedString(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func parseJobStatusLine(_ line: String) -> (status: String, detail: String?)? {
        guard line.hasPrefix("[status: "), line.hasSuffix("]") else { return nil }
        let body = line.dropFirst("[status: ".count).dropLast()
        let parts = body.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let status = parts.first, !status.isEmpty, status.utf8.count <= 64 else { return nil }
        let detail = parts.count == 2 && parts[1].utf8.count <= 2 * 1_024 ? parts[1] : nil
        return (status, detail)
    }

    static func utf8Prefix(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var used = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            guard used + fragment.utf8.count <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
            used += fragment.utf8.count
        }
        return result
    }
}
