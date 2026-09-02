import Foundation

/// Mirrors upstream `hooks-claude-code/src/config.ts`: parsing of either a
/// settings `hooks` value or a bare `hooks.json` event map. Malformed entries
/// are ignored rather than failing boot; unsupported events are dropped before
/// their groups parse; non-command hooks land in `skipped`; substitutions are
/// applied to every surviving command. UserPromptSubmit and Stop have no
/// matcher subject, so their matcher fields are discarded. A matcher-bearing
/// supported group with an invalid regex rejects the whole config.
enum ClaudeCodeHookConfigParser {
    struct ParsedConfig: Sendable, Equatable {
        var config: [HookPoint: [HookMatcherGroup]]
        /// Non-command hooks that were skipped, for diagnostics.
        var skipped: [SkippedHook]
    }

    struct SkippedHook: Sendable, Equatable {
        let event: String
        let type: String
    }

    struct SubstitutionVars: Sendable, Equatable {
        var pluginRoot: String?
        var projectDir: String?
    }

    static let supportedEvents = Set(HookPoint.allCases.map(\.rawValue))
    /// Events with no matcher subject.
    static let matcherlessEvents: Set<String> = [
        HookPoint.userPromptSubmit.rawValue,
        HookPoint.stop.rawValue
    ]

    /// Replaces every occurrence of each set token in the command.
    static func substituteCommand(_ command: String, vars: SubstitutionVars) -> String {
        var out = command
        if let pluginRoot = vars.pluginRoot {
            out = out.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot)
        }
        if let projectDir = vars.projectDir {
            out = out.replacingOccurrences(of: "${CLAUDE_PROJECT_DIR}", with: projectDir)
        }
        return out
    }

    static func parse(raw: JSONValue, vars: SubstitutionVars = SubstitutionVars()) throws -> ParsedConfig {
        var config: [HookPoint: [HookMatcherGroup]] = [:]
        var skipped: [SkippedHook] = []
        // Accept either `{ hooks: { … } }` (a settings file) or the bare map.
        let root = raw.objectValue
        let hooksMap = root?["hooks"]?.objectValue ?? root
        guard let hooksMap, !hooksMap.isEmpty else { return ParsedConfig(config: [:], skipped: []) }

        for point in HookPoint.allCases {
            let event = point.rawValue
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
                        skipped.append(SkippedHook(event: event, type: type))
                        continue
                    }
                    guard let command = hookObject["command"]?.stringValue else { continue }
                    let timeout: Int? = {
                        guard case let .number(value)? = hookObject["timeout"] else { return nil }
                        return Int(value)
                    }()
                    commands.append(CommandHook(
                        command: substituteCommand(command, vars: vars),
                        timeoutSec: timeout
                    ))
                }
                if commands.isEmpty { continue }
                var matcher: String?
                if !matcherlessEvents.contains(event) {
                    matcher = groupObject["matcher"]?.stringValue
                }
                // A matcher-bearing supported group with an invalid regex
                // rejects the complete config before listeners register.
                if let matcher, !matcher.isEmpty, matcher != "*" {
                    guard let regex = try? NSRegularExpression(pattern: matcher) else {
                        throw ClaudeCodeConfigError.invalidMatcher(
                            matcher: matcher,
                            event: event
                        )
                    }
                    _ = regex
                }
                groups.append(HookMatcherGroup(matcher: matcher, hooks: commands))
            }
            if !groups.isEmpty {
                config[point] = groups
            }
        }
        return ParsedConfig(config: config, skipped: skipped)
    }
}

enum ClaudeCodeConfigError: LocalizedError, Equatable {
    case invalidMatcher(matcher: String, event: String)

    var errorDescription: String? {
        switch self {
        case let .invalidMatcher(matcher, event):
            "hooks 配置的 matcher 不是合法正则：\(matcher)（事件 \(event)）。"
        }
    }
}
