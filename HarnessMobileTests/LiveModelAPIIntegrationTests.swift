import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class LiveModelAPIIntegrationTests: XCTestCase {
    func testConfiguredDeepSeekStreamWhenExplicitlyEnabled() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["HARNESS_LIVE_API_KEY"],
              !apiKey.isEmpty else {
            throw XCTSkip("Set HARNESS_LIVE_API_KEY only for an explicit live API test.")
        }

        var configuration = AgentConfiguration()
        configuration.reasoningMode = .off
        configuration.maxOutputTokens = 128
        let request = ModelRequest(
            configuration: configuration,
            apiKey: apiKey,
            systemPrompt: "This is a connectivity test. Follow the user instruction exactly.",
            messages: [.user("Reply with exactly OK")],
            tools: []
        )

        var text = ""
        var sawFinish = false
        for try await event in OpenAICompatibleClient().stream(request) {
            switch event {
            case let .text(delta):
                text += delta
            case .finish:
                sawFinish = true
            case .reasoning, .toolCallDelta, .usage:
                break
            }
        }

        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
        XCTAssertTrue(sawFinish)
    }

    func testDeepSeekLocalToolRoundTripWhenExplicitlyEnabled() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["HARNESS_LIVE_API_KEY"],
              !apiKey.isEmpty else {
            throw XCTSkip("Set HARNESS_LIVE_API_KEY only for an explicit live API test.")
        }

        var configuration = AgentConfiguration()
        configuration.reasoningMode = .high
        configuration.maxSteps = 4
        configuration.maxOutputTokens = 256
        let recorder = LiveEventRecorder()
        let runtime = AgentRuntime(
            client: OpenAICompatibleClient(),
            registry: LocalToolRegistry(tools: [LiveProbeTool()]),
            systemPrompt: "You are a protocol test. You must call live_probe exactly once before answering the user.",
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        try await runtime.run(
            history: [.user("Call live_probe, then reply with LOCAL_TOOL_OK.")],
            configuration: configuration,
            apiKey: apiKey
        )

        let events = await recorder.events
        let committed = events.compactMap { event -> [AgentMessage]? in
            guard case let .messagesCommitted(messages) = event else { return nil }
            return messages
        }
        XCTAssertEqual(committed.count, 2)
        XCTAssertEqual(committed.first?.map(\.role), [.assistant, .tool])
        XCTAssertTrue(committed.last?.last?.content.contains("LOCAL_TOOL_OK") == true)
    }
}

private struct LiveProbeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "live_probe",
        description: "Return the fixed local protocol-test value.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String { "local protocol probe" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        return "{\"probe\":\"LOCAL_TOOL_OK\"}"
    }
}

private actor LiveEventRecorder {
    private(set) var events: [AgentRuntimeEvent] = []

    func append(_ event: AgentRuntimeEvent) {
        events.append(event)
    }
}
