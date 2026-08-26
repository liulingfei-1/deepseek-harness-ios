import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class AgentRuntimeTests: XCTestCase {
    func testDefinitionOwnedFinalizerRunsOnceAndPreservesCanonicalValue() async throws {
        let counter = FinalizerCounter()
        let tool = FinalizingEchoTool(counter: counter, shouldThrow: false)
        let result = CordisToolExecutionResult(
            text: "raw",
            isError: false,
            value: .object(["canonical": .string("raw")])
        )
        let execution = CordisToolExecution(
            agentID: UUID(), runID: UUID(), turn: 1, step: 1,
            call: AgentToolCall(id: "c", name: "finalizing", arguments: "{}"),
            arguments: [:], risk: .pure, summary: "finalizing"
        )
        let finalized = LocalToolFinalizer.apply(tool: tool, execution: execution, result: result)
        XCTAssertEqual(finalized.text, "presented")
        XCTAssertEqual(finalized.value, result.value)
        XCTAssertFalse(finalized.isError)
        XCTAssertEqual(counter.value, 1)
    }

    func testThrowingDefinitionFinalizerFailsOpenAndRunsOnceForErrorResult() async throws {
        let counter = FinalizerCounter()
        let tool = FinalizingEchoTool(counter: counter, shouldThrow: true)
        let result = CordisToolExecutionResult(text: "error", isError: true, value: nil)
        let finalized = LocalToolFinalizer.apply(tool: tool, execution: nil, result: result)
        XCTAssertEqual(finalized, result)
        XCTAssertEqual(counter.value, 1)
    }

    func testCodeModeChildFailureClosesNestedDispatchAndKeepsParentTurnAlive() async throws {
        let script = ModelScript(turns: [[
            .toolCallDelta(
                index: 0,
                id: "provider/opaque/../run-code",
                type: "function",
                name: "run_code",
                arguments: "{}"
            ),
            .finish(.toolCalls)
        ], [
            .text("recovered"),
            .finish(.stop)
        ]])
        let recorder = EventRecorder()
        let sessionEvents = SessionDraftRecorder()
        let codePreset = try XCTUnwrap(
            AgentPresetRegistry.systemPresets.first { $0.id == "code" }
        ).runtimeProjection
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [
                TestRunCodeBridgeTool(),
                FailingCodeChildTool()
            ]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) },
            permissionMode: .dangerFullAccess,
            agentPreset: codePreset,
            sessionEventHandler: { draft in
                await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("exercise Code Mode")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.tools.map(\.name), ["run_code"])

        let drafts = await sessionEvents.drafts
        let nested = drafts.filter {
            $0.type == "tool/code-dispatch-start" || $0.type == "tool/code-dispatch"
        }
        XCTAssertEqual(nested.map(\.type), [
            "tool/code-dispatch-start",
            "tool/code-dispatch"
        ])
        XCTAssertEqual(
            nested.last?.data.objectValue?["isError"],
            .bool(true)
        )
        XCTAssertTrue(
            nested.last?.data.objectValue?["content"]?.stringValue?
                .contains("nested failure") == true
        )

        let runtimeEvents = await recorder.events
        XCTAssertTrue(runtimeEvents.contains { event in
            guard case let .toolEventChanged(root) = event else { return false }
            return root.callID == "provider/opaque/../run-code"
                && root.children.contains {
                    $0.name == "failing_child" && $0.status == .failed
                }
        })
        let committed = runtimeEvents.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages
        }
        XCTAssertEqual(committed.last?.content, "recovered")
    }

    func testConversationRerunKeepsSelectedUserMessageAndDropsLaterBranch() throws {
        let first = AgentMessage.user("first")
        let reply = AgentMessage.assistant("reply")
        let selected = AgentMessage.user("retry me")
        let later = AgentMessage.assistant("old branch")

        let preparation = try ConversationRerunPlanner.prepare(
            messages: [first, reply, selected, later],
            messageID: selected.id
        )

        XCTAssertEqual(preparation.messages, [first, reply, selected])
        XCTAssertEqual(preparation.initialUserMessage, selected)
        XCTAssertEqual(preparation.removedMessageCount, 1)
    }

    func testConversationEditPreservesMessageIdentityAndRejectsEmptyText() throws {
        let selected = AgentMessage.user("before")
        let later = AgentMessage.assistant("old branch")
        let preparation = try ConversationRerunPlanner.prepare(
            messages: [selected, later],
            messageID: selected.id,
            replacementText: "  after  "
        )

        XCTAssertEqual(preparation.initialUserMessage.id, selected.id)
        XCTAssertEqual(preparation.initialUserMessage.content, "after")
        XCTAssertThrowsError(
            try ConversationRerunPlanner.prepare(
                messages: [selected],
                messageID: selected.id,
                replacementText: "  \n "
            )
        ) { error in
            XCTAssertEqual(error as? ConversationRerunError, .emptyReplacement)
        }
    }

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

    func testInitialUserMessageIsIncludedInFirstProviderRequestWhenHistoryIsEmpty() async throws {
        let script = ModelScript(turns: [[.text("done"), .finish(.stop)]])
        let sessionEvents = SessionEventRecorder()
        let initial = AgentMessage.user("compile the plugin now")
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
            history: [],
            configuration: AgentConfiguration(),
            apiKey: "test-only",
            initialUserMessage: initial
        )

        let requests = await script.requests
        XCTAssertEqual(try XCTUnwrap(requests.first).messages.map(\.content), [
            "compile the plugin now"
        ])
        let userEvents = await sessionEvents.events.filter {
            $0.userMessageData != nil
        }
        XCTAssertEqual(userEvents.count, 1)
    }

    func testInstructionInjectionCanNormalizeOnlyTheProviderFacingUserMessage() async throws {
        let script = ModelScript(turns: [[.text("done"), .finish(.stop)]])
        let sessionEvents = SessionEventRecorder()
        let userMessage = AgentMessage.user(
            "compare @[Old run](dsh-session:opaque-token)"
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            userMessageInjectionProvider: { message in
                guard message.id == userMessage.id else { return [] }
                return [
                    AgentRuntimeInstructionInjection(
                        content: "<referenced-sessions>[]</referenced-sessions>",
                        source: .object([
                            "kind": .string("session-reference"),
                            "form": .string("recall")
                        ]),
                        normalizedUserContent: "compare @Old run"
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
        XCTAssertEqual(try XCTUnwrap(requests.first).messages.map(\.content), [
            "compare @Old run",
            "<referenced-sessions>[]</referenced-sessions>"
        ])
        let events = await sessionEvents.events
        let direct = try XCTUnwrap(events.first(where: {
            $0.userMessageData?.objectValue?["source"]?.objectValue?["kind"] == .string("user")
        }))
        XCTAssertEqual(
            direct.userMessageData?.objectValue?["content"]?.displayText.contains("opaque-token"),
            true
        )
        let injected = try XCTUnwrap(events.first(where: {
            $0.userMessageData?.objectValue?["source"]?.objectValue?["kind"]
                == .string("session-reference")
        }))
        XCTAssertNotNil(injected.userMessageData)
    }

    func testPreStepInstructionProviderAppendsDurableTransitionsBeforeEveryRequest() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "instruction-step",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"touch\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let injectionScript = PreStepInjectionScript()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            preStepInstructionProvider: { messages in
                await injectionScript.next(visibleMessages: messages)
            },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
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
        XCTAssertEqual(
            requests[0].messages.filter(\.isWorkspaceInstructionTransition).map(\.content),
            ["workspace baseline"]
        )
        XCTAssertEqual(
            requests[1].messages.filter(\.isWorkspaceInstructionTransition).map(\.content),
            ["workspace baseline", "workspace update"]
        )
        let durableTransitions = await sessionEvents.events.filter { event in
            event.userMessageData?.objectValue?["source"]?.objectValue?["kind"]
                == .string(WorkspaceInstructionMessageSource.kind)
        }
        XCTAssertEqual(durableTransitions.count, 2)
        let sawBaselineBeforeSecond = await injectionScript.sawBaselineBeforeSecond
        XCTAssertTrue(sawBaselineBeforeSecond)
    }

    func testTimeContextProviderAppendsDurableTailWithoutChangingRequestHeader() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "time-step",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"tick\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            timeContextInjectionProvider: { messages, turn, step, now in
                try TimeContextOverlay.injection(
                    settings: TimeContextSettings(
                        isEnabled: true,
                        timeZoneIdentifier: "UTC",
                        refreshIntervalMilliseconds: 0
                    ),
                    messages: messages,
                    turn: turn,
                    step: step,
                    now: now
                )
            },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )
        var configuration = AgentConfiguration()
        configuration.maxSteps = 2

        try await runtime.run(
            history: [.user("what time is it")],
            configuration: configuration,
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.systemPrompt), [MobileHarnessPrompt.text, MobileHarnessPrompt.text])
        XCTAssertEqual(
            requests[0].messages.filter { message in
                message.source?.objectValue?["plugin"]?.stringValue == TimeContextOverlay.pluginID
            }.count,
            1
        )
        XCTAssertEqual(
            requests[1].messages.filter { message in
                message.source?.objectValue?["plugin"]?.stringValue == TimeContextOverlay.pluginID
            }.count,
            2
        )
        let durable = await sessionEvents.events.filter { event in
            event.userMessageData?.objectValue?["source"]?.objectValue?["plugin"]?.stringValue
                == TimeContextOverlay.pluginID
        }
        XCTAssertEqual(durable.count, 2)
    }

    func testReadImageToolResultBecomesDurableHiddenVisionContext() async throws {
        let attachment = AgentImageAttachmentRef(
            id: UUID(),
            path: ".harness-mobile/attachments/tool-image.jpg",
            mimeType: "image/jpeg",
            byteCount: 3
        )
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "read-image-call",
                    type: "function",
                    name: "read_image",
                    arguments: "{}"
                ),
                .finish(.toolCalls)
            ],
            [.text("I can inspect the image."), .finish(.stop)]
        ])
        let sessionEvents = SessionEventRecorder()
        let imageProvider = TestImageAttachmentProvider(
            expected: attachment,
            data: Data([1, 2, 3])
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ReadImageEnvelopeTool(attachment: attachment)]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            imageAttachmentProvider: { refs in
                try await imageProvider.resolve(refs)
            },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("inspect screenshot")],
            configuration: AgentConfiguration(model: "deepseek-v4-flash-vision-exp"),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].imagePayloads.map(\.id), [attachment.id])
        let imageContext = try XCTUnwrap(
            requests[1].messages.first(where: { message in
                message.source?.objectValue?["kind"] == .string("tool-result-image")
            })
        )
        XCTAssertEqual(imageContext.imageAttachments, [attachment])
        XCTAssertTrue(imageContext.isHiddenContextMessage)
        XCTAssertFalse(imageContext.isChatVisible)

        let events = await sessionEvents.events
        let durableContext = try XCTUnwrap(events.first(where: { event in
            event.userMessageData?.objectValue?["source"]?.objectValue?["kind"]
                == .string("tool-result-image")
        }))
        XCTAssertEqual(
            durableContext.userMessageData?.objectValue?["imageAttachments"]?.displayText
                .contains(attachment.id.uuidString),
            true
        )
    }

    func testImageAggregateBudgetSkipsOldestAttachmentsBeforeReadingThem() async throws {
        let refs = (0..<16).map { index in
            AgentImageAttachmentRef(
                id: UUID(),
                path: "Attachments/image-\(index).jpg",
                mimeType: "image/jpeg",
                byteCount: WorkspaceStore.maximumModelRequestImageBytes
            )
        }
        let history = refs.enumerated().map { index, ref in
            AgentMessage.user("image \(index)", imageAttachments: [ref])
        }
        let script = ModelScript(turns: [[.text("done"), .finish(.stop)]])
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            imageAttachmentProvider: { selected in
                selected.map {
                    ModelImagePayload(id: $0.id, mimeType: $0.mimeType, data: Data([1]))
                }
            }
        )

        try await runtime.run(
            history: history,
            configuration: AgentConfiguration(model: "deepseek-v4-flash-vision-exp"),
            apiKey: "test-only"
        )

        let requests = await script.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertLessThan(request.imagePayloads.count, refs.count)
        XCTAssertEqual(
            request.imagePayloads.map(\.id),
            Array(refs.suffix(request.imagePayloads.count)).map(\.id)
        )
    }

    func testContextSourceLabelUsesDurableProducerIdentity() {
        XCTAssertEqual(
            AgentRuntime.contextSourceLabel(
                .object([
                    "kind": .string("plugin"),
                    "plugin": .string("memory-palace"),
                    "name": .string("fallback-name")
                ])
            ),
            "memory-palace"
        )
        XCTAssertEqual(
            AgentRuntime.contextSourceLabel(
                .object([
                    "kind": .string("skill-invocation"),
                    "name": .string("release-notes")
                ])
            ),
            "release-notes"
        )
        XCTAssertEqual(
            AgentRuntime.promptSourceLabel("harness:base"),
            "@deepseek-ai/dsh-system-prompt"
        )
    }

    func testContextPipelineRejectsConflictingNormalizedUserContent() {
        let source: JSONValue = .object(["kind": .string("test")])

        XCTAssertThrowsError(
            try AgentContextPipeline.normalizedUserContent(in: [
                AgentRuntimeInstructionInjection(
                    content: "first",
                    source: source,
                    normalizedUserContent: "normalized one"
                ),
                AgentRuntimeInstructionInjection(
                    content: "second",
                    source: source,
                    normalizedUserContent: "normalized two"
                )
            ])
        ) { error in
            guard case AgentRuntimeError.conflictingNormalizedUserContent = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testContextPipelineUsesAppendOnlyClearedRuntimeSnapshot() throws {
        let snapshot = try XCTUnwrap(
            AgentContextPipeline.nextRuntimeContextSnapshot(
                current: "",
                retained: "Mode: previously active"
            )
        )

        XCTAssertEqual(
            snapshot.content,
            "Current runtime context: none. Earlier runtime-context snapshots no longer apply."
        )
        XCTAssertEqual(snapshot.message.role, .user)
        XCTAssertTrue(snapshot.message.isRuntimeContextSnapshot)
    }

    func testRuntimeContextChangesAppendAtTailWithoutRewritingSystemHeader() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "context-call",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"updated\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let counter = ToolCounter()
        let recorder = EventRecorder()
        let sessionEvents = SessionEventRecorder()
        let plugins = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await plugins.install(
            services.pluginDefinition(baseSystemPrompt: "stable base prompt")
        )
        _ = try await plugins.install(
            CordisPluginDefinition(
                id: "test.cache-context",
                version: "1",
                dependencies: [
                    CordisAgentServiceKeys.systemPrompt.name,
                    CordisAgentServiceKeys.tools.name
                ]
            ) { context in
                try await context.registerTool(EchoTool(counter: counter))
                try await context.promptContext(
                    CordisPromptContextContribution(
                        name: "test:tool-count",
                        order: 0,
                        text: { _ in
                            "Tool executions: \(await counter.value)"
                        }
                    )
                )
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("update the context")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.systemPrompt), [
            "stable base prompt",
            "stable base prompt"
        ])
        let first = try XCTUnwrap(requests.first)
        let second = try XCTUnwrap(requests.last)
        XCTAssertEqual(Array(second.messages.prefix(first.messages.count)), first.messages)
        XCTAssertEqual(
            first.messages.filter(\.isRuntimeContextSnapshot).map(\.content),
            [
                "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\nTool executions: 0"
            ]
        )
        XCTAssertEqual(
            second.messages.filter(\.isRuntimeContextSnapshot).map(\.content),
            [
                "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\nTool executions: 0",
                "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\nTool executions: 1"
            ]
        )

        let committedSnapshots = await recorder.events.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages.filter(\.isRuntimeContextSnapshot)
        }
        XCTAssertEqual(committedSnapshots.count, 2)
        let recordedSessionEvents = await sessionEvents.events
        XCTAssertEqual(
            recordedSessionEvents.filter {
                $0.type == SessionEventVocabulary.requestHeader
            }.count,
            1
        )
    }

    func testRetainedRuntimeContextIsNotDuplicatedAfterRuntimeRecreation() async throws {
        let content = "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\nMode: stable."
        let source = JSONValue.object([
            "kind": .string("plugin"),
            "plugin": .string(AgentMessage.runtimeContextPluginID),
            "form": .string("snapshot")
        ])
        let retained = AgentMessage(role: .user, content: content, source: source)
        let history: [AgentMessage] = [
            .user("first"),
            retained,
            .assistant("first answer"),
            .user("second")
        ]
        let script = ModelScript(turns: [[.text("second answer"), .finish(.stop)]])
        let recorder = EventRecorder()
        let plugins = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await plugins.install(
            services.pluginDefinition(baseSystemPrompt: "stable base prompt")
        )
        _ = try await plugins.install(
            CordisPluginDefinition(
                id: "test.stable-context",
                version: "1",
                dependencies: [CordisAgentServiceKeys.systemPrompt.name]
            ) { context in
                try await context.promptContext(
                    CordisPromptContextContribution(
                        name: "test:mode",
                        order: 0,
                        text: "Mode: stable."
                    )
                )
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        try await runtime.run(
            history: history,
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.messages, history)
        XCTAssertEqual(request.messages.filter(\.isRuntimeContextSnapshot), [retained])
        let newlyCommitted = await recorder.events.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages.filter(\.isRuntimeContextSnapshot)
        }
        XCTAssertTrue(newlyCommitted.isEmpty)
    }

    func testFallbackForceCompactionRejectsSummaryThatDoesNotShrinkOmittedHistory() async throws {
        let recorder = FallbackCompactionRequestRecorder()
        let runtime = AgentRuntime(
            client: FallbackCompactionClient(recorder: recorder),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in }
        )

        do {
            try await runtime.run(
                history: [
                    .user(String(repeating: "old context ", count: 900)),
                    .assistant("recent")
                ],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            XCTFail("An oversized fallback compaction summary must not be dispatched")
        } catch is ModelClientError {
            // The original provider context error remains the terminal failure.
        }

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(
            requests[1].messages.last?.content.contains("compaction engine") == true
        )
    }

    func testConfiguredCompactionRouteFallsBackBeforeAnySummaryOutput() async throws {
        let script = CompactionRouteScript(mode: .failBeforeOutput)
        let traceRecorder = CompactionRouteTraceRecorder()
        var configuredRoute = ModelProviderCatalog.applying(
            .openAI,
            to: AgentConfiguration()
        )
        configuredRoute.model = "gpt-4.1-mini"
        let summaryConfiguration = configuredRoute
        let runtime = AgentRuntime(
            client: CompactionRouteClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            apiKeyProvider: { configuration in
                configuration.providerID == .openAI ? "summary-key" : "main-key"
            },
            compactionConfigurationProvider: { _ in summaryConfiguration },
            traceHandler: { draft in await traceRecorder.append(draft) }
        )

        try await runtime.run(
            history: [
                .user(String(repeating: "old context ", count: 900)),
                .assistant("recent")
            ],
            configuration: AgentConfiguration(),
            apiKey: "main-key"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].configuration.providerID, .openAI)
        XCTAssertEqual(requests[1].configuration.model, "gpt-4.1-mini")
        XCTAssertEqual(requests[1].apiKey, "summary-key")
        XCTAssertEqual(requests[2].configuration.providerID, .deepSeekOfficial)
        XCTAssertEqual(requests[2].apiKey, "main-key")
        XCTAssertEqual(requests[3].configuration.providerID, .deepSeekOfficial)
        let drafts = await traceRecorder.drafts
        XCTAssertTrue(
            drafts.contains {
                $0.name == "compaction/summary-route-fallback"
                    && $0.attributes["configuredProvider"] == .string("openai")
            }
        )
    }

    func testConfiguredCompactionRouteNeverFallsBackAfterPartialSummaryOutput() async throws {
        let script = CompactionRouteScript(mode: .failAfterPartialOutput)
        var configuredRoute = ModelProviderCatalog.applying(
            .openAI,
            to: AgentConfiguration()
        )
        configuredRoute.model = "gpt-4.1-mini"
        let summaryConfiguration = configuredRoute
        let runtime = AgentRuntime(
            client: CompactionRouteClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            apiKeyProvider: { _ in "summary-key" },
            compactionConfigurationProvider: { _ in summaryConfiguration }
        )

        do {
            try await runtime.run(
                history: [
                    .user(String(repeating: "old context ", count: 900)),
                    .assistant("recent")
                ],
                configuration: AgentConfiguration(),
                apiKey: "main-key"
            )
            XCTFail("The original context failure should remain terminal")
        } catch is ModelClientError {
            // Overflow recovery preserves the original provider failure.
        }

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].configuration.providerID, .openAI)
    }

    func testRuntimeContextIsReinjectedAfterCompactionDropsItsEarlierSnapshot() async throws {
        let plugins = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await plugins.install(
            services.pluginDefinition(baseSystemPrompt: "base prompt")
        )
        _ = try await plugins.install(
            CordisPluginDefinition(
                id: "test.runtime-context-compaction",
                version: "1",
                dependencies: [
                    CordisAgentServiceKeys.systemPrompt.name,
                    CordisAgentServiceKeys.tools.name
                ]
            ) { context in
                try await context.registerTool(EchoTool(counter: ToolCounter()))
                try await context.promptContext(
                    CordisPromptContextContribution(
                        name: "test:mode",
                        order: 0,
                        text: "Mode: stable."
                    )
                )
            }
        )

        let snapshotContent = "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\nMode: stable."
        let snapshotSource = JSONValue.object([
            "kind": .string("plugin"),
            "plugin": .string(AgentMessage.runtimeContextPluginID),
            "form": .string("snapshot")
        ])
        let script = CompactionRuntimeContextScript()
        let runtime = AgentRuntime(
            client: CompactionRuntimeContextClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { _ in }
        )

        try await runtime.run(
            history: [
                .user(String(repeating: "old context ", count: 900)),
                AgentMessage(role: .user, content: snapshotContent, source: snapshotSource),
                .assistant("recent")
            ],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(requests[2].messages.contains(where: \.isRuntimeContextSnapshot))
        XCTAssertTrue(requests[3].messages.contains(where: \.isRuntimeContextSnapshot))
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
        XCTAssertEqual(replayedAssistant.modelSource?.provider, ModelProviderID.deepSeekOfficial.rawValue)
        XCTAssertEqual(replayedAssistant.modelSource?.model, configuration.model)

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
        XCTAssertEqual(
            committedTurns.first?.first?.modelSource,
            replayedAssistant.modelSource
        )
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

    func testPinnedDeepSeekToolSchedulerDifferentialFixture() async throws {
        let fixture = try ToolSchedulerFixture.load()
        let lock = try DeepSeekUpstreamLock.load()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.source.project, "deepseek-ai/deepseek-harness")
        XCTAssertEqual(fixture.source.lockPath, "Dependencies/upstreams.lock.json")
        XCTAssertEqual(fixture.source.commit, lock.deepseekHarness.commit)

        for scenario in fixture.scenarios {
            switch scenario.id {
            case "reclassification-before-launch":
                let result = try await runToolSchedulerReclassificationScenario()
                XCTAssertEqual(result.modeChecks, scenario.expected.modeChecks, scenario.id)
                XCTAssertEqual(result.startedIDs, scenario.expected.startedIDs, scenario.id)
                XCTAssertEqual(result.maximumConcurrent, scenario.expected.maximumConcurrent, scenario.id)
                XCTAssertEqual(result.resultIDs, scenario.expected.resultIDs, scenario.id)
            case "abort-started-vs-skipped":
                let result = try await runToolSchedulerAbortScenario()
                XCTAssertEqual(result.startedIDs, scenario.expected.startedIDs, scenario.id)
                XCTAssertEqual(result.resultIDs, scenario.expected.resultIDs, scenario.id)
                XCTAssertEqual(result.resultErrorCodes, scenario.expected.resultErrorCodes, scenario.id)
            default:
                XCTFail("Unknown tool scheduler fixture scenario: \(scenario.id)")
            }
        }
    }

    private func runToolSchedulerReclassificationScenario() async throws -> ToolSchedulerScenarioResult {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(index: 0, id: "reclass-1", type: "function", name: "reclassifying_gate", arguments: "{\"id\":\"1\",\"resource\":\"r1\"}"),
                .toolCallDelta(index: 1, id: "reclass-2", type: "function", name: "reclassifying_gate", arguments: "{\"id\":\"2\",\"resource\":\"r2\"}"),
                .toolCallDelta(index: 2, id: "reclass-3", type: "function", name: "reclassifying_gate", arguments: "{\"id\":\"3\",\"resource\":\"r3\"}"),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let gate = ParallelToolGate()
        let mode = ReclassifyingModeProbe(parallelChecks: 2)
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ReclassifyingGateTool(gate: gate, mode: mode)]),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        let task = Task {
            try await runtime.run(history: [.user("reclassify")], configuration: AgentConfiguration(), apiKey: "test-only")
        }
        try await eventually { await gate.startedIDs == ["1", "2"] }
        await gate.release("1")
        try await eventually { mode.checks == [true, true, false] }
        await gate.release("2")
        try await eventually { await gate.startedIDs == ["1", "2", "3"] }
        await gate.release("3")
        try await task.value

        let requests = await script.requests
        let resultIDs = requests[1].messages.filter { $0.role == .tool }.compactMap(\.toolCallID)
        return ToolSchedulerScenarioResult(
            modeChecks: mode.checks,
            startedIDs: await gate.startedIDs,
            maximumConcurrent: await gate.maximumConcurrent,
            resultIDs: resultIDs,
            resultErrorCodes: []
        )
    }

    private func runToolSchedulerAbortScenario() async throws -> ToolSchedulerScenarioResult {
        let script = ModelScript(turns: [[
            .toolCallDelta(index: 0, id: "abort-1", type: "function", name: "parallel_gate", arguments: "{\"id\":\"1\",\"resource\":\"r1\"}"),
            .toolCallDelta(index: 1, id: "abort-2", type: "function", name: "parallel_gate", arguments: "{\"id\":\"2\",\"resource\":\"r2\"}"),
            .toolCallDelta(index: 2, id: "abort-3", type: "function", name: "parallel_gate", arguments: "{\"id\":\"3\",\"resource\":\"r3\"}"),
            .toolCallDelta(index: 3, id: "abort-4", type: "function", name: "parallel_gate", arguments: "{\"id\":\"4\",\"resource\":\"r4\"}"),
            .finish(.toolCalls)
        ]])
        let gate = ParallelToolGate()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ParallelGateTool(gate: gate)]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in try await sessionEvents.append(draft) }
        )
        let task = Task {
            try await runtime.run(history: [.user("abort")], configuration: AgentConfiguration(), apiKey: "test-only")
        }
        try await eventually { await gate.startedIDs == ["1", "2"] }
        task.cancel()
        await gate.release("1")
        await gate.release("2")
        do {
            try await task.value
            XCTFail("Cancelled scheduler run must throw")
        } catch is CancellationError {
            // Expected.
        }

        let results = await sessionEvents.events.filter { $0.type == SessionEventVocabulary.toolResult }
        let resultIDs = results.compactMap { $0.toolResultData?.callID }
        let resultErrorCodes = results.compactMap { $0.toolResultData?.error?.objectValue?["code"]?.stringValue }
        return ToolSchedulerScenarioResult(
            modeChecks: [],
            startedIDs: await gate.startedIDs,
            maximumConcurrent: await gate.maximumConcurrent,
            resultIDs: resultIDs,
            resultErrorCodes: resultErrorCodes
        )
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
        let sessionEvents = SessionEventRecorder()
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
            eventHandler: { event in await recorder.append(event) },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
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

    func testApprovalWritesUpstreamAuditPairBeforeToolExecution() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "approval-audit",
                    type: "function",
                    name: "approval_counting",
                    arguments: "{\"value\":\"allowed\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("done"), .finish(.stop)]
        ])
        let counter = ToolCounter()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalCountingTool(counter: counter)]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("audit approval")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 1)
        let events = await sessionEvents.events
        let asked = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.approvalAsked }
        )
        let decided = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.approvalDecided }
        )
        let requestID = try XCTUnwrap(asked.data.objectValue?["id"]?.stringValue)
        XCTAssertEqual(asked.data.objectValue?["toolName"]?.stringValue, "approval_counting")
        XCTAssertEqual(asked.data.objectValue?["callId"]?.stringValue, "approval-audit")
        XCTAssertEqual(asked.data.objectValue?["reason"]?.stringValue, "approval counting")
        XCTAssertEqual(asked.data.objectValue?["risk"]?.stringValue, ToolRisk.sideEffect.rawValue)
        XCTAssertFalse(asked.data.objectValue?["modelDestination"]?.stringValue?.isEmpty ?? true)
        guard case let .array(resources)? = asked.data.objectValue?["resources"] else {
            return XCTFail("approval/asked resources must be an array")
        }
        XCTAssertEqual(resources, [.string("tool")])
        XCTAssertEqual(decided.data.objectValue?["id"]?.stringValue, requestID)
        XCTAssertEqual(decided.data.objectValue?["outcome"]?.stringValue, "allowed-once")
        XCTAssertLessThan(asked.seq, decided.seq)
    }

    func testApprovalAuditAppendFailurePreventsToolExecution() async throws {
        for failingType in [
            SessionEventVocabulary.approvalAsked,
            SessionEventVocabulary.approvalDecided
        ] {
            let script = ModelScript(turns: [
                [
                    .toolCallDelta(
                        index: 0,
                        id: "approval-fail-\(failingType)",
                        type: "function",
                        name: "approval_counting",
                        arguments: "{\"value\":\"blocked\"}"
                    ),
                    .finish(.toolCalls)
                ],
                [.text("handled"), .finish(.stop)]
            ])
            let counter = ToolCounter()
            let sessionEvents = SessionEventRecorder()
            let runtime = AgentRuntime(
                client: ScriptedModelClient(script: script),
                registry: LocalToolRegistry(tools: [ApprovalCountingTool(counter: counter)]),
                approvalHandler: { _ in true },
                eventHandler: { _ in },
                sessionEventHandler: { draft in
                    if draft.type == failingType {
                        throw ApprovalAuditTestError.persistenceFailed
                    }
                    return try await sessionEvents.append(draft)
                }
            )

            try await runtime.run(
                history: [.user("fail closed")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )

            let executionCount = await counter.value
            XCTAssertEqual(executionCount, 0, "Failed open for \(failingType)")
        }
    }

    func testMissingDurableApprovalWriterPreventsToolExecution() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "approval-missing-writer",
                    type: "function",
                    name: "approval_counting",
                    arguments: "{\"value\":\"blocked\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("handled"), .finish(.stop)]
        ])
        let counter = ToolCounter()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalCountingTool(counter: counter)]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { _ in nil }
        )

        try await runtime.run(
            history: [.user("missing audit writer")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
    }

    func testDeniedApprovalWritesRejectedDecisionAndDoesNotExecuteTool() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "approval-denied",
                    type: "function",
                    name: "approval_counting",
                    arguments: "{\"value\":\"blocked\"}"
                ),
                .finish(.toolCalls)
            ],
            [.text("handled"), .finish(.stop)]
        ])
        let counter = ToolCounter()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [ApprovalCountingTool(counter: counter)]),
            approvalHandler: { _ in false },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        try await runtime.run(
            history: [.user("deny approval")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
        let events = await sessionEvents.events
        let decision = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.approvalDecided }
        )
        XCTAssertEqual(decision.data.objectValue?["outcome"]?.stringValue, "rejected")
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
        let truncatedTurn: [LLMStreamEvent] = [
            .toolCallDelta(
                index: 0,
                id: "call-1",
                type: "function",
                name: "echo",
                arguments: "{\"value\":\"must-not-run\"}"
            ),
            .finish(.length)
        ]
        let script = ModelScript(turns: [truncatedTurn])
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
            XCTFail("A repeatedly length-truncated tool call must not execute")
        } catch let error as AgentRuntimeError {
            guard case .unsafeFinishReason(.length) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
        let requestCount = await script.requests.count
        XCTAssertEqual(requestCount, 1)
        let events = await recorder.events
        XCTAssertFalse(events.contains { event in
            if case .messagesCommitted = event { return true }
            return false
        })
    }

    func testLengthTruncatedToolCallDoesNotReissueEvenWhenLaterScriptWouldBeValid() async throws {
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
            ], [
                .toolCallDelta(
                    index: 0,
                    id: "call-2",
                    type: "function",
                    name: "echo",
                    arguments: "{\"value\":\"safe-retry\"}"
                ),
                .finish(.toolCalls)
            ], [
                .text("done"),
                .finish(.stop)
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
            XCTFail("A truncated tool call must fail instead of being reissued")
        } catch let error as AgentRuntimeError {
            guard case .unsafeFinishReason(.length) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let executionCount = await counter.value
        XCTAssertEqual(executionCount, 0)
        let requests = await script.requests
        XCTAssertEqual(requests.map(\.configuration.maxOutputTokens), [8_192])
        let events = await recorder.events
        XCTAssertFalse(events.contains { event in
            if case .toolFinished = event { return true }
            return false
        })
    }

    func testReasoningOnlyLengthFinishCommitsIncompleteResponseWithoutContinuation() async throws {
        let script = ModelScript(turns: [[
            .reasoning("unfinished private reasoning"),
            .finish(.length)
        ]])
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        try await runtime.run(
            history: [.user("think deeply")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.map(\.configuration.maxOutputTokens), [8_192])
        let committed = await recorder.events.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages
        }
        XCTAssertEqual(committed.map(\.content), [""])
        XCTAssertEqual(committed.first?.reasoning, "unfinished private reasoning")
        XCTAssertTrue(committed.first?.isIncomplete == true)
        XCTAssertEqual(committed.first?.incompleteReason, .modelOutputLength)
    }

    func testTextLengthFinishCommitsOneIncompleteResponseWithoutContinuation() async throws {
        let script = ModelScript(turns: [[
            .reasoning("partial rationale"),
            .text("partial response"),
            .finish(.length)
        ]])
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        try await runtime.run(
            history: [.user("complete the task")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.map(\.configuration.maxOutputTokens), [8_192])
        let recordedEvents = await recorder.events
        let committed = recordedEvents.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages
        }
        XCTAssertEqual(committed.map(\.content), ["partial response"])
        XCTAssertEqual(committed.first?.reasoning, "partial rationale")
        XCTAssertTrue(committed.first?.isIncomplete == true)
        XCTAssertEqual(committed.first?.incompleteReason, .modelOutputLength)
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
        let truncatedTurn: [LLMStreamEvent] = [
            .toolCallDelta(
                index: 0,
                id: "call-1",
                type: "function",
                name: "echo",
                arguments: "{\"value\":\"must-not-run\"}"
            ),
            .finish(.length)
        ]
        let script = ModelScript(
            turns: [truncatedTurn, truncatedTurn, truncatedTurn, truncatedTurn]
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
            eventHandler: { event in await recorder.append(event) },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
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

    func testCancellationDuringModelStreamCommitsVisiblePrefixBeforeClosingTurn() async throws {
        let gate = SilentStreamGate()
        let usage = ModelTokenUsage(
            promptTokens: 12,
            completionTokens: 5,
            totalTokens: 17,
            cachedPromptTokens: nil,
            reasoningTokens: 2
        )
        let recorder = EventRecorder()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: PrefixThenHangModelClient(
                events: [
                    .reasoning("considering the request"),
                    .text("delivered answer prefix"),
                    .toolCallDelta(
                        index: 0,
                        id: "unfinished-call",
                        type: "function",
                        name: "echo",
                        arguments: "{\"value\":"
                    ),
                    .usage(usage)
                ],
                gate: gate
            ),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("start")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        await gate.waitUntilSubscribed()
        try await eventually {
            await recorder.events.contains { event in
                if case .usage = event { return true }
                return false
            }
        }
        task.cancel()
        await gate.finish()

        do {
            try await task.value
            XCTFail("Cancelled run should throw")
        } catch is CancellationError {
            // Expected.
        }

        let runtimeEvents = await recorder.events
        let committed = runtimeEvents.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages
        }
        let interrupted = try XCTUnwrap(committed.last)
        XCTAssertEqual(interrupted.role, .assistant)
        XCTAssertEqual(interrupted.content, "delivered answer prefix")
        XCTAssertEqual(interrupted.reasoning, "considering the request")
        XCTAssertTrue(interrupted.toolCalls.isEmpty)
        XCTAssertTrue(interrupted.isIncomplete)
        XCTAssertEqual(interrupted.incompleteReason, .cancelled)

        let durableEvents = await sessionEvents.events
        let assistantEvent = try XCTUnwrap(
            durableEvents.first { $0.type == SessionEventVocabulary.assistantMessage }
        )
        XCTAssertTrue(assistantEvent.assistantMessageData?.interrupted == true)
        XCTAssertEqual(assistantEvent.assistantMessageData?.incompleteReason, .cancelled)
        XCTAssertEqual(
            assistantEvent.sourceEventSeqs,
            durableEvents.filter { $0.type == SessionEventVocabulary.assistantChunk }.map(\.seq)
        )
        XCTAssertEqual(
            assistantEvent.assistantMessageData?.usage,
            SessionTokenUsage(
                inputTokens: 12,
                outputTokens: 5,
                cacheReadTokens: nil,
                reasoningTokens: 2
            )
        )
        let types = durableEvents.map(\.type)
        let assistantIndex = try XCTUnwrap(types.firstIndex(of: SessionEventVocabulary.assistantMessage))
        let stepEndIndex = try XCTUnwrap(types.firstIndex(of: SessionEventVocabulary.stepEnd))
        let turnEndIndex = try XCTUnwrap(types.firstIndex(of: SessionEventVocabulary.turnEnd))
        XCTAssertLessThan(assistantIndex, stepEndIndex)
        XCTAssertLessThan(stepEndIndex, turnEndIndex)

        let projected = SessionTrajectoryConversationProjection.messages(from: durableEvents)
        let projectedAssistant = try XCTUnwrap(projected.last { $0.role == .assistant })
        XCTAssertEqual(projectedAssistant.content, interrupted.content)
        XCTAssertEqual(projectedAssistant.reasoning, interrupted.reasoning)
        XCTAssertTrue(projectedAssistant.isIncomplete)
        XCTAssertEqual(projectedAssistant.incompleteReason, .cancelled)

        let followUpScript = ModelScript(turns: [[.text("continued"), .finish(.stop)]])
        let followUpRuntime = AgentRuntime(
            client: ScriptedModelClient(script: followUpScript),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in }
        )
        try await followUpRuntime.run(
            history: [.user("start"), interrupted, .user("continue from there")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )
        let followUpRequests = await followUpScript.requests
        let followUpRequest = try XCTUnwrap(followUpRequests.first)
        XCTAssertTrue(followUpRequest.messages.contains { message in
            message.id == interrupted.id
                && message.content == "delivered answer prefix"
                && message.reasoning == "considering the request"
        })
    }

    func testCancellationDuringToolOnlyStreamDoesNotCommitAssistantMessage() async throws {
        let gate = SilentStreamGate()
        let recorder = EventRecorder()
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: PrefixThenHangModelClient(
                events: [
                    .toolCallDelta(
                        index: 0,
                        id: "unfinished-call",
                        type: "function",
                        name: "echo",
                        arguments: "{\"value\":"
                    )
                ],
                gate: gate
            ),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("start")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        await gate.waitUntilSubscribed()
        try await eventually {
            await sessionEvents.events.contains {
                $0.type == SessionEventVocabulary.assistantChunk
            }
        }
        task.cancel()
        await gate.finish()

        do {
            try await task.value
            XCTFail("Cancelled run should throw")
        } catch is CancellationError {
            // Expected.
        }

        let runtimeEvents = await recorder.events
        XCTAssertFalse(runtimeEvents.contains { event in
            if case .messagesCommitted = event { return true }
            return false
        })
        let durableEvents = await sessionEvents.events
        XCTAssertFalse(durableEvents.contains {
            $0.type == SessionEventVocabulary.assistantMessage
        })
    }

    func testCancellationDuringReasoningOnlyStreamCommitsReasoningPrefix() async throws {
        let gate = SilentStreamGate()
        let recorder = EventRecorder()
        let runtime = AgentRuntime(
            client: PrefixThenHangModelClient(
                events: [.reasoning("reasoning prefix")],
                gate: gate
            ),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { event in await recorder.append(event) }
        )

        let task = Task {
            try await runtime.run(
                history: [.user("start")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
        }
        await gate.waitUntilSubscribed()
        try await eventually {
            await recorder.events.contains { event in
                if case .reasoningDelta = event { return true }
                return false
            }
        }
        task.cancel()
        await gate.finish()

        do {
            try await task.value
            XCTFail("Cancelled run should throw")
        } catch is CancellationError {
            // Expected.
        }

        let committed = await recorder.events.flatMap { event -> [AgentMessage] in
            guard case let .messagesCommitted(messages) = event else { return [] }
            return messages
        }
        XCTAssertEqual(committed.last?.content, "")
        XCTAssertEqual(committed.last?.reasoning, "reasoning prefix")
        XCTAssertTrue(committed.last?.isIncomplete == true)
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

    func testInboxPreClaimDiscardsThenRewritesWithoutChangingOccurrenceIdentity() async throws {
        let script = ModelScript(turns: [
            [.text("first answer"), .finish(.stop)],
            [.text("second answer"), .finish(.stop)]
        ])
        let discarded = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000331")!,
            text: "discard me",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        let rewritten = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000332")!,
            text: "rewrite me",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 301)
        )
        let inbox = TestQueuedInputInbox(inputs: [discarded, rewritten])
        let observed = InboxCheckpointRecorder()
        let plugins = CordisPluginRuntime()
        _ = try await plugins.install(
            CordisAgentServices().pluginDefinition(baseSystemPrompt: MobileHarnessPrompt.text)
        )
        _ = try await plugins.install(
            CordisPluginDefinition(id: "test.inbox-policy", version: "1") { context in
                try await context.intercept(
                    CordisAgentLoopCheckpoints.inboxPreClaim
                ) { input, _ in
                    await observed.append(input)
                    if input.message.id == discarded.id {
                        return .discard
                    }
                    return .claim(text: "rewritten by plugin")
                }
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            queuedInputProvider: { boundary in
                await inbox.next(at: boundary)
            },
            queuedInputCommitter: { messageID in
                await inbox.claim(messageID: messageID)
            },
            workspaceBoundary: "/workspace/session-a"
        )

        try await runtime.run(
            history: [.user("start")],
            configuration: {
                var configuration = AgentConfiguration()
                configuration.maxSteps = 2
                return configuration
            }(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests.flatMap(\.messages).contains { $0.id == discarded.id })
        let claimed = try XCTUnwrap(
            requests[1].messages.first(where: { $0.id == rewritten.id })
        )
        XCTAssertEqual(claimed.role, .user)
        XCTAssertEqual(claimed.content, "rewritten by plugin")
        XCTAssertEqual(claimed.createdAt, rewritten.createdAt)
        let inboxIsEmpty = await inbox.isEmpty
        XCTAssertTrue(inboxIsEmpty)

        let contexts = await observed.values
        XCTAssertEqual(contexts.map(\.message.id), [discarded.id, rewritten.id])
        XCTAssertTrue(contexts.allSatisfy { $0.source == "user" })
        XCTAssertTrue(contexts.allSatisfy { $0.workspaceBoundary == "/workspace/session-a" })
        XCTAssertTrue(contexts.allSatisfy { $0.boundary == .turnStopping })
        XCTAssertTrue(contexts.allSatisfy { $0.turn == 2 && $0.step == 0 })
    }

    func testInboxLifecycleEventsPublishStableClaimAndDiscardFacts() async throws {
        let script = ModelScript(turns: [
            [.text("first answer"), .finish(.stop)],
            [.text("second answer"), .finish(.stop)]
        ])
        let discarded = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000341")!,
            text: "discard lifecycle",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 340)
        )
        let claimed = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000342")!,
            text: "claim lifecycle",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 341)
        )
        let inbox = TestQueuedInputInbox(inputs: [discarded, claimed])
        let recorder = InboxLifecycleEventRecorder()
        let plugins = CordisPluginRuntime()
        let services = CordisAgentServices()
        _ = try await plugins.install(
            services.pluginDefinition(baseSystemPrompt: MobileHarnessPrompt.text)
        )
        _ = try await plugins.install(
            CordisPluginDefinition(id: "test.inbox-lifecycle", version: "1") { context in
                try await context.intercept(
                    CordisAgentLoopCheckpoints.inboxPreClaim
                ) { input, _ in
                    if input.message.id == discarded.id {
                        return .discard
                    }
                    return .claim(text: input.message.text)
                }
                _ = try await context.on(CordisAgentLoopEvents.agentInboxDiscarded) { input in
                    await recorder.recordDiscarded(input)
                }
                _ = try await context.on(CordisAgentLoopEvents.agentInboxClaimed) { input in
                    await recorder.recordClaimed(input)
                }
            }
        )

        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000343")!
        let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000344")!
        let runtime = AgentRuntime(
            agentID: agentID,
            runID: runID,
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            queuedInputProvider: { boundary in
                await inbox.next(at: boundary)
            },
            queuedInputCommitter: { messageID in
                await inbox.claim(messageID: messageID)
            }
        )

        try await runtime.run(
            history: [.user("start")],
            configuration: {
                var configuration = AgentConfiguration()
                configuration.maxSteps = 2
                return configuration
            }(),
            apiKey: "test-only"
        )
        try await eventually {
            await recorder.count == 2
        }

        let events = await recorder.events
        XCTAssertEqual(events.map(\.kind), [.discarded, .claimed])
        XCTAssertEqual(events.map(\.messageID), [discarded.id, claimed.id])
        XCTAssertEqual(events.map(\.text), [discarded.text, claimed.text])
        XCTAssertTrue(events.allSatisfy { $0.agentID == agentID && $0.runID == runID })
        XCTAssertTrue(events.allSatisfy { $0.source == "user" && $0.boundary == .turnStopping })
        XCTAssertEqual(events.first?.reason, "plugin")
        XCTAssertNil(events.last?.reason)
    }

    func testInboxLifecycleListenerFailureDoesNotAbortAgentLoop() async throws {
        let script = ModelScript(turns: [
            [.text("completed"), .finish(.stop)],
            [.text("completed after claim"), .finish(.stop)]
        ])
        let queued = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000345")!,
            text: "continue despite listener",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 345)
        )
        let inbox = TestQueuedInputInbox(inputs: [queued])
        let plugins = CordisPluginRuntime()
        _ = try await plugins.install(
            CordisAgentServices().pluginDefinition(baseSystemPrompt: MobileHarnessPrompt.text)
        )
        _ = try await plugins.install(
            CordisPluginDefinition(id: "test.inbox-listener-failure", version: "1") { context in
                _ = try await context.on(CordisAgentLoopEvents.agentInboxClaimed) { _ in
                    throw TestInboxLifecycleError.injected
                }
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            queuedInputProvider: { boundary in
                await inbox.next(at: boundary)
            },
            queuedInputCommitter: { messageID in
                await inbox.claim(messageID: messageID)
            }
        )

        try await runtime.run(
            history: [.user("start")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )
        let inboxIsEmpty = await inbox.isEmpty
        XCTAssertTrue(inboxIsEmpty)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].messages.contains { $0.id == queued.id })
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
        let recorder = EventRecorder()
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
            eventHandler: { event in await recorder.append(event) }
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
        let injections = await recorder.events.compactMap { event -> AgentContextInjection? in
            guard case let .contextInjected(injection) = event else { return nil }
            return injection
        }
        XCTAssertEqual(injections.count, 2)
        XCTAssertEqual(
            Set(injections.map(\.sourceLabel)),
            ["@deepseek-ai/dsh-system-prompt", "test:prompt"]
        )
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

    func testDurabilityCheckpointsCoverModelToolAndTurnBoundaries() async throws {
        let script = ModelScript(turns: [[
            .toolCallDelta(
                index: 0,
                id: "checkpoint-call",
                type: "function",
                name: "echo",
                arguments: "{\"value\":\"durable\"}"
            ),
            .finish(.toolCalls)
        ], [
            .text("done"),
            .finish(.stop)
        ]])
        let recorder = CheckpointRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: ToolCounter())]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            checkpointHandler: {
                await recorder.record("checkpoint")
            }
        )

        try await runtime.run(
            history: [.user("checkpoint test")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let entries = await recorder.entries
        XCTAssertEqual(entries.filter { $0 == "checkpoint" }.count, 6)
    }

    func testModelCheckpointFailurePreventsProviderDispatch() async throws {
        let script = ModelScript(turns: [[
            .text("must not be requested"),
            .finish(.stop)
        ]])
        let checkpoints = FailingCheckpoint(failOnInvocation: 1)
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            checkpointHandler: {
                try await checkpoints.hit()
            }
        )

        do {
            try await runtime.run(
                history: [.user("fail before provider dispatch")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            XCTFail("A failed model checkpoint must abort the run")
        } catch let error as AgentRuntimeError {
            guard case .sessionEventPersistenceFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let requests = await script.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testToolCheckpointFailurePreventsToolBody() async throws {
        let script = ModelScript(turns: [[
            .toolCallDelta(
                index: 0,
                id: "fail-closed-tool",
                type: "function",
                name: "echo",
                arguments: "{\"value\":\"must not execute\"}"
            ),
            .finish(.toolCalls)
        ], [
            .text("handled safely"),
            .finish(.stop)
        ]])
        let toolCounter = ToolCounter()
        // Invocation 1 is the model request checkpoint; invocation 2 is the
        // checkpoint after tool/call and immediately before the tool body.
        let checkpoints = FailingCheckpoint(failOnInvocation: 2)
        let sessionEvents = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [EchoTool(counter: toolCounter)]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                try await sessionEvents.append(draft)
            },
            checkpointHandler: {
                try await checkpoints.hit()
            }
        )

        try await runtime.run(
            history: [.user("fail before tool side effect")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let executionCount = await toolCounter.value
        XCTAssertEqual(executionCount, 0)
        let events = await sessionEvents.events
        let call = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.toolCall }
        )
        let result = try XCTUnwrap(
            events.first { $0.type == SessionEventVocabulary.toolResult }
        )
        XCTAssertEqual(result.sourceEventSeqs, [call.seq])
        let resultMessage = try XCTUnwrap(result.toolResultData?.message)
        XCTAssertTrue(resultMessage.displayText.contains("Error"))
        XCTAssertEqual(
            result.toolResultData?.error?.objectValue?["name"]?.stringValue,
            "ToolExecutionError"
        )
    }

    func testCodeModeChildIntentIsRecordedBeforeItsCheckpoint() async throws {
        let script = ModelScript(turns: [
            [
                .toolCallDelta(
                    index: 0,
                    id: "code-parent-checkpoint",
                    type: "function",
                    name: "run_code",
                    arguments: "{}"
                ),
                .finish(.toolCalls)
            ],
            [.text("continued after child checkpoint failure"), .finish(.stop)]
        ])
        let childCounter = ToolCounter()
        let sessionEvents = SessionDraftRecorder()
        let checkpoints = FailingCheckpoint(failOnInvocation: 3)
        let codePreset = try XCTUnwrap(
            AgentPresetRegistry.systemPresets.first { $0.id == "code" }
        ).runtimeProjection
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: script),
            registry: LocalToolRegistry(tools: [
                CheckpointingRunCodeBridgeTool(),
                CheckpointingCodeChildTool(counter: childCounter)
            ]),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            permissionMode: .dangerFullAccess,
            agentPreset: codePreset,
            sessionEventHandler: { draft in
                _ = await sessionEvents.append(draft)
                return nil
            },
            checkpointHandler: {
                try await checkpoints.hit()
            }
        )

        try await runtime.run(
            history: [.user("exercise child checkpoint ordering")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let childCount = await childCounter.value
        XCTAssertEqual(childCount, 0)
        let drafts = await sessionEvents.drafts
        XCTAssertTrue(
            drafts.contains { $0.type == "tool/code-dispatch-start" },
            "the child intent must be present before the failing checkpoint"
        )
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

    func testTextOnlyLengthFinishPersistsIncompleteAssistantMessage() async throws {
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
        XCTAssertEqual(
            assistant.assistantMessageData?.incompleteReason,
            .modelOutputLength
        )
        let reason = try XCTUnwrap(events.last?.turnEndData?.reason.objectValue)
        XCTAssertEqual(reason["kind"], .string("truncated"))
    }

    func testPinnedDeepSeekAgentLifecycleDifferentialFixture() async throws {
        let fixture = try AgentLifecycleFixture.load()
        let lock = try DeepSeekUpstreamLock.load()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.source.project, "deepseek-ai/deepseek-harness")
        XCTAssertEqual(fixture.source.lockPath, "Dependencies/upstreams.lock.json")
        XCTAssertEqual(fixture.source.commit, lock.deepseekHarness.commit)

        for scenario in fixture.scenarios {
            let events = try await AgentLifecycleFixtureRunner.run(scenario.id)
            XCTAssertEqual(
                events.map(\.type),
                scenario.eventTypes,
                "Unexpected durable event sequence for \(scenario.id)"
            )
            XCTAssertEqual(
                AgentLifecycleFixtureRunner.sourceLinks(in: events),
                scenario.sourceLinks,
                "Unexpected source-event sequence for \(scenario.id)"
            )

            let turnsStarted = events.filter { $0.type == SessionEventVocabulary.turnStart }.count
            let stepsStarted = events.filter { $0.type == SessionEventVocabulary.stepStart }.count
            let turnsEnded = events.filter { $0.type == SessionEventVocabulary.turnEnd }.count
            let stepsEnded = events.filter { $0.type == SessionEventVocabulary.stepEnd }.count
            XCTAssertEqual(turnsStarted, scenario.closure.turnStarts, scenario.id)
            XCTAssertEqual(stepsStarted, scenario.closure.stepStarts, scenario.id)
            XCTAssertEqual(turnsEnded, scenario.closure.turnEnds, scenario.id)
            XCTAssertEqual(stepsEnded, scenario.closure.stepEnds, scenario.id)
            XCTAssertEqual(turnsStarted, turnsEnded, "Unclosed turn in \(scenario.id)")
            XCTAssertEqual(stepsStarted, stepsEnded, "Unclosed step in \(scenario.id)")
            XCTAssertEqual(
                events.compactMap { $0.turnEndData?.reason.objectValue?["kind"]?.stringValue },
                scenario.closure.terminalKinds,
                "Unexpected terminal closure for \(scenario.id)"
            )
        }
    }
}

private struct AgentLifecycleFixture: Decodable {
    let schemaVersion: Int
    let source: Source
    let scenarios: [Scenario]

    struct Source: Decodable {
        let project: String
        let commit: String
        let lockPath: String
    }

    struct Scenario: Decodable {
        let id: String
        let eventTypes: [String]
        let sourceLinks: [String]
        let closure: Closure
    }

    struct Closure: Decodable {
        let turnStarts: Int
        let stepStarts: Int
        let turnEnds: Int
        let stepEnds: Int
        let terminalKinds: [String]
    }

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
            .appendingPathComponent("deepseek", isDirectory: true)
            .appendingPathComponent("agent-lifecycle-v1.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private struct DeepSeekUpstreamLock: Decodable {
    let deepseekHarness: Entry

    struct Entry: Decodable {
        let commit: String
    }

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("Dependencies", isDirectory: true)
            .appendingPathComponent("upstreams.lock.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private enum AgentLifecycleFixtureRunner {
    static func run(_ id: String) async throws -> [SessionEvent] {
        switch id {
        case "normal-response":
            return try await normalResponse()
        case "empty-response":
            return try await emptyResponse()
        case "tool-turn":
            return try await toolTurn()
        case "steer":
            return try await steer()
        case "inject":
            return try await inject()
        case "followup":
            return try await followup()
        case "pre-step-rejection":
            return try await preStepRejection()
        case "request-failure-retry":
            return try await requestFailureRetry()
        case "cancellation":
            return try await cancellation()
        default:
            throw AgentLifecycleFixtureError.unknownScenario(id)
        }
    }

    static func sourceLinks(in events: [SessionEvent]) -> [String] {
        let typesBySequence = Dictionary(uniqueKeysWithValues: events.map { ($0.seq, $0.type) })
        return events.compactMap { event in
            guard let sourceEventSeqs = event.sourceEventSeqs, !sourceEventSeqs.isEmpty else {
                return nil
            }
            let sourceTypes = sourceEventSeqs.compactMap { typesBySequence[$0] }
            return "\(event.type)<-\(sourceTypes.joined(separator: ","))"
        }
    }

    private static func normalResponse() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let runtime = runtime(
            client: ScriptedModelClient(script: ModelScript(turns: [[.text("normal"), .finish(.stop)]])),
            sessionEvents: events
        )
        try await run(runtime)
        return await events.events
    }

    private static func emptyResponse() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let runtime = runtime(
            client: ScriptedModelClient(script: ModelScript(turns: [[.finish(.stop)]])),
            sessionEvents: events
        )
        do {
            try await run(runtime, configuration: noRetryConfiguration())
            throw AgentLifecycleFixtureError.expectedFailure("empty response")
        } catch is ModelClientError {
            return await events.events
        }
    }

    private static func toolTurn() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let runtime = runtime(
            client: ScriptedModelClient(script: ModelScript(turns: [
                [.toolCallDelta(index: 0, id: "lifecycle-tool", type: "function", name: "echo", arguments: "{\"value\":\"tool\"}"), .finish(.toolCalls)],
                [.text("done"), .finish(.stop)]
            ])),
            tools: [EchoTool(counter: ToolCounter())],
            sessionEvents: events
        )
        var configuration = AgentConfiguration()
        configuration.maxSteps = 2
        try await run(runtime, configuration: configuration)
        return await events.events
    }

    private static func steer() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let queued = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            text: "steered direction",
            disposition: .steer,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let inbox = TestQueuedInputInbox(inputs: [queued])
        let runtime = runtime(
            client: ScriptedModelClient(script: ModelScript(turns: [
                [.toolCallDelta(index: 0, id: "steer-tool", type: "function", name: "echo", arguments: "{\"value\":\"first\"}"), .finish(.toolCalls)],
                [.text("steered response"), .finish(.stop)]
            ])),
            tools: [EchoTool(counter: ToolCounter())],
            eventHandler: { event in
                if case let .messagesCommitted(messages) = event {
                    await inbox.acknowledge(messageIDs: messages.map(\.id))
                }
            },
            queuedInputProvider: { boundary in await inbox.next(at: boundary) },
            sessionEvents: events
        )
        var configuration = AgentConfiguration()
        configuration.maxSteps = 2
        try await run(runtime, configuration: configuration)
        return await events.events
    }

    private static func inject() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: ModelScript(turns: [[.text("injected response"), .finish(.stop)]])),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            preStepInstructionProvider: { _ in
                [AgentRuntimeInstructionInjection(
                    content: "plugin context",
                    source: .object(["kind": .string("plugin"), "plugin": .string("fixture")])
                )]
            },
            sessionEventHandler: { draft in try await events.append(draft) }
        )
        try await run(runtime)
        return await events.events
    }

    private static func followup() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let queued = try QueuedAgentInput(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
            text: "follow up",
            disposition: .queued,
            createdAt: Date(timeIntervalSinceReferenceDate: 2)
        )
        let inbox = TestQueuedInputInbox(inputs: [queued])
        let runtime = runtime(
            client: ScriptedModelClient(script: ModelScript(turns: [
                [.text("first response"), .finish(.stop)],
                [.text("followup response"), .finish(.stop)]
            ])),
            eventHandler: { event in
                if case let .messagesCommitted(messages) = event {
                    await inbox.acknowledge(messageIDs: messages.map(\.id))
                }
            },
            queuedInputProvider: { boundary in await inbox.next(at: boundary) },
            sessionEvents: events
        )
        try await run(runtime)
        return await events.events
    }

    private static func preStepRejection() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let plugins = CordisPluginRuntime()
        _ = try await plugins.install(
            CordisAgentServices().pluginDefinition(baseSystemPrompt: MobileHarnessPrompt.text)
        )
        _ = try await plugins.install(
            CordisPluginDefinition(id: "fixture.pre-step-rejection", version: "1") { context in
                try await context.intercept(CordisAgentLoopCheckpoints.preStep) { _, _ in
                    throw AgentLifecycleFixtureError.preStepRejected
                }
            }
        )
        let runtime = AgentRuntime(
            client: ScriptedModelClient(script: ModelScript(turns: [[.text("unreached"), .finish(.stop)]])),
            registry: LocalToolRegistry(tools: []),
            plugins: plugins,
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in try await events.append(draft) }
        )
        do {
            try await run(runtime)
            throw AgentLifecycleFixtureError.expectedFailure("pre-step rejection")
        } catch AgentLifecycleFixtureError.preStepRejected {
            return await events.events
        }
    }

    private static func requestFailureRetry() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let script = LifecycleRetryScript()
        let runtime = runtime(client: LifecycleRetryClient(script: script), sessionEvents: events)
        var configuration = AgentConfiguration()
        configuration.retryPolicy = ProviderRetryPolicyConfiguration(
            mode: .normal,
            maxRetries: 1,
            backoff: .init(initialDelayMs: 1, maxDelayMs: 1, jitterRatio: 0)
        )
        try await run(runtime, configuration: configuration)
        return await events.events
    }

    private static func cancellation() async throws -> [SessionEvent] {
        let events = SessionEventRecorder()
        let gate = SilentStreamGate()
        let runtime = runtime(
            client: PrefixThenHangModelClient(events: [.text("visible prefix")], gate: gate),
            sessionEvents: events
        )
        let task = Task { try await run(runtime) }
        await gate.waitUntilSubscribed()
        try await eventually {
            await events.events.contains { $0.type == SessionEventVocabulary.assistantChunk }
        }
        task.cancel()
        await gate.finish()
        do {
            try await task.value
            throw AgentLifecycleFixtureError.expectedFailure("cancellation")
        } catch is CancellationError {
            return await events.events
        }
    }

    private static func runtime(
        client: any LLMStreamingClient,
        tools: [any LocalAgentTool] = [],
        eventHandler: @escaping AgentRuntime.EventHandler = { _ in },
        queuedInputProvider: AgentRuntime.QueuedInputProvider? = nil,
        sessionEvents: SessionEventRecorder
    ) -> AgentRuntime {
        AgentRuntime(
            client: client,
            registry: LocalToolRegistry(tools: tools),
            approvalHandler: { _ in true },
            eventHandler: eventHandler,
            queuedInputProvider: queuedInputProvider,
            sessionEventHandler: { draft in try await sessionEvents.append(draft) }
        )
    }

    private static func run(
        _ runtime: AgentRuntime,
        configuration: AgentConfiguration = AgentConfiguration()
    ) async throws {
        try await runtime.run(
            history: [.user("lifecycle fixture")],
            configuration: configuration,
            apiKey: "test-only"
        )
    }

    private static func noRetryConfiguration() -> AgentConfiguration {
        var configuration = AgentConfiguration()
        configuration.retryPolicy = ProviderRetryPolicyConfiguration(mode: .normal, maxRetries: 0)
        return configuration
    }
}

