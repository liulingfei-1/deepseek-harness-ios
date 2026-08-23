import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class DeepSeekWireTests: XCTestCase {
    func testToolTranscriptValidationRejectsMissingResultLocally() {
        let request = ModelRequest(
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [
                .assistant("", toolCalls: [
                    AgentToolCall(id: "call-missing", name: "fixture", arguments: "{}")
                ])
            ],
            tools: []
        )

        XCTAssertThrowsError(try OpenAICompatibleClient.encodeOpenAIRequestBody(request)) { error in
            guard case let ModelClientError.invalidToolTranscript(message) = error else {
                return XCTFail("expected local tool transcript validation, got: \(error)")
            }
            XCTAssertTrue(message.contains("call-missing"))
        }
    }

    func testToolTranscriptValidationRejectsOrphanAndDuplicateResults() {
        let orphan = ModelRequest(
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [.tool(callID: "orphan", content: "bad")],
            tools: []
        )
        XCTAssertThrowsError(try OpenAICompatibleClient.encodeOpenAIRequestBody(orphan))

        let duplicate = ModelRequest(
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [
                .assistant("", toolCalls: [
                    AgentToolCall(id: "call-duplicate", name: "fixture", arguments: "{}")
                ]),
                .tool(callID: "call-duplicate", content: "one"),
                .tool(callID: "call-duplicate", content: "two")
            ],
            tools: []
        )
        XCTAssertThrowsError(try OpenAICompatibleClient.encodeOpenAIRequestBody(duplicate))
    }

    func testModelReplayEnvelopeRoundTripsWithoutFlatteningAdapterState() throws {
        let replayState: JSONValue = .object([
            "kind": .string("signed-thinking"),
            "version": .number(1),
            "signature": .string("provider-opaque-value")
        ])
        let source = AgentModelSource(
            provider: "anthropic",
            model: "claude-test",
            replayState: replayState
        )
        let message = AgentMessage.assistant(
            "",
            reasoning: "private thought",
            toolCalls: [AgentToolCall(id: "call-1", name: "clock", arguments: "{}")],
            source: source.jsonValue
        )

        let restored = try JSONDecoder().decode(
            AgentMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(restored.modelSource, source)
        XCTAssertEqual(restored.modelSource?.replayState, replayState)
    }

    func testRequestBodyIsStableAcrossEquivalentSchemaInsertionOrder() throws {
        let firstSchema = JSONValue.object(Dictionary(uniqueKeysWithValues: [
            ("type", .string("object")),
            ("properties", .object([
                "beta": .object(["type": .string("number")]),
                "alpha": .object(["type": .string("string")])
            ])),
            ("additionalProperties", .bool(false))
        ]))
        let secondSchema = JSONValue.object(Dictionary(uniqueKeysWithValues: [
            ("additionalProperties", .bool(false)),
            ("properties", .object([
                "alpha": .object(["type": .string("string")]),
                "beta": .object(["type": .string("number")])
            ])),
            ("type", .string("object"))
        ]))
        XCTAssertEqual(firstSchema, secondSchema)

        func request(schema: JSONValue) -> ModelRequest {
            ModelRequest(
                configuration: AgentConfiguration(),
                apiKey: "test-only",
                systemPrompt: "stable system",
                messages: [.user("hello")],
                tools: [
                    ModelToolDefinition(
                        name: "ordered_schema",
                        description: "Tests deterministic request encoding.",
                        parameters: schema
                    )
                ]
            )
        }

        let first = try OpenAICompatibleClient.encodeOpenAIRequestBody(
            request(schema: firstSchema)
        )
        let second = try OpenAICompatibleClient.encodeOpenAIRequestBody(
            request(schema: secondSchema)
        )
        XCTAssertEqual(first, second)
    }

    func testModelSessionAllowsLongFirstTokenLatency() {
        let configuration = OpenAICompatibleClient.makeSessionConfiguration()

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 180)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 600)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

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

    func testPlainAssistantReplaysReasoningWithoutToolCalls() {
        let assistant = AgentMessage.assistant("answer", reasoning: "private thought")
        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [assistant]
        )

        XCTAssertEqual(messages[1].content, "answer")
        XCTAssertEqual(messages[1].reasoningContent, "private thought")
        XCTAssertNil(messages[1].toolCalls)
    }

    func testReasoningOnlyAssistantReplaysReasoningWithNonNullContent() {
        let assistant = AgentMessage.assistant("", reasoning: "reasoning-only turn")
        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [assistant]
        )

        XCTAssertEqual(messages[1].content, "")
        XCTAssertEqual(messages[1].reasoningContent, "reasoning-only turn")
        XCTAssertNil(messages[1].toolCalls)
    }

    func testPlainAssistantWithoutReasoningOmitsReasoningContent() {
        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [.assistant("answer")]
        )

        XCTAssertEqual(messages[1].content, "answer")
        XCTAssertNil(messages[1].reasoningContent)
    }

    func testVisionMessageUsesOpenAIImageURLPartsAndKeepsToolMessagesTextual() throws {
        let id = UUID()
        let user = AgentMessage.user(
            "看这张图",
            imageAttachments: [
                AgentImageAttachmentRef(
                    id: id,
                    path: "Attachments/\(id.uuidString).data",
                    mimeType: "image/png",
                    byteCount: 3
                )
            ]
        )
        let request = ModelRequest(
            configuration: AgentConfiguration(model: "deepseek-v4-flash-vision-exp"),
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [
                user,
                .assistant("", toolCalls: [
                    AgentToolCall(id: "call-1", name: "fixture", arguments: "{}")
                ]),
                .tool(callID: "call-1", content: "done")
            ],
            tools: [],
            imagePayloads: [ModelImagePayload(id: id, mimeType: "image/png", data: Data([1, 2, 3]))]
        )

        let encoded = try OpenAICompatibleClient.encodeOpenAIRequestBody(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(userContent[0]["type"] as? String, "text")
        XCTAssertEqual(userContent[1]["type"] as? String, "image_url")
        XCTAssertEqual(
            ((userContent[1]["image_url"] as? [String: String])?["url"]),
            "data:image/png;base64,AQID"
        )
        XCTAssertEqual(messages[3]["content"] as? String, "done")
    }

    func testVisionMessageUsesDeepSeekFilePartWhenFileAPIReferenceIsAvailable() throws {
        let id = UUID()
        let request = ModelRequest(
            configuration: AgentConfiguration(model: "deepseek-v4-flash-vision-exp"),
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [AgentMessage.user(
                "看这张图",
                imageAttachments: [AgentImageAttachmentRef(
                    id: id,
                    path: "Attachments/\(id.uuidString).png",
                    mimeType: "image/png",
                    byteCount: 3
                )]
            )],
            tools: [],
            imagePayloads: [ModelImagePayload(
                id: id,
                mimeType: "image/png",
                data: Data([1, 2, 3]),
                fileID: "file-api-test-123"
            )]
        )

        let encoded = try OpenAICompatibleClient.encodeOpenAIRequestBody(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(content[1]["type"] as? String, "file")
        XCTAssertEqual(content[1]["file_id"] as? String, "file-api-test-123")
        XCTAssertNil(content[1]["image_url"])
    }

    func testVisionMessageKeepsExplicitPlaceholderWhenEveryImageWasBudgetOmitted() throws {
        let id = UUID()
        let user = AgentMessage.user(
            "比较这张历史图片",
            imageAttachments: [
                AgentImageAttachmentRef(
                    id: id,
                    path: "Attachments/\(id.uuidString).jpg",
                    mimeType: "image/jpeg",
                    byteCount: 1_024
                )
            ]
        )
        let messages = ChatWireSerializer.makeMessages(
            systemPrompt: "system",
            messages: [user],
            imagePayloads: []
        )

        let encoded = try JSONEncoder().encode(messages[1])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let content = try XCTUnwrap(object["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"] as? String, "比较这张历史图片")
        XCTAssertEqual(
            content[1]["text"] as? String,
            "[1 earlier image(s) omitted because the request image limit was reached.]"
        )
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

    func testLowThinkingWireFieldsMatchLatestDeepSeekDialect() throws {
        var configuration = AgentConfiguration()
        configuration.reasoningMode = .low
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [.user("hello")],
            tools: []
        )

        let encoded = try JSONEncoder().encode(ChatWireSerializer.makeRequest(request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((object["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(object["reasoning_effort"] as? String, "low")
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

    func testDeepSeekCacheHitAndMissFieldsUseTheProviderValues() throws {
        let client = OpenAICompatibleClient()
        let events = try client.decodeEvents(
            """
            {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":12,"total_tokens":1012,"prompt_cache_hit_tokens":997,"prompt_cache_miss_tokens":3}}
            """
        )

        guard case let .usage(usage) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected a usage event")
        }
        XCTAssertEqual(usage.promptTokens, 1000)
        XCTAssertEqual(usage.cachedPromptTokens, 997)
        XCTAssertEqual(usage.uncachedPromptTokens, 3)
    }

    func testOpenAICompatCacheDetailsDoNotGetMaskedByAZeroDeepSeekField() throws {
        let client = OpenAICompatibleClient()
        let events = try client.decodeEvents(
            """
            {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":1,"total_tokens":1001,"prompt_cache_hit_tokens":0,"prompt_tokens_details":{"cached_tokens":997}}}
            """
        )

        guard case let .usage(usage) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected a usage event")
        }
        XCTAssertEqual(usage.cachedPromptTokens, 997)
        XCTAssertEqual(usage.uncachedPromptTokens, 3)
    }

    func testCacheFieldsCannotExceedPromptTokens() throws {
        let client = OpenAICompatibleClient()
        XCTAssertThrowsError(
            try client.decodeEvents(
                """
                {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11,"prompt_cache_hit_tokens":8,"prompt_cache_miss_tokens":8}}
                """
            )
        ) { error in
            guard case ModelClientError.invalidUsage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRetryAfterParsesSecondsAndRejectsUnsafeValues() {
        XCTAssertEqual(
            OpenAICompatibleClient.retryAfterMilliseconds("2"),
            2_000
        )
        XCTAssertNil(OpenAICompatibleClient.retryAfterMilliseconds("0"))
        XCTAssertNil(OpenAICompatibleClient.retryAfterMilliseconds("-1"))
        XCTAssertNil(OpenAICompatibleClient.retryAfterMilliseconds(String(repeating: "9", count: 40)))
        XCTAssertNil(OpenAICompatibleClient.retryAfterMilliseconds("not-a-date"))
    }

    func testRetryAfterParsesHTTPDateWithinBoundedWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = try XCTUnwrap(formatter.string(from: now.addingTimeInterval(3)))

        XCTAssertEqual(
            OpenAICompatibleClient.retryAfterMilliseconds(future, now: now),
            3_000
        )
        XCTAssertNil(
            OpenAICompatibleClient.retryAfterMilliseconds(
                formatter.string(from: now.addingTimeInterval(86_401)),
                now: now
            )
        )
    }

    func testProviderFailureMetadataCarriesRetryAndRequestFactsWithoutCredential() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Retry-After": "2",
                    "X-DeepSeek-Request-ID": "deepseek-req-1"
                ]
            )
        )
        let metadata = OpenAICompatibleClient.providerFailureMetadata(
            response: response,
            errorCode: "RATE_LIMIT",
            errorType: nil
        )

        XCTAssertEqual(metadata.status, 429)
        XCTAssertEqual(metadata.code, "RATE_LIMIT")
        XCTAssertEqual(metadata.retryAfterMilliseconds, 2_000)
        XCTAssertEqual(metadata.requestID, "deepseek-req-1")
        XCTAssertTrue(metadata.isRetryable)
        XCTAssertFalse(
            ModelClientError.httpFailure(metadata, "slow down")
                .localizedDescription.contains("Bearer")
        )
    }

    func testOpenAICompatibleStreamTerminationAcceptsEitherTerminalMarker() throws {
        let client = OpenAICompatibleClient()

        // A gateway may close cleanly after a semantic finish without sending
        // the optional [DONE] sentinel.
        let semanticFinish = try client.decodeEvents(
            "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}"
        )
        XCTAssertEqual(semanticFinish, [.finish(.stop)])

        // A gateway that only sends [DONE] is represented by the fallback
        // contract in performOpenAI; tool deltas select tool_calls.
        XCTAssertTrue(
            OpenAICompatibleClient.acceptsTerminalMarkers(
                sawSemanticFinish: true,
                sawDone: false
            )
        )
        XCTAssertTrue(
            OpenAICompatibleClient.acceptsTerminalMarkers(
                sawSemanticFinish: false,
                sawDone: true
            )
        )
        XCTAssertFalse(
            OpenAICompatibleClient.acceptsTerminalMarkers(
                sawSemanticFinish: false,
                sawDone: false
            )
        )

        XCTAssertTrue(OpenAICompatibleClient.isDoneMarker("[DONE]"))
        XCTAssertTrue(OpenAICompatibleClient.isDoneMarker("  [done]\n"))
        XCTAssertFalse(OpenAICompatibleClient.isDoneMarker("[DONE] extra"))
    }
}
