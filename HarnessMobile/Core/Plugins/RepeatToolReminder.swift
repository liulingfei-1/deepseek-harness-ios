import Foundation

/// Advisory per-Agent repeat-call detector ported from the vendored
/// `repeat-tool-reminder` Cordis guard. It only appends model-visible notice
/// context; it never vetoes, rewrites, or limits a tool call.
enum RepeatToolReminder {
    struct Configuration: Sendable, Equatable {
        var thresholds: [Int] = [3, 5, 8]
        var include: [String] = []
        var exclude: [String] = []
        var argumentsPreviewChars: Int = 500
    }

    static let pluginID: CordisPluginID = "core.repeat-tool-reminder"

    static func pluginDefinition(
        configuration: Configuration = Configuration()
    ) -> CordisPluginDefinition {
        CordisPluginDefinition(
            id: pluginID,
            version: "1",
            activate: { context in
                let normalized = try NormalizedConfiguration(configuration)
                let state = RepeatToolReminderState(
                    thresholds: normalized.thresholds,
                    include: normalized.include,
                    exclude: normalized.exclude,
                    argumentsPreviewChars: normalized.argumentsPreviewChars
                )
                _ = try await context.intercept(
                    CordisAgentLoopCheckpoints.toolsPostExecute,
                    label: "repeat-tool-reminder/post-execute"
                ) { input, next in
                    // Count before delegation so a downstream denial or value
                    // replacement cannot hide the repeated attempt.
                    let reminder = await state.observe(input.execution)
                    let downstream = try await next()
                    guard let reminder else { return downstream }
                    return CordisToolExecutionResult(
                        text: downstream.text,
                        isError: downstream.isError,
                        value: downstream.value,
                        errorCode: downstream.errorCode,
                        additionalContexts: [reminder] + downstream.additionalContexts
                    )
                }
                _ = try await context.intercept(
                    CordisAgentLoopCheckpoints.preStep,
                    label: "repeat-tool-reminder/pre-step"
                ) { input, next in
                    await state.resetForUserBoundary(input)
                    return try await next()
                }
            }
        )
    }

    private struct NormalizedConfiguration: Sendable {
        let thresholds: [Int]
        let include: [String]
        let exclude: [String]
        let argumentsPreviewChars: Int

        init(_ configuration: Configuration) throws {
            guard !configuration.thresholds.isEmpty else {
                throw RepeatToolReminderError.invalidThresholds("must not be empty")
            }
            guard configuration.thresholds.allSatisfy({ $0 >= 2 }) else {
                throw RepeatToolReminderError.invalidThresholds("must contain integers >= 2")
            }
            guard Set(configuration.thresholds).count == configuration.thresholds.count else {
                throw RepeatToolReminderError.invalidThresholds("must not contain duplicates")
            }
            guard configuration.argumentsPreviewChars >= 1 else {
                throw RepeatToolReminderError.invalidPreviewLength
            }
            thresholds = configuration.thresholds.sorted()
            include = configuration.include
            exclude = configuration.exclude
            argumentsPreviewChars = configuration.argumentsPreviewChars
        }
    }
}

enum RepeatToolReminderError: LocalizedError, Sendable, Equatable {
    case invalidThresholds(String)
    case invalidPreviewLength

    var errorDescription: String? {
        switch self {
        case let .invalidThresholds(reason):
            return "repeat-tool-reminder thresholds \(reason)."
        case .invalidPreviewLength:
            return "repeat-tool-reminder argumentsPreviewChars must be an integer >= 1."
        }
    }
}

private actor RepeatToolReminderState {
    private struct Chain: Sendable {
        let key: String
        let count: Int
    }

    private let thresholds: Set<Int>
    private let firstThreshold: Int
    private let include: [String]
    private let exclude: [String]
    private let argumentsPreviewChars: Int
    private var chains: [UUID: Chain] = [:]
    private var seenUserMessages: [UUID: Set<UUID>] = [:]

    init(
        thresholds: [Int],
        include: [String],
        exclude: [String],
        argumentsPreviewChars: Int
    ) {
        self.thresholds = Set(thresholds)
        self.firstThreshold = thresholds[0]
        self.include = include
        self.exclude = exclude
        self.argumentsPreviewChars = argumentsPreviewChars
    }

    func resetForUserBoundary(_ context: CordisAgentPreStepContext) {
        let directUserIDs = context.messages.compactMap { message -> UUID? in
            guard message.role == .user else { return nil }
            guard let source = message.source?.objectValue else { return message.id }
            return source["kind"] == .string("user") ? message.id : nil
        }
        guard !directUserIDs.isEmpty else { return }
        var seen = seenUserMessages[context.agentID, default: []]
        let hasNewBoundary = directUserIDs.contains { !seen.contains($0) }
        seen.formUnion(directUserIDs)
        seenUserMessages[context.agentID] = seen
        if hasNewBoundary {
            chains.removeValue(forKey: context.agentID)
        }
    }

    func observe(_ execution: CordisToolExecution) -> AgentMessage? {
        guard isTracked(execution.call.name) else { return nil }
        let canonicalArguments = Self.canonicalJSON(.object(execution.arguments))
        let key = "\(execution.call.name)\u{0}\(canonicalArguments)"
        let count: Int
        if let chain = chains[execution.agentID], chain.key == key {
            count = chain.count + 1
        } else {
            count = 1
        }
        chains[execution.agentID] = Chain(key: key, count: count)
        guard thresholds.contains(count) else { return nil }

        let content: String
        if count == firstThreshold {
            content = "You are repeating the exact same tool call with identical arguments. Carefully analyze the previous result before calling again: if the task is not complete, try a different approach or different arguments instead of repeating the call."
        } else {
            content = "Repeated tool call detected:\n"
                + "- tool: \(execution.call.name)\n"
                + "- consecutive_calls: \(count)\n"
                + "- arguments: \(Self.preview(canonicalArguments, maximumCharacters: argumentsPreviewChars))\n"
                + "The repeated calls are not making progress. Do not call this tool with these exact arguments again. Inspect the latest result and choose a different action, different arguments, or finish the task if enough evidence has been gathered."
        }
        let source: JSONValue = .object([
            "kind": .string("plugin"),
            "plugin": .string("repeat-tool-reminder"),
            "form": .string("notice"),
            "summary": .string("\(execution.call.name) × \(count)")
        ])
        return AgentMessage(role: .user, content: content, source: source)
    }

    private func isTracked(_ name: String) -> Bool {
        if !include.isEmpty && !include.contains(where: { Self.matches($0, name) }) {
            return false
        }
        return !exclude.contains(where: { Self.matches($0, name) })
    }

    private static func matches(_ pattern: String, _ value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        return (try? NSRegularExpression(pattern: "^(?:\(escaped))$"))?.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)
        ) != nil
    }

    private static func canonicalJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(value), encoding: .utf8)) ?? "null"
    }

    private static func preview(_ value: String, maximumCharacters: Int) -> String {
        guard value.count > maximumCharacters else { return value }
        return "\(value.prefix(maximumCharacters))… (+\(value.count - maximumCharacters) more chars)"
    }
}
