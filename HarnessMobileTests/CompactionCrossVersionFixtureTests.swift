import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class CompactionCrossVersionFixtureTests: XCTestCase {
    func testPinnedProjectionPreservesEveryCompactionBoundaryKind() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.source.commit,
            "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e"
        )

        let keyedMessages = try fixture.messages.map { spec in
            (spec.key, try spec.message())
        }
        let messages = keyedMessages.map(\.1)
        let keyByID = Dictionary(uniqueKeysWithValues: keyedMessages.map { ($0.1.id, $0.0) })
        let state = ConversationWorkState(
            goal: ConversationGoal(title: "Finish parity remediation", status: .active),
            plan: [
                ConversationPlanStep(title: "Preserve tool transaction", status: .completed)
            ],
            todos: [
                ConversationTodoItem(title: "Verify cancellation replay", status: .active)
            ]
        )

        let projection = try ConversationCompactor.project(
            messages: messages,
            workState: state,
            maximumUTF8Bytes: fixture.maximumUTF8Bytes
        )

        XCTAssertEqual(
            projection.omittedMessages.compactMap { keyByID[$0.id] },
            fixture.expected.omittedKeys
        )
        XCTAssertEqual(
            projection.messages.compactMap { keyByID[$0.id] },
            fixture.expected.retainedKeys
        )
        XCTAssertLessThanOrEqual(projection.encodedUTF8Bytes, fixture.maximumUTF8Bytes)
        for fragment in fixture.expected.stateSummaryFragments {
            XCTAssertTrue(
                projection.stateSummary?.contains(fragment) == true,
                "Missing state fragment: \(fragment)"
            )
        }

        let call = try XCTUnwrap(projection.messages.first(where: { !$0.toolCalls.isEmpty }))
        XCTAssertEqual(call.toolCalls.first?.id, fixture.expected.toolCallID)
        XCTAssertTrue(projection.messages.contains { message in
            message.source?.objectValue?["kind"]?.stringValue
                == fixture.expected.instructionSourceKind
        })
        XCTAssertTrue(projection.messages.contains { message in
            message.imageAttachments.first?.path == fixture.expected.imagePath
        })
        XCTAssertTrue(projection.messages.contains { message in
            message.source?.objectValue?["uri"]?.stringValue == fixture.expected.referenceURI
        })
        let incompleteID = try XCTUnwrap(
            keyedMessages.first(where: { $0.0 == fixture.expected.incompleteAssistantKey })?.1.id
        )
        XCTAssertEqual(
            projection.messages.first(where: { $0.id == incompleteID })?.isIncomplete,
            true
        )
    }

    private func loadFixture() throws -> CompactionFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("CompatibilityFixtures/deepseek/compaction-cross-version-v1.json")
        return try JSONDecoder().decode(CompactionFixture.self, from: Data(contentsOf: url))
    }
}

private struct CompactionFixture: Decodable {
    let schemaVersion: Int
    let source: Source
    let maximumUTF8Bytes: Int
    let messages: [MessageSpec]
    let expected: Expected

    struct Source: Decodable { let commit: String }
    struct Expected: Decodable {
        let omittedKeys: [String]
        let retainedKeys: [String]
        let toolCallID: String
        let instructionSourceKind: String
        let imagePath: String
        let referenceURI: String
        let incompleteAssistantKey: String
        let stateSummaryFragments: [String]
    }
}

private struct MessageSpec: Decodable {
    let key: String
    let id: UUID
    let role: AgentRole
    let content: String
    let repeatCount: Int?
    let toolCalls: [AgentToolCall]?
    let toolCallID: String?
    let toolName: String?
    let isIncomplete: Bool?
    let source: JSONValue?
    let imageAttachment: AgentImageAttachmentRef?

    func message() throws -> AgentMessage {
        guard (repeatCount ?? 1) > 0 else { throw FixtureError.invalidRepeatCount }
        return AgentMessage(
            id: id,
            role: role,
            content: String(repeating: content, count: repeatCount ?? 1),
            toolCalls: toolCalls ?? [],
            toolCallID: toolCallID,
            toolName: toolName,
            isIncomplete: isIncomplete ?? false,
            source: source,
            imageAttachments: imageAttachment.map { [$0] } ?? [],
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }
}

private enum FixtureError: Error { case invalidRepeatCount }
