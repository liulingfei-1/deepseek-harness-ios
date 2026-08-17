import Foundation

struct ConversationContextProjection: Sendable, Equatable {
    let stateSummary: String?
    let messages: [AgentMessage]
    let omittedMessageCount: Int
    let encodedUTF8Bytes: Int
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
        let units = makeUnits(repaired)
        guard !units.isEmpty else {
            let summary = makeStateSummary(workState: workState, omittedMessageCount: 0)
            return try fittedProjection(
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
                omittedMessageCount: omittedCount
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
        let fullSummary = makeStateSummary(
            workState: workState,
            omittedMessageCount: omittedCount
        )
        return try fittedProjection(
            messages: selectedMessages,
            fullSummary: fullSummary,
            omittedMessageCount: omittedCount,
            maximumUTF8Bytes: maximumUTF8Bytes,
            mustFitMessages: true
        )
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
        omittedMessageCount: Int
    ) -> String? {
        var lines: [String] = []
        if omittedMessageCount > 0 {
            lines.append("Omitted transcript messages: \(omittedMessageCount)")
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

    private static func fittedProjection(
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
