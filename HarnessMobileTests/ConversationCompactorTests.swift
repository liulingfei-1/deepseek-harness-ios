import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ConversationCompactorTests: XCTestCase {
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
}
