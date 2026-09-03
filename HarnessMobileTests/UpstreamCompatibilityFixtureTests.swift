import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class UpstreamCompatibilityFixtureTests: XCTestCase {
    func testPinnedDeepSeekStreamingContract() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.source.commit,
            "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e"
        )

        let client = OpenAICompatibleClient()
        let events = try fixture.stream.payloads.flatMap(client.decodeEvents)
        XCTAssertEqual(events.map(Self.describe), fixture.stream.expectedEvents)
    }

    func testPinnedDeepSeekToolRoundTripReplayContract() throws {
        let fixture = try loadFixture()
        let replay = fixture.requestReplay
        let assistant = AgentMessage.assistant(
            replay.assistantContent,
            reasoning: replay.assistantReasoning,
            toolCalls: [
                AgentToolCall(
                    id: replay.toolCall.id,
                    name: replay.toolCall.name,
                    arguments: replay.toolCall.arguments
                )
            ]
        )

        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [
                assistant,
                .tool(callID: replay.toolCall.id, content: replay.toolResult)
            ],
            replayEmptyReasoningForToolCalls: replay.replayEmptyReasoning
        )

        XCTAssertEqual(messages.map(\.role), replay.expectedRoles)
        XCTAssertEqual(messages[1].reasoningContent, replay.expectedAssistantReasoning)
        XCTAssertEqual(messages[1].content, replay.assistantContent)
        XCTAssertEqual(messages[1].toolCalls?.first?.id, replay.toolCall.id)
        XCTAssertEqual(messages[2].toolCallID, replay.toolCall.id)
        XCTAssertEqual(messages[2].content, replay.toolResult)
    }

    private func loadFixture() throws -> HarnessWireFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
            .appendingPathComponent("deepseek", isDirectory: true)
            .appendingPathComponent("harness-wire-v1.json")
        return try JSONDecoder().decode(
            HarnessWireFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
    }

    private static func describe(_ event: LLMStreamEvent) -> String {
        switch event {
        case let .text(value):
            return "text:\(value)"
        case let .reasoning(value):
            return "reasoning:\(value)"
        case let .reasoningSignature(value):
            return "reasoningSignature:\(value)"
        case let .toolCallDelta(index, id, type, name, arguments):
            return [
                "tool",
                String(index),
                id ?? "-",
                type ?? "-",
                name ?? "-",
                arguments
            ].joined(separator: ":")
        case let .usage(value):
            return [
                "usage",
                String(value.promptTokens),
                String(value.completionTokens),
                String(value.totalTokens),
                value.cachedPromptTokens.map(String.init) ?? "-",
                value.reasoningTokens.map(String.init) ?? "-"
            ].joined(separator: ":")
        case let .finish(value):
            return "finish:\(value.rawValue)"
        }
    }
}

private struct HarnessWireFixture: Decodable {
    let schemaVersion: Int
    let source: Source
    let stream: Stream
    let requestReplay: RequestReplay

    struct Source: Decodable {
        let project: String
        let commit: String
    }

    struct Stream: Decodable {
        let payloads: [String]
        let expectedEvents: [String]
    }

    struct RequestReplay: Decodable {
        let replayEmptyReasoning: Bool
        let assistantContent: String
        let assistantReasoning: String?
        let toolCall: ToolCall
        let toolResult: String
        let expectedAssistantReasoning: String
        let expectedRoles: [String]

        struct ToolCall: Decodable {
            let id: String
            let name: String
            let arguments: String
        }
    }
}