private enum AgentLifecycleFixtureError: LocalizedError {
    case unknownScenario(String)
    case expectedFailure(String)
    case preStepRejected

    var errorDescription: String? {
        switch self {
        case let .unknownScenario(id): return "Unknown lifecycle fixture scenario \(id)"
        case let .expectedFailure(name): return "Expected lifecycle fixture failure: \(name)"
        case .preStepRejected: return "fixture pre-step rejected"
        }
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

private actor PreStepInjectionScript {
    private var invocation = 0
    private(set) var sawBaselineBeforeSecond = false

    func next(visibleMessages: [AgentMessage]) -> [AgentRuntimeInstructionInjection] {
        invocation += 1
        let text: String
        let action: WorkspaceInstructionTransitionAction
        switch invocation {
        case 1:
            text = "workspace baseline"
            action = .set
        case 2:
            sawBaselineBeforeSecond = visibleMessages.contains {
                $0.content == "workspace baseline"
            }
            text = "workspace update"
            action = .replace
        default:
            return []
        }
        let source = WorkspaceInstructionMessageSource(
            baseline: invocation == 1,
            baselineIdentity: invocation == 1 ? "fixture" : nil,
            changes: [
                WorkspaceInstructionChange(
                    action: action,
                    scope: ".\u{0}AGENTS.md",
                    path: "AGENTS.md",
                    digest: String(invocation)
                )
            ]
        )
        return [AgentRuntimeInstructionInjection(content: text, source: source.jsonValue)]
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

private actor LifecycleRetryScript {
    private var invocation = 0

    func next() -> Int {
        invocation += 1
        return invocation
    }
}

private struct LifecycleRetryClient: LLMStreamingClient {
    let script: LifecycleRetryScript

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await script.next() == 1 {
                    continuation.finish(
                        throwing: ModelClientError.httpFailure(
                            ModelProviderHTTPFailureMetadata(
                                status: 429,
                                code: "rate_limit",
                                retryAfterMilliseconds: nil,
                                requestID: "lifecycle-retry"
                            ),
                            "fixture rate limited"
                        )
                    )
                    return
                }
                continuation.yield(.text("retried response"))
                continuation.yield(.finish(.stop))
                continuation.finish()
            }
        }
    }
}

private actor FallbackCompactionRequestRecorder {
    private(set) var requests: [ModelRequest] = []

    func append(_ request: ModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

private struct FallbackCompactionClient: LLMStreamingClient {
    let recorder: FallbackCompactionRequestRecorder

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let invocation = await recorder.append(request)
                if invocation == 1 {
                    continuation.finish(
                        throwing: ModelClientError.httpFailure(
                            ModelProviderHTTPFailureMetadata(
                                status: 400,
                                code: "context_length_exceeded",
                                retryAfterMilliseconds: nil,
                                requestID: nil
                            ),
                            "context_length_exceeded"
                        )
                    )
                    return
                }

                continuation.yield(
                    .text(String(repeating: "summary ", count: 2_000))
                )
                continuation.yield(.finish(.stop))
                continuation.finish()
            }
        }
    }
}

