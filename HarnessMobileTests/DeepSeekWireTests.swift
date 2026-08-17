import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class DeepSeekWireTests: XCTestCase {
    func testToolCallAssistantReplaysReasoningAndNonNullContent() throws {
        let assistant = AgentMessage.assistant(
            "",
            reasoning: "I should read the clock.",
            toolCalls: [
                AgentToolCall(id: "call-1", name: "device_time", arguments: "{}")
            ]
        )

        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [assistant, .tool(callID: "call-1", content: "ok")]
        )

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[1].role, "assistant")
        XCTAssertEqual(messages[1].content, "")
        XCTAssertEqual(messages[1].reasoningContent, "I should read the clock.")
        XCTAssertEqual(messages[1].toolCalls?.first?.id, "call-1")
        XCTAssertEqual(messages[2].role, "tool")
        XCTAssertEqual(messages[2].toolCallID, "call-1")
    }

    func testPlainAssistantDoesNotReplayReasoning() {
        let assistant = AgentMessage.assistant("answer", reasoning: "private thought")
        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [assistant]
        )

        XCTAssertEqual(messages[1].content, "answer")
        XCTAssertNil(messages[1].reasoningContent)
    }

    func testHighThinkingWireFieldsAndNoToolChoice() throws {
        var configuration = AgentConfiguration()
        configuration.reasoningMode = .high
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [.user("hello")],
            tools: []
        )

        let encoded = try JSONEncoder().encode(ChatWireSerializer.makeRequest(request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(
            (object["thinking"] as? [String: String])?["type"],
            "enabled"
        )
        XCTAssertEqual(object["reasoning_effort"] as? String, "high")
        XCTAssertNil(object["tool_choice"])
    }

    func testOfficialDeepSeekReplaysEmptyReasoningFieldForToolTurn() throws {
        var configuration = AgentConfiguration()
        configuration.reasoningMode = .high
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [
                .assistant(
                    "",
                    toolCalls: [
                        AgentToolCall(id: "call-1", name: "device_time", arguments: "{}")
                    ]
                )
            ],
            tools: []
        )

        let wire = ChatWireSerializer.makeRequest(request)
        XCTAssertEqual(wire.messages[1].reasoningContent, "")
        XCTAssertEqual(wire.messages[1].content, "")
    }

    func testUsageFallbackRejectsIntOverflow() throws {
        let payload = """
        {"choices":[],"usage":{"prompt_tokens":\(Int.max),"completion_tokens":1}}
        """

        XCTAssertThrowsError(try OpenAICompatibleClient().decodeEvents(payload)) { error in
            guard case ModelClientError.invalidUsage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUsageRejectsNegativeAndUnreasonablyLargeCounts() throws {
        let client = OpenAICompatibleClient()
        let negative = """
        {"choices":[],"usage":{"prompt_tokens":-1,"completion_tokens":0,"total_tokens":0}}
        """
        let tooLarge = """
        {"choices":[],"usage":{"prompt_tokens":100000001,"completion_tokens":0,"total_tokens":100000001}}
        """

        for payload in [negative, tooLarge] {
            XCTAssertThrowsError(try client.decodeEvents(payload)) { error in
                guard case ModelClientError.invalidUsage = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }
}
