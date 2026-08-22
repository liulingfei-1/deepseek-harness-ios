import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ConversationExportBuilderTests: XCTestCase {
    func testExportOmitsInternalRuntimeContextSnapshots() throws {
        let internalMarker = "INTERNAL_RUNTIME_CONTEXT_MARKER"
        let snapshot = AgentMessage(
            role: .user,
            content: internalMarker,
            source: .object([
                "kind": .string("plugin"),
                "plugin": .string(AgentMessage.runtimeContextPluginID),
                "form": .string("snapshot")
            ])
        )
        let input = ConversationExportInput(
            sessionID: UUID(),
            title: "Cache-safe context",
            providerID: "deepseek",
            model: "deepseek-chat",
            messages: [.user("visible question"), snapshot, .assistant("visible answer")]
        )

        for format in ConversationExportFormat.allCases {
            let data = try ConversationExportBuilder.makeData(input: input, format: format)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains(internalMarker))
            XCTAssertTrue(text.contains("visible question"))
            XCTAssertTrue(text.contains("visible answer"))
        }
    }

    func testJSONExportRedactsTokensOmitsArgumentsAndIncludesFeedback() throws {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        let call = AgentToolCall(
            id: "call-1",
            name: "shell",
            arguments: #"{"command":"echo secret"}"#
        )
        let event = AgentToolEvent(
            call: call,
            summary: "Check Authorization: Bearer \(secret)",
            status: .succeeded,
            result: "api_key=\(secret)"
        )
        let message = AgentMessage(
            role: .assistant,
            content: "Token \(secret)",
            reasoning: "Authorization: Bearer \(secret)",
            toolCalls: [call],
            toolEvents: [event],
            feedback: MessageFeedback(rating: .positive, note: "Useful \(secret)")
        )
        let data = try ConversationExportBuilder.makeData(
            input: ConversationExportInput(
                sessionID: UUID(),
                title: "Export",
                providerID: "deepseek",
                model: "deepseek-chat",
                messages: [message]
            ),
            format: .json
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains("[REDACTED]"))
        XCTAssertTrue(text.contains(#""argumentsOmitted" : true"#))
        XCTAssertFalse(text.contains(#""arguments""#))
        XCTAssertTrue(text.contains(#""rating" : "positive""#))
    }

    func testMarkdownExportUsesNativeTranscriptShape() throws {
        let message = AgentMessage(
            role: .assistant,
            content: "完成",
            feedback: MessageFeedback(rating: .negative, note: "需要补充测试")
        )
        let data = try ConversationExportBuilder.makeData(
            input: ConversationExportInput(
                sessionID: UUID(),
                title: "插件市场",
                providerID: "deepseek",
                model: "deepseek-chat",
                messages: [.user("修复问题"), message]
            ),
            format: .markdown
        )
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("# 插件市场"))
        XCTAssertTrue(text.contains("## User"))
        XCTAssertTrue(text.contains("## Harness"))
        XCTAssertTrue(text.contains("Feedback: negative"))
        XCTAssertTrue(text.contains("Note: 需要补充测试"))
    }
}
