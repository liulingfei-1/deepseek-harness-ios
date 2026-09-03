import Foundation

struct ConversationContextProjection: Sendable, Equatable {
    let stateSummary: String?
    let omittedMessages: [AgentMessage]
    let messages: [AgentMessage]
    let omittedMessageCount: Int
    let encodedUTF8Bytes: Int
}

struct ConversationTokenMeasurement: Sendable, Equatable {
    let systemTokens: Int
    let toolsTokens: Int
    let messageTokens: Int

    var totalTokens: Int {
        systemTokens + toolsTokens + messageTokens
    }
}

struct ConversationTokenCompactionPlan: Sendable, Equatable {
    let measurement: ConversationTokenMeasurement
    let omittedMessages: [AgentMessage]
    let retainedMessages: [AgentMessage]
    let omittedTokens: Int
    let retainedTokens: Int
}

/// Swift port of the upstream token-meter's fixed heuristic: four UTF-16
/// code units per token plus role/block framing. It is deliberately only a
/// request-boundary pressure meter; provider usage remains the source of truth
/// for the UI's billed-token and cache statistics.
enum ConversationTokenMeter {
    private static let charactersPerToken = 4
    private static let blockOverhead = 4
    private static let roleOverhead = 4

    static func measure(_ request: ModelRequest) -> ConversationTokenMeasurement {
        ConversationTokenMeasurement(
            systemTokens: estimateText(request.systemPrompt) + roleOverhead,
            toolsTokens: estimateTools(request.tools),
            messageTokens: estimateMessages(request.messages)
        )
    }

    static func estimateMessages(_ messages: [AgentMessage]) -> Int {
        messages.reduce(into: 0) { total, message in
            total += estimateMessage(message)
        }
    }

    static func estimateMessage(_ message: AgentMessage) -> Int {
        var tokens = roleOverhead
        if !message.content.isEmpty {
            tokens += estimateText(message.content) + blockOverhead
            if message.role == .tool { tokens += blockOverhead }
        }
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            tokens += estimateText(reasoning) + blockOverhead
        }
        for call in message.toolCalls {
            // These identifiers are part of the provider wire envelope and
            // remain in every replayed tool transaction. Counting them keeps
            // tool-heavy histories from being underestimated until the
            // provider rejects an already-too-large request.
            tokens += estimateText(call.id)
                + estimateText(call.name)
                + estimateText(call.arguments)
                + blockOverhead
        }
        if let toolCallID = message.toolCallID, !toolCallID.isEmpty {
            tokens += estimateText(toolCallID) + blockOverhead
        }
        // Image references carry a route-owned request price; under the fixed
        // heuristic they retain a conservative structural price (mirrors
        // upstream dsh-token-meter). Previously they were not counted at all,
        // which let vision-heavy requests slip past the pressure meter.
        for attachment in message.imageAttachments {
            tokens += TokenPricing.structuralPrice(
                .init(label: "\(attachment.mimeType)/\(attachment.byteCount)B")
            )
        }
        return tokens
    }

    private static func estimateTools(_ tools: [ModelToolDefinition]) -> Int {
        guard !tools.isEmpty,
              let data = try? JSONEncoder().encode(tools),
              let text = String(data: data, encoding: .utf8) else { return 0 }
        return estimateText(text) + blockOverhead
    }

    private static func estimateText(_ text: String) -> Int {
        let count = text.utf16.count
        return (count + charactersPerToken - 1) / charactersPerToken
    }
}

enum ConversationCompactionError: LocalizedError, Sendable {
    case invalidMaximumUTF8Bytes
    case recentBoundaryExceedsLimit(requiredBytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidMaximumUTF8Bytes:
            return "模型上下文字节上限必须大于零。"
        case let .recentBoundaryExceedsLimit(requiredBytes, limit):
            return "最近完整事务需要 \(requiredBytes) 字节，超过 \(limit) 字节上限。"
        }
    }
}

enum ConversationCompactor {
    private struct ContextEnvelope: Encodable {
        let stateSummary: String?
        let messages: [AgentMessage]
    }

    private struct MessageUnit {
        let messages: [AgentMessage]
        let isToolTransaction: Bool

        var estimatedTokens: Int {
            ConversationTokenMeter.estimateMessages(messages)
        }
    }

