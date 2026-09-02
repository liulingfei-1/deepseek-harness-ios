import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ConversationMessageWindowTests: XCTestCase {
    func testProjectionKeepsOnlyLatestPageWithStableMessageIdentity() {
        let source = (0..<205).map { AgentMessage.user("message-\($0)") }

        let window = ConversationMessageWindow.project(source, limit: 80)

        XCTAssertEqual(window.totalCount, 205)
        XCTAssertEqual(window.hiddenCount, 125)
        XCTAssertEqual(window.messages.count, 80)
        XCTAssertEqual(window.messages.first?.id, source[125].id)
        XCTAssertEqual(window.messages.last?.id, source[204].id)
    }

    func testProjectionRemovesToolRowsAlreadyRepresentedByNestedEvents() {
        let childCall = AgentToolCall(id: "child-call", name: "read", arguments: "{}")
        let child = AgentToolEvent(call: childCall, status: .succeeded)
        let rootCall = AgentToolCall(id: "root-call", name: "run_code", arguments: "{}")
        let root = AgentToolEvent(call: rootCall, status: .succeeded, children: [child])
        let assistant = AgentMessage.assistant("", toolEvents: [root])
        let rootResult = AgentMessage.tool(callID: rootCall.id, name: rootCall.name, content: "root")
        let childResult = AgentMessage.tool(callID: childCall.id, name: childCall.name, content: "child")
        let orphan = AgentMessage.tool(callID: "legacy-call", name: "legacy", content: "orphan")

        let window = ConversationMessageWindow.project(
            [assistant, rootResult, childResult, orphan],
            limit: 80
        )

        XCTAssertEqual(window.messages.map(\.id), [assistant.id, orphan.id])
        XCTAssertEqual(window.hiddenCount, 0)
        XCTAssertEqual(window.totalCount, 2)
    }

    func testProjectionOmitsHiddenRuntimeContextBeforePaging() {
        let hidden = AgentMessage(
            role: .user,
            content: "runtime",
            source: .object(["kind": .string("plugin")])
        )
        let visible = [AgentMessage.user("one"), AgentMessage.user("two")]

        let window = ConversationMessageWindow.project([hidden] + visible, limit: 1)

        XCTAssertEqual(window.messages.map(\.id), [visible[1].id])
        XCTAssertEqual(window.hiddenCount, 1)
        XCTAssertEqual(window.totalCount, 2)
    }

    func testProjectionSupportsZeroLimitWithoutLosingCount() {
        let source = [AgentMessage.user("one"), AgentMessage.assistant("two")]

        let window = ConversationMessageWindow.project(source, limit: 0)

        XCTAssertTrue(window.messages.isEmpty)
        XCTAssertEqual(window.hiddenCount, 2)
        XCTAssertEqual(window.totalCount, 2)
    }

    func testMessageActionsRetryFromNearestDurableUserBoundary() {
        let firstUser = AgentMessage.user("first")
        let firstAssistant = AgentMessage.assistant("answer one")
        let tool = AgentMessage.tool(callID: "call", content: "result")
        let secondUser = AgentMessage.user("second")
        let secondAssistant = AgentMessage.assistant("answer two")

        let targets = ConversationMessageActionTargets.resolve([
            firstUser,
            firstAssistant,
            tool,
            secondUser,
            secondAssistant
        ]).retryUserMessageIDByMessageID

        XCTAssertEqual(targets[firstUser.id], firstUser.id)
        XCTAssertEqual(targets[firstAssistant.id], firstUser.id)
        XCTAssertNil(targets[tool.id])
        XCTAssertEqual(targets[secondUser.id], secondUser.id)
        XCTAssertEqual(targets[secondAssistant.id], secondUser.id)
    }

    func testLiveToolOutputReducerMergesChannelsAndPreservesOrder() {
        var output: [AgentToolOutputChunk] = []

        AgentToolEvent.appendOutput(.init(channel: .stdout, text: "one"), to: &output)
        AgentToolEvent.appendOutput(.init(channel: .stdout, text: "two"), to: &output)
        AgentToolEvent.appendOutput(.init(channel: .stderr, text: "three"), to: &output)

        XCTAssertEqual(output.map(\.channel), [.stdout, .stderr])
        XCTAssertEqual(output.map(\.text), ["onetwo", "three"])
    }

    func testLiveToolOutputReducerBoundsMultibyteChunks() {
        var output: [AgentToolOutputChunk] = []

        AgentToolEvent.appendOutput(
            .init(channel: .stdout, text: String(repeating: "中", count: 30_000)),
            to: &output
        )

        let retainedBytes = output.reduce(0) { $0 + $1.text.utf8.count }
        XCTAssertLessThanOrEqual(
            retainedBytes,
            AgentToolEvent.maximumPersistedOutputBytes + 64
        )
        XCTAssertTrue(output.contains { $0.channel == .system && $0.text.contains("truncated") })
        XCTAssertTrue(output.allSatisfy { String(data: Data($0.text.utf8), encoding: .utf8) != nil })
    }
}
