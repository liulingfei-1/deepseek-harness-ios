import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the hook protocol: matcher modes, output parsing across both
/// decision channels, fail-loud exit-2 blocking, and halt handling.
final class HookProtocolTests: XCTestCase {
    func testMatcherModesSeparateLiteralFromRegex() {
        let literalGroup = HookMatcherGroup(matcher: "Bash|Edit", hooks: [])
        XCTAssertTrue(literalGroup.matches(toolName: "Bash", mode: .claudeCode))
        XCTAssertTrue(literalGroup.matches(toolName: "Edit", mode: .claudeCode))
        // In codex mode the pattern is regex, so `Bash|Edit` alternation
        // genuinely matches "Bash".
        XCTAssertTrue(literalGroup.matches(toolName: "Bash", mode: .codex))

        let regexGroup = HookMatcherGroup(matcher: "^Web.*", hooks: [])
        XCTAssertTrue(regexGroup.matches(toolName: "WebFetch", mode: .codex))
        XCTAssertTrue(regexGroup.matches(toolName: "WebFetch", mode: .claudeCode))
        XCTAssertFalse(regexGroup.matches(toolName: "Bash", mode: .claudeCode))

        XCTAssertTrue(HookMatcherGroup(matcher: nil, hooks: []).matches(toolName: "Anything", mode: .claudeCode))
        XCTAssertTrue(HookMatcherGroup(matcher: "*", hooks: []).matches(toolName: "Anything", mode: .codex))
    }

    func testParseJSONOutputWithPermissionDecision() {
        let output = HookProtocol.parseHookOutput(
            exitCode: 0,
            stdout: #"{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"sensitive read"}}"#,
            stderr: ""
        )
        XCTAssertEqual(output.decision, .ask)
        XCTAssertEqual(output.reason, "sensitive read")
        XCTAssertEqual(output.hookEventName, "PreToolUse")
        XCTAssertFalse(HookProtocol.blocks(output))
    }

    func testLegacyTopLevelDecisionOnlyAcceptsApproveAndBlock() {
        let approve = HookProtocol.parseHookOutput(
            exitCode: 0,
            stdout: #"{"decision":"approve"}"#,
            stderr: ""
        )
        XCTAssertEqual(approve.decision, .approve)
        // An out-of-band deny at top level is invalid and ignored.
        let invalidDeny = HookProtocol.parseHookOutput(
            exitCode: 0,
            stdout: #"{"decision":"deny"}"#,
            stderr: ""
        )
        XCTAssertNil(invalidDeny.decision)
    }

    func testExitTwoBlocksWithStderrAndHaltStops() {
        let blocking = HookProtocol.parseHookOutput(
            exitCode: 2,
            stdout: "",
            stderr: "  protected file; refuse  "
        )
        XCTAssertTrue(HookProtocol.blocks(blocking))
        XCTAssertEqual(HookProtocol.blockReason(blocking), "protected file; refuse")

        let halt = HookProtocol.parseHookOutput(
            exitCode: 0,
            stdout: #"{"continue":false,"stopReason":"waiting for user"}"#,
            stderr: ""
        )
        XCTAssertTrue(HookProtocol.blocks(halt))
        XCTAssertEqual(HookProtocol.blockReason(halt), "waiting for user")
    }

    func testPlainStdoutIsPreservedVerbatimAndAdditionalContextIsKept() {
        let plain = HookProtocol.parseHookOutput(exitCode: 0, stdout: "plain text", stderr: "")
        XCTAssertEqual(plain.stdout, "plain text")
        XCTAssertNil(plain.decision)

        let withContext = HookProtocol.parseHookOutput(
            exitCode: 0,
            stdout: #"{"additionalContext":"ctx for next request","systemMessage":"heads up"}"#,
            stderr: ""
        )
        XCTAssertEqual(withContext.additionalContext, "ctx for next request")
        XCTAssertEqual(withContext.systemMessage, "heads up")
    }
}
