import Foundation

/// Reconstructs the model-facing conversation from the lossless trajectory.
///
/// SessionStore is the UI snapshot and can lag the append-only stream around a
/// crash or force quit. This projection intentionally consumes only final
/// message events; streaming chunks are presentation/audit records and must
/// not become duplicate model messages on recovery.
enum SessionTrajectoryConversationProjection {
    static func messages(from events: [SessionEvent]) -> [AgentMessage] {
        surfaceNodes(from: events).map(\.message)
    }

    /// The balanced model-visible prefix that an in-process fork child may
    /// inherit. Delegation happens while the parent's current tool-calling
    /// turn is still open, so copying messages after the newest `turn/end`
    /// would create an assistant tool call without its eventual result. This
    /// mirrors dsh-subagent-fork-in-process: no completed turn means no seed.
    static func messagesThroughLastCompletedTurn(
        from events: [SessionEvent]
    ) -> [AgentMessage] {
        let ordered = events.sorted { $0.seq < $1.seq }
        guard let boundary = ordered.last(where: {
            $0.type == SessionEventVocabulary.turnEnd
        }) else { return [] }
        return messages(from: ordered.filter { $0.seq <= boundary.seq })
    }

    /// Returns the durable sequence range occupied by the oldest visible
    /// `count` surface messages. Compaction uses this to commit one upstream-
    /// compatible `surfaceOp.replace` instead of keeping a second hidden
    /// authority for the shortened model history.
    static func replacementRangeForPrefix(
        count: Int,
        events: [SessionEvent]
    ) -> ClosedRange<UInt64>? {
        guard count > 0 else { return nil }
        let nodes = surfaceNodes(from: events)
        guard count <= nodes.count,
              let first = nodes.first,
              let last = nodes.prefix(count).last else { return nil }
        return first.sequence...last.sequence
    }

    private struct SurfaceNode {
        let sequence: UInt64
        let message: AgentMessage
    }

    private static func surfaceNodes(from events: [SessionEvent]) -> [SurfaceNode] {
        var result: [SurfaceNode] = []
        var toolNames: [String: String] = [:]

        for event in events.sorted(by: { $0.seq < $1.seq }) {
            if let user = event.userMessageData,
               let message = decodeUserMessage(user) {
                apply(event: event, message: message, to: &result)
                continue
            }

            if let assistant = event.assistantMessageData,
               let message = decodeAssistantMessage(
                   assistant.message,
                   interrupted: assistant.interrupted
               ) {
                for call in message.toolCalls {
                    toolNames[call.id] = call.name
                }
                apply(event: event, message: message, to: &result)
                continue
            }

            if let tool = event.toolResultData,
               let callID = tool.callID,
               let message = decodeToolMessage(
                   tool.message,
                   callID: callID,
                   name: toolNames[callID],
                   error: tool.error
                ) {
                // A repaired interruption result is a real model-visible
                // message and is therefore deliberately included here.
                apply(event: event, message: message, to: &result)
            }
        }
        return result
    }

    private static func apply(
        event: SessionEvent,
        message: AgentMessage,
        to nodes: inout [SurfaceNode]
    ) {
        if case let .replace(start, end) = event.surfaceOp {
            nodes.removeAll { start...end ~= $0.sequence }
        }
        nodes.append(SurfaceNode(sequence: event.seq, message: message))
    }

    /// Repairs a SessionStore snapshot by appending the durable trajectory
    /// suffix after its last exact message boundary. SessionStore remains the
    /// selected UI branch, while the trajectory supplies messages committed
    /// after the last snapshot (including synthetic interruption results).
    static func reconcile(
        sessionMessages: [AgentMessage],
        events: [SessionEvent]
    ) -> [AgentMessage] {
        let recovered = messages(from: events)
        guard !recovered.isEmpty else { return sessionMessages }

        guard !sessionMessages.isEmpty else { return recovered }

        // A durable surface replacement intentionally removes the old prefix
        // from the trajectory. SessionStore may still contain that stale prefix
        // because compaction is model-facing context and is not a chat-visible
        // message commit. Reconcile by preserving the newest common suffix and
        // taking the replacement prefix from the trajectory; otherwise the next
        // cold run would resurrect all compacted messages from SessionStore.
        if events.contains(where: {
            if case .replace = $0.surfaceOp { return true }
            return false
        }) {
            var suffixLength = 0
            while suffixLength < sessionMessages.count,
                  suffixLength < recovered.count,
                  sameModelSurfaceMessage(
                      sessionMessages[sessionMessages.count - 1 - suffixLength],
                      recovered[recovered.count - 1 - suffixLength]
                  ) {
                suffixLength += 1
            }
            if suffixLength > 0 {
                return Array(recovered.dropLast(suffixLength))
                    + Array(sessionMessages.suffix(suffixLength))
            }
            return recovered
        }

        // Find the newest exact boundary shared by both stores. Any durable
        // trajectory messages after that boundary belong between the snapshot
        // prefix and a newly typed, not-yet-logged user message.
        var boundary: (session: Int, recovered: Int)?
        for sessionIndex in sessionMessages.indices.reversed() {
            guard let recoveredIndex = recovered.lastIndex(where: {
                sameModelSurfaceMessage($0, sessionMessages[sessionIndex])
            }) else { continue }
            boundary = (sessionIndex, recoveredIndex)
            break
        }
        guard let boundary else {
            // An edited/rerun branch intentionally has a different message
            // identity or content. Do not resurrect its old trajectory.
            return sessionMessages
        }
        let trajectorySuffix = recovered.dropFirst(boundary.recovered + 1)
        guard !trajectorySuffix.isEmpty else { return sessionMessages }
        let sessionSuffix = sessionMessages.dropFirst(boundary.session + 1)
        return Array(sessionMessages.prefix(boundary.session + 1))
            + trajectorySuffix
            + sessionSuffix
    }