    /// Selects the oldest balanced surface prefix for durable checkpoint
    /// replacement. The default policy mirrors upstream compaction-basic:
    /// trigger at 80% of the routed model window and retain at least 16% of the
    /// window as recent, verbatim message units. A provider-confirmed overflow
    /// bypasses the pressure threshold and keeps the newest indivisible unit.
    static func tokenCompactionPlan(
        for request: ModelRequest,
        contextWindow: Int?,
        force: Bool = false,
        thresholdRatio: Double = 0.8,
        retainRatio: Double = 0.16
    ) -> ConversationTokenCompactionPlan? {
        let measurement = ConversationTokenMeter.measure(request)
        if !force {
            guard let contextWindow, contextWindow > 0 else { return nil }
            let thresholdTokens = Int((Double(contextWindow) * thresholdRatio).rounded(.down))
            guard measurement.totalTokens >= thresholdTokens else { return nil }
        }

        let repaired = repairIncompleteToolTurn(request.messages)
        guard repaired == request.messages else { return nil }
        let units = makeUnits(repaired)
        guard units.count > 1 else { return nil }

        let minimumRetainedTokens: Int
        if force {
            minimumRetainedTokens = 0
        } else {
            guard let contextWindow else { return nil }
            minimumRetainedTokens = Int((Double(contextWindow) * retainRatio).rounded(.down))
        }
        var retainedUnitStart = units.count
        var retainedTokens = 0
        for index in units.indices.reversed() {
            retainedTokens += units[index].estimatedTokens
            retainedUnitStart = index
            if retainedTokens >= minimumRetainedTokens { break }
        }
        guard retainedUnitStart > 0 else { return nil }

        let omitted = units[..<retainedUnitStart].flatMap(\.messages)
        let retained = units[retainedUnitStart...].flatMap(\.messages)
        guard !omitted.isEmpty, !retained.isEmpty else { return nil }
        return ConversationTokenCompactionPlan(
            measurement: measurement,
            omittedMessages: omitted,
            retainedMessages: retained,
            omittedTokens: ConversationTokenMeter.estimateMessages(omitted),
            retainedTokens: ConversationTokenMeter.estimateMessages(retained)
        )
    }

