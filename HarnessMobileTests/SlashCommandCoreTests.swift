import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SlashCommandCoreTests: XCTestCase {
    func testInputTriggerDetectorMatchesUpstreamBoundariesAndGuardTiers() {
        XCTAssertEqual(
            InputTriggerDetector.detect("/go"),
            InputTriggerHit(
                trigger: .slash,
                query: "go",
                position: .leading,
                span: InputTriggerSpan(start: 0, end: 3, draftRevision: 0)
            )
        )
        XCTAssertEqual(
            InputTriggerDetector.detect("第一行\n@worker"),
            InputTriggerHit(
                trigger: .at,
                query: "worker",
                position: .inline,
                span: InputTriggerSpan(start: 4, end: 11, draftRevision: 0)
            )
        )
        XCTAssertNil(InputTriggerDetector.detect("user@host"))
        XCTAssertNil(InputTriggerDetector.detect("https://example.com"))
        XCTAssertNil(InputTriggerDetector.detect("/goal x"))
        XCTAssertNil(InputTriggerDetector.detect("/goal", guardTier: .claimed))
        XCTAssertNotNil(InputTriggerDetector.detect("/goal @worker", guardTier: .claimed))
        XCTAssertNil(InputTriggerDetector.detect("@worker", guardTier: .frozen))
    }

    func testInputTriggerDetectorUsesNearestTokenAndRevisionGuardedReplacement() {
        let draft = "先处理 /goal @worker"
        let hit = InputTriggerDetector.detect(
            draft,
            draftRevision: 7
        )
        XCTAssertEqual(hit?.trigger, .at)
        XCTAssertEqual(hit?.query, "worker")
        XCTAssertEqual(
            hit.flatMap {
                InputTriggerDetector.replacing(
                    draft,
                    span: $0.span,
                    with: "@researcher ",
                    currentRevision: 7
                )
            },
            "先处理 /goal @researcher "
        )
        XCTAssertNil(
            hit.flatMap {
                InputTriggerDetector.replacing(
                    draft,
                    span: $0.span,
                    with: "@stale ",
                    currentRevision: 8
                )
            }
        )
    }

    func testQuotedFileTriggerTracksWhitespaceUnicodeAndDraftRevision() throws {
        let draft = "前文已编辑 @\"Docs/deep re"
        let hit = try XCTUnwrap(
            InputTriggerDetector.detect(
                draft,
                guardTier: .claimed,
                draftRevision: 12
            )
        )
        XCTAssertEqual(hit.trigger, .at)
        XCTAssertEqual(hit.query, "Docs/deep re")
        XCTAssertTrue(hit.quoted)
        XCTAssertEqual(hit.span.start, Array("前文已编辑 ").count)
        XCTAssertEqual(hit.span.end, Array(draft).count)
        XCTAssertEqual(
            InputTriggerDetector.replacing(
                draft,
                span: hit.span,
                with: "@\"Docs/deep report.md\" ",
                currentRevision: 12
            ),
            "前文已编辑 @\"Docs/deep report.md\" "
        )
        XCTAssertNil(
            InputTriggerDetector.replacing(
                "新前缀" + draft,
                span: hit.span,
                with: "@\"Docs/deep report.md\" ",
                currentRevision: 13
            )
        )
        XCTAssertNil(InputTriggerDetector.detect("@\"Docs/closed path.md\""))

        let legacy = Data(
            """
            {"trigger":"@","query":"file","position":"leading","span":{"start":0,"end":5,"draftRevision":1}}
            """.utf8
        )
        XCTAssertFalse(try JSONDecoder().decode(InputTriggerHit.self, from: legacy).quoted)
    }

    func testAddressedSubagentInputRequiresDurableUUIDAndMessage() {
        let address = "A24CBBD8-D577-4A9F-AEFC-26FC9C9AFEA4"
        XCTAssertEqual(
            AddressedSubagentInputParser.parse("@\(address) 继续检查缓存"),
            AddressedSubagentInput(
                address: address.lowercased(),
                message: "继续检查缓存"
            )
        )
        XCTAssertNil(AddressedSubagentInputParser.parse("@worker 继续"))
        XCTAssertNil(AddressedSubagentInputParser.parse("@\(address)"))
        XCTAssertNil(AddressedSubagentInputParser.parse("普通消息 @\(address) 继续"))
        XCTAssertNil(
            AddressedSubagentInputParser.parse(
                "@\(address) "
                    + String(repeating: "x", count: AddressedSubagentInputParser.maximumMessageUTF8Bytes + 1)
            )
        )
    }

    func testParserPreservesSeparatorWhitespaceAndMatchesUpstreamBoundary() {
        XCTAssertEqual(
            SlashCommandParser.parse("/plan\t  review"),
            ParsedSlashCommand(name: "plan", rawInput: "\t  review")
        )
        XCTAssertEqual(
            SlashCommandParser.parse("/model_name-2"),
            ParsedSlashCommand(name: "model_name-2", rawInput: "")
        )
        XCTAssertEqual(parseCommand("/help"), ParsedSlashCommand(name: "help", rawInput: ""))
        XCTAssertNil(SlashCommandParser.parse(" /help"))
        XCTAssertNil(SlashCommandParser.parse("/Help"))
        XCTAssertNil(SlashCommandParser.parse("/help/path"))
        XCTAssertNil(SlashCommandParser.parse("/help🔥"))
    }

    func testParserDistinguishesPlainTextAndMalformedSlashInput() {
        XCTAssertEqual(SlashCommandParser.parseDetailed("hello"), .notACommand)
        XCTAssertEqual(SlashCommandParser.parseDetailed("/"), .invalid(.missingName))
        XCTAssertEqual(SlashCommandParser.parseDetailed("/1"), .invalid(.invalidNameStart))
        XCTAssertEqual(SlashCommandParser.parseDetailed("/help!"), .invalid(.invalidNameBoundary))
        XCTAssertEqual(
            SlashCommandParser.parseDetailed(String(repeating: "x", count: SlashCommandParser.maximumLineBytes + 1)),
            .notACommand
        )
        XCTAssertEqual(
            SlashCommandParser.parseDetailed("/help" + String(repeating: "x", count: SlashCommandParser.maximumLineBytes)),
            .invalid(.lineTooLong)
        )
    }

    func testBuiltInDirectoryContainsTheDesktopCoreCommands() async {
        let registry = SlashCommandRegistry(instanceToken: "tests")
        let names = await registry.list().map(\.name)
        XCTAssertEqual(names, ["agent", "clear", "compact", "feedback", "goal", "help", "model", "new", "plan", "status"])
    }

    func testFeedbackCommandProducesTypedOperationsAndStableMessageTarget() async throws {
        let registry = SlashCommandRegistry(instanceToken: "feedback")
        guard case let .prepared(like) = await registry.prepare("/feedback like") else {
            return XCTFail("expected /feedback like to prepare")
        }
        let likeExecution = await registry.execute(like)
        guard case let .feedback(messageID: nil, operation: .setRating(.positive))? = likeExecution.result.action else {
            return XCTFail("expected positive feedback action")
        }

        let messageID = try XCTUnwrap(UUID(uuidString: "A24CBBD8-D577-4A9F-AEFC-26FC9C9AFEA4"))
        guard case let .prepared(note) = await registry.prepare(
            "/feedback \(messageID.uuidString) note 需要补充回归测试"
        ) else {
            return XCTFail("expected /feedback note to prepare")
        }
        let noteExecution = await registry.execute(note)
        guard case let .feedback(messageID: parsedID, operation: .note(text))? = noteExecution.result.action else {
            return XCTFail("expected note feedback action")
        }
        XCTAssertEqual(parsedID, messageID)
        XCTAssertEqual(text, "需要补充回归测试")
    }

    func testFeedbackCommandRejectsUnknownOperationAndOversizedNote() async {
        let registry = SlashCommandRegistry(instanceToken: "feedback-errors")
        guard case let .prepared(unknown) = await registry.prepare("/feedback shrug") else {
            return XCTFail("expected command to prepare before handler validation")
        }
        let unknownExecution = await registry.execute(unknown)
        XCTAssertEqual(unknownExecution.result.errorCode, .invalidArguments)

        guard case let .prepared(oversized) = await registry.prepare(
            "/feedback note " + String(repeating: "x", count: MessageFeedback.maximumNoteUTF8Bytes + 1)
        ) else {
            return XCTFail("expected oversized command to prepare")
        }
        let oversizedExecution = await registry.execute(oversized)
        XCTAssertEqual(oversizedExecution.result.errorCode, .invalidArguments)
    }

    func testBuiltInImagePolicyExplicitlyAdmitsGoalAndPlanOnly() async {
        let registry = SlashCommandRegistry(instanceToken: "image-policy")
        let commands = await registry.list()
        XCTAssertEqual(commands.first(where: { $0.name == "goal" })?.imagePolicy, .accepted)
        XCTAssertEqual(commands.first(where: { $0.name == "plan" })?.imagePolicy, .accepted)
        XCTAssertEqual(commands.first(where: { $0.name == "status" })?.imagePolicy, .rejected)

        let legacyJSON = Data("{\"name\":\"legacy\",\"description\":\"legacy command\"}".utf8)
        let decoded = try? JSONDecoder().decode(
            SlashCommandDescriptor.self,
            from: legacyJSON
        )
        XCTAssertEqual(decoded?.imagePolicy, .rejected)

        let acceptedJSON = try? JSONEncoder().encode(commands.first { $0.name == "goal" })
        let acceptedDecoded = acceptedJSON.flatMap {
            try? JSONDecoder().decode(SlashCommandDescriptor.self, from: $0)
        }
        XCTAssertEqual(acceptedDecoded?.imagePolicy, .accepted)
    }

    func testImagePolicyIsEnforcedByRegistryAndAttachmentsReachAcceptedHandlers() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "image-execution")
        let rejected = try SlashCommandDefinition(
            name: "plain",
            description: "plain command"
        ) { _ in
            return .failure(.handlerFailed, text: "handler unexpectedly invoked")
        }
        let accepted = try SlashCommandDefinition(
            name: "vision",
            description: "vision command",
            imagePolicy: .accepted
        ) { invocation in
            .success(text: "attachments=\(invocation.imageAttachments.count)")
        }
        _ = try await registry.register(rejected)
        _ = try await registry.register(accepted)
        let attachment = AgentImageAttachmentRef(
            path: "Attachments/test.jpg",
            mimeType: "image/jpeg",
            byteCount: 12
        )

        guard case let .prepared(plain) = await registry.prepare("/plain") else {
            return XCTFail("expected plain command to prepare")
        }
        let rejectedExecution = await registry.execute(plain, imageAttachments: [attachment])
        XCTAssertEqual(rejectedExecution.result.errorCode, .invalidArguments)
        XCTAssertEqual(rejectedExecution.result.text, "/plain does not accept image attachments")

        guard case let .prepared(vision) = await registry.prepare("/vision") else {
            return XCTFail("expected vision command to prepare")
        }
        let acceptedExecution = await registry.execute(vision, imageAttachments: [attachment])
        XCTAssertEqual(acceptedExecution.result.text, "attachments=1")

        let builtins = SlashCommandRegistry(instanceToken: "plan-image")
        guard case let .prepared(planOff) = await builtins.prepare("/plan off") else {
            return XCTFail("expected built-in plan command to prepare")
        }
        let planOffExecution = await builtins.execute(planOff, imageAttachments: [attachment])
        XCTAssertEqual(planOffExecution.result.errorCode, .invalidArguments)
        XCTAssertEqual(planOffExecution.result.text, "Image attachments cannot accompany /plan off.")
    }

    func testUnknownAndMalformedCommandsNeverBecomeModelInput() async {
        let registry = SlashCommandRegistry(instanceToken: "tests")

        if case let .unknownCommand(parsed) = await registry.dispatch("/does-not-exist hello") {
            XCTAssertEqual(parsed.name, "does-not-exist")
            XCTAssertEqual(parsed.rawInput, " hello")
        } else {
            XCTFail("expected unknown command")
        }
        let unknownMessage = await registry.dispatch("/does-not-exist").userMessage
        XCTAssertEqual(unknownMessage, "Unknown command /does-not-exist. Use /help to list commands.")
        let ordinary = await registry.dispatch("ordinary prompt")
        XCTAssertEqual(ordinary, .notACommand)
        let uppercase = await registry.dispatch("/Bad")
        XCTAssertEqual(uppercase, .invalidSyntax(.invalidNameStart))
    }

    func testBuiltInActionsAndArgumentBoundaries() async throws {
        let registry = SlashCommandRegistry(instanceToken: "tests")

        let plan = try await executed(registry, "/plan  write tests")
        XCTAssertEqual(
            plan.result,
            .success(
                text: "Plan mode on. Use /plan off to leave.",
                action: .plan(mode: .on, message: "write tests")
            )
        )

        let off = try await executed(registry, "/plan off")
        XCTAssertEqual(off.result.action, .plan(mode: .off, message: nil))

        let model = try await executed(registry, "/model deepseek/deepseek-chat --reasoning high")
        XCTAssertEqual(
            model.result.action,
            .model(selection: try SlashModelSelection(provider: "deepseek", model: "deepseek-chat", reasoning: "high"))
        )

        let low = try await executed(registry, "/model deepseek/deepseek-chat --reasoning low")
        XCTAssertEqual(
            low.result.action,
            .model(selection: try SlashModelSelection(provider: "deepseek", model: "deepseek-chat", reasoning: "low"))
        )

        let newSession = try await executed(registry, "/new  My session  ")
        XCTAssertEqual(newSession.result.action, .newSession(title: "My session"))

        let help = try await executed(registry, "/help model")
        XCTAssertEqual(help.result.action, .help(query: "model"))

        let clear = try await executed(registry, "/clear")
        XCTAssertEqual(clear.result.action, .clear)
        let goal = try await executed(registry, "/goal  ship the vision flow  ")
        XCTAssertEqual(goal.result.action, .goal(message: "ship the vision flow"))
        let editGoal = try await executed(registry, "/goal edit ship the revised flow")
        XCTAssertEqual(
            editGoal.result.action,
            .goalCommand(operation: .edit, message: "ship the revised flow")
        )
        let pauseGoal = try await executed(registry, "/goal pause")
        XCTAssertEqual(pauseGoal.result.action, .goalCommand(operation: .pause, message: nil))
        let clearGoal = try await executed(registry, "/goal clear")
        XCTAssertEqual(clearGoal.result.action, .goalCommand(operation: .clear, message: nil))
        let compact = try await executed(registry, "/compact")
        XCTAssertEqual(compact.result.action, .compact)
        let status = try await executed(registry, "/status")
        XCTAssertEqual(status.result.action, .status)
        let picker = try await executed(registry, "/agent")
        XCTAssertEqual(picker.result.action, .agent(preset: nil))
    }

    func testNoArgumentCommandsRejectNonWhitespaceArgumentsWithStableUsage() async throws {
        let registry = SlashCommandRegistry(instanceToken: "tests")

        for line in ["/clear now", "/compact now", "/status now"] {
            let execution = try await executed(registry, line)
            XCTAssertEqual(execution.result.kind, .error)
            XCTAssertEqual(execution.result.errorCode, .invalidArguments)
            XCTAssertTrue(execution.result.text?.hasPrefix("Usage: /") == true)
        }
        let whitespace = try await executed(registry, "/compact \t  ")
        XCTAssertEqual(whitespace.result.action, .compact)
    }

    func testRegistrySupportsScopedShadowingAndRemoval() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "tests")
        let global = try SlashCommandDefinition(name: "echo", description: "global") { _ in
            .success(text: "global")
        }
        let scoped = try SlashCommandDefinition(name: "echo", description: "scoped") { _ in
            .success(text: "scoped")
        }
        let globalRegistration = try await registry.register(global)
        let scopedRegistration = try await registry.register(scoped, scope: "session-1")

        let scopedResult = try await executed(registry, "/echo", scope: "session-1")
        XCTAssertEqual(scopedResult.result.text, "scoped")
        let globalResult = try await executed(registry, "/echo", scope: "session-2")
        XCTAssertEqual(globalResult.result.text, "global")
        let removedScoped = await registry.unregister(scopedRegistration)
        XCTAssertTrue(removedScoped)
        let fallbackResult = try await executed(registry, "/echo", scope: "session-1")
        XCTAssertEqual(fallbackResult.result.text, "global")
        let removedGlobal = await registry.unregister(globalRegistration)
        XCTAssertTrue(removedGlobal)
        let afterRemoval = await registry.dispatch("/echo", scope: "session-1")
        if case .unknownCommand = afterRemoval {
            // expected
        } else {
            XCTFail("expected the final registration to be gone")
        }
    }

    func testDuplicateRegistrationFailsOnlyWithinTheSameLayer() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "tests")
        let first = try SlashCommandDefinition(name: "same", description: "first") { _ in .success() }
        let second = try SlashCommandDefinition(name: "same", description: "second") { _ in .success() }
        _ = try await registry.register(first)
        do {
            _ = try await registry.register(second)
            XCTFail("expected duplicate")
        } catch let error as SlashCommandRegistryError {
            XCTAssertEqual(error, .duplicate("same", scope: nil))
        }
        _ = try await registry.register(second, scope: "session")
    }

    func testFuzzySearchRanksPrefixesAndSeparatorBoundaries() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "tests")
        for name in ["status", "session-status", "set-model", "model"] {
            let definition = try SlashCommandDefinition(name: name, description: name) { _ in .success() }
            _ = try await registry.register(definition)
        }
        let modelMatches = await registry.search("mod").map(\.name)
        XCTAssertEqual(modelMatches, ["model", "set-model"])
        let statusMatch = await registry.search("ss").first?.name
        XCTAssertEqual(statusMatch, "session-status")
    }

    func testHandlerErrorsAndCancellationBecomeTypedResults() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "tests")
        let failing = try SlashCommandDefinition(name: "fail", description: "fails") { _ in
            throw NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "broken"])
        }
        _ = try await registry.register(failing)
        let failed = try await executed(registry, "/fail")
        XCTAssertEqual(failed.result.errorCode, .handlerFailed)
        XCTAssertEqual(failed.result.text, "broken")

        let waiting = try SlashCommandDefinition(name: "wait", description: "waits") { _ in
            try await Task.sleep(for: .seconds(10))
            return .success(text: "late")
        }
        _ = try await registry.register(waiting)
        let task = Task { await registry.dispatch("/wait") }
        task.cancel()
        guard case let .executed(execution) = await task.value else {
            return XCTFail("expected a settled execution")
        }
        XCTAssertEqual(execution.result.errorCode, .cancelled)
    }

    func testHelpTextUsesCurrentDirectoryAndInputHints() async throws {
        let registry = SlashCommandRegistry(instanceToken: "tests")
        let help = await registry.helpText(query: "model")
        XCTAssertTrue(help.contains("/model"))
        XCTAssertTrue(help.contains("provider/"))
        XCTAssertFalse(help.contains("/compact"))
    }

    func testTypedActionsAndResultsRoundTripThroughCodable() throws {
        let result = SlashCommandResult.success(
            text: "Plan mode on.",
            action: .plan(mode: .on, message: "inspect files"),
            sourceEventSequence: 12
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(SlashCommandResult.self, from: data)
        XCTAssertEqual(decoded, result)

        let selection = try SlashModelSelection(
            provider: "deepseek",
            model: "deepseek-chat",
            reasoning: "providerDefault"
        )
        let action = SlashCommandAction.model(selection: selection)
        let actionData = try JSONEncoder().encode(action)
        XCTAssertEqual(try JSONDecoder().decode(SlashCommandAction.self, from: actionData), action)
    }

    func testArgumentCompletionDetectsRanksAndDeduplicatesTypedSources() throws {
        let descriptor = try SlashCommandDescriptor(
            name: "model",
            description: "choose",
            input: SlashCommandInputDescriptor(hint: "model", completion: .model)
        )
        let match = try XCTUnwrap(
            SlashCommandCompletionDetector.detect(
                "/model deep",
                descriptor: descriptor,
                draftRevision: 4
            )
        )
        XCTAssertEqual(match.kind, .model)
        XCTAssertEqual(match.hit.query, "deep")
        XCTAssertEqual(match.hit.span, InputTriggerSpan(start: 7, end: 11, draftRevision: 4))
        XCTAssertEqual(
            SlashCommandCompletionDetector.filter(
                [
                    SlashCommandCompletionCandidate(source: .model, value: "openai/gpt", detail: "Deep fallback"),
                    SlashCommandCompletionCandidate(source: .model, value: "deepseek/chat", detail: nil),
                    SlashCommandCompletionCandidate(source: .model, value: "deepseek/chat", detail: "duplicate")
                ],
                query: "deep"
            ).map(\.value),
            ["deepseek/chat", "openai/gpt"]
        )
    }

    func testMergedOriginsHaveStablePriorityAndWithdrawalReveal() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "merge")
        func definition(_ text: String) throws -> SlashCommandDefinition {
            try SlashCommandDefinition(name: "inspect", description: text) { _ in
                .success(text: text)
            }
        }
        let native = try await registry.register(try definition("native"), origin: .native)
        let client = try await registry.register(try definition("client"), origin: .nativeClient)
        let host = try await registry.register(try definition("host"), origin: .host)

        let hostExecution = try await executed(registry, "/inspect")
        let searchResults = await registry.search("inspect")
        let didUnregisterHost = await registry.unregister(host)
        let clientExecution = try await executed(registry, "/inspect")
        let didUnregisterClient = await registry.unregister(client)
        let nativeExecution = try await executed(registry, "/inspect")
        let didUnregisterNative = await registry.unregister(native)

        XCTAssertEqual(hostExecution.result.text, "host")
        XCTAssertEqual(searchResults.map(\.name), ["inspect"])
        XCTAssertTrue(didUnregisterHost)
        XCTAssertEqual(clientExecution.result.text, "client")
        XCTAssertTrue(didUnregisterClient)
        XCTAssertEqual(nativeExecution.result.text, "native")
        XCTAssertTrue(didUnregisterNative)
    }

    func testPopupAndConfirmationResumeTheOriginalCommandIdentity() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "interaction")
        let definition = try SlashCommandDefinition(name: "choose", description: "choose") { invocation in
            switch invocation.interactionResponse {
            case nil:
                return .interaction(.popupSelect(
                    title: "Target",
                    options: [SlashCommandSelectOption(id: "one", label: "One")]
                ))
            case .selected(optionID: "one"):
                return .interaction(.confirmation(
                    SlashCommandConfirmation(
                        title: "Confirm",
                        description: "Continue",
                        acknowledgeLabel: "I understand",
                        cancelLabel: "No",
                        confirmLabel: "Yes"
                    )
                ))
            case .confirmed:
                return .success(text: "finished")
            default:
                return .failure(.invalidArguments, text: "unexpected")
            }
        }
        _ = try await registry.register(definition)
        let first = try await executed(registry, "/choose")
        XCTAssertEqual(first.result.kind, .interaction)
        let selectedOptional = await registry.resumeInteraction(
            commandID: first.commandID,
            response: .selected(optionID: "one")
        )
        let selected = try XCTUnwrap(selectedOptional)
        XCTAssertEqual(selected.commandID, first.commandID)
        XCTAssertEqual(selected.result.kind, .interaction)
        let confirmedOptional = await registry.resumeInteraction(
            commandID: first.commandID,
            response: .confirmed
        )
        let confirmed = try XCTUnwrap(confirmedOptional)
        XCTAssertEqual(confirmed.commandID, first.commandID)
        XCTAssertEqual(confirmed.result.text, "finished")

        let second = try await executed(registry, "/choose")
        let deniedOptional = await registry.resumeInteraction(
            commandID: second.commandID,
            response: .cancelled
        )
        let denied = try XCTUnwrap(deniedOptional)
        XCTAssertEqual(denied.result.errorCode, .cancelled)
        let resumedAfterCancellation = await registry.resumeInteraction(
            commandID: second.commandID,
            response: .selected(optionID: "one")
        )
        XCTAssertNil(resumedAfterCancellation)
    }

    func testImageAttachmentsSurviveInteractionResume() async throws {
        let registry = SlashCommandRegistry(includeBuiltIns: false, instanceToken: "image-interaction")
        let definition = try SlashCommandDefinition(
            name: "inspect_image",
            description: "Inspect an image",
            imagePolicy: .accepted
        ) { invocation in
            if invocation.interactionResponse == nil {
                return .interaction(.confirmation(
                    SlashCommandConfirmation(
                        title: "Confirm",
                        description: "Inspect",
                        acknowledgeLabel: "I understand",
                        cancelLabel: "No",
                        confirmLabel: "Yes"
                    )
                ))
            }
            return .success(text: "attachments=\(invocation.imageAttachments.count)")
        }
        _ = try await registry.register(definition)
        guard case let .prepared(prepared) = await registry.prepare("/inspect_image") else {
            return XCTFail("expected image command to prepare")
        }
        let attachment = AgentImageAttachmentRef(
            path: "Attachments/interaction.jpg",
            mimeType: "image/jpeg",
            byteCount: 8
        )
        let first = await registry.execute(prepared, imageAttachments: [attachment])
        XCTAssertEqual(first.result.kind, .interaction)
        let resumedOptional = await registry.resumeInteraction(
            commandID: first.commandID,
            response: .confirmed
        )
        let resumed = try XCTUnwrap(resumedOptional)
        XCTAssertEqual(resumed.result.text, "attachments=1")
    }

    private func executed(
        _ registry: SlashCommandRegistry,
        _ line: String,
        scope: String? = nil
    ) async throws -> SlashCommandExecution {
        guard case let .executed(execution) = await registry.dispatch(line, scope: scope) else {
            XCTFail("expected execution for \(line)")
            throw TestError.notExecuted
        }
        return execution
    }
}

private enum TestError: Error {
    case notExecuted
}
