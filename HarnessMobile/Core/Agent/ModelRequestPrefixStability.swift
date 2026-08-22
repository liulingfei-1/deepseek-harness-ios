import CryptoKit
import Foundation

enum ModelRequestPrefixDifference: Sendable, Equatable {
    case identical
    case messagesAppended(count: Int, workspaceInstructions: Bool)
    case systemPromptChanged
    case toolSchemaChanged
    case messagePrefixChanged(index: Int)
    case messagesRemoved(count: Int)
}

struct ModelRequestPrefixSnapshot: Sendable, Equatable {
    let systemPromptDigest: String
    let toolSchemaDigest: String
    let messageDigests: [String]
    let workspaceInstructionFlags: [Bool]

    static func capture(_ request: ModelRequest) -> Self {
        Self(
            systemPromptDigest: Self.digest(Data(request.systemPrompt.utf8)),
            toolSchemaDigest: Self.digest(Self.encode(request.tools)),
            messageDigests: request.messages.map { Self.digest(Self.encode(WireMessage($0))) },
            workspaceInstructionFlags: request.messages.map(\.isWorkspaceInstructionTransition)
        )
    }

    func difference(from previous: Self) -> ModelRequestPrefixDifference {
        guard systemPromptDigest == previous.systemPromptDigest else {
            return .systemPromptChanged
        }
        guard toolSchemaDigest == previous.toolSchemaDigest else {
            return .toolSchemaChanged
        }
        let commonCount = min(messageDigests.count, previous.messageDigests.count)
        for index in 0..<commonCount where messageDigests[index] != previous.messageDigests[index] {
            return .messagePrefixChanged(index: index)
        }
        if messageDigests.count == previous.messageDigests.count { return .identical }
        if messageDigests.count < previous.messageDigests.count {
            return .messagesRemoved(count: previous.messageDigests.count - messageDigests.count)
        }
        let appendedRange = previous.messageDigests.count..<messageDigests.count
        return .messagesAppended(
            count: appendedRange.count,
            workspaceInstructions: appendedRange.allSatisfy {
                workspaceInstructionFlags.indices.contains($0) && workspaceInstructionFlags[$0]
            }
        )
    }

    private struct WireMessage: Encodable {
        let role: AgentRole
        let content: String
        let reasoning: String?
        let toolCalls: [AgentToolCall]
        let toolCallID: String?
        let toolName: String?
        let isToolError: Bool?

        init(_ message: AgentMessage) {
            role = message.role
            content = message.content
            reasoning = message.reasoning
            toolCalls = message.toolCalls
            toolCallID = message.toolCallID
            toolName = message.toolName
            isToolError = message.isToolError
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