    static func project(
        session: ConversationSession,
        maximumUTF8Bytes: Int
    ) throws -> ConversationContextProjection {
        try project(
            messages: session.messages,
            workState: session.workState,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    static func project(
        messages: [AgentMessage],
        workState: ConversationWorkState = ConversationWorkState(),
        maximumUTF8Bytes: Int
    ) throws -> ConversationContextProjection {
        guard maximumUTF8Bytes > 0 else {
            throw ConversationCompactionError.invalidMaximumUTF8Bytes
        }

        let repaired = repairIncompleteToolTurn(messages)
        // Mirrors upstream `compaction-tool-result-pruner`: while compaction
        // runs, tool results beyond the byte budget are replaced by a bounded
        // head, a middle marker, and a bounded tail. Tool calls, steps, errors
        // and metadata are preserved — only the text content changes. The full
        // original stays in the durable session log for exact replay.
        let pruned = pruneOversizedToolResults(repaired)
        let units = makeUnits(pruned)
        guard !units.isEmpty else {
            let summary = makeStateSummary(workState: workState, omittedMessageCount: 0)
            return try fittedProjection(
                omittedMessages: [],
                messages: [],
                fullSummary: summary,
                omittedMessageCount: 0,
                maximumUTF8Bytes: maximumUTF8Bytes,
                mustFitMessages: false
            )
        }

        // Preserve the newest complete tool transaction and every message after
        // it. Without one, preserve at least the newest message.
        let mandatoryStart = units.lastIndex(where: \.isToolTransaction)
            ?? (units.count - 1)
        var selectedStart = mandatoryStart
        var selectedMessages = units[mandatoryStart...].flatMap(\.messages)

        let mandatoryBytes = try encodedSize(summary: nil, messages: selectedMessages)
        guard mandatoryBytes <= maximumUTF8Bytes else {
            throw ConversationCompactionError.recentBoundaryExceedsLimit(
                requiredBytes: mandatoryBytes,
                limit: maximumUTF8Bytes
            )
        }

        // Add older history only as whole units. Structured state is prioritized
        // over stale transcript text by requiring its full summary to keep fitting.
        while selectedStart > 0 {
            let candidateStart = selectedStart - 1
            let candidateMessages = units[candidateStart...].flatMap(\.messages)
            let omittedCount = units[..<candidateStart]
                .reduce(0) { $0 + $1.messages.count }
            let summary = makeStateSummary(
                workState: workState,
                omittedMessageCount: omittedCount,
                omittedMessages: units[..<candidateStart].flatMap(\.messages)
            )
            let candidateBytes = try encodedSize(
                summary: summary,
                messages: candidateMessages
            )
            guard candidateBytes <= maximumUTF8Bytes else { break }
            selectedStart = candidateStart
            selectedMessages = candidateMessages
        }

        let omittedCount = units[..<selectedStart]
            .reduce(0) { $0 + $1.messages.count }
        let omittedMessages = units[..<selectedStart].flatMap(\.messages)
        let fullSummary = makeStateSummary(
            workState: workState,
            omittedMessageCount: omittedCount,
            omittedMessages: omittedMessages
        )
        return try fittedProjection(
            omittedMessages: omittedMessages,
            messages: selectedMessages,
            fullSummary: fullSummary,
            omittedMessageCount: omittedCount,
            maximumUTF8Bytes: maximumUTF8Bytes,
            mustFitMessages: true
        )
    }

    /// Replaces tool-result text beyond the pruner's byte budget with the
    /// bounded head/marker/tail form. Only `content` changes; role, tool call
    /// ids and every other field are preserved, matching upstream's
    /// "only the text content changes" contract.
    static func pruneOversizedToolResults(
        _ messages: [AgentMessage],
        maxBytes: Int = ToolResultPruner.defaultMaxBytes
    ) -> [AgentMessage] {
        guard messages.contains(where: { $0.role == .tool && $0.content.utf8.count > maxBytes }) else {
            return messages
        }
        return messages.map { message in
            guard message.role == .tool, message.content.utf8.count > maxBytes else {
                return message
            }
            var copy = message
            copy.content = ToolResultPruner.prune(message.content, maxBytes: maxBytes)
            return copy
        }
    }

    static func repairIncompleteToolTurn(
        _ messages: [AgentMessage]
    ) -> [AgentMessage] {
        var pendingCallIDs = Set<String>()
        var transactionStart: Int?
        var lastValidBoundary = 0

        for (index, message) in messages.enumerated() {
            if !pendingCallIDs.isEmpty {
                guard message.role == .tool,
                      let callID = message.toolCallID,
                      pendingCallIDs.remove(callID) != nil else {
                    return Array(messages.prefix(transactionStart ?? lastValidBoundary))
                }
                if pendingCallIDs.isEmpty {
                    transactionStart = nil
                    lastValidBoundary = index + 1
                }
                continue
            }

            if message.role == .assistant, !message.toolCalls.isEmpty {
                let ids = message.toolCalls.map(\.id)
                guard Set(ids).count == ids.count,
                      ids.allSatisfy({ !$0.isEmpty }) else {
                    return Array(messages.prefix(lastValidBoundary))
                }
                transactionStart = index
                pendingCallIDs = Set(ids)
            } else if message.role == .tool {
                return Array(messages.prefix(lastValidBoundary))
            } else {
                lastValidBoundary = index + 1
            }
        }

        if !pendingCallIDs.isEmpty {
            return Array(messages.prefix(transactionStart ?? lastValidBoundary))
        }
        return messages
    }

    private static func makeUnits(_ messages: [AgentMessage]) -> [MessageUnit] {
        var units: [MessageUnit] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            if message.role == .assistant, !message.toolCalls.isEmpty {
                let end = index + 1 + message.toolCalls.count
                precondition(end <= messages.count)
                units.append(
                    MessageUnit(
                        messages: Array(messages[index..<end]),
                        isToolTransaction: true
                    )
                )
                index = end
            } else {
                units.append(MessageUnit(messages: [message], isToolTransaction: false))
                index += 1
            }
        }
        return units
    }

    private static func makeStateSummary(
        workState: ConversationWorkState,
        omittedMessageCount: Int,
        omittedMessages: [AgentMessage] = []
    ) -> String? {
        var lines: [String] = []
        if omittedMessageCount > 0 {
            lines.append("Omitted transcript messages: \(omittedMessageCount)")
            let facts = summaryFacts(from: omittedMessages)
            if !facts.isEmpty {
                lines.append("Earlier transcript facts:")
                lines.append(contentsOf: facts)
            }
        }
        if let goal = workState.goal {
            lines.append("Goal [\(goal.status.rawValue)]: \(goal.title)")
        }
        if !workState.plan.isEmpty {
            lines.append("Plan:")
            lines.append(contentsOf: workState.plan.enumerated().map { index, step in
                "\(index + 1). [\(step.status.rawValue)] \(step.title)"
            })
        }
        if !workState.todos.isEmpty {
            lines.append("Todo:")
            lines.append(contentsOf: workState.todos.map {
                "- [\($0.status.rawValue)] \($0.title)"
            })
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Preserve a small deterministic set of old user/tool facts when history
    /// is compacted. This is deliberately extractive: it never invents facts
    /// and keeps tool transactions intact in the live message tail.
    private static func summaryFacts(from messages: [AgentMessage]) -> [String] {
        let candidates = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !candidates.isEmpty else { return [] }
        var selected: [AgentMessage] = []
        if let firstUser = candidates.first(where: { $0.role == .user }) {
            selected.append(firstUser)
        }
        for message in candidates.reversed() where selected.count < 4 {
            guard !selected.contains(where: { $0.id == message.id }) else { continue }
            selected.append(message)
        }
        return selected.prefix(4).map { message in
            let role: String
            switch message.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .tool: role = "tool"
            }
            return "- [\(role)] \(boundedPrefix(message.content, maximumUTF8Bytes: 420))"
        }
    }

    private static func boundedPrefix(_ value: String, maximumUTF8Bytes: Int) -> String {
        // Mirrors upstream `dsh-output-retention`'s byte-oriented head
        // window: cut only on UTF-8 boundaries, reserving room for the
        // ellipsis.
        let budget = max(0, maximumUTF8Bytes - 3)
        guard value.utf8.count > budget else { return value }
        return OutputRetention.safeHead(value, maxBytes: budget) + "..."
    }

    private static func fittedProjection(
        omittedMessages: [AgentMessage],
        messages: [AgentMessage],
        fullSummary: String?,
        omittedMessageCount: Int,
        maximumUTF8Bytes: Int,
        mustFitMessages: Bool
    ) throws -> ConversationContextProjection {
        let messagesOnlyBytes = try encodedSize(summary: nil, messages: messages)
        if mustFitMessages, messagesOnlyBytes > maximumUTF8Bytes {
            throw ConversationCompactionError.recentBoundaryExceedsLimit(
                requiredBytes: messagesOnlyBytes,
                limit: maximumUTF8Bytes
            )
        }

        let fittedSummary = try fitSummary(
            fullSummary,
            messages: messages,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        let bytes = try encodedSize(summary: fittedSummary, messages: messages)
        guard bytes <= maximumUTF8Bytes else {
            throw ConversationCompactionError.recentBoundaryExceedsLimit(
                requiredBytes: bytes,
                limit: maximumUTF8Bytes
            )
        }
        return ConversationContextProjection(
            stateSummary: fittedSummary,
            omittedMessages: omittedMessages,
            messages: messages,
            omittedMessageCount: omittedMessageCount,
            encodedUTF8Bytes: bytes
        )
    }

    private static func fitSummary(
        _ summary: String?,
        messages: [AgentMessage],
        maximumUTF8Bytes: Int
    ) throws -> String? {
        guard let summary, !summary.isEmpty else { return nil }
        if try encodedSize(summary: summary, messages: messages) <= maximumUTF8Bytes {
            return summary
        }

        let characters = Array(summary)
        var lower = 0
        var upper = characters.count
        var best: String?
        while lower <= upper {
            let middle = (lower + upper) / 2
            let prefix = String(characters.prefix(middle))
            let candidate = middle == characters.count ? prefix : prefix + "…"
            if try encodedSize(summary: candidate, messages: messages) <= maximumUTF8Bytes {
                best = candidate.isEmpty ? nil : candidate
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        return best
    }

    private static func encodedSize(
        summary: String?,
        messages: [AgentMessage]
    ) throws -> Int {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            ContextEnvelope(stateSummary: summary, messages: messages)
        ).count
    }
}
