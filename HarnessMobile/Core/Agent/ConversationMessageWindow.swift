import Foundation

/// A stable, bounded projection of durable messages for the SwiftUI chat.
///
/// Projection is intentionally performed only when the durable message revision
/// or paging limit changes. Streaming deltas must not rescan the retained
/// conversation or rebuild duplicate tool-result rows.
struct ConversationMessageWindow: Sendable, Equatable {
    let messages: [AgentMessage]
    let hiddenCount: Int
    let totalCount: Int

    static func project(_ source: [AgentMessage], limit: Int) -> ConversationMessageWindow {
        let visible = source.filter(\.isChatVisible)
        let representedCallIDs = visible.reduce(into: Set<String>()) { result, message in
            guard message.role == .assistant else { return }
            for event in message.toolEvents {
                event.collectCallIDs(into: &result)
            }
        }
        let deduplicated = visible.filter { message in
            guard message.role == .tool,
                  let callID = message.toolCallID else { return true }
            return !representedCallIDs.contains(callID)
        }
        let boundedLimit = max(0, limit)
        let presented = Array(deduplicated.suffix(boundedLimit))
        return ConversationMessageWindow(
            messages: presented,
            hiddenCount: max(0, deduplicated.count - presented.count),
            totalCount: deduplicated.count
        )
    }
}

/// Resolves the durable user message that a visible chat row should rerun.
/// User rows rerun themselves; assistant rows rerun the nearest preceding
/// user turn. Tool rows intentionally have no direct rerun action because
/// replay must restart at a user-authored boundary.
struct ConversationMessageActionTargets: Sendable, Equatable {
    let retryUserMessageIDByMessageID: [UUID: UUID]

    static func resolve(_ messages: [AgentMessage]) -> Self {
        var latestUserMessageID: UUID?
        var retryTargets: [UUID: UUID] = [:]
        retryTargets.reserveCapacity(messages.count)

        for message in messages where message.isChatVisible {
            switch message.role {
            case .user:
                latestUserMessageID = message.id
                retryTargets[message.id] = message.id
            case .assistant:
                if let latestUserMessageID {
                    retryTargets[message.id] = latestUserMessageID
                }
            case .tool:
                break
            }
        }
        return Self(retryUserMessageIDByMessageID: retryTargets)
    }
}

private extension AgentToolEvent {
    func collectCallIDs(into result: inout Set<String>) {
        result.insert(callID)
        for child in children {
            child.collectCallIDs(into: &result)
        }
    }
}
