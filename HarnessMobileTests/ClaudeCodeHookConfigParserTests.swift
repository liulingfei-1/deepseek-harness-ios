import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the Claude Code hooks config parser: settings/bare-map duality,
/// malformed-entry tolerance, non-command skipping, matcher discipline, and
/// variable substitution.
final class ClaudeCodeHookConfigParserTests: XCTestCase {
    private func json(_ text: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testAcceptsSettingsFileAndBareEventMap() throws {
        let bare = json(#"""
        {"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}
        """#)
        let settings = json(#"""
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo hi"}]}]}}
        """#)
        let fromBare = try ClaudeCodeHookConfigParser.parse(raw: bare)
        let fromSettings = try ClaudeCodeHookConfigParser.parse(raw: settings)
        XCTAssertEqual(fromBare.config, fromSettings.config)
        XCTAssertEqual(fromBare.config[.preToolUse]?.first?.hooks.first?.command, "echo hi")
    }

    func testMalformedEntriesAreIgnoredAndNonCommandsAreSkipped() throws {
        let raw = json(#"""
        {"PreToolUse":[
            {"matcher":"Bash","hooks":[
                {"type":"prompt","prompt":"skip me"},
                {"type":"agent","agent":"skip me too"},
                {"type":"command"},
                {"type":"command","command":"keep 1"},
                {"not":"even a hook"},
                {"type":"command","command":"keep 2"}
            ]}
        ]}
        """#)
        let parsed = try ClaudeCodeHookConfigParser.parse(raw: raw)
        XCTAssertEqual(parsed.config[.preToolUse]?.first?.hooks.map(\.command), ["keep 1", "keep 2"])
        XCTAssertEqual(parsed.skipped.map(\.type), ["prompt", "agent"])
    }

    func testMatcherlessEventsDiscardMatcherAndSubstitutionsApply() throws {
        let raw = json(#"""
        {"Stop":[{"matcher":"should-discard","hooks":[{"type":"command","command":"${CLAUDE_PROJECT_DIR}/run.sh"}]}],
         "UserPromptSubmit":[{"matcher":"also-discard","hooks":[{"type":"command","command":"echo ${CLAUDE_PLUGIN_ROOT}"}]}]}
        """#)
        let parsed = try ClaudeCodeHookConfigParser.parse(
            raw: raw,
            vars: .init(pluginRoot: "/plugins", projectDir: "/work")
        )
        XCTAssertNil(parsed.config[.stop]?.first?.matcher)
        XCTAssertEqual(parsed.config[.stop]?.first?.hooks.first?.command, "/work/run.sh")
        XCTAssertNil(parsed.config[.userPromptSubmit]?.first?.matcher)
        XCTAssertEqual(parsed.config[.userPromptSubmit]?.first?.hooks.first?.command, "echo /plugins")
    }

    func testInvalidRegexMatcherRejectsWholeConfig() throws {
        let raw = json(#"""
        {"PreToolUse":[{"matcher":"([unclosed","hooks":[{"type":"command","command":"x"}]}]}
        """#)
        XCTAssertThrowsError(try ClaudeCodeHookConfigParser.parse(raw: raw)) {
            guard case let ClaudeCodeConfigError.invalidMatcher(matcher, event) = $0 else {
                return XCTFail("expected invalidMatcher")
            }
            XCTAssertEqual(matcher, "([unclosed")
            XCTAssertEqual(event, "PreToolUse")
        }
    }
}
