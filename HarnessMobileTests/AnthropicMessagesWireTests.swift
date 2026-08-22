import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class AnthropicMessagesWireTests: XCTestCase {
    func testSerializerPreservesUserImagesAsAnthropicBase64Blocks() throws {
        let imageID = UUID()
        let configuration = ModelProviderCatalog.applying(.anthropic, to: AgentConfiguration())
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system prompt",
            messages: [
                .user(
                    "describe",
                    imageAttachments: [
                        AgentImageAttachmentRef(
                            id: imageID,
                            path: "Attachments/\(imageID.uuidString).png",
                            mimeType: "image/png",
                            byteCount: 3
                        )
                    ]
                )
            ],
            tools: [],
            imagePayloads: [
                ModelImagePayload(
                    id: imageID,
                    mimeType: "image/png",
                    data: Data([1, 2, 3])
                )
            ]
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try AnthropicWireSerializer.encodeRequest(request))
                as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["text", "image"])
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")
    }

    func testSerializerRejectsUnsupportedImagePlacementAndMIME() throws {
        let imageID = UUID()
        let reference = AgentImageAttachmentRef(
            id: imageID,
            path: "Attachments/\(imageID.uuidString).bin",
            mimeType: "image/tiff",
            byteCount: 3
        )
        let payload = ModelImagePayload(
            id: imageID,
            mimeType: "image/tiff",
            data: Data([1, 2, 3])
        )
        XCTAssertThrowsError(
            try AnthropicWireSerializer.makeMessages(
                [.user("image", imageAttachments: [reference])],
                imagePayloads: [payload]
            )
        ) { error in
            XCTAssertEqual(
                error as? AnthropicMessagesWireError,
                .unsupportedImageMIME("image/tiff")
            )
        }

        let assistant = AgentMessage(
            role: .assistant,
            content: "",
            imageAttachments: [reference]
        )
        XCTAssertThrowsError(
            try AnthropicWireSerializer.makeMessages([assistant], imagePayloads: [payload])
        ) { error in
            XCTAssertEqual(
                error as? AnthropicMessagesWireError,
                .unsupportedImageRole("assistant")
            )
        }
    }

    func testMissingBoundedImagePayloadBecomesVisibleOmissionMarker() throws {
        let imageID = UUID()
        let messages = try AnthropicWireSerializer.makeMessages([
            .user(
                "",
                imageAttachments: [
                    AgentImageAttachmentRef(
                        id: imageID,
                        path: "Attachments/\(imageID.uuidString).png",
                        mimeType: "image/png",
                        byteCount: 3
                    )
                ]
            )
        ])
        let encoded = try JSONEncoder().encode(messages)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        let content = try XCTUnwrap(object[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertTrue(
            (content[0]["text"] as? String)?.contains("1 earlier image") == true
        )
    }

    func testSerializerUsesMessagesContentBlocksAndGroupsToolResults() throws {
        let configuration = ModelProviderCatalog.applying(.anthropic, to: AgentConfiguration())
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system prompt",
            messages: [
                .user("use both tools"),
                .assistant(
                    "",
                    toolCalls: [
                        AgentToolCall(
                            id: "toolu_1",
                            name: "first_tool",
                            arguments: "{\"value\":1}"
                        ),
                        AgentToolCall(
                            id: "toolu_2",
                            name: "second_tool",
                            arguments: "{}"
                        ),
                    ]
                ),
                .tool(callID: "toolu_1", content: "one"),
                .tool(callID: "toolu_2", content: "two", isError: true),
            ],
            tools: [
                ModelToolDefinition(
                    name: "first_tool",
                    description: "First tool",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                    ])
                )
            ]
        )

        let encoded = try JSONEncoder().encode(AnthropicWireSerializer.makeRequest(request))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["system"] as? String, "system prompt")
        XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["max_tokens"] as? Int, configuration.maxOutputTokens)

        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistant = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["tool_use", "tool_use"])
        XCTAssertEqual((assistant[0]["input"] as? [String: Int])?["value"], 1)
        let toolResults = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(toolResults.map { $0["tool_use_id"] as? String }, ["toolu_1", "toolu_2"])
        XCTAssertEqual(toolResults[1]["is_error"] as? Bool, true)

        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools[0]["input_schema"])
        XCTAssertNil(tools[0]["parameters"])
    }

    func testSerializerRejectsNonObjectToolArguments() throws {
        let assistant = AgentMessage.assistant(
            "",
            toolCalls: [
                AgentToolCall(id: "toolu_1", name: "bad_tool", arguments: "[]")
            ]
        )

        XCTAssertThrowsError(try AnthropicWireSerializer.makeMessages([assistant])) { error in
            XCTAssertEqual(
                error as? AnthropicMessagesWireError,
                .invalidToolArguments("bad_tool")
            )
        }
    }

    func testStreamDecoderMapsTextToolUseUsageAndFinish() throws {
        var decoder = AnthropicStreamDecoder()

        XCTAssertEqual(
            try decoder.decodeEvents(
                """
                {"type":"message_start","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":3,"output_tokens":0}}}
                """
            ),
            []
        )
        XCTAssertEqual(
            try decoder.decodeEvents(
                """
                {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Hi"}}
                """
            ),
            [.text("Hi")]
        )
        XCTAssertEqual(
            try decoder.decodeEvents(
                """
                {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"clock","input":{}}}
                """
            ),
            [.toolCallDelta(index: 1, id: "toolu_1", type: "function", name: "clock", arguments: "")]
        )
        XCTAssertEqual(
            try decoder.decodeEvents(
                """
                {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"zone\\":\\"UTC\\"}"}}
                """
            ),
            [.toolCallDelta(index: 1, id: nil, type: nil, name: nil, arguments: "{\"zone\":\"UTC\"}")]
        )

        let final = try decoder.decodeEvents(
            """
            {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}
            """
        )
        XCTAssertEqual(
            final,
            [
                .usage(
                    ModelTokenUsage(
                        promptTokens: 15,
                        completionTokens: 7,
                        totalTokens: 22,
                        cachedPromptTokens: 3,
                        reasoningTokens: nil
                    )
                ),
                .finish(.toolCalls),
            ]
        )
        XCTAssertTrue(
            AnthropicStreamDecoder.isMessageStop("{\"type\":\"message_stop\"}")
        )
        XCTAssertEqual(
            try decoder.decodeEvents("{\"type\":\"message_stop\"}"),
            []
        )
    }

    func testStreamErrorAndInvalidUsageAreRejected() throws {
        var decoder = AnthropicStreamDecoder()
        XCTAssertThrowsError(
            try decoder.decodeEvents(
                "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}"
            )
        ) { error in
            guard case ModelClientError.providerStreamFailure(
                code: "overloaded_error",
                message: "busy"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let failure = ModelRetryPolicy.failure(
            for: ModelClientError.providerStreamFailure(
                code: "overloaded_error",
                message: "busy"
            )
        )
        XCTAssertEqual(failure?.code, "SERVER")

        XCTAssertThrowsError(
            try decoder.decodeEvents(
                "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":-1}}"
            )
        ) { error in
            guard case ModelClientError.invalidUsage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