private actor CompactionRuntimeContextScript {
    private(set) var requests: [ModelRequest] = []

    func next(_ request: ModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

private actor CompactionRouteTraceRecorder {
    private(set) var drafts: [HarnessTraceDraft] = []

    func append(_ draft: HarnessTraceDraft) {
        drafts.append(draft)
    }
}

private actor CompactionRouteScript {
    enum Mode: Sendable, Equatable { case failBeforeOutput, failAfterPartialOutput }

    let mode: Mode
    private(set) var requests: [ModelRequest] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func next(_ request: ModelRequest) -> (Int, Mode) {
        requests.append(request)
        return (requests.count, mode)
    }
}

private struct CompactionRouteClient: LLMStreamingClient {
    let script: CompactionRouteScript

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let (invocation, mode) = await script.next(request)
                switch invocation {
                case 1:
                    continuation.finish(
                        throwing: ModelClientError.httpFailure(
                            ModelProviderHTTPFailureMetadata(
                                status: 400,
                                code: "context_length_exceeded",
                                retryAfterMilliseconds: nil,
                                requestID: nil
                            ),
                            "context_length_exceeded"
                        )
                    )
                case 2:
                    if mode == .failAfterPartialOutput {
                        continuation.yield(.text("partial checkpoint"))
                    }
                    continuation.finish(
                        throwing: ModelClientError.httpFailure(
                            ModelProviderHTTPFailureMetadata(
                                status: 503,
                                code: "summary_unavailable",
                                retryAfterMilliseconds: nil,
                                requestID: "summary-route"
                            ),
                            "summary unavailable"
                        )
                    )
                case 3:
                    continuation.yield(.text("checkpoint: retain the active task"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                default:
                    continuation.yield(.text("done"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
        }
    }
}

private struct CompactionRuntimeContextClient: LLMStreamingClient {
    let script: CompactionRuntimeContextScript

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let invocation = await script.next(request)
                switch invocation {
                case 1:
                    continuation.finish(
                        throwing: ModelClientError.httpFailure(
                            ModelProviderHTTPFailureMetadata(
                                status: 400,
                                code: "context_length_exceeded",
                                retryAfterMilliseconds: nil,
                                requestID: nil
                            ),
                            "context_length_exceeded"
                        )
                    )
                case 2:
                    continuation.yield(.text("checkpoint: preserve the active task"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                case 3:
                    continuation.yield(
                        .toolCallDelta(
                            index: 0,
                            id: "runtime-context-call",
                            type: "function",
                            name: "echo",
                            arguments: "{\"value\":\"step\"}"
                        )
                    )
                    continuation.yield(.finish(.toolCalls))
                    continuation.finish()
                default:
                    continuation.yield(.text("done"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
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

private struct PrefixThenHangModelClient: LLMStreamingClient {
    let events: [LLMStreamEvent]
    let gate: SilentStreamGate

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                }
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

private struct FinalizingEchoTool: LocalAgentTool {
    let counter: FinalizerCounter
    let shouldThrow: Bool
    let definition = ModelToolDefinition(
        name: "finalizing",
        description: "Test definition finalizer.",
        parameters: .object(["type": .string("object")])
    )
    let risk: ToolRisk = .pure

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys([])
    }

    func summary(arguments: [String: JSONValue]) -> String { "finalizing" }

    func execute(arguments: [String: JSONValue]) async throws -> String { "raw" }

    func finalizeContent(
        execution: CordisToolExecution?,
        result: CordisToolExecutionResult
    ) throws -> String? {
        counter.increment()
        if shouldThrow { throw FinalizerError() }
        return result.isError ? "presented-error" : "presented"
    }

    private struct FinalizerError: Error {}
}

private final class FinalizerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func increment() {
        lock.lock(); storage += 1; lock.unlock()
    }
}

private struct TestRunCodeBridgeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "run_code",
        description: "Test Code Mode bridge.",
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

    func summary(arguments: [String: JSONValue]) -> String { "test run_code" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let context = CodeModeExecutionScope.context else {
            throw LocalToolError.pluginFailed("missing Code Mode context")
        }
        let result = await context.dispatch(
            CodeModeChildDispatchRequest(
                callID: "code-child-1",
                name: "failing_child",
                arguments: [:]
            )
        )
        return JSONValue.object([
            "error": result.error.map(JSONValue.string) ?? .null
        ]).displayText
    }
}

private struct FailingCodeChildTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "failing_child",
        description: "Fail inside a Code Mode child dispatch.",
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

    func summary(arguments: [String: JSONValue]) -> String { "failing child" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        throw LocalToolError.pluginFailed("nested failure")
    }
}

private struct CheckpointingRunCodeBridgeTool: LocalAgentTool {
    let definition = ModelToolDefinition(
        name: "run_code",
        description: "Test Code Mode checkpoint ordering.",
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

    func summary(arguments: [String: JSONValue]) -> String { "test run_code" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        guard let context = CodeModeExecutionScope.context else {
            throw LocalToolError.pluginFailed("missing Code Mode context")
        }
        let result = await context.dispatch(
            CodeModeChildDispatchRequest(
                callID: "checkpoint-child-1",
                name: "checkpoint_child",
                arguments: [:]
            )
        )
        return JSONValue.object([
            "error": result.error.map(JSONValue.string) ?? .null
        ]).displayText
    }
}

private struct CheckpointingCodeChildTool: LocalAgentTool {
    let counter: ToolCounter
    let definition = ModelToolDefinition(
        name: "checkpoint_child",
        description: "Count a Code Mode child dispatch.",
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

    func summary(arguments: [String: JSONValue]) -> String { "checkpoint child" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        await counter.increment()
        return "child ran"
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

private struct ApprovalCountingTool: LocalAgentTool {
    let counter: ToolCounter
    let definition = ModelToolDefinition(
        name: "approval_counting",
        description: "Test approval audit ordering.",
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

    func summary(arguments: [String: JSONValue]) -> String { "approval counting" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        await counter.increment()
        return try arguments.requiredString("value", maximumUTF8Bytes: 128)
    }
}

private enum ApprovalAuditTestError: Error {
    case persistenceFailed
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

private struct ReadImageEnvelopeTool: LocalAgentTool {
    let attachment: AgentImageAttachmentRef
    let definition = ModelToolDefinition(
        name: "read_image",
        description: "Return a test image attachment envelope.",
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

    func summary(arguments: [String: JSONValue]) -> String { "read image" }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        return WorkspaceReadImageToolValue(
            path: "/workspace/screenshot.jpg",
            attachment: attachment,
            width: 1,
            height: 1,
            originalWidth: 1,
            originalHeight: 1
        ).jsonValue.displayText
    }
}

private actor TestImageAttachmentProvider {
    let expected: AgentImageAttachmentRef
    let data: Data

    init(expected: AgentImageAttachmentRef, data: Data) {
        self.expected = expected
        self.data = data
    }

    func resolve(_ refs: [AgentImageAttachmentRef]) throws -> [ModelImagePayload] {
        guard refs == [expected] else { throw AgentRuntimeError.imageAttachmentUnavailable }
        return [ModelImagePayload(id: expected.id, mimeType: expected.mimeType, data: data)]
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

private struct ReclassifyingGateTool: LocalAgentTool {
    let gate: ParallelToolGate
    let mode: ReclassifyingModeProbe
    let definition = ModelToolDefinition(
        name: "reclassifying_gate",
        description: "A scheduler reclassification test tool.",
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
        "reclassifying \(arguments["id"]?.stringValue ?? "unknown")"
    }

    func isConcurrencySafe(arguments _: [String: JSONValue]) throws -> Bool {
        mode.nextIsParallel()
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        [try arguments.requiredString("resource", maximumUTF8Bytes: 128)]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
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

private final class ReclassifyingModeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let parallelChecks: Int
    private var values: [Bool] = []

    init(parallelChecks: Int) {
        self.parallelChecks = parallelChecks
    }

    var checks: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func nextIsParallel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let result = values.count < parallelChecks
        values.append(result)
        return result
    }
}

private struct ToolSchedulerFixture: Decodable {
    let schemaVersion: Int
    let source: Source
    let scenarios: [Scenario]

    struct Source: Decodable {
        let project: String
        let commit: String
        let lockPath: String
    }

    struct Scenario: Decodable {
        let id: String
        let expected: Expected
    }

    struct Expected: Decodable {
        let modeChecks: [Bool]
        let startedIDs: [String]
        let maximumConcurrent: Int
        let resultIDs: [String]
        let resultErrorCodes: [String]
    }

    static func load() throws -> Self {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root
            .appendingPathComponent("CompatibilityFixtures/deepseek/tool-scheduler-v1.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

private struct ToolSchedulerScenarioResult {
    let modeChecks: [Bool]
    let startedIDs: [String]
    let maximumConcurrent: Int
    let resultIDs: [String]
    let resultErrorCodes: [String]
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

private actor CheckpointRecorder {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

private actor FailingCheckpoint {
    private let failOnInvocation: Int
    private var invocation = 0

    init(failOnInvocation: Int) {
        self.failOnInvocation = failOnInvocation
    }

    func hit() throws {
        invocation += 1
        if invocation == failOnInvocation {
            throw FailingCheckpointError.injectedFailure
        }
    }
}

private enum FailingCheckpointError: LocalizedError {
    case injectedFailure

    var errorDescription: String? {
        "injected checkpoint persistence failure"
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

    func claim(messageID: UUID) -> Bool {
        guard let index = inputs.firstIndex(where: { $0.id == messageID }) else {
            return false
        }
        inputs.remove(at: index)
        return true
    }
}

private actor InboxCheckpointRecorder {
    private var storage: [CordisAgentInboxPreClaimContext] = []

    var values: [CordisAgentInboxPreClaimContext] { storage }

    func append(_ value: CordisAgentInboxPreClaimContext) {
        storage.append(value)
    }
}

private enum InboxLifecycleEventKind: Equatable, Sendable {
    case claimed
    case discarded
}

private struct InboxLifecycleEventRecord: Equatable, Sendable {
    let kind: InboxLifecycleEventKind
    let agentID: UUID
    let runID: UUID
    let messageID: UUID
    let text: String
    let source: String
    let boundary: QueuedInputBoundary
    let reason: String?
}

private enum TestInboxLifecycleError: Error {
    case injected
}

private actor InboxLifecycleEventRecorder {
    private(set) var events: [InboxLifecycleEventRecord] = []

    var count: Int { events.count }

    func recordClaimed(_ input: CordisAgentInboxClaimedContext) {
        events.append(
            InboxLifecycleEventRecord(
                kind: .claimed,
                agentID: input.agentID,
                runID: input.runID,
                messageID: input.message.id,
                text: input.message.text,
                source: input.source,
                boundary: input.boundary,
                reason: nil
            )
        )
    }

    func recordDiscarded(_ input: CordisAgentInboxDiscardedContext) {
        events.append(
            InboxLifecycleEventRecord(
                kind: .discarded,
                agentID: input.agentID,
                runID: input.runID,
                messageID: input.message.id,
                text: input.message.text,
                source: input.source,
                boundary: input.boundary,
                reason: input.reason
            )
        )
    }
}
