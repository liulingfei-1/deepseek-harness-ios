import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class CustomOpenAICompatibleWireTests: XCTestCase {
    func testUnknownCustomGatewayUsesConservativeLegacyProfile() throws {
        var configuration = customConfiguration()
        configuration.reasoningMode = .high
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [
                .assistant(
                    "",
                    reasoning: "provider-private reasoning",
                    toolCalls: [AgentToolCall(id: "call-1", name: "clock", arguments: "{}")]
                )
            ],
            tools: []
        )

        let object = try jsonObject(OpenAICompatibleClient.encodeOpenAIRequestBody(request))
        XCTAssertNil(object["thinking"])
        XCTAssertNil(object["reasoning_effort"])
        XCTAssertNil(object["stream_options"])
        XCTAssertFalse(containsNull(object))
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[1]["content"] as? String, "")
        XCTAssertNil(messages[1]["reasoning_content"])
        XCTAssertNotNil(messages[1]["tool_calls"])
        let toolCalls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        XCTAssertFalse(containsNull(toolCalls))
    }

    func testOpenAIProfileKeepsSupportedEffortButDropsDeepSeekFields() throws {
        var configuration = AgentConfiguration(
            providerID: .openAI,
            baseURL: "https://api.openai.com/v1",
            model: "gpt-5"
        )
        configuration.reasoningMode = .high
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [.assistant("answer", reasoning: "do not replay")],
            tools: []
        )

        let object = try jsonObject(OpenAICompatibleClient.encodeOpenAIRequestBody(request))
        XCTAssertEqual(object["reasoning_effort"] as? String, "high")
        XCTAssertNil(object["thinking"])
        XCTAssertNotNil(object["stream_options"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertNil(messages[1]["reasoning_content"])
    }

    func testKnownDeepSeekHostRetainsDeepSeekDialectEvenOnCustomRoute() throws {
        var configuration = customConfiguration(baseURL: "https://api.deepseek.com")
        configuration.reasoningMode = .low
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [.assistant("", toolCalls: [AgentToolCall(id: "c", name: "clock", arguments: "{}")])],
            tools: []
        )

        let object = try jsonObject(OpenAICompatibleClient.encodeOpenAIRequestBody(request))
        XCTAssertEqual((object["thinking"] as? [String: Any])?["type"] as? String, "enabled")
        XCTAssertEqual(object["reasoning_effort"] as? String, "low")
        XCTAssertNotNil(object["stream_options"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, "")
        XCTAssertEqual(messages[1]["content"] as? String, "")
    }

    func testSparseGatewayOverridesAreAppliedIndependently() throws {
        var configuration = customConfiguration()
        configuration.reasoningMode = .high
        configuration.openAIWireProfile = .legacyGateway
        configuration.openAICompatibility = OpenAICompletionsCompatibility(
            supportsDeveloperRole: true,
            supportsReasoningEffort: true,
            supportsUsageInStreaming: true,
            maxTokensField: .maxCompletionTokens,
            requiresToolResultName: true,
            requiresAssistantAfterToolResult: true,
            requiresReasoningContentOnAssistantMessages: true
        )
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [
                .assistant(
                    "",
                    reasoning: "reasoning",
                    toolCalls: [AgentToolCall(id: "call-1", name: "clock", arguments: "{}")]
                ),
                .tool(callID: "call-1", name: "clock", content: "12:00"),
                .user("continue")
            ],
            tools: []
        )

        let object = try jsonObject(OpenAICompatibleClient.encodeOpenAIRequestBody(request))
        XCTAssertEqual(object["reasoning_effort"] as? String, "high")
        XCTAssertNotNil(object["stream_options"])
        XCTAssertNil(object["max_tokens"])
        XCTAssertEqual(object["max_completion_tokens"] as? Int, 8_192)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "developer")
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, "reasoning")
        XCTAssertEqual(messages[2]["name"] as? String, "clock")
        XCTAssertEqual(messages[3]["role"] as? String, "assistant")
        XCTAssertEqual(messages[4]["role"] as? String, "user")
    }

    func testCompatibilityCodablePreservesFalseAndRejectsUnknownOrNull() throws {
        let value = OpenAICompletionsCompatibility(
            supportsReasoningEffort: false,
            supportsUsageInStreaming: true
        )
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(
            OpenAICompletionsCompatibility.self,
            from: data
        )
        XCTAssertEqual(decoded.supportsReasoningEffort, false)
        XCTAssertEqual(decoded.supportsUsageInStreaming, true)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                OpenAICompletionsCompatibility.self,
                from: Data(#"{"supportsReasoningEffort":true,"typo":false}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                OpenAICompletionsCompatibility.self,
                from: Data(#"{"supportsReasoningEffort":null}"#.utf8)
            )
        )
    }

    func testLegacyReasoningDeltaSpellingsAreAccepted() throws {
        for key in ["reasoning", "reasoningContent"] {
            let events = try OpenAICompatibleClient().decodeEvents(
                "{\"choices\":[{\"index\":0,\"delta\":{\"\(key)\":\"thinking\"}}]}"
            )
            XCTAssertEqual(events, [.reasoning("thinking")])
        }
    }

    private func customConfiguration(
        baseURL: String = "https://gateway.example/v1"
    ) -> AgentConfiguration {
        AgentConfiguration(
            providerID: .customOpenAICompatible,
            baseURL: baseURL,
            model: "legacy-chat"
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func containsNull(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let object = value as? [String: Any] {
            return object.values.contains(where: containsNull)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsNull)
        }
        return false
    }
}