    private static func decodeUserMessage(_ value: JSONValue) -> AgentMessage? {
        decodeMessage(value, role: .user)
    }

    private static func decodeAssistantMessage(
        _ value: JSONValue,
        interrupted: Bool
    ) -> AgentMessage? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let content = contentBlocks(object["content"]),
              let role = object["role"]?.stringValue,
              role == AgentRole.assistant.rawValue else { return nil }

        var text = ""
        var reasoning: String?
        var calls: [AgentToolCall] = []
        for block in content {
            guard let blockObject = block.objectValue,
                  let type = blockObject["type"]?.stringValue else { continue }
            switch type {
            case "text":
                text += blockObject["text"]?.stringValue ?? ""
            case "reasoning", "thinking":
                let value = blockObject["text"]?.stringValue
                    ?? blockObject["thinking"]?.stringValue
                    ?? ""
                if !value.isEmpty { reasoning = (reasoning ?? "") + value }
            case "tool-call":
                guard let callID = blockObject["id"]?.stringValue
                        ?? blockObject["callId"]?.stringValue,
                      let name = blockObject["name"]?.stringValue,
                      let arguments = blockObject["arguments"]?.stringValue else { continue }
                calls.append(AgentToolCall(id: callID, name: name, arguments: arguments))
            default:
                continue
            }
        }

        return AgentMessage(
            id: id,
            role: .assistant,
            content: text,
            reasoning: reasoning,
            toolCalls: calls,
            isIncomplete: interrupted,
            source: object["source"]
        )
    }

    private static func decodeToolMessage(
        _ value: JSONValue,
        callID: String,
        name: String?,
        error: JSONValue?
    ) -> AgentMessage? {
        guard let object = value.objectValue,
              let content = contentBlocks(object["content"]) else { return nil }
        let text = content.map(textContent).joined()
        let isError = content.contains {
            $0.objectValue?["isError"] == .bool(true)
        } || error != nil
        return AgentMessage.tool(
            callID: callID,
            name: name,
            content: text,
            isError: isError
        )
    }

    private static func decodeMessage(_ value: JSONValue, role: AgentRole) -> AgentMessage? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              object["role"]?.stringValue == role.rawValue,
              let content = contentBlocks(object["content"]) else { return nil }
        let text = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        let source: JSONValue?
        if role == .user,
           object["source"]?.objectValue?["kind"]?.stringValue == "user" {
            source = nil
        } else {
            source = object["source"]
        }
        let attachmentValues: [JSONValue]
        if case let .array(values)? = object["imageAttachments"] {
            attachmentValues = values
        } else {
            attachmentValues = []
        }
        let attachments: [AgentImageAttachmentRef] = attachmentValues
            .compactMap { value in
                guard let item = value.objectValue,
                      let rawID = item["id"]?.stringValue,
                      let attachmentID = UUID(uuidString: rawID),
                      let path = item["path"]?.stringValue,
                      let mimeType = item["mimeType"]?.stringValue else { return nil }
                let byteCount = item["byteCount"].flatMap { value -> Int? in
                    guard case let .number(number) = value,
                          number.isFinite,
                          number >= 0,
                          number <= Double(Int.max) else { return nil }
                    return Int(number)
                } ?? 0
                return AgentImageAttachmentRef(
                    id: attachmentID,
                    path: path,
                    mimeType: mimeType,
                    byteCount: byteCount
                )
            }
        return AgentMessage(
            id: id,
            role: role,
            content: text,
            source: source,
            imageAttachments: attachments
        )
    }

    private static func contentBlocks(_ value: JSONValue?) -> [JSONValue]? {
        guard case let .array(values)? = value else { return nil }
        return values
    }

    private static func textContent(_ value: JSONValue) -> String {
        guard let object = value.objectValue else { return "" }
        if let text = object["text"]?.stringValue { return text }
        guard case let .array(children)? = object["content"] else { return "" }
        return children.map(textContent).joined()
    }

    private static func uuid(_ value: JSONValue?) -> UUID? {
        guard let string = value?.stringValue else { return nil }
        return UUID(uuidString: string)
    }

    private static func sameModelSurfaceMessage(
        _ lhs: AgentMessage,
        _ rhs: AgentMessage
    ) -> Bool {
        guard lhs.role == rhs.role,
              lhs.content == rhs.content,
              lhs.reasoning == rhs.reasoning,
              lhs.toolCalls == rhs.toolCalls,
              lhs.toolCallID == rhs.toolCallID,
              lhs.isToolError == rhs.isToolError else { return false }
        if lhs.role == .tool {
            return lhs.toolName == rhs.toolName || lhs.toolName == nil || rhs.toolName == nil
        }
        return lhs.id == rhs.id
    }
}
