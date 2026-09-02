import Foundation

/// Mirrors upstream `hooks-codex/src/config.ts`: parsing of Codex's
/// five-event hook subset into the shared matcher groups. Only synchronous
/// command hooks run; other types and `async: true` commands are recorded as
/// skipped. Codex performs no command substitution, and every matcher is
/// regex.
enum CodexHookConfigParser {
    static let supportedEvents: Set<String> = [
        HookPoint.preToolUse.rawValue,
        HookPoint.postToolUse.rawValue,
        HookPoint.sessionStart.rawValue,
        HookPoint.userPromptSubmit.rawValue,
        HookPoint.stop.rawValue
    ]

    struct ParsedConfig: Sendable, Equatable {
        var config: [HookPoint: [HookMatcherGroup]]
        /// Skipped hooks with their reasons, surfaced so the bridge can warn.
        var skipped: [SkippedHook]
    }

    struct SkippedHook: Sendable, Equatable {
        let event: String
        let reason: String
    }

    static func parse(raw: JSONValue) throws -> ParsedConfig {
        var config: [HookPoint: [HookMatcherGroup]] = [:]
        var skipped: [SkippedHook] = []
        // Accept either a `{ hooks: … }` wrapper or the bare event map.
        let root = raw.objectValue
        let hooksMap = root?["hooks"]?.objectValue ?? root
        guard let hooksMap, !hooksMap.isEmpty else { return ParsedConfig(config: [:], skipped: []) }

        for event in supportedEvents.sorted() {
            guard case let .array(rawGroups)? = hooksMap[event] else { continue }
            var groups: [HookMatcherGroup] = []
            for rawGroup in rawGroups {
                guard let groupObject = rawGroup.objectValue,
                      case let .array(rawHooks)? = groupObject["hooks"] else { continue }
                var commands: [CommandHook] = []
                for rawHook in rawHooks {
                    guard let hookObject = rawHook.objectValue else { continue }
                    let type = hookObject["type"]?.stringValue ?? "command"
                    guard type == "command" else {
                        skipped.append(SkippedHook(event: event, reason: "type \(type)"))
                        continue
                    }
                    // Asynchronous hooks cannot be awaited by the runner.
                    let isAsync: Bool = {
                        guard let raw = hookObject["async"] else { return false }
                        if case let .bool(flag) = raw { return flag }
                        if case let .string(flag) = raw { return flag == "true" }
                        return false
                    }()
                    if isAsync {
                        skipped.append(SkippedHook(event: event, reason: "async"))
                        continue
                    }
                    guard let command = hookObject["command"]?.stringValue else { continue }
                    let timeout: Int? = {
                        guard case let .number(value)? = hookObject["timeout"] else { return nil }
                        return Int(value)
                    }()
                    commands.append(CommandHook(command: command, timeoutSec: timeout))
                }
                if commands.isEmpty { continue }
                var matcher: String?
                if !ClaudeCodeHookConfigParser.matcherlessEvents.contains(event) {
                    matcher = groupObject["matcher"]?.stringValue
                }
                // Codex matchers are always regex; an invalid one rejects the
                // complete config before listeners register.
                if let matcher, !matcher.isEmpty, matcher != "*" {
                    guard let regex = try? NSRegularExpression(pattern: matcher) else {
                        throw ClaudeCodeConfigError.invalidMatcher(matcher: matcher, event: event)
                    }
                    _ = regex
                }
                groups.append(HookMatcherGroup(matcher: matcher, hooks: commands))
            }
            if !groups.isEmpty {
                config[HookPoint(rawValue: event) ?? .preToolUse] = groups
            }
        }
        return ParsedConfig(config: config, skipped: skipped)
    }
}
