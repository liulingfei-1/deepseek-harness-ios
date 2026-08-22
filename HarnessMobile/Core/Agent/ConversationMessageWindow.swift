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

private extension AgentToolEvent {
    func collectCallIDs(into result: inout Set<String>) {
        result.insert(callID)
        for child in children {
            child.collectCallIDs(into: &result)
        }
    }
}
