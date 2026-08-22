import CryptoKit
import Foundation

enum WorkspaceInstructionTransitionAction: String, Codable, Sendable, Equatable, Hashable {
    case set
    case replace
    case remove
}

struct WorkspaceInstructionChange: Codable, Sendable, Equatable, Hashable {
    let action: WorkspaceInstructionTransitionAction
    let scope: String
    let path: String
    let digest: String?

    init(
        action: WorkspaceInstructionTransitionAction,
        scope: String,
        path: String,
        digest: String? = nil
    ) {
        self.action = action
        self.scope = scope
        self.path = path
        self.digest = digest
    }
}

/// Typed source metadata used by dsh-v0.1.1-rc.2. The model sees only the
/// framed message text; these fields remain in durable local history so resume
/// and compaction can fold instruction state without parsing prose.
struct WorkspaceInstructionMessageSource: Sendable, Equatable {
    static let kind = "agent-instructions"

    let baseline: Bool
    let baselineIdentity: String?
    let changes: [WorkspaceInstructionChange]

    init(
        baseline: Bool = false,
        baselineIdentity: String? = nil,
        changes: [WorkspaceInstructionChange]
    ) {
        self.baseline = baseline
        self.baselineIdentity = baselineIdentity
        self.changes = changes
    }

    init?(jsonValue: JSONValue?) {
        guard let object = jsonValue?.objectValue,
              object["kind"] == .string(Self.kind),
              object["form"] == .string("instructions"),
              case let .array(rawChanges) = object["changes"] else { return nil }
        var decoded: [WorkspaceInstructionChange] = []
        for raw in rawChanges {
            guard let value = raw.objectValue,
                  let actionValue = value["action"]?.stringValue,
                  let action = WorkspaceInstructionTransitionAction(rawValue: actionValue),
                  let scope = value["scope"]?.stringValue,
                  let path = value["path"]?.stringValue else { continue }
            decoded.append(
                WorkspaceInstructionChange(
                    action: action,
                    scope: scope,
                    path: path,
                    digest: value["digest"]?.stringValue
                )
            )
        }
        baseline = object["baseline"] == .bool(true)
        baselineIdentity = object["baselineIdentity"]?.stringValue
        changes = decoded
    }

    var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "kind": .string(Self.kind),
            "form": .string("instructions"),
            "changes": .array(changes.map { change in
                var value: [String: JSONValue] = [
                    "action": .string(change.action.rawValue),
                    "scope": .string(change.scope),
                    "path": .string(change.path)
                ]
                if let digest = change.digest { value["digest"] = .string(digest) }
                return .object(value)
            })
        ]
        if baseline { object["baseline"] = .bool(true) }
        if let baselineIdentity { object["baselineIdentity"] = .string(baselineIdentity) }
        return .object(object)
    }
}

extension AgentMessage {
    var workspaceInstructionSource: WorkspaceInstructionMessageSource? {
        WorkspaceInstructionMessageSource(jsonValue: source)
    }

    var isWorkspaceInstructionTransition: Bool {
        role == .user && workspaceInstructionSource != nil
    }

    static func workspaceInstruction(
        _ content: String,
        source: WorkspaceInstructionMessageSource
    ) -> AgentMessage {
        AgentMessage(role: .user, content: content, source: source.jsonValue)
    }
}

struct WorkspaceInstructionVisibleState: Sendable, Equatable {
    let baselineIdentity: String?
    let baselineIsVisible: Bool
    let changesByScope: [String: WorkspaceInstructionChange]

    static func fold(_ messages: [AgentMessage]) -> Self {
        var baselineIdentity: String?
        var baselineIsVisible = false
        var changes: [String: WorkspaceInstructionChange] = [:]
        for message in messages {
            guard let source = message.workspaceInstructionSource else { continue }
            if source.baseline {
                baselineIsVisible = true
                baselineIdentity = source.baselineIdentity
            }
            for change in source.changes { changes[change.scope] = change }
        }
        return Self(
            baselineIdentity: baselineIdentity,
            baselineIsVisible: baselineIsVisible,
            changesByScope: changes
        )
    }

    var activeChanges: [String: WorkspaceInstructionChange] {
        changesByScope.filter { $0.value.action != .remove }
    }
}

