import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class AgentRuntimeTests: XCTestCase {
    func testUserMessageInstructionInjectionIsModelVisibleButNotChatCommitted() async throws {
        let script = ModelScript(turns: [[.text("done"), .finish(.stop)]])
        let recorder = EventRecorder()
        let sessionEvents = SessionEventRecorder()
        let userMessage = AgentMessage.user("/release-notes summarize this change")
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) },
            userMessageInjectionProvider: { message in
                guard message.id == userMessage.id else { return [] }
                return [
                    AgentRuntimeInstructionInjection(
                        content: "<skill_content name=\"release-notes\">instructions</skill_content>",
                        source: .object([
                            "kind": .string("skill-invocation"),
                            "name": .string("release-notes"),
                            "form": .string("instructions")
                        ])
                    )
                ]
            },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [userMessage],
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            initialUserMessage: userMessage
        )

        let requests = await script.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.messages.map(\.content), [
            "/release-notes summarize this change",
            "<skill_content name=\"release-notes\">instructions</skill_content>"
        ])
        let recordedSessionEvents = await sessionEvents.events
        let injectedEvent = try XCTUnwrap(recordedSessionEvents.first { event in
            event.userMessageData?.objectValue?["source"]?.objectValue?["kind"]
                == JSONValue.string("skill-invocation")
        })
        XCTAssertEqual(
            injectedEvent.userMessageData?.objectValue?["source"]?.objectValue?["name"],
            JSONValue.string("release-notes")
        )
        let recordedRuntimeEvents = await recorder.events
        let committedUserMessages = recordedRuntimeEvents.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages.filter { $0.role == .user }
        }
        XCTAssertTrue(committedUserMessages.isEmpty)
    }

    func testReasoningToolRoundTripAndLocalExecution() async throws {
        let script = ModelScript(
            turns: [
                [
                    .reasoning("I should echo."),
                    .toolCallDelta(
                        index: 0,
                        id: "call-1",
                        type: "function",
                        name: "echo",
                        arguments: "{\"value\":"
                    ),
                    .toolCallDelta(
                        index: 0,
                        id: nil,
                        type: nil,
                        name: nil,
                        arguments: "\"hello\"}"
                    ),
                    .finish(.toolCalls)
                ],
                [
                    .text("done"),
                    .finish(.stop)
                ]
            ]
        )
        let counter = ToolCounter()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: counter)]),
            approvalHandler: { _ in true },
            eventHandler: { event in
                await recorder.append(event)
            }
        )

        var configuration = AgentConfiguration()
        configuration.maxSteps = 4
        try await runtime.run(
            history: [.user("echo hello")],
            configuration: configuration,
            apiKey: "test-only"
        )

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 1)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        let replayedAssistant = try XCTUnwrap(
            requests[1].messages.first(where: { !$0.toolCalls.isEmpty })
        )
        XCTAssertEqual(replayedAssistant.reasoning, "I should echo.")
        XCTAssertEqual(replayedAssistant.content, "")

        let events = await recorder.events
        XCTAssertTrue(events.contains { event in
            guard case let .toolFinished(call, text, isError) = event else {
                return false
            }
            return call.id == "call-1" && text == "hello" && !isError
        })
        XCTAssertTrue(events.contains(.textDelta("done")))
        let committedTurns = events.compactMap { event -> [AgentMessage]? in
            guard case let .messagesCommitted(messages) = event else { return nil }
            return messages
        }
        XCTAssertEqual(committedTurns.first?.map(\.role), [.assistant, .tool])
        XCTAssertEqual(committedTurns.last?.map(\.role), [.assistant])
    }

    func testStreamingToolOutputIsEmittedAndPersistedOnAssistantEvent() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "stream-call",
                    type: "function",
                    name: "stream_echo",
                    arguments: "{}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [StreamingEchoTool()]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        try await runtime.run(
            history: [.user("stream")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let events = await recorder.events
        let chunks = events.compactMap { event -> AgentToolOutputChunk? in
            guard case let .toolOutput(callID, chunk) = event,
                  callID == "stream-call" else { return nil }
            return chunk
        }
        XCTAssertEqual(chunks.map(\.channel), [.stdout, .stderr])
        XCTAssertEqual(chunks.map(\.text), ["first\n", "warning\n"])

        let committedAssistant = try XCTUnwrap(events.compactMap { event -> AgentMessage? in
            guard case let .messagesCommitted(messages) = event else { return nil }
            return messages.first(where: { !$0.toolEvents.isEmpty })
        }.first)
        let toolEvent = try XCTUnwrap(committedAssistant.toolEvents.first)
        XCTAssertEqual(toolEvent.status, .succeeded)
        XCTAssertEqual(toolEvent.output.map(\.channel), [.stdout, .stderr])
        XCTAssertEqual(toolEvent.output.map(\.text), ["first\n", "warning\n"])
        XCTAssertEqual(toolEvent.result, "stream complete")
        XCTAssertNotNil(toolEvent.startedAt)
        XCTAssertNotNil(toolEvent.finishedAt)
    }

    func testParallelSafeToolsUseTwoSlotRollingPoolAndCommitInModelOrder() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "parallel-1",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"1\",\"resource\":\"r1\"}"
                ),
                .toolCallDelta(
                    index: 1,
                    id: "parallel-2",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"2\",\"resource\":\"r2\"}"
                ),
                .toolCallDelta(
                    index: 2,
                    id: "parallel-3",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"3\",\"resource\":\"r3\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let gate = ParallelToolGate()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ParallelGateTool(gate: gate)]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("run three")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        try await eventually { await gate.startedIDs.count == 2 }
        let firstStartedIDs = await gate.startedIDs
        let firstMaximumConcurrent = await gate.maximumConcurrent
        XCTAssertEqual(firstStartedIDs, ["1", "2"])
        XCTAssertEqual(firstMaximumConcurrent, 2)

        await gate.release("2")
        try await eventually { await recorder.finishedCallIDs == ["parallel-2"] }
        try await eventually { await gate.startedIDs.count == 3 }
        let allStartedIDs = await gate.startedIDs
        let rollingMaximumConcurrent = await gate.maximumConcurrent
        XCTAssertEqual(allStartedIDs, ["1", "2", "3"])
        XCTAssertEqual(rollingMaximumConcurrent, 2)

        await gate.release("3")
        try await eventually {
            await recorder.finishedCallIDs == ["parallel-2", "parallel-3"]
        }
        await gate.release("1")
        try await task.value

        let finishedCallIDs = await recorder.finishedCallIDs
        XCTAssertEqual(finishedCallIDs, ["parallel-2", "parallel-3", "parallel-1"])
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        let durableTools = requests[1].messages.filter { $0.role == .tool }
        XCTAssertEqual(durableTools.compactMap(\.toolCallID), [
            "parallel-1", "parallel-2", "parallel-3"
        ])
        XCTAssertEqual(durableTools.map(\.content), ["done-1", "done-2", "done-3"])
    }

    func testApprovalCallWaitsForParallelPoolToDrain() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "parallel-before",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"before\",\"resource\":\"before\"}"
                ),
                .toolCallDelta(
                    index: 1,
                    id: "approval-barrier",
                    type: "function",
                    name: "approval_barrier",
                    arguments: "{\"id\":\"approval\"}"
                ),
                .toolCallDelta(
                    index: 2,
                    id: "parallel-after",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"after\",\"resource\":\"after\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let gate = ParallelToolGate()
        let approval = ApprovalProbe()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [
                ParallelGateTool(gate: gate),
                ApprovalBarrierTool()
            ]),
            approvalHandler: { request in
                await approval.recordRequest(request)
                return true
            },
            eventHandler: { event in await recorder.append(event) }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("approval barrier")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        try await eventually { await gate.startedIDs == ["before"] }
        try await eventually {
            await recorder.hasStatus(callID: "approval-barrier", status: .awaitingApproval)
        }
        let requestsBeforeDrain = await approval.requestCount
        let activeBeforeDrain = await gate.activeCount
        XCTAssertEqual(requestsBeforeDrain, 0)
        XCTAssertEqual(activeBeforeDrain, 1)

        await gate.release("before")
        try await eventually { await approval.requestCount == 1 }
        let approvalRequest = await approval.lastRequest
        XCTAssertEqual(approvalRequest?.scope.risk, .sideEffect)
        XCTAssertEqual(approvalRequest?.scope.resources, ["tool"])
        XCTAssertFalse(approvalRequest?.scope.modelDestination.isEmpty ?? true)
        try await eventually { await gate.startedIDs == ["before", "after"] }
        let barrierMaximumConcurrent = await gate.maximumConcurrent
        XCTAssertEqual(barrierMaximumConcurrent, 1)
        await gate.release("after")
        try await task.value
    }

    func testParallelSafeCallsWithSameResourceRunSerially() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "resource-1",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"1\",\"resource\":\"shared\"}"
                ),
                .toolCallDelta(
                    index: 1,
                    id: "resource-2",
                    type: "function",
                    name: "parallel_gate",
                    arguments: "{\"id\":\"2\",\"resource\":\"shared\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let gate = ParallelToolGate()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ParallelGateTool(gate: gate)]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("same resource")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        try await eventually { await gate.startedIDs == ["1"] }
        try await eventually {
            await recorder.hasStatus(callID: "resource-2", status: .pending)
        }
        let startedBeforeRelease = await gate.startedIDs
        let maximumBeforeRelease = await gate.maximumConcurrent
        XCTAssertEqual(startedBeforeRelease, ["1"])
        XCTAssertEqual(maximumBeforeRelease, 1)

        await gate.release("1")
        try await eventually { await gate.startedIDs == ["1", "2"] }
        let resourceMaximumConcurrent = await gate.maximumConcurrent
        XCTAssertEqual(resourceMaximumConcurrent, 1)
        await gate.release("2")
        try await task.value
    }

    func testLegacyAgentMessageWithoutToolEventsStillDecodes() throws {
        let data = Data(
            """
            {
              "id":"00000000-0000-0000-0000-000000000001",
              "role":"assistant",
              "content":"legacy",
              "toolCalls":[],
              "createdAt":0
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(AgentMessage.self, from: data)
        XCTAssertEqual(message.content, "legacy")
        XCTAssertEqual(message.toolEvents, [])
    }

    func testReadOnlyPermissionHidesAndRejectsSideEffectToolWithoutApproval() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "denied-call",
                    type: "function",
                    name: "approved_echo",
                    arguments: "{\"value\":\"blocked\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("handled"), .finish(.stop)]
        ])
        let approvalCounter = ToolCounter()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalEchoTool()]),
            approvalHandler: { _ in
                await approvalCounter.increment()
                return true
            },
            eventHandler: { event in await recorder.append(event) },
            permissionMode: .readOnly
        )

        try await runtime.run(
            history: [.user("attempt write")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let approvalCount = await approvalCounter.value
        XCTAssertEqual(approvalCount, 0)
        let requests = await script.requests
        XCTAssertFalse(requests[0].tools.contains(where: { $0.name == "approved_echo" }))
        let events = await recorder.events
        XCTAssertTrue(events.contains { event in
            guard case let .toolEventChanged(toolEvent) = event else { return false }
            return toolEvent.callID == "denied-call" && toolEvent.status == .denied
        })
    }

    func testDangerFullAccessExecutesRegisteredSideEffectWithoutApproval() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "allowed-call",
                    type: "function",
                    name: "approved_echo",
                    arguments: "{\"value\":\"allowed\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let approvalCounter = ToolCounter()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalEchoTool()]),
            approvalHandler: { _ in
                await approvalCounter.increment()
                return false
            },
            eventHandler: { event in await recorder.append(event) },
            permissionMode: .dangerFullAccess
        )

        try await runtime.run(
            history: [.user("run")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let approvalCount = await approvalCounter.value
        XCTAssertEqual(approvalCount, 0)
        let requests = await script.requests
        XCTAssertTrue(requests[0].tools.contains(where: { $0.name == "approved_echo" }))
        let events = await recorder.events
        XCTAssertTrue(events.contains { event in
            guard case let .toolEventChanged(toolEvent) = event else { return false }
            return toolEvent.callID == "allowed-call" && toolEvent.status == .succeeded
        })
    }

    func testValidLookingToolArgumentsAreNotExecutedAfterLengthFinish() async throws {
        let script = ModelScript(
            turns: [[
                .toolCallDelta(
                    index: 0,
                    id: "call-1",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"must-not-run\"}"
                ),
                .finish(.length)
            ]]
        )
        let counter = ToolCounter()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: counter)]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        do {
            try await runtime.run(
                history: [.user("test")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            XCTFail("A length-truncated tool call must not execute")
        } catch let error as AgentRuntimeError {
            guard case .unsafeFinishReason(.length) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
        let events = await recorder.events
        XCTAssertFalse(events.contains { event in
            if case .messagesCommitted = event { return true }
            return false
        })
    }

    func testSessionEventsFollowDurableTurnAndStepOrder() async throws {
        let script = ModelScript(turns: [[.text("done"), .finish(.stop)]])
        let message = AgentMessage.user("hello")
        let sessionEvents = SessionDraftRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [message],
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            initialUserMessage: message
        )

        let types = await sessionEvents.drafts.map(\.type)
        XCTAssertEqual(
            types,
            [
                SessionEventVocabulary.turnStart,
                SessionEventVocabulary.userMessage,
                SessionEventVocabulary.stepStart,
                SessionEventVocabulary.requestHeader,
                SessionEventVocabulary.requestContext,
                SessionEventVocabulary.assistantChunk,
                SessionEventVocabulary.assistantMessage,
                SessionEventVocabulary.stepEnd,
                SessionEventVocabulary.turnEnd
            ]
        )
    }

    func testUnsafeFinishDoesNotCommitAssistantOrToolSessionEvents() async throws {
        let script = ModelScript(
            turns: [[
                .toolCallDelta(
                    index: 0,
                    id: "call-1",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"must-not-run\"}"
                ),
                .finish(.length)
            ]]
        )
        let sessionEvents = SessionDraftRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                await sessionEvents.append(draft)
            }
        )

        do {
            try await runtime.run(
                history: [.user("test")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            XCTFail("A length-truncated response must fail")
        } catch let error as AgentRuntimeError {
            guard case .unsafeFinishReason(.length) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let types = await sessionEvents.drafts.map(\.type)
        XCTAssertTrue(types.contains(SessionEventVocabulary.assistantChunk))
        XCTAssertFalse(types.contains(SessionEventVocabulary.assistantMessage))
        XCTAssertFalse(types.contains(SessionEventVocabulary.toolCall))
        XCTAssertFalse(types.contains(SessionEventVocabulary.toolResult))
        XCTAssertEqual(Array(types.suffix(2)), [
            SessionEventVocabulary.stepEnd,
            SessionEventVocabulary.turnEnd
        ])
    }

    func testDuplicateToolCallIDsAreRejectedBeforeAnyToolExecutes() async throws {
        let script = ModelScript(
            turns: [[
                .toolCallDelta(
                    index: 0,
                    id: "duplicate-id",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"first\"}"
                ),
                .toolCallDelta(
                    index: 1,
                    id: "duplicate-id",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"second\"}"
                ),
                .finish(.toolCalls)
            ]]
        )
        let counter = ToolCounter()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: counter)]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        do {
            try await runtime.run(
                history: [.user("test")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            XCTFail("Duplicate tool-call IDs must be rejected")
        } catch let error as AgentRuntimeError {
            guard case .invalidToolCallStream = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
        let events = await recorder.events
        XCTAssertFalse(events.contains { event in
            if case .messagesCommitted = event { return true }
            return false
        })
    }

    func testCancellationDuringApprovalDoesNotCommitPartialToolHistory() async throws {
        let script = ModelScript(
            turns: [[
                .toolCallDelta(
                    index: 0,
                    id: "call-1",
                    type: "function",
                    name: "approved_echo",
                    arguments: "{\"value\":\"hello\"}"
                ),
                .finish(.toolCalls)
            ]]
        )
        let gate = ApprovalGate()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalEchoTool()]),
            approvalHandler: { _ in
                await gate.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return true
                } catch {
                    return false
                }
            },
            eventHandler: { event in await recorder.append(event) }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("test")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        await gate.waitUntilStarted()
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled run should throw")
        } catch is CancellationError {
            // Expected.
        }

        let events = await recorder.events
        XCTAssertFalse(events.contains { event in
            if case .messagesCommitted = event { return true }
            return false
        })
    }

    func testCancellationAfterSilentlyFinishedModelStreamPropagatesCancellation() async throws {
        let gate = SilentStreamGate()
        let runtime = AgentRuntime(
            client: SilentFinishModelClient(gate: gate),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("wait")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        await gate.waitUntilSubscribed()
        task.cancel()
        await gate.finish()

        do {
            try await task.value
            XCTFail("A cancelled stream must not become invalidFinishSequence")
        } catch is CancellationError {
            // Expected. A cancelled transport stream can finish without a
            // terminal SSE event, which should stay a cancellation.
        }
    }

    func testSteerInputIsCommittedAtNextSafeStepBoundary() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "call-1",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"tool result\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("steered"), .finish(.stop)]
        ])
        let queued = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            text: "change direction",
            disposition: .steer,
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let inbox = TestQueuedInputInbox(inputs: [queued])
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { event in
                if case let .messagesCommitted(messages) = event {
                    await inbox.acknowledge(messageIDs: messages.map(\.id))
                }
            },
            queuedInputProvider: { boundary in
                await inbox.next(at: boundary)
            }
        )

        var configuration = AgentConfiguration()
        configuration.maxSteps = 2
        try await runtime.run(
            history: [.user("start")],
            configuration: configuration,
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests[0].messages.contains(where: { $0.id == queued.id }))
        let injected = try XCTUnwrap(requests[1].messages.first(where: { $0.id == queued.id }))
        XCTAssertEqual(injected.role, .user)
        XCTAssertEqual(injected.content, queued.text)
        let steerInboxIsEmpty = await inbox.isEmpty
        XCTAssertTrue(steerInboxIsEmpty)
    }

    func testNormalQueuedInputWaitsForCompletedAssistantTurn() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "call-1",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"tool result\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("first answer"), .finish(.stop)],
            [.text("queued answer"), .finish(.stop)]
        ])
        let queued = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            text: "follow up",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let inbox = TestQueuedInputInbox(inputs: [queued])
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { event in
                if case let .messagesCommitted(messages) = event {
                    await inbox.acknowledge(messageIDs: messages.map(\.id))
                }
            },
            queuedInputProvider: { boundary in
                await inbox.next(at: boundary)
            }
        )

        var configuration = AgentConfiguration()
        configuration.maxSteps = 2
        try await runtime.run(
            history: [.user("start")],
            configuration: configuration,
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests[1].messages.contains(where: { $0.id == queued.id }))
        let injected = try XCTUnwrap(requests[2].messages.first(where: { $0.id == queued.id }))
        XCTAssertEqual(injected.content, queued.text)
        XCTAssertTrue(requests[2].messages.contains { message in
            message.role == .assistant && message.content == "first answer"
        })
        let normalInboxIsEmpty = await inbox.isEmpty
        XCTAssertTrue(normalInboxIsEmpty)
    }

    func testCordisProvidesPromptAndDynamicToolToAgentLoop() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "cordis-call",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"from plugin\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let counter = ToolCounter()
        let plugins = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await plugins.install(
            services.pluginDefinition(baseSystemPrompt: "base prompt")
        )
        _ = try await plugins.install(
            CordisPluginDefinition(
                id: "test.dynamic-agent",
                version: "1",
                dependencies: [
                    CordisAgentServiceKeys.tools.name,
                    CordisAgentServiceKeys.systemPrompt.name
                ]
            ) { context in
                try await context.registerTool(EchoTool(counter: counter))
                try await context.promptSection(
                    CordisPromptSection(
                        name: "test:prompt",
                        order: 0,
                        text: "plugin prompt"
                    )
                )
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { _ in }
        )

        try await runtime.run(
            history: [.user("use plugin")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(requests.first?.tools.map(\.name), ["echo"])
        XCTAssertEqual(requests.first?.systemPrompt, "base prompt\n\nplugin prompt")
    }

    func testCordisGuardCanDenyButCannotBeOverriddenByFullAccess() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "guarded-call",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"blocked\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("handled"), .finish(.stop)]
        ])
        let counter = ToolCounter()
        let recorder = EventRecorder()
        let plugins = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await plugins.install(services.pluginDefinition(baseSystemPrompt: "base"))
        _ = try await plugins.install(
            CordisPluginDefinition(
                id: "test.guarded-tool",
                version: "1",
                dependencies: [CordisAgentServiceKeys.tools.name]
            ) { context in
                try await context.registerTool(EchoTool(counter: counter))
                try await context.guardTool(label: "deny-echo") { execution in
                    execution.call.name == "echo" ? "blocked by test guard" : nil
                }
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) },
            permissionMode: .dangerFullAccess
        )

        try await runtime.run(
            history: [.user("blocked")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
        let events = await recorder.events
        XCTAssertTrue(events.contains { event in
            guard case let .toolEventChanged(toolEvent) = event else { return false }
            return toolEvent.callID == "guarded-call"
                && toolEvent.status == .denied
                && toolEvent.errorMessage?.contains("blocked by test guard") == true
        })
    }

    func testSessionEventsRecordOrderedSuccessfulTrajectoryAndNeverPersistAPIKey() async throws {
        let apiKey = "sk-session-secret-must-not-be-persisted"
        let initialMessage = AgentMessage.user("trace this response")
        let usage = ModelTokenUsage(
            promptTokens: 21,
            completionTokens: 8,
            totalTokens: 29,
            cachedPromptTokens: 13,
            reasoningTokens: 3
        )
        let script = ModelScript(turns: [[
            .reasoning("considering"),
            .text("complete"),
            .usage(usage),
            .finish(.stop)
        ]])
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [initialMessage],
            configuration: AgentConfiguration(),
            apiKey: apiKey,
            initialUserMessage: initialMessage,
            requestHeaderReason: .resume,
            contextWindow: 131_072
        )

        let events = await sessionEvents.events
        XCTAssertEqual(events.map(\.seq), events.indices.map { UInt64($0 + 1) })
        XCTAssertEqual(events.map(\.type), [
            SessionEventVocabulary.turnStart,
            SessionEventVocabulary.userMessage,
            SessionEventVocabulary.stepStart,
            SessionEventVocabulary.requestHeader,
            SessionEventVocabulary.requestContext,
            SessionEventVocabulary.assistantChunk,
            SessionEventVocabulary.assistantChunk,
            SessionEventVocabulary.assistantChunk,
            SessionEventVocabulary.assistantMessage,
            SessionEventVocabulary.stepEnd,
            SessionEventVocabulary.turnEnd
        ])
        XCTAssertEqual(events.first?.turnStartData, SessionTurnStartData(turn: 1))
        XCTAssertEqual(events[2].stepData, SessionStepData(turn: 1, step: 1))
        XCTAssertEqual(events[9].stepData, SessionStepData(turn: 1, step: 1))
        XCTAssertEqual(events.last?.turnEndData?.turn, 1)
        XCTAssertEqual(
            events.last?.turnEndData?.reason,
            .object(["kind": .string("completed")])
        )

        let chunks = events.filter { $0.type == SessionEventVocabulary.assistantChunk }
        let assistantMessage = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.assistantMessage }
        )
        XCTAssertEqual(assistantMessage.sourceEventSeqs, chunks.map(\.seq))
        XCTAssertEqual(
            assistantMessage.assistantMessageData?.usage,
            SessionTokenUsage(
                inputTokens: 8,
                outputTokens: 8,
                cacheReadTokens: 13,
                reasoningTokens: 3
            )
        )
        XCTAssertEqual(
            events.first { $0.type == SessionEventVocabulary.requestHeader }?.requestHeaderData?.reason,
            .resume
        )
        XCTAssertEqual(
            events.first { $0.type == SessionEventVocabulary.requestContext }?.requestContextData,
            SessionRequestContextData(
                provider: ModelProviderID.deepSeekOfficial.rawValue,
                model: AgentConfiguration.defaultModel,
                contextWindow: 131_072
            )
        )

        let encodedEvents = try JSONEncoder().encode(events)
        let persistedText = String(decoding: encodedEvents, as: UTF8.self)
        XCTAssertFalse(persistedText.contains(apiKey))
    }

    func testSessionEventsLinkToolCallAndResultAcrossClosedSteps() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "trace-call",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"tool output\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("final answer"), .finish(.stop)]
        ])
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("use the tool")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let events = await sessionEvents.events
        XCTAssertEqual(events.map(\.type), [
            SessionEventVocabulary.turnStart,
            SessionEventVocabulary.stepStart,
            SessionEventVocabulary.requestHeader,
            SessionEventVocabulary.requestContext,
            SessionEventVocabulary.assistantChunk,
            SessionEventVocabulary.assistantMessage,
            SessionEventVocabulary.toolCall,
            SessionEventVocabulary.toolResult,
            SessionEventVocabulary.stepEnd,
            SessionEventVocabulary.stepStart,
            SessionEventVocabulary.assistantChunk,
            SessionEventVocabulary.assistantMessage,
            SessionEventVocabulary.stepEnd,
            SessionEventVocabulary.turnEnd
        ])

        let assistantMessages = events.filter {
            $0.type == SessionEventVocabulary.assistantMessage
        }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].sourceEventSeqs, [events[4].seq])
        XCTAssertEqual(assistantMessages[1].sourceEventSeqs, [events[10].seq])

        let toolCall = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.toolCall }
        )
        let toolResult = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.toolResult }
        )
        XCTAssertEqual(toolCall.toolCallData?.callID, "trace-call")
        XCTAssertEqual(toolResult.toolResultData?.callID, "trace-call")
        XCTAssertEqual(toolResult.sourceEventSeqs, [toolCall.seq])
        XCTAssertEqual(
            events.filter { $0.type == SessionEventVocabulary.stepStart }.compactMap(\.stepData),
            [SessionStepData(turn: 1, step: 1), SessionStepData(turn: 1, step: 2)]
        )
        XCTAssertEqual(
            events.filter { $0.type == SessionEventVocabulary.stepEnd }.compactMap(\.stepData),
            [SessionStepData(turn: 1, step: 1), SessionStepData(turn: 1, step: 2)]
        )
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.turnStart }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.turnEnd }.count, 1)
    }

    func testSessionEventsCloseOpenBoundariesOnCancellation() async throws {
        let script = ModelScript(turns: [[
            .toolCallDelta(
                index: 0,
                id: "cancelled-call",
                type: "function",
                name: "approved_echo",
                arguments: "{\"value\":\"hello\"}"
            ),
            .finish(.toolCalls)
        ]])
        let gate = ApprovalGate()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalEchoTool()]),
            approvalHandler: { _ in
                await gate.markStarted()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return true
                } catch {
                    return false
                }
            },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("cancel")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        await gate.waitUntilStarted()
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled run should throw")
        } catch is CancellationError {
            // Expected.
        }

        let events = await sessionEvents.events
        XCTAssertEqual(Array(events.suffix(3).map(\.type)), [
            SessionEventVocabulary.toolResult,
            SessionEventVocabulary.stepEnd,
            SessionEventVocabulary.turnEnd
        ])
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.stepStart }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.stepEnd }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.turnStart }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.turnEnd }.count, 1)

        let toolCall = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.toolCall }
        )
        let interruptedResult = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.toolResult }
        )
        XCTAssertEqual(interruptedResult.sourceEventSeqs, [toolCall.seq])
        XCTAssertEqual(
            interruptedResult.toolResultData?.error,
            .object([
                "name": .string("CancellationError"),
                "code": .string("TOOL_INTERRUPTED")
            ])
        )
        XCTAssertEqual(
            events.last?.turnEndData?.reason,
            .object([
                "kind": .string("aborted"),
                "reason": .object(["kind": .string("user")])
            ])
        )
    }

    func testTextOnlyLengthFinishCommitsIncompleteAssistantMessage() async throws {
        let script = ModelScript(turns: [[
            .text("partial response"),
            .finish(.length)
        ]])
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("truncate")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let events = await sessionEvents.events
        XCTAssertEqual(Array(events.suffix(2).map(\.type)), [
            SessionEventVocabulary.stepEnd,
            SessionEventVocabulary.turnEnd
        ])
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.stepStart }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.stepEnd }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.turnStart }.count, 1)
        XCTAssertEqual(events.filter { $0.type == SessionEventVocabulary.turnEnd }.count, 1)
        let assistant = try XCTUnwrap(events.first {
            $0.type == SessionEventVocabulary.assistantMessage
        })
        let expectedContent: JSONValue = .array([
            .object([
                "type": .string("text"),
                "text": .string("partial response")
            ])
        ])
        XCTAssertEqual(
            assistant.assistantMessageData?.message.objectValue?["content"],
            expectedContent
        )

        let reason = try XCTUnwrap(events.last?.turnEndData?.reason.objectValue)
        XCTAssertEqual(reason["kind"], .string("truncated"))
    }
}

private actor ModelScript {
    private var turns: [[LLMStreamEvent]]
    private(set) var requests: [ModelRequest] = []

    init(turns: [[LLMStreamEvent]]) {
        self.turns = turns
    }

    func next(for request: ModelRequest) -> [LLMStreamEvent] {
        requests.append(request)
        guard !turns.isEmpty else {
            return [.finish(.stop)]
        }
        return turns.removeFirst()
    }
}

private struct ScriptedModelClient: LLMStreamingClient {
    let script: ModelScript

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let events = await script.next(for: request)
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private actor SilentStreamGate {
    private var continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func install(_ continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation) {
        self.continuation = continuation
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilSubscribed() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func finish() {
        continuation?.finish()
        continuation = nil
    }
}

private struct SilentFinishModelClient: LLMStreamingClient {
    let gate: SilentStreamGate

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await gate.install(continuation)
            }
        }
    }
}

private actor ToolCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private struct EchoTool: LocalAgentTool {
    let counter: ToolCounter
    let definition = ModelToolDefinition(
        name: "echo",
        description: "Echo a value.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object(["type": .string("string")])
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["value"])
        _ = try arguments.requiredString("value", maximumUTF8Bytes: 128)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "echo"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        await counter.increment()
        return try arguments.requiredString("value")
    }
}

private struct ApprovalEchoTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "approved_echo",
        description: "Test approval.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "value": .object(["type": .string("string")])
            ]),
            "required": .array([.string("value")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["value"])
        _ = try arguments.requiredString("value", maximumUTF8Bytes: 128)
    }

    func summary(arguments: [String: JSONValue]) -> String { "approval test" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try arguments.requiredString("value")
    }
}

private struct StreamingEchoTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "stream_echo",
        description: "Emit stdout and stderr chunks.",
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

    func summary(arguments: [String: JSONValue]) -> String {
        "stream output"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "stream complete"
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try validate(arguments: arguments)
        await onOutput(AgentToolOutputChunk(channel: .stdout, text: "first\n"))
        await onOutput(AgentToolOutputChunk(channel: .stderr, text: "warning\n"))
        return "stream complete"
    }
}

private struct ParallelGateTool: LocalAgentTool {
    let gate: ParallelToolGate
    let definition = ModelToolDefinition(
        name: "parallel_gate",
        description: "A deterministic parallel scheduler test tool.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")]),
                "resource": .object(["type": .string("string")])
            ]),
            "required": .array([.string("id"), .string("resource")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["id", "resource"])
        _ = try arguments.requiredString("id", maximumUTF8Bytes: 64)
        _ = try arguments.requiredString("resource", maximumUTF8Bytes: 128)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "parallel \(arguments["id"]?.stringValue ?? "unknown")"
    }

    func isConcurrencySafe(arguments: [String: JSONValue]) throws -> Bool {
        true
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        [try arguments.requiredString("resource", maximumUTF8Bytes: 128)]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let id = try arguments.requiredString("id", maximumUTF8Bytes: 64)
        await gate.run(id)
        return "done-\(id)"
    }
}

private struct ApprovalBarrierTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "approval_barrier",
        description: "An approval scheduler barrier test tool.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object(["type": .string("string")])
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["id"])
        _ = try arguments.requiredString("id", maximumUTF8Bytes: 64)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "approval barrier"
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try arguments.requiredString("id", maximumUTF8Bytes: 64)
    }
}

private actor ParallelToolGate {
    private(set) var startedIDs: [String] = []
    private(set) var activeCount = 0
    private(set) var maximumConcurrent = 0
    private var releaseWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasedBeforeWait: Set<String> = []

    func run(_ id: String) async {
        startedIDs.append(id)
        activeCount += 1
        maximumConcurrent = max(maximumConcurrent, activeCount)
        if releasedBeforeWait.remove(id) == nil {
            await withCheckedContinuation { continuation in
                releaseWaiters[id] = continuation
            }
        }
        activeCount -= 1
    }

    func release(_ id: String) {
        if let continuation = releaseWaiters.removeValue(forKey: id) {
            continuation.resume()
        } else {
            releasedBeforeWait.insert(id)
        }
    }
}

private actor ApprovalProbe {
    private(set) var requestCount = 0
    private(set) var lastRequest: ToolApprovalRequest?

    func recordRequest(_ request: ToolApprovalRequest? = nil) {
        requestCount += 1
        lastRequest = request
    }
}

private enum AsyncTestWaitError: Error {
    case timedOut
}

private func eventually(
    attempts: Int = 1_000,
    condition: @Sendable @escaping () async -> Bool
) async throws {
    for _ in 0..<attempts {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw AsyncTestWaitError.timedOut
}

private actor ApprovalGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor EventRecorder {
    private(set) var events: [AgentRuntimeEvent] = []

    var finishedCallIDs: [String] {
        events.compactMap { event in
            guard case let .toolFinished(call, _, _) = event else { return nil }
            return call.id
        }
    }

    func append(_ event: AgentRuntimeEvent) {
        events.append(event)
    }

    func hasStatus(callID: String, status: AgentToolEventStatus) -> Bool {
        events.contains { event in
            guard case let .toolEventChanged(toolEvent) = event else { return false }
            return toolEvent.callID == callID && toolEvent.status == status
        }
    }
}

private actor SessionEventRecorder {
    private(set) var events: [SessionEvent] = []

    func append(_ draft: SessionEventDraft) throws -> SessionEvent {
        let event = try SessionEvent(
            type: draft.type,
            seq: UInt64(events.count + 1),
            time: draft.time,
            data: draft.data,
            ignorable: draft.ignorable,
            sourceEventSeqs: draft.sourceEventSeqs,
            surfaceOp: draft.surfaceOp
        )
        events.append(event)
        return event
    }
}

private actor SessionDraftRecorder {
    private(set) var drafts: [SessionEventDraft] = []

    func append(_ draft: SessionEventDraft) -> SessionEvent? {
        drafts.append(draft)
        return nil
    }
}

private actor TestQueuedInputInbox {
    private var inputs: [QueuedAgentInput]

    init(inputs: [QueuedAgentInput]) {
        self.inputs = inputs
    }

    var isEmpty: Bool { inputs.isEmpty }

    func next(at boundary: QueuedInputBoundary) -> QueuedAgentInput? {
        switch boundary {
        case .nextStep:
            return inputs.first { $0.disposition == .steer }
        case .turnStopping:
            return inputs.first
        }
    }

    func acknowledge(messageIDs: [UUID]) {
        let committed = Set(messageIDs)
        inputs.removeAll { committed.contains($0.id) }
    }
}
