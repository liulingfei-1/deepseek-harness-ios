import Foundation

/// Mirrors upstream `hook-protocol`: the dialect-neutral vocabulary shared by
/// the Claude Code and Codex hook bridges. Payload construction and
/// extension-point decision mapping remain owned by each bridge; this file
/// owns the types, the matcher, and the outcome parser.
enum HookDialect: String, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex
}

/// Hook points recognized by the protocol. The raw string stays the wire
/// format; this enum names the ones the runner can serve on this device.
enum HookPoint: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
}

/// One configured command hook — the `{ type: 'command', command, timeout? }`
/// shape shared by both dialects. Non-command hook types (prompt/agent/http)
/// are parsed-and-skipped by the configuration parser, so only this shape
/// reaches the runner.
struct CommandHook: Codable, Sendable, Equatable {
    let command: String
    /// Per-hook timeout in SECONDS (the wire unit).
    let timeoutSec: Int?

    init(command: String, timeoutSec: Int? = nil) {
        self.command = command
        self.timeoutSec = timeoutSec
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        timeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("command", forKey: .type)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(timeoutSec, forKey: .timeoutSec)
    }

    enum CodingKeys: String, CodingKey {
        case command
        case timeoutSec = "timeout"
        case type
    }

    /// Accepts only `{type: 'command', command, timeout?}`; other shapes
    /// (prompt/agent/http) return nil and are dropped by the parser.
    static func parse(from raw: JSONValue) -> CommandHook? {
        guard raw.objectValue?["type"]?.stringValue == "command" else { return nil }
        guard let command = raw.objectValue?["command"]?.stringValue, !command.isEmpty else {
            return nil
        }
        let timeout: Int? = {
            guard let raw = raw.objectValue?["timeout"], case let .number(value) = raw else { return nil }
            return Int(value)
        }()
        return CommandHook(command: command, timeoutSec: timeout)
    }
}

/// One matcher group: a matcher pattern (absent/`''`/`'*'` = match-all) plus
/// the command hooks that run when it matches.
struct HookMatcherGroup: Codable, Sendable, Equatable {
    var matcher: String?
    var hooks: [CommandHook]

    /// Claude Code uses literal matching when the pattern is purely
    /// `[A-Za-z0-9_|]+` (pipe = exact-match alternation) and regex otherwise.
    /// Codex is always regex.
    enum MatcherMode {
        case claudeCode
        case codex
    }

    func matches(toolName: String, mode: MatcherMode) -> Bool {
        let pattern = matcher ?? ""
        if pattern.isEmpty || pattern == "*" { return true }
        switch mode {
        case .claudeCode:
            let literalPattern = "^[A-Za-z0-9_|]+$"
            guard pattern.range(of: literalPattern, options: .regularExpression) != nil else {
                return HookMatcher.regexMatch(pattern: pattern, value: toolName)
            }
            return pattern.split(separator: "|").contains { $0 == toolName }
        case .codex:
            return HookMatcher.regexMatch(pattern: pattern, value: toolName)
        }
    }
}

enum HookMatcher {
    static func regexMatch(pattern: String, value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: (value as NSString).length)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

/// The dialect-neutral outcome a hook produced, parsed from its exit code +
/// stdout JSON + stderr by `parseHookOutput`. Every field is optional because
/// a hook may exercise any subset; the bridge decides which are meaningful
/// for its hook point.
struct HookOutput: Codable, Sendable, Equatable {
    /// The neutral decision folded from the two channels the reference
    /// protocols keep DISTINCT: legacy top-level `decision` (`approve`/`block`
    /// only) and `hookSpecificOutput.permissionDecision`
    /// (`allow`/`deny`/`ask`).
    enum Decision: String, Codable, Sendable {
        case approve, allow, block, deny, ask
    }

    var exitCode: Int?
    var stderr: String
    var stdout: String
    /// `false` ⇒ the hook asked to halt; `true`/absent ⇒ proceed.
    var continueFlag: Bool?
    var stopReason: String?
    var decision: Decision?
    var reason: String?
    var hookEventName: String?
    var additionalContext: String?
    var systemMessage: String?
    /// Parsed but NOT honored — input rewrite is deferred upstream too; a
    /// bridge logs and warns when present.
    var updatedInputPresent: Bool

    var wantsHalt: Bool { continueFlag == false }
    /// A blocking (exit 2) hook without an explicit decision blocks with its
    /// stderr as the reason.
    var isBlockingExit: Bool { exitCode == 2 }
}

enum HookProtocol {
    static let defaultStderrSummaryMaxChars = 200

