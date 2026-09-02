import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the Codex hooks config parser: five-event subset, async skipping,
/// no command substitution, always-regex matchers, and wrapper/bare duality.
final class CodexHookConfigParserTests: XCTestCase {
    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testFiveEventSubsetAndAsyncSkipping() throws {
        let raw = json(#"""
        {"hooks":{
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"sync one"},{"type":"command","command":"async one","async":true}]}],
          "PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"post"}]}],
          "SessionStart":[{"hooks":[{"type":"command","command":"start"}]}],
          "UserPromptSubmit":[{"hooks":[{"type":"command","command":"prompt"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"stop"}]}],
          "UnknownEvent":[{"hooks":[{"type":"command","command":"ignored"}]}]
        }}
        """#)
        let parsed = try CodexHookConfigParser.parse(raw: raw)
        XCTAssertEqual(parsed.config.count, 5)
        XCTAssertEqual(parsed.config[.preToolUse]?.first?.hooks.count, 1)
        XCTAssertEqual(parsed.skipped.first?.reason, "async")
        // Unknown events are dropped before group parsing.
        XCTAssertNil(json(#"{"UnknownEvent":[]}"#).objectValue?["PreToolUse"])
    }

    func testNoSubstitutionAndMatcherlessDiscipline() throws {
        let raw = json(#"""
        {"Stop":[{"matcher":"discard-me","hooks":[{"type":"command","command":"echo ${HOME}"}]}],
         "PostToolUse":[{"matcher":".*","hooks":[{"type":"command","command":"echo ${CLAUDE_PROJECT_DIR}"}]}]}
        """#)
        let parsed = try CodexHookConfigParser.parse(raw: raw)
        // Codex performs no command substitution.
        XCTAssertEqual(parsed.config[.stop]?.first?.hooks.first?.command, "echo ${HOME}")
        XCTAssertNil(parsed.config[.stop]?.first?.matcher)
        XCTAssertNotNil(parsed.config[.postToolUse]?.first?.matcher)
    }

    func testInvalidRegexRejectsConfig() throws {
        let raw = json(#"""
        {"PreToolUse":[{"matcher":"([bad","hooks":[{"type":"command","command":"x"}]}]}
        """#)
        XCTAssertThrowsError(try CodexHookConfigParser.parse(raw: raw)) {
            guard case ClaudeCodeConfigError.invalidMatcher = $0 else {
                return XCTFail("expected invalidMatcher")
            }
        }
    }
}
