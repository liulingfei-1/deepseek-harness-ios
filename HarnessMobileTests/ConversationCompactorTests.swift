import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ConversationCompactorTests: XCTestCase {
    func testTokenPressureBelowThresholdDoesNotCompactAt79Percent() {
        let request = makeRequest(messages: [
            .user(String(repeating: "u", count: 65)),
            .assistant(String(repeating: "a", count: 65)),
            .user(String(repeating: "n", count: 65))
        ])

        let measurement = ConversationTokenMeter.measure(request)
        XCTAssertEqual(measurement.totalTokens, 79)
        XCTAssertNil(
            ConversationCompactor.tokenCompactionPlan(
                for: request,
                contextWindow: 100
            )
        )
    }

    func testTokenPressureAt80PercentCompacts() {
        let request = makeRequest(messages: [
            .user(String(repeating: "u", count: 120)),
            .assistant(String(repeating: "a", count: 120))
        ])

        let measurement = ConversationTokenMeter.measure(request)
        XCTAssertEqual(measurement.totalTokens, 80)
        let plan = ConversationCompactor.tokenCompactionPlan(
            for: request,
            contextWindow: 100
        )
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.omittedMessages.map(\.id), [request.messages[0].id])
        XCTAssertEqual(plan?.retainedMessages.map(\.id), [request.messages[1].id])
    }

    func testTokenPressureIncludesSystemPromptAndToolDefinitions() {
        let requestWithoutPromptAndTools = makeRequest(messages: [
            .user(String(repeating: "u", count: 32)),
            .assistant(String(repeating: "a", count: 32))
        ])
        let request = ModelRequest(
            configuration: requestWithoutPromptAndTools.configuration,
            apiKey: requestWithoutPromptAndTools.apiKey,
            systemPrompt: String(repeating: "system ", count: 40),
            messages: requestWithoutPromptAndTools.messages,
            tools: [
                ModelToolDefinition(
                    name: "large_tool",
                    description: String(repeating: "tool ", count: 40),
                    parameters: .object([:])
                )
            ]
        )

        let messagesOnly = ConversationTokenMeter.estimateMessages(request.messages)
        let measurement = ConversationTokenMeter.measure(request)
        XCTAssertLessThan(messagesOnly, 80)
        XCTAssertGreaterThan(measurement.systemTokens, 0)
        XCTAssertGreaterThan(measurement.toolsTokens, 0)
        XCTAssertGreaterThanOrEqual(measurement.totalTokens, 80)
        XCTAssertNotNil(
            ConversationCompactor.tokenCompactionPlan(
                for: request,
                contextWindow: 100
            )
        )
    }

    func testTokenCompactionRetainsAtLeastRecent16PercentAsCompleteUnits() {
        let messages = [
            AgentMessage.user(String(repeating: "1", count: 48)),
            AgentMessage.assistant(String(repeating: "2", count: 48)),
            AgentMessage.user(String(repeating: "3", count: 48)),
            AgentMessage.assistant(String(repeating: "4", count: 48)),
            AgentMessage.user(String(repeating: "5", count: 48))
        ]
        let request = makeRequest(messages: messages)
        let plan = try! XCTUnwrap(
            ConversationCompactor.tokenCompactionPlan(
                for: request,
                contextWindow: 100
            )
        )

        XCTAssertGreaterThanOrEqual(plan.retainedTokens, 16)
        XCTAssertEqual(plan.retainedMessages.map(\.id), messages.suffix(1).map(\.id))
        XCTAssertEqual(plan.omittedMessages.map(\.id), messages.dropLast().map(\.id))
    }

    func testTokenCompactionKeepsMultiCallTransactionTogether() {
        let call = AgentMessage.assistant(
            "",
            toolCalls: [
                AgentToolCall(id: "first", name: "one", arguments: "{}"),
                AgentToolCall(id: "second", name: "two", arguments: "{}")
            ]
        )
        let resultOne = AgentMessage.tool(callID: "first", content: "one")
        let resultTwo = AgentMessage.tool(callID: "second", content: "two")
        let request = makeRequest(messages: [
            .user(String(repeating: "old", count: 120)),
            call,
            resultTwo,
            resultOne
        ])

        let plan = try! XCTUnwrap(
            ConversationCompactor.tokenCompactionPlan(
                for: request,
                contextWindow: 100,
                force: true
            )
        )

        XCTAssertFalse(plan.retainedMessages.isEmpty)
        XCTAssertEqual(plan.retainedMessages.map(\.id), [call.id, resultTwo.id, resultOne.id])
        XCTAssertFalse(plan.omittedMessages.contains(where: { $0.id == call.id }))
        XCTAssertFalse(plan.omittedMessages.contains(where: { $0.id == resultOne.id }))
        XCTAssertFalse(plan.omittedMessages.contains(where: { $0.id == resultTwo.id }))
    }

    func testTokenMeterCountsToolCallIdentifiersAndResultIDs() {
        let shortCall = AgentMessage.assistant(
            "",
            toolCalls: [AgentToolCall(id: "a", name: "read", arguments: "{}")]
        )
        let longCall = AgentMessage.assistant(
            "",
            toolCalls: [
                AgentToolCall(
                    id: String(repeating: "call-", count: 20),
                    name: "read",
                    arguments: "{}"
                )
            ]
        )
        let shortResult = AgentMessage.tool(callID: "a", content: "ok")
        let longResult = AgentMessage.tool(
            callID: String(repeating: "result-", count: 20),
            content: "ok"
        )

        XCTAssertGreaterThan(
            ConversationTokenMeter.estimateMessage(longCall),
            ConversationTokenMeter.estimateMessage(shortCall)
        )
        XCTAssertGreaterThan(
            ConversationTokenMeter.estimateMessage(longResult),
            ConversationTokenMeter.estimateMessage(shortResult)
        )
    }

    func testProjectionIsDeterministicBoundedAndKeepsNewestCompleteToolTransaction() throws {
        let oldUser = AgentMessage.user(String(repeating: "old-user-", count: 700))
        let oldAssistant = AgentMessage.assistant(String(repeating: "old-assistant-", count: 700))
        let recentUser = AgentMessage.user("What time is it?")
        let toolCall = AgentMessage.assistant(
            "",
            toolCalls: [
                AgentToolCall(id: "call-latest", name: "device_time", arguments: "{}")
            ]
        )
        let toolResult = AgentMessage.tool(
            callID: "call-latest",
            content: "{\"iso8601\":\"2026-08-15T08:00:00Z\"}"
        )
        let finalAssistant = AgentMessage.assistant("It is 08:00 UTC.")
        let state = ConversationWorkState(
            goal: ConversationGoal(title: "Answer using a local tool", status: .active),
            plan: [ConversationPlanStep(title: "Read device time", status: .completed)],
            todos: [ConversationTodoItem(title: "Return concise answer", status: .completed)]
        )

        let first = try ConversationCompactor.project(
            messages: [
                oldUser,
                oldAssistant,
                recentUser,
                toolCall,
                toolResult,
                finalAssistant
            ],
            workState: state,
            maximumUTF8Bytes: 2_500
        )
        let second = try ConversationCompactor.project(
            messages: [
                oldUser,
                oldAssistant,
                recentUser,
                toolCall,
                toolResult,
                finalAssistant
            ],
            workState: state,
            maximumUTF8Bytes: 2_500
        )

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.encodedUTF8Bytes, 2_500)
        XCTAssertGreaterThan(first.omittedMessageCount, 0)
        XCTAssertEqual(
            first.messages.suffix(3).map(\.id),
            [toolCall.id, toolResult.id, finalAssistant.id]
        )
        XCTAssertFalse(first.messages.map(\.id).contains(oldUser.id))
        XCTAssertFalse(first.messages.map(\.id).contains(oldAssistant.id))
        XCTAssertTrue(first.stateSummary?.contains("Answer using a local tool") == true)
        XCTAssertTrue(first.stateSummary?.contains("Omitted transcript messages") == true)
    }

    func testProjectionNeverSplitsMultiCallToolTransaction() throws {
        let call = AgentMessage.assistant(
            "",
            toolCalls: [
                AgentToolCall(id: "a", name: "first", arguments: "{}"),
                AgentToolCall(id: "b", name: "second", arguments: "{}")
            ]
        )
        let resultB = AgentMessage.tool(callID: "b", content: "second result")
        let resultA = AgentMessage.tool(callID: "a", content: "first result")
        let final = AgentMessage.assistant("done")

        let projection = try ConversationCompactor.project(
            messages: [AgentMessage.user(String(repeating: "stale", count: 1_000)), call, resultB, resultA, final],
            maximumUTF8Bytes: 2_000
        )

        XCTAssertEqual(projection.messages.map(\.id), [call.id, resultB.id, resultA.id, final.id])
        XCTAssertEqual(
            Set(projection.messages.compactMap(\.toolCallID)),
            Set(["a", "b"])
        )
    }

    func testProjectionRejectsLimitThatCannotFitNewestToolBoundary() throws {
        let call = AgentMessage.assistant(
            "",
            toolCalls: [AgentToolCall(id: "large", name: "workspace_read_text", arguments: "{}")]
        )
        let result = AgentMessage.tool(
            callID: "large",
            content: String(repeating: "x", count: 8_000)
        )

        XCTAssertThrowsError(
            try ConversationCompactor.project(
                messages: [call, result],
                maximumUTF8Bytes: 1_000
            )
        ) { error in
            guard case let ConversationCompactionError.recentBoundaryExceedsLimit(required, limit) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(required, limit)
            XCTAssertEqual(limit, 1_000)
        }
    }

    func testProjectionRepairsIncompleteTrailingToolTurnBeforeSelection() throws {
        let valid = AgentMessage.user("valid")
        let incomplete = AgentMessage.assistant(
            "",
            toolCalls: [AgentToolCall(id: "missing", name: "device_time", arguments: "{}")]
        )

        let projection = try ConversationCompactor.project(
            messages: [valid, incomplete],
            maximumUTF8Bytes: 2_000
        )
        XCTAssertEqual(projection.messages.map(\.id), [valid.id])
    }

    func testRepairDropsOrphanToolMessageAtHistoryBoundary() {
        let orphan = AgentMessage.tool(callID: "missing", content: "orphan")
        let user = AgentMessage.user("continue")

        XCTAssertEqual(
            ConversationCompactor.repairIncompleteToolTurn([orphan, user]),
            []
        )
    }

    func testProjectionRetainsExtractiveFactsFromOmittedHistory() throws {
        let oldRequest = AgentMessage.user("Investigate the plugin installer crash. " + String(repeating: "details ", count: 90))
        let oldAnswer = AgentMessage.assistant("The installer writes a staged archive before host activation. " + String(repeating: "evidence ", count: 90))
        let recent = AgentMessage.user("Continue with the fix")

        let projection = try ConversationCompactor.project(
            messages: [oldRequest, oldAnswer, recent],
            maximumUTF8Bytes: 1_200
        )

        XCTAssertTrue(projection.omittedMessageCount > 0)
        XCTAssertTrue(projection.stateSummary?.contains("Earlier transcript facts:") == true)
        XCTAssertTrue(projection.stateSummary?.contains("plugin installer crash") == true)
    }

    private func makeRequest(messages: [AgentMessage]) -> ModelRequest {
        ModelRequest(
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            systemPrompt: "",
            messages: messages,
            tools: []
        )
    }

        /// Mirrors upstream `compaction-tool-result-pruner`: while compaction runs,
    /// an over-budget tool result enters the projection as the bounded
    /// head/marker/tail form with every other field preserved, while results
    /// within budget pass through untouched.
    func testProjectionPrunesOversizedToolResultsAndKeepsMetadata() throws {
        let oversizedTool = AgentMessage(
            role: .tool,
            content: String(repeating: "R", count: 20_000),
            toolCallID: "call-1"
        )
        let normalTool = AgentMessage(
            role: .tool,
            content: "compact result",
            toolCallID: "call-2"
        )
        let messages: [AgentMessage] = [
            .user("run tools"),
            .assistant("", toolCalls: [
                .init(id: "call-1", name: "big", arguments: "{}"),
                .init(id: "call-2", name: "small", arguments: "{}")
            ]),
            oversizedTool,
            normalTool,
            .assistant("done")
        ]

        // Direct pruner contract: content is bounded, other fields untouched.
        let pruned = ConversationCompactor.pruneOversizedToolResults(messages)
        let prunedOversized = pruned[2]
        XCTAssertLessThanOrEqual(prunedOversized.content.utf8.count, ToolResultPruner.defaultMaxBytes)
        XCTAssertEqual(prunedOversized.toolCallID, "call-1")
        XCTAssertTrue(prunedOversized.content.contains(ToolResultPruner.middleMarker))
        XCTAssertEqual(pruned[3].content, "compact result")

        // A projection over the same history carries the pruned form forward.
        let projection = try ConversationCompactor.project(
            messages: pruned,
            workState: ConversationWorkState(),
            maximumUTF8Bytes: 64 * 1_024
        )
        let projectedTool = projection.messages.first { $0.toolCallID == "call-1" }
        XCTAssertEqual(projectedTool?.toolCallID, "call-1")
        XCTAssertLessThanOrEqual(
            projectedTool?.content.utf8.count ?? .max,
            ToolResultPruner.defaultMaxBytes
        )
    }
}
