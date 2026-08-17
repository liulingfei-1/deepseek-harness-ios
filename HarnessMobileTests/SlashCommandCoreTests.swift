import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SlashCommandCoreTests: XCTestCase {
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
        XCTAssertEqual(names, ["agent", "clear", "compact", "help", "model", "new", "plan", "status"])
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

        let newSession = try await executed(registry, "/new  My session  ")
        XCTAssertEqual(newSession.result.action, .newSession(title: "My session"))

        let help = try await executed(registry, "/help model")
        XCTAssertEqual(help.result.action, .help(query: "model"))

        let clear = try await executed(registry, "/clear")
        XCTAssertEqual(clear.result.action, .clear)
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
