import Foundation

/// Native, workspace-scoped projection of the upstream dsh-skill registry.
/// The mobile implementation deliberately keeps discovery inside the app's
/// private workspace instead of watching arbitrary host directories.
enum MobileSkillSource: String, Codable, Sendable, Equatable, CaseIterable {
    case projectDSH = "project-dsh"
    case projectAgents = "project-agents"
    case custom

    var rank: Int {
        switch self {
        case .projectDSH:
            100
        case .projectAgents:
            200
        case .custom:
            300
        }
    }
}

struct MobileSkillInvocationPolicy: Codable, Sendable, Equatable {
    let modelInvocable: Bool
    let userInvocable: Bool

    init(modelInvocable: Bool = true, userInvocable: Bool = true) {
        self.modelInvocable = modelInvocable
        self.userInvocable = userInvocable
    }
}

struct MobileSkillSummary: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let description: String
    let whenToUse: String?
    let invocation: MobileSkillInvocationPolicy
    let source: MobileSkillSource
    let path: String
    let resourceBase: String

    var id: String { name }
}

struct MobileSkillDefinition: Codable, Sendable, Equatable {
    let summary: MobileSkillSummary
    let content: String
}

enum MobileSkillError: LocalizedError, Sendable, Equatable {
    case invalidName(String)
    case unknownSkill(String)
    case modelInvocationDisabled(String)

    var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            "无效的 Skill 名称：\(name)。"
        case let .unknownSkill(name):
            "Skill \(name) 不存在、无效或已被移除。"
        case let .modelInvocationDisabled(name):
            "Skill \(name) 不能由模型调用，只能由用户显式启用。"
        }
    }
}