    /// Parses a hook run into the neutral outcome. On a clean exit a hook may
    /// emit plain (non-JSON) stdout that the bridge renders as output or
    /// additional context, so the raw text is kept either way.
    static func parseHookOutput(exitCode: Int?, stdout: String, stderr: String) -> HookOutput {
        var output = HookOutput(
            exitCode: exitCode,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
            stdout: stdout,
            continueFlag: nil,
            stopReason: nil,
            decision: nil,
            reason: nil,
            hookEventName: nil,
            additionalContext: nil,
            systemMessage: nil,
            updatedInputPresent: false
        )
        guard exitCode != 2, exitCode != nil || !stdout.isEmpty else { return output }
        guard let data = stdout.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(fields) = json else {
            return output
        }
        if let raw = fields["continue"], case let .bool(continueValue) = raw {
            output.continueFlag = continueValue
        }
        if let raw = fields["stopReason"], case let .string(reason) = raw {
            output.stopReason = reason
        }
        if let raw = fields["systemMessage"], case let .string(systemMessage) = raw {
            output.systemMessage = systemMessage
        }
        if let raw = fields["additionalContext"], case let .string(additionalContext) = raw {
            output.additionalContext = additionalContext
        }
        if let raw = fields["hookEventName"], case let .string(hookEventName) = raw {
            output.hookEventName = hookEventName
        }
        if let raw = fields["hookSpecificOutput"], case let .object(specific) = raw,
           let nested = specific["hookEventName"], case let .string(nestedName) = nested {
            output.hookEventName = nestedName
        }
        if fields["updatedInput"]?.objectValue != nil {
            output.updatedInputPresent = true
        }
        // Legacy top-level decision: only `approve`/`block` are valid here.
        if let raw = fields["decision"], case let .string(legacy) = raw,
           legacy == "approve" || legacy == "block" {
            output.decision = HookOutput.Decision(rawValue: legacy)
        }
        // permissionDecision is the only source of allow/deny/ask.
        if let raw = fields["hookSpecificOutput"], case let .object(specific) = raw {
            if let rawPerm = specific["permissionDecision"], case let .string(permission) = rawPerm {
                output.decision = HookOutput.Decision(rawValue: permission) ?? output.decision
            }
            if let rawReason = specific["permissionDecisionReason"], case let .string(permissionReason) = rawReason {
                output.reason = permissionReason
            }
        }
        if output.decision == nil, output.reason == nil,
           case let .string(reason)? = fields["reason"] {
            output.reason = reason
        }
        return output
    }

    /// A hook blocks the wrapped action when it exited 2 with no explicit
    /// decision, or asked to halt, or decided deny/block.
    static func blocks(_ output: HookOutput) -> Bool {
        if output.wantsHalt { return true }
        switch output.decision {
        case .block, .deny:
            return true
        case .approve, .allow, .ask, .none:
            return output.isBlockingExit
        }
    }

    /// The reason a blocking hook reports, bounded to the stderr budget.
    static func blockReason(_ output: HookOutput) -> String {
        if let reason = output.reason, !reason.isEmpty { return reason }
        if let stopReason = output.stopReason, !stopReason.isEmpty { return stopReason }
        return String(output.stderr.prefix(defaultStderrSummaryMaxChars))
    }
}

struct HookRunResult: Sendable, Equatable {
    let outputs: [HookOutput]
    let blocked: Bool
    let blockReason: String?
    let additionalContext: [String]
}

/// Executes configured command hooks in declaration order. Process spawning
/// remains an injected boundary (iSH/ACP/host supplies the executor), while
/// matching, stdin JSON construction and decision folding are shared with the
/// desktop hook protocol.
enum HookRunner {
    typealias Executor = @Sendable (_ command: String, _ stdinJSON: String, _ timeoutSec: Int?) async throws -> HookOutput

    static func run(
        point: HookPoint,
        toolName: String?,
        payload: JSONValue,
        groups: [HookMatcherGroup],
        mode: HookMatcherGroup.MatcherMode,
        executor: @escaping Executor
    ) async -> HookRunResult {
        let stdinJSON = payload.displayText
        var outputs: [HookOutput] = []
        var contexts: [String] = []
        for group in groups {
            guard group.matches(toolName: toolName ?? "", mode: mode) else { continue }
            for hook in group.hooks {
                do {
                    let output = try await executor(hook.command, stdinJSON, hook.timeoutSec)
                    outputs.append(output)
                    if let context = output.additionalContext, !context.isEmpty {
                        contexts.append(context)
                    }
                    if HookProtocol.blocks(output) {
                        return HookRunResult(
                            outputs: outputs,
                            blocked: true,
                            blockReason: HookProtocol.blockReason(output),
                            additionalContext: contexts
                        )
                    }
                } catch {
                    let output = HookOutput(
                        exitCode: nil,
                        stderr: String(describing: error),
                        stdout: "",
                        continueFlag: false,
                        stopReason: "hook execution failed",
                        decision: .block,
                        reason: String(describing: error),
                        hookEventName: point.rawValue,
                        additionalContext: nil,
                        systemMessage: nil,
                        updatedInputPresent: false
                    )
                    outputs.append(output)
                    return HookRunResult(outputs: outputs, blocked: true, blockReason: HookProtocol.blockReason(output), additionalContext: contexts)
                }
            }
        }
        return HookRunResult(outputs: outputs, blocked: false, blockReason: nil, additionalContext: contexts)
    }
}
