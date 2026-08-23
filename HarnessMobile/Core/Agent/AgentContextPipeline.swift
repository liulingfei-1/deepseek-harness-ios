import Foundation

/// Pure, small-context rules for model-visible context. The runtime owns
/// persistence and event publication; this type decides only which durable
/// messages are safe to append. Keeping that distinction explicit lets an AI
/// change context policy without loading the stream/tool execution loop.
struct AgentContextPipeline {
    struct PreparedInstructionInjection: Sendable {
        let content: String
        let source: JSONValue
        let message: AgentMessage
    }

    struct RuntimeContextSnapshot: Sendable {
        let content: String
        let source: JSONValue
        let message: AgentMessage
    }

    static let maximumInstructionInjectionBytes = 256 * 1_024
    private static let clearedRuntimeContext =
        "Current runtime context: none. Earlier runtime-context snapshots no longer apply."

    static func normalizedUserContent(
        in injections: [AgentRuntimeInstructionInjection]
    ) throws -> String? {
        let normalizedContents = Set(
            injections.compactMap { injection in
                injection.normalizedUserContent?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )
        guard normalizedContents.count <= 1 else {
            throw AgentRuntimeError.conflictingNormalizedUserContent
        }
        return normalizedContents.first
    }

    static func prepare(
        _ injections: [AgentRuntimeInstructionInjection]
    ) throws -> [PreparedInstructionInjection] {
        try injections.compactMap { injection in
            let content = injection.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            guard content.utf8.count <= maximumInstructionInjectionBytes else {
                throw AgentRuntimeError.injectedInstructionTooLarge
            }
            let message = AgentMessage(role: .user, content: content, source: injection.source)
            return PreparedInstructionInjection(
                content: content,
                source: injection.source,
                message: message
            )
        }
    }

    /// Models receive dynamic Cordis state as an append-only user snapshot,
    /// preserving a stable system-prompt prefix for cache reuse and recovery.
    static func nextRuntimeContextSnapshot(
        current: String,
        retained: String?
    ) throws -> RuntimeContextSnapshot? {
        if retained == nil, current.isEmpty { return nil }
        let content = current.isEmpty ? clearedRuntimeContext : current
        guard retained != content else { return nil }
        guard content.utf8.count <= 128 * 1_024 else {
            throw AgentRuntimeError.injectedInstructionTooLarge
        }

        let source: JSONValue = .object([
            "kind": .string("plugin"),
            "plugin": .string(AgentMessage.runtimeContextPluginID),
            "form": .string("snapshot")
        ])
        let message = AgentMessage(role: .user, content: content, source: source)
        return RuntimeContextSnapshot(content: content, source: source, message: message)
    }
}
