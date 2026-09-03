import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Drives the ACP subagent client against an in-memory transport that plays
/// the agent side of the wire (initialize → session/new → streaming updates →
/// permission request → prompt result), pinning the request sequence, text
/// folding, permission policy answers, and closed stop-reason mapping.
final class ACPSubagentClientTests: XCTestCase {
    private final class MockTransport: ACPLineTransport, @unchecked Sendable {
        var onLine: @Sendable (String) -> Void = { _ in }
        private(set) var sent: [String] = []

        func send(_ line: String) {
            sent.append(line)
        }

        func agentResponds(_ object: [String: JSONValue]) {
            let data = try! JSONEncoder().encode(JSONValue.object(object))
            onLine(String(decoding: data, as: UTF8.self))
        }
    }

    private func request(id: Int, method: String) -> [String: JSONValue]? {
        nil
    }

    func testFullLifecycleFoldsTextAndMapsStopReason() {
        let transport = MockTransport()
        let client = ACPSubagentClient(transport: transport, cwd: "/workspace")
        client.run(prompt: "总结本次巡检")

        // initialize request shape
        XCTAssertTrue(transport.sent[0].contains("initialize"))
        XCTAssertTrue(transport.sent[0].contains("protocolVersion"))
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(1),
            "result": .object(["agentCapabilities": .object([:])])
        ])
        // session/new carries cwd and empty mcpServers
        XCTAssertTrue(transport.sent[1].contains("session/new"))
        XCTAssertTrue(transport.sent[1].contains("/workspace"))
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(2),
            "result": .object(["sessionId": .string("s-1")])
        ])
        // prompt carries sessionId and a text block
        XCTAssertTrue(transport.sent[2].contains("session/prompt"))
        XCTAssertTrue(transport.sent[2].contains("s-1"))
        XCTAssertTrue(transport.sent[2].contains("总结本次巡检"))

        // streaming updates fold into output text
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "method": .string("session/update"),
            "params": .object([
                "sessionId": .string("s-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("今日配注 ")])
                ])
            ])
        ])
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "method": .string("session/update"),
            "params": .object([
                "sessionId": .string("s-1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("42.5 吨。")])
                ])
            ])
        ])
        // terminal result
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(3),
            "result": .object(["stopReason": .string("end_turn")])
        ])

        XCTAssertEqual(client.outcome, .completed)
        XCTAssertEqual(client.outputText, "今日配注 42.5 吨。")
    }

    func testPermissionRequestAutoAnsweredByPolicy() {
        let transport = MockTransport()
        let client = ACPSubagentClient(transport: transport, cwd: "/workspace", permissionPolicy: .allow)
        client.run(prompt: "hi")
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(1),
            "result": .object([:])
        ])
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(2),
            "result": .object(["sessionId": .string("s")])
        ])
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(3),
            "result": .object(["stopReason": .string("end_turn")])
        ])
        // server→client permission request arrives mid-prompt
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(10), "method": .string("session/request_permission"),
            "params": .object([
                "options": .array([
                    .object(["optionId": .string("deny"), "kind": .string("reject_once")]),
                    .object(["optionId": .string("run-once"), "kind": .string("allow_once")])
                ]),
                "toolCall": .object(["kind": .string("execute")])
            ])
        ])
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(3),
            "result": .object(["stopReason": .string("end_turn")])
        ])

        let answer = transport.sent.last { $0.contains("request_permission") == false && $0.contains("\"id\":10") || $0.contains("\"id\": 10") }
        XCTAssertNotNil(answer)
        XCTAssertTrue(answer?.contains("selected") ?? false)
        XCTAssertTrue(answer?.contains("run-once") ?? false)
        XCTAssertEqual(client.outcome, .completed)
    }

    func testUnknownStopReasonIsErrorNotSilentSuccess() {
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object(["stopReason": .string("end_turn")])), .completed)
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object(["stopReason": .string("max_tokens")])), .maxTokens)
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object(["stopReason": .string("refusal")])), .refusal)
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object(["stopReason": .string("cancelled")])), .aborted)
        // max_turn_requests and unknown future variants are failures.
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object(["stopReason": .string("max_turn_requests")])), .error)
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object(["stopReason": .string("something-new")])), .error)
        XCTAssertEqual(ACPWire.stopOutcome(fromResult: .object([:])), .error)
    }

    func testRejectPolicyAnswersCancelled() {
        let transport = MockTransport()
        let client = ACPSubagentClient(transport: transport, cwd: "/w", permissionPolicy: .reject)
        client.run(prompt: "hi")
        transport.agentResponds(["jsonrpc": .string("2.0"), "id": .number(1), "result": .object([:])])
        transport.agentResponds(["jsonrpc": .string("2.0"), "id": .number(2), "result": .object(["sessionId": .string("s")])])
        transport.agentResponds(["jsonrpc": .string("2.0"), "id": .number(3), "result": .object(["stopReason": .string("end_turn")])])
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(10), "method": .string("session/request_permission"),
            "params": .object([
                "options": .array([.object(["optionId": .string("ok"), "kind": .string("allow_once")])])
            ])
        ])
        let answer = transport.sent.last { $0.contains("request_permission") == false && $0.contains("\"id\":10") || $0.contains("\"id\": 10") }
        XCTAssertTrue(answer?.contains("cancelled") ?? false)
    }

    func testCancelSendsSessionCancelNotification() {
        let transport = MockTransport()
        let client = ACPSubagentClient(transport: transport, cwd: "/w")
        client.run(prompt: "hi")
        transport.agentResponds(["jsonrpc": .string("2.0"), "id": .number(1), "result": .object([:])])
        transport.agentResponds(["jsonrpc": .string("2.0"), "id": .number(2), "result": .object(["sessionId": .string("s-9")])])
        client.cancel()
        XCTAssertTrue(transport.sent.contains { $0.contains("session/cancel") && $0.contains("s-9") })
    }

    func testProviderCatalogValidatesAndOrdersDescriptors() async throws {
        let zed = try ACPSubagentProviderDescriptor(id: "zed", command: "/usr/bin/node")
        let alpha = try ACPSubagentProviderDescriptor(
            id: "alpha",
            command: "/usr/bin/node",
            args: ["agent.mjs"],
            permission: .allow,
            environment: ["DEEPSEEK_API_KEY": "explicit"]
        )
        let catalog = ACPSubagentProviderCatalog(descriptors: [zed])
        await catalog.register(alpha)
        let ids = await catalog.all().map(\.id)
        let alphaPermission = await catalog.descriptor(id: "alpha")?.permission
        XCTAssertEqual(ids, ["alpha", "zed"])
        XCTAssertEqual(alphaPermission, .allow)
        XCTAssertThrowsError(try ACPSubagentProviderDescriptor(id: "", command: "/usr/bin/node"))
    }

    func testRunAndWaitReturnsStreamedOutput() async throws {
        let transport = MockTransport()
        let client = ACPSubagentClient(transport: transport, cwd: "/workspace")
        Task {
            while transport.sent.count < 1 { await Task.yield() }
            transport.agentResponds([
                "jsonrpc": .string("2.0"), "id": .number(1), "result": .object([:])
            ])
            transport.agentResponds([
                "jsonrpc": .string("2.0"), "id": .number(2),
                "result": .object(["sessionId": .string("s")])
            ])
            transport.agentResponds([
                "jsonrpc": .string("2.0"), "method": .string("session/update"),
                "params": .object([
                    "sessionId": .string("s"),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["text": .string("ok")])
                    ])
                ])
            ])
            transport.agentResponds([
                "jsonrpc": .string("2.0"), "id": .number(3),
                "result": .object(["stopReason": .string("end_turn")])
            ])
        }
        let result = try await client.runAndWait(prompt: "hi", timeout: .seconds(2))
        XCTAssertEqual(result, "ok")
    }

    func testRunAndWaitCancellationPropagatesToActiveSession() async throws {
        let transport = MockTransport()
        let client = ACPSubagentClient(transport: transport, cwd: "/workspace")
        let task = Task { () -> Result<String, Error> in
            do {
                return .success(try await client.runAndWait(prompt: "hi", timeout: .seconds(2)))
            } catch {
                return .failure(error)
            }
        }
        while transport.sent.count < 1 { await Task.yield() }
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(1), "result": .object([:])
        ])
        transport.agentResponds([
            "jsonrpc": .string("2.0"), "id": .number(2),
            "result": .object(["sessionId": .string("cancel-me")])
        ])
        while !transport.sent.contains(where: { $0.contains("session/prompt") }) {
            await Task.yield()
        }
        task.cancel()
        let result = await task.value
        guard case let .failure(error) = result else {
            return XCTFail("cancelled ACP run must fail")
        }
        XCTAssertEqual(error as? ACPSubagentError, .cancelled)
        XCTAssertTrue(transport.sent.contains { $0.contains("session/cancel") && $0.contains("cancel-me") })
    }
}
