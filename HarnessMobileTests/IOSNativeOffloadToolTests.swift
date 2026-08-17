import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class IOSNativeOffloadToolTests: XCTestCase {
    func testNormalizesGuestPOSIXWaitStatus() {
        XCTAssertEqual(ISHExitStatus.normalized(0), 0)
        XCTAssertEqual(ISHExitStatus.normalized(256), 1)
        XCTAssertEqual(ISHExitStatus.normalized(512), 2)
    }

    func testAllowlistCoversOpenMinisMobileCapabilityFamilies() throws {
        let required: Set<String> = [
            "apple-bluetooth",
            "apple-calendar",
            "apple-clipboard",
            "apple-device",
            "apple-healthkit",
            "apple-homekit",
            "apple-location",
            "apple-nfc",
            "apple-open",
            "apple-photos",
            "apple-reminders",
            "apple-speech",
            "apple-vision",
        ]
        XCTAssertTrue(required.isSubset(of: IOSNativeOffloadTool.allowedCommands))

        let tool = IOSNativeOffloadTool(
            store: WorkspaceStore(),
            sessionID: "test"
        )
        XCTAssertNoThrow(try tool.validate(arguments: [
            "command": .string("apple-calendar"),
            "arguments": .array([.string("list"), .string("--today")]),
            "timeout_seconds": .number(30),
        ]))
        XCTAssertEqual(
            try tool.approvalResources(arguments: [
                "command": .string("apple-calendar"),
            ]),
            ["ios-native:apple-calendar"]
        )
    }

    func testRejectsArbitraryShellCommandsAndMalformedArgumentVectors() throws {
        let tool = IOSNativeOffloadTool(
            store: WorkspaceStore(),
            sessionID: "test"
        )
        let invalid: [[String: JSONValue]] = [
            ["command": .string("sh")],
            ["command": .string("apple-calendar; id")],
            ["command": .string("apple-device"), "arguments": .string("info")],
            ["command": .string("apple-device"), "arguments": .array([.number(1)])],
            ["command": .string("apple-device"), "timeout_seconds": .number(0)],
            ["command": .string("apple-device"), "timeout_seconds": .number(1.5)],
            ["command": .string("apple-device"), "unexpected": .bool(true)],
        ]

        for arguments in invalid {
            XCTAssertThrowsError(try tool.validate(arguments: arguments))
        }
    }

    func testPermanentApprovalScopeIsPerNativeCapability() throws {
        let tool = IOSNativeOffloadTool(
            store: WorkspaceStore(),
            sessionID: "test"
        )
        let calendar = try tool.approvalResources(arguments: [
            "command": .string("apple-calendar"),
            "arguments": .array([.string("list")]),
        ])
        let contactsAdjacent = try tool.approvalResources(arguments: [
            "command": .string("apple-reminders"),
            "arguments": .array([.string("list")]),
        ])

        XCTAssertNotEqual(calendar, contactsAdjacent)
    }

    func testOpenBridgeLeavesEveryURLSchemeToUIApplication() throws {
        let tool = IOSNativeOffloadTool(store: WorkspaceStore(), sessionID: "test")
        for target in [
            "tel:10086",
            "sms:10086?body=hello",
            "mailto:user@example.com",
            "my-app://handoff/task",
            "settings://wifi",
            "https://example.com/path",
            "javascript:alert(1)",
            "file:///private/secret",
            "data:text/plain,secret"
        ] {
            XCTAssertNoThrow(try tool.validate(arguments: [
                "command": .string("apple-open"),
                "arguments": .array([.string(target)])
            ]), "target should be accepted: \(target)")
        }
        for target in ["", "  ", "bad\u{0}url"] {
            XCTAssertThrowsError(try tool.validate(arguments: [
                "command": .string("apple-open"),
                "arguments": .array([.string(target)])
            ]), "target should be rejected: \(target)")
        }
        XCTAssertEqual(
            try tool.approvalResources(arguments: [
                "command": .string("apple-open"),
                "arguments": .array([.string("tel:10086")])
            ]),
            ["ios-native:apple-open"]
        )
    }
}