enum WorkspaceInstructionCompactionProjection {
    /// Mirrors upstream surface semantics: typed instruction state is visible
    /// state, not hidden cache state. If compaction shadows the only compatible
    /// baseline, the next pre-step must compose a complete current baseline.
    static func requiresBaselineRearm(
        beforeCompaction: [AgentMessage],
        visibleAfterCompaction: [AgentMessage],
        baselineIdentity: String
    ) -> Bool {
        let before = WorkspaceInstructionVisibleState.fold(beforeCompaction)
        guard before.baselineIsVisible || !before.changesByScope.isEmpty else { return false }
        let after = WorkspaceInstructionVisibleState.fold(visibleAfterCompaction)
        return !after.baselineIsVisible || after.baselineIdentity != baselineIdentity
    }
}

/// Session-local port of the rc.2 instruction state machine. Durable messages
/// are the authority; this actor caches only provider version/digest metadata.
actor WorkspaceInstructionTransitionEngine {
    static let defaultBaselineIdentity = "workspace-v1|AGENTS.md,CLAUDE.md|AGENTS.local.md,CLAUDE.local.md|49152|65536"

    private struct Candidate: Sendable, Hashable {
        let path: String
        let displayPath: String
        let directory: String
        let scope: String
        let isGlobal: Bool
    }

    private struct VersionState: Sendable, Equatable {
        let path: String
        let version: HarnessFsVersion
        let digest: String
        let trimmedDigest: String
    }

    private struct Loaded: Sendable {
        let candidate: Candidate
        let content: String
        let version: HarnessFsVersion
        let digest: String
        let trimmedDigest: String
    }

    private enum Probe {
        case present(HarnessFsTarget, HarnessFsInfo)
        case absent
        case unavailable
    }

    private struct RenderItem {
        let change: WorkspaceInstructionChange
        let content: String
    }

    private let workspaceStore: WorkspaceStore
    private let maximumSourceBytes: Int
    private let maximumMessageBytes: Int
    private var versionsBySession: [UUID: [String: VersionState]] = [:]
    private var knownScopesBySession: [UUID: Set<String>] = [:]
    private var touchedPathsBySession: [UUID: Set<String>] = [:]

    init(
        workspaceStore: WorkspaceStore,
        maximumSourceBytes: Int = 64 * 1_024,
        maximumMessageBytes: Int = 48 * 1_024
    ) {
        self.workspaceStore = workspaceStore
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumMessageBytes = maximumMessageBytes
    }

    /// Returns at most one append-only durable user message. Unchanged state
    /// returns nil, keeping every earlier request byte-for-byte stable.
    func prepareTransition(
        sessionID: UUID,
        visibleMessages: [AgentMessage],
        durableMessages: [AgentMessage]? = nil,
        touchedPaths: [String] = [],
        baselineIdentity: String = defaultBaselineIdentity
    ) async -> AgentMessage? {
        guard maximumSourceBytes > 0, maximumMessageBytes > 0 else { return nil }
        let visible = WorkspaceInstructionVisibleState.fold(visibleMessages)
        let durable = durableMessages.map(WorkspaceInstructionVisibleState.fold)
        let durableScopes = durable.map { Set($0.changesByScope.keys) } ?? []
        let priorKnown = knownScopesBySession[sessionID] ?? []
        let knownScopes = priorKnown
            .union(durableScopes)
            .union(visible.changesByScope.keys)
        knownScopesBySession[sessionID] = knownScopes
        let rememberedTouches = touchedPathsBySession[sessionID] ?? []
        let candidates = candidateChain(
            touchedPaths: Array(rememberedTouches.union(touchedPaths)),
            visibleScopes: knownScopes
        )

        if !visible.baselineIsVisible || visible.baselineIdentity != baselineIdentity {
            let previous = visible.baselineIsVisible || !visible.changesByScope.isEmpty
                ? visible
                : durable ?? visible
            return await composeBaseline(
                sessionID: sessionID,
                candidates: candidates,
                previous: previous,
                identity: baselineIdentity
            )
        }
        return await composeChanges(
            sessionID: sessionID,
            candidates: candidates,
            previous: visible
        )
    }

    func clearSession(_ sessionID: UUID) {
        versionsBySession.removeValue(forKey: sessionID)
        knownScopesBySession.removeValue(forKey: sessionID)
        touchedPathsBySession.removeValue(forKey: sessionID)
    }

    /// Successful filesystem tools are the discovery boundary for nested
    /// instruction files. The transition itself is still composed at the next
    /// model pre-step so a failed/blocked tool never changes model context.
    func noteTouchedPath(
        sessionID: UUID,
        path rawPath: String,
        mutation: WorkspaceInstructionMutation
    ) {
        let path = Self.normalizedPath(rawPath)
        guard !path.isEmpty else { return }
        switch mutation {
        case .observed, .replaced:
            touchedPathsBySession[sessionID, default: []].insert(path)
        case .deleted:
            if let current = touchedPathsBySession[sessionID] {
                touchedPathsBySession[sessionID] = Set(current.filter {
                    $0 != path && !$0.hasPrefix(path + "/")
                })
            }
        }
    }

    private func composeBaseline(
        sessionID: UUID,
        candidates: [Candidate],
        previous: WorkspaceInstructionVisibleState,
        identity: String
    ) async -> AgentMessage? {
        var loaded: [Loaded] = []
        var seenByDirectory: [String: Set<String>] = [:]
        for candidate in candidates {
            guard case let .present(target, info) = await probe(candidate),
                  let file = await load(candidate, target: target, info: info) else { continue }
            if seenByDirectory[file.candidate.directory, default: []].contains(file.trimmedDigest) {
                continue
            }
            seenByDirectory[file.candidate.directory, default: []].insert(file.trimmedDigest)
            loaded.append(file)
        }

        let replacing = previous.baselineIsVisible
        let rendered = renderBaseline(loaded, replacing: replacing)
        var changes = rendered.loaded.map { file in
            WorkspaceInstructionChange(
                action: .set,
                scope: file.candidate.scope,
                path: file.candidate.displayPath,
                digest: file.digest
            )
        }
        if replacing {
            let replacementScopes = Set(changes.map(\.scope))
            for prior in previous.activeChanges.values
                where !replacementScopes.contains(prior.scope) {
                changes.insert(
                    WorkspaceInstructionChange(
                        action: .remove,
                        scope: prior.scope,
                        path: prior.path
                    ),
                    at: 0
                )
            }
        }
        guard !rendered.text.isEmpty else { return nil }
        var versions: [String: VersionState] = [:]
        for file in rendered.loaded {
            versions[file.candidate.scope] = VersionState(
                path: file.candidate.displayPath,
                version: file.version,
                digest: file.digest,
                trimmedDigest: file.trimmedDigest
            )
        }
        versionsBySession[sessionID] = versions
        knownScopesBySession[sessionID, default: []].formUnion(changes.map(\.scope))
        return .workspaceInstruction(
            rendered.text,
            source: WorkspaceInstructionMessageSource(
                baseline: true,
                baselineIdentity: identity,
                changes: changes
            )
        )
    }

    private func composeChanges(
        sessionID: UUID,
        candidates: [Candidate],
        previous: WorkspaceInstructionVisibleState
    ) async -> AgentMessage? {
        var versions = versionsBySession[sessionID] ?? [:]
        var items: [RenderItem] = []

        for group in Dictionary(grouping: candidates, by: \.directory)
            .sorted(by: { Self.directoryPrecedes($0.key, $1.key) }) {
            var keptTrimmed = Set<String>()
            var groupItems: [RenderItem] = []
            var groupUpdates: [String: VersionState?] = [:]
            var groupUnavailable = false
            for candidate in group.value {
                let prior = previous.changesByScope[candidate.scope]
                switch await probe(candidate) {
                case .unavailable:
                    // Same-directory candidates form one authority group. Keep
                    // the last-good group when any active member is unavailable.
                    if prior?.action != .remove, prior != nil { groupUnavailable = true }
                case .absent:
                    if let prior, prior.action != .remove {
                        groupItems.append(
                            RenderItem(
                                change: WorkspaceInstructionChange(
                                    action: .remove,
                                    scope: candidate.scope,
                                    path: prior.path
                                ),
                                content: ""
                            )
                        )
                    }
                    groupUpdates[candidate.scope] = .some(nil)
                case let .present(target, info):
                    if let cached = versions[candidate.scope],
                       cached.path == candidate.displayPath,
                       cached.version == info.version,
                       prior?.action != .remove,
                       prior?.path == cached.path,
                       prior?.digest == cached.digest {
                        if keptTrimmed.contains(cached.trimmedDigest), let prior {
                            groupItems.append(
                                RenderItem(
                                    change: WorkspaceInstructionChange(
                                        action: .remove,
                                        scope: candidate.scope,
                                        path: prior.path
                                    ),
                                    content: ""
                                )
                            )
                            groupUpdates[candidate.scope] = .some(nil)
                        } else {
                            keptTrimmed.insert(cached.trimmedDigest)
                        }
                        continue
                    }
                    guard let file = await load(candidate, target: target, info: info) else {
                        if prior?.action != .remove, prior != nil { groupUnavailable = true }
                        continue
                    }
                    if keptTrimmed.contains(file.trimmedDigest) {
                        if let prior, prior.action != .remove {
                            groupItems.append(
                                RenderItem(
                                    change: WorkspaceInstructionChange(
                                        action: .remove,
                                        scope: candidate.scope,
                                        path: prior.path
                                    ),
                                    content: ""
                                )
                            )
                        }
                        groupUpdates[candidate.scope] = .some(nil)
                        continue
                    }
                    keptTrimmed.insert(file.trimmedDigest)
                    let state = VersionState(
                        path: candidate.displayPath,
                        version: file.version,
                        digest: file.digest,
                        trimmedDigest: file.trimmedDigest
                    )
                    if prior?.action != .remove,
                       prior?.path == candidate.displayPath,
                       prior?.digest == file.digest {
                        groupUpdates[candidate.scope] = .some(state)
                        continue
                    }
                    let action: WorkspaceInstructionTransitionAction = prior == nil || prior?.action == .remove
                        ? .set
                        : .replace
                    let change = WorkspaceInstructionChange(
                        action: action,
                        scope: candidate.scope,
                        path: candidate.displayPath,
                        digest: file.digest
                    )
                    groupItems.append(RenderItem(change: change, content: file.content))
                    groupUpdates[candidate.scope] = .some(state)
                }
            }
            guard !groupUnavailable else { continue }
            items.append(contentsOf: groupItems)
            for (scope, update) in groupUpdates {
                if let state = update { versions[scope] = state }
                else { versions.removeValue(forKey: scope) }
            }
        }

        guard !items.isEmpty else {
            versionsBySession[sessionID] = versions
            return nil
        }
        let rendered = renderChanges(items)
        guard !rendered.text.isEmpty, !rendered.changes.isEmpty else { return nil }
        let representedScopes = Set(rendered.changes.map(\.scope))
        for item in items where !representedScopes.contains(item.change.scope) {
            // A budget-omitted transition remains eligible for the next touch.
            versions.removeValue(forKey: item.change.scope)
        }
        versionsBySession[sessionID] = versions
        knownScopesBySession[sessionID, default: []].formUnion(rendered.changes.map(\.scope))
        return .workspaceInstruction(
            rendered.text,
            source: WorkspaceInstructionMessageSource(changes: rendered.changes)
        )
    }

    private func candidateChain(
        touchedPaths: [String],
        visibleScopes: Set<String>
    ) -> [Candidate] {
        var directories = Set([""])
        for path in touchedPaths {
            let components = Self.normalizedPath(path).split(separator: "/").map(String.init)
            if components.count > 1 {
                for index in 1..<components.count {
                    directories.insert(components.prefix(index).joined(separator: "/"))
                }
            }
        }
        for scope in visibleScopes {
            let directory = Self.decodeDirectory(scope)
            if directory != "user-global" && directory != "." { directories.insert(directory) }
        }
        var result = [
            Candidate(
                path: ".dsh/AGENTS.md",
                displayPath: "$DSH_HOME/AGENTS.md",
                directory: "user-global",
                scope: Self.scope(directory: "user-global", name: "AGENTS.md"),
                isGlobal: true
            )
        ]
        for directory in directories.sorted(by: Self.directoryPrecedes) {
            for name in ["AGENTS.md", "CLAUDE.md", "AGENTS.local.md", "CLAUDE.local.md"] {
                let path = directory.isEmpty ? name : "\(directory)/\(name)"
                result.append(
                    Candidate(
                        path: path,
                        displayPath: path,
                        directory: directory.isEmpty ? "." : directory,
                        scope: Self.scope(directory: directory.isEmpty ? "." : directory, name: name),
                        isGlobal: false
                    )
                )
            }
        }
        return result
    }

    private func probe(_ candidate: Candidate) async -> Probe {
        do {
            let target = try await workspaceStore.fileSystemResolve(
                path: candidate.path,
                cwd: "/workspace"
            )
            guard let info = try await workspaceStore.fileSystemStat(target: target),
                  info.type == .file else { return .absent }
            return .present(target, info)
        } catch {
            return .unavailable
        }
    }

    private func load(
        _ candidate: Candidate,
        target: HarnessFsTarget,
        info: HarnessFsInfo
    ) async -> Loaded? {
        guard info.size.map({ $0 <= maximumSourceBytes }) ?? true else { return nil }
        do {
            let content = try await workspaceStore.fileSystemReadText(
                target: target,
                maximumBytes: maximumSourceBytes
            )
            let normalized = content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return Loaded(
                candidate: candidate,
                content: normalized,
                version: info.version,
                digest: Self.sha1(normalized),
                trimmedDigest: Self.sha1(
                    normalized.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        } catch {
            return nil
        }
    }

    private func renderBaseline(
        _ loaded: [Loaded],
        replacing: Bool
    ) -> (text: String, loaded: [Loaded]) {
        if loaded.isEmpty {
            guard replacing else { return ("", []) }
            return (Self.frame([
                "This complete workspace instruction baseline replaces all earlier workspace instruction baselines. No workspace instructions are currently active."
            ]), [])
        }
        let intro = replacing
            ? "This complete workspace instruction baseline replaces all earlier workspace instruction baselines. The following workspace instructions may be relevant to your work. Use them as guidance when applicable. More specific instructions take precedence over broader ones. They do not override system, developer, or direct user instructions."
            : "The following workspace instructions may be relevant to your work. Use them as guidance when applicable. More specific instructions take precedence over broader ones. They do not override system, developer, or direct user instructions."
        var selected = loaded
        while !selected.isEmpty {
            let sections = [intro] + selected.map {
                "Instructions from: \($0.candidate.displayPath)\n\n\($0.content)"
            }
            let text = Self.frame(sections)
            if text.utf8.count <= maximumMessageBytes { return (text, selected) }
            selected.removeFirst()
        }
        return ("", [])
    }

    private func renderChanges(
        _ items: [RenderItem]
    ) -> (text: String, changes: [WorkspaceInstructionChange]) {
        var selected = items
        while !selected.isEmpty {
            let text = Self.frame(selected.map(Self.changeSection))
            if text.utf8.count <= maximumMessageBytes {
                return (text, selected.map(\.change))
            }
            selected.removeFirst()
        }
        return ("", [])
    }

    private static func changeSection(_ item: RenderItem) -> String {
        switch item.change.action {
        case .set:
            let directory = decodeDirectory(item.change.scope)
            return [
                "Additional instructions from: \(item.change.path)",
                "",
                "These instructions apply to work under `\(directory)`. Use them as guidance when relevant; more specific instructions take precedence. They do not override system, developer, or direct user instructions.",
                "",
                item.content
            ].joined(separator: "\n")
        case .replace:
            return [
                "Updated instructions from: \(item.change.path)",
                "",
                "This file changed after it was loaded. Use the following content instead of the previously loaded instructions from this file.",
                "",
                item.content
            ].joined(separator: "\n")
        case .remove:
            return "Instructions removed: \(item.change.path)\n\nThe previously loaded instructions from this file no longer apply."
        }
    }

    private static func frame(_ sections: [String]) -> String {
        let body = sections
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .replacingOccurrences(of: "</system-reminder>", with: "<\\/system-reminder>")
        return "<system-reminder>\n\(body)\n</system-reminder>"
    }

    private static func normalizedPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var components: [String] = []
        for component in trimmed.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(component))
        }
        if components.first == "workspace", trimmed.hasPrefix("/workspace") {
            components.removeFirst()
        }
        return components.joined(separator: "/")
    }

    private static func scope(directory: String, name: String) -> String {
        "\(directory)\u{0}\(name)"
    }

    private static func decodeDirectory(_ scope: String) -> String {
        String(scope.prefix { $0 != "\u{0}" })
    }

    private static func directoryPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let leftDepth = lhs.split(separator: "/").count
        let rightDepth = rhs.split(separator: "/").count
        if leftDepth != rightDepth { return leftDepth < rightDepth }
        return lhs < rhs
    }

    private static func sha1(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