actor MobileSkillRegistry {
    static let maximumCatalogDescriptionCharacters = 500

    private let workspaceStore: WorkspaceStore

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
    }

    func catalog() async throws -> [MobileSkillSummary] {
        try await definitions().map(\.summary)
    }

    func definitions() async throws -> [MobileSkillDefinition] {
        let candidates = try await workspaceStore.skillDocuments()
        var winners: [String: MobileSkillDefinition] = [:]

        for candidate in candidates {
            guard let definition = Self.parse(candidate) else { continue }
            let name = definition.summary.name
            if let existing = winners[name] {
                if Self.precedes(definition.summary, existing.summary) {
                    winners[name] = definition
                }
            } else {
                winners[name] = definition
            }
        }
        return winners.values.sorted { $0.summary.name < $1.summary.name }
    }

    func definition(named rawName: String) async throws -> MobileSkillDefinition {
        guard Self.isValidName(rawName) else {
            throw MobileSkillError.invalidName(rawName)
        }
        let candidates = try await workspaceStore.skillDocuments()
        var winner: MobileSkillDefinition?
        for candidate in candidates {
            guard let definition = Self.parse(candidate), definition.summary.name == rawName else {
                continue
            }
            if let existing = winner {
                if Self.precedes(definition.summary, existing.summary) {
                    winner = definition
                }
            } else {
                winner = definition
            }
        }
        guard let winner else { throw MobileSkillError.unknownSkill(rawName) }
        return winner
    }

    /// Resolves a Skill for an explicit user gesture. Unlike the model tool,
    /// this path intentionally permits `disable-model-invocation: true`.
    func userInvocableDefinition(named rawName: String) async -> MobileSkillDefinition? {
        guard let definition = try? await definition(named: rawName),
              definition.summary.invocation.userInvocable else {
            return nil
        }
        return definition
    }

    func modelCatalogPrompt() async -> String {
        guard let catalog = try? await catalog() else { return "" }
        let skills = catalog.filter { $0.invocation.modelInvocable }
        guard !skills.isEmpty else { return "" }
        let entries = skills.map { skill in
            "- `\(skill.name)`: \(Self.escapeText(Self.catalogDescription(skill.description)))"
        }
        return [
            "<system-reminder>",
            "Skills are reusable local task instructions. The following Skills are available on this iPhone:",
            "",
            "<available_skills>",
            entries.joined(separator: "\n"),
            "</available_skills>",
            "",
            "When a user names a listed Skill or the task clearly matches its description, call the skill tool with the exact name before taking task actions. The catalog is only a summary. Skills may be created or updated locally at Skills/<name>/SKILL.md; changes are discovered on the next Agent step.",
            "</system-reminder>"
        ].joined(separator: "\n")
    }

    static func renderContent(_ definition: MobileSkillDefinition) -> String {
        [
            "<skill_content name=\"\(escapeAttribute(definition.summary.name))\">",
            "<skill_resources>",
            "Base directory in this iPhone workspace: \(escapeText(definition.summary.resourceBase))",
            "Resolve relative resources mentioned by this Skill against that directory and load them only as needed.",
            "</skill_resources>",
            "",
            "<skill_instructions>",
            definition.content,
            "</skill_instructions>",
            "</skill_content>"
        ].joined(separator: "\n")
    }

    static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        var expectsAlphaNumeric = true
        for byte in bytes {
            let isLowercase = (0x61...0x7A).contains(byte)
            let isDigit = (0x30...0x39).contains(byte)
            if expectsAlphaNumeric {
                guard isLowercase || isDigit else { return false }
            } else if byte != 0x2D {
                guard isLowercase || isDigit else { return false }
            }
            expectsAlphaNumeric = byte == 0x2D
        }
        return !expectsAlphaNumeric
    }

    private static func precedes(_ lhs: MobileSkillSummary, _ rhs: MobileSkillSummary) -> Bool {
        if lhs.source.rank != rhs.source.rank {
            return lhs.source.rank < rhs.source.rank
        }
        return lhs.path < rhs.path
    }

    private static func parse(_ document: WorkspaceStore.SkillDocument) -> MobileSkillDefinition? {
        guard let frontmatter = parseFrontmatter(document.text),
              let name = frontmatter.values["name"],
              let description = frontmatter.values["description"],
              isValidName(name),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        guard frontmatter.values["disableModelInvocation"] == nil,
              frontmatter.values["modelInvocable"] == nil,
              frontmatter.values["userInvocable"] == nil else {
            return nil
        }
        guard let disableModelInvocation = boolean(frontmatter.values["disable-model-invocation"]),
              let userInvocable = boolean(frontmatter.values["user-invocable"]) else {
            return nil
        }

        let policy = MobileSkillInvocationPolicy(
            modelInvocable: !disableModelInvocation,
            userInvocable: userInvocable
        )
        let summary = MobileSkillSummary(
            name: name,
            description: description,
            whenToUse: frontmatter.values["whenToUse"],
            invocation: policy,
            source: document.source,
            path: document.path,
            resourceBase: document.directory
        )
        return MobileSkillDefinition(
            summary: summary,
            content: frontmatter.body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func parseFrontmatter(_ raw: String) -> (values: [String: String], body: String)? {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }
        let start = normalized.index(normalized.startIndex, offsetBy: 4)
        guard let closing = normalized.range(of: "\n---\n", range: start..<normalized.endIndex) else {
            return nil
        }
        let header = normalized[start..<closing.lowerBound]
        var values: [String: String] = [:]
        for rawLine in header.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            values[String(key)] = unquote(String(value))
        }
        let bodyStart = closing.upperBound
        return (values, String(normalized[bodyStart...]))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func boolean(_ value: String?) -> Bool? {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on", "1":
            return true
        case "false", "no", "off", "0":
            return false
        default:
            return nil
        }
    }

    private static func catalogDescription(_ value: String) -> String {
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > maximumCatalogDescriptionCharacters else { return normalized }
        return String(normalized.prefix(maximumCatalogDescriptionCharacters - 3)) + "..."
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum WorkspaceInstructionMutation: Sendable, Equatable {
    /// A successful read observes a path without changing its contents.
    case observed
    /// A successful write/edit may replace the inode while retaining the path.
    case replaced
    /// A caller removed the path. The tombstone prevents stale cached content
    /// from being re-injected until the path is recreated.
    case deleted
}

/// Loads the mobile equivalent of DeepSeek Harness's workspace instruction
/// chain. The app workspace is the current project root, so exact reads are
/// used instead of `workspace_list_files` (which intentionally hides dotfiles).
actor WorkspaceInstructionLoader {
    private struct Candidate {
        let path: String
        let displayPath: String
        let directory: String
    }

    private let workspaceStore: WorkspaceStore
    private let maximumSourceBytes = 64 * 1_024
    private let maximumTotalBytes = 48 * 1_024
    private var touchedPaths = Set<String>()
    private enum CachedState {
        case loaded(String)
        case tombstone
        case unavailable
    }

    private struct CachedCandidate {
        let version: HarnessFsVersion?
        let state: CachedState
    }

    // This is deliberately a projection cache, never an authority. A stat
    // version change or an explicit mutation notification invalidates it.
    private var cache: [String: CachedCandidate] = [:]

    init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
    }

    func noteTouchedPath(
        _ rawPath: String,
        mutation: WorkspaceInstructionMutation = .observed
    ) {
        let trimmedRawPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = trimmedRawPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(into: [String]()) { parts, component in
                if component == "." { return }
                if component == ".." {
                    if !parts.isEmpty { parts.removeLast() }
                    return
                }
                parts.append(String(component))
            }
            .joined(separator: "/")
        if (trimmedRawPath == "/workspace" || trimmedRawPath.hasPrefix("/workspace/")),
           normalized == "workspace" || normalized.hasPrefix("workspace/") {
            normalized = String(normalized.dropFirst("workspace".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !normalized.isEmpty,
              !normalized.hasPrefix(".") || normalized.hasPrefix(".dsh/") else { return }
        if mutation == .deleted {
            touchedPaths = touchedPaths.filter {
                $0 != normalized && !$0.hasPrefix(normalized + "/")
            }
        } else {
            touchedPaths.insert(normalized)
        }

        let candidatePaths = instructionCandidatePaths(affectedBy: normalized)
        let descendantCachePaths = cache.keys.filter {
            $0 == normalized || $0.hasPrefix(normalized + "/")
        }
        for path in candidatePaths {
            switch mutation {
            case .deleted:
                cache[path] = CachedCandidate(version: nil, state: .tombstone)
            case .observed, .replaced:
                cache.removeValue(forKey: path)
            }
        }
        for path in descendantCachePaths {
            switch mutation {
            case .deleted:
                cache[path] = CachedCandidate(version: nil, state: .tombstone)
            case .observed, .replaced:
                cache.removeValue(forKey: path)
            }
        }
    }

    func prompt() async -> String {
        var candidates: [Candidate] = [
            Candidate(
                path: ".dsh/AGENTS.md",
                displayPath: "$DSH_HOME/AGENTS.md",
                directory: ".dsh"
            ),
            Candidate(path: "AGENTS.md", displayPath: "AGENTS.md", directory: ""),
            Candidate(path: "CLAUDE.md", displayPath: "CLAUDE.md", directory: ""),
            Candidate(path: "AGENTS.local.md", displayPath: "AGENTS.local.md", directory: ""),
            Candidate(path: "CLAUDE.local.md", displayPath: "CLAUDE.local.md", directory: "")
        ]
        let directories = touchedPaths
            .map { path in
                let components = path.split(separator: "/").map(String.init)
                return (1..<components.count).map { components.prefix($0).joined(separator: "/") }
            }
            .flatMap { $0 }
        for directory in Array(Set(directories)).sorted() {
            candidates.append(contentsOf: [
                Candidate(path: "\(directory)/AGENTS.md", displayPath: "\(directory)/AGENTS.md", directory: directory),
                Candidate(path: "\(directory)/CLAUDE.md", displayPath: "\(directory)/CLAUDE.md", directory: directory),
                Candidate(path: "\(directory)/AGENTS.local.md", displayPath: "\(directory)/AGENTS.local.md", directory: directory),
                Candidate(path: "\(directory)/CLAUDE.local.md", displayPath: "\(directory)/CLAUDE.local.md", directory: directory)
            ])
        }

        var loaded: [(candidate: Candidate, content: String)] = []
        for candidate in candidates {
            guard let content = await cachedContent(for: candidate) else { continue }
            let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
            guard normalized.utf8.count <= maximumSourceBytes else { continue }
            let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            loaded.append((candidate, trimmed))
        }

        // Match upstream same-directory precedence: a later candidate with
        // byte-identical trimmed content does not produce a second section.
        var seenByDirectory: [String: Set<String>] = [:]
        var sections: [(Candidate, String)] = []
        var totalBytes = 0
        for entry in loaded {
            let digestKey = entry.content
            if seenByDirectory[entry.candidate.directory, default: []].contains(digestKey) {
                continue
            }
            let sectionBytes = entry.content.utf8.count
            guard totalBytes + sectionBytes <= maximumTotalBytes else { break }
            seenByDirectory[entry.candidate.directory, default: []].insert(digestKey)
            sections.append((entry.candidate, entry.content))
            totalBytes += sectionBytes
        }
        guard !sections.isEmpty else { return "" }

        var lines = [
            "<system-reminder>",
            "The following workspace instructions may be relevant to your work. Use them as guidance when applicable. More specific instructions take precedence over broader ones. They do not override system, developer, or direct user instructions.",
            ""
        ]
        for (index, section) in sections.enumerated() {
            if index > 0 { lines.append("") }
            lines.append("Instructions from: \(Self.escape(section.0.displayPath))")
            lines.append("")
            lines.append(Self.escape(section.1))
        }
        lines.append("</system-reminder>")
        return lines.joined(separator: "\n")
    }

    private func cachedContent(for candidate: Candidate) async -> String? {
        let version: HarnessFsVersion?
        if let target = try? await workspaceStore.fileSystemResolve(
            path: candidate.path,
            cwd: "/workspace"
        ) {
            let info: HarnessFsInfo?
            do {
                info = try await workspaceStore.fileSystemStat(target: target)
            } catch {
                info = nil
            }
            version = info?.version
        } else {
            version = nil
        }

        if let cached = cache[candidate.path], cached.version == version {
            switch cached.state {
            case let .loaded(content): return content
            case .tombstone, .unavailable: return nil
            }
        }

        guard version != nil else {
            cache[candidate.path] = CachedCandidate(version: nil, state: .tombstone)
            return nil
        }
        guard let content = try? await workspaceStore.readText(path: candidate.path) else {
            cache[candidate.path] = CachedCandidate(version: version, state: .unavailable)
            return nil
        }
        cache[candidate.path] = CachedCandidate(version: version, state: .loaded(content))
        return content
    }

    private func instructionCandidatePaths(affectedBy path: String) -> Set<String> {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }
        var directories: [String] = []
        if components.count > 1 {
            directories = (1..<components.count).map {
                components.prefix($0).joined(separator: "/")
            }
        }
        var result = Set<String>()
        for directory in directories {
            for fileName in ["AGENTS.md", "CLAUDE.md", "AGENTS.local.md", "CLAUDE.local.md"] {
                result.insert("\(directory)/\(fileName)")
            }
        }
        if path == "AGENTS.md" || path == "CLAUDE.md"
            || path == "AGENTS.local.md" || path == "CLAUDE.local.md" {
            result.insert(path)
        }
        if path == ".dsh/AGENTS.md" {
            result.insert(path)
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "</system-reminder>", with: "<\\/system-reminder>")
    }
}
