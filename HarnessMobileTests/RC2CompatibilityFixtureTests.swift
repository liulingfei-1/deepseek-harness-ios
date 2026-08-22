import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class RC2CompatibilityFixtureTests: XCTestCase {
    private static let pinnedCommit = "b150a551b8d465e31e418e1b2eaf5e79bbb7d28e"

    func testReasoningReplayFixtureCoversPlainAndToolCallTurns() throws {
        let fixture: ReasoningCancelFixture = try load("reasoning-cancel-v1.json")
        try assertPinned(fixture.source, schemaVersion: fixture.schemaVersion)

        for replay in fixture.reasoningReplay {
            let assistant = AgentMessage.assistant(
                replay.assistant.content,
                reasoning: replay.assistant.reasoning,
                toolCalls: replay.assistant.toolCalls.map {
                    AgentToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
                }
            )
            let wire = ChatWireSerializer.makeMessages(
                systemPrompt: "fixture-system",
                messages: [assistant]
            )
            XCTAssertEqual(
                try encodedJSON(wire[1]),
                replay.expectedWire,
                "reasoning replay drifted for \(replay.name)"
            )
        }
    }

    func testCancelledPrefixFixtureKeepsInterruptedDurableProjection() throws {
        let fixture: ReasoningCancelFixture = try load("reasoning-cancel-v1.json")
        let value = fixture.cancelPrefix
        let messageID = try XCTUnwrap(UUID(uuidString: value.messageID))
        let message = AgentMessage(
            id: messageID,
            role: .assistant,
            content: value.content,
            reasoning: value.reasoning,
            isIncomplete: true,
            source: .object([
                "kind": .string("model"),
                "provider": .string("deepseek"),
                "model": .string("deepseek-v4-flash")
            ]),
            createdAt: Date(timeIntervalSince1970: 1_777_777_777)
        )
        let restored = try JSONDecoder().decode(
            AgentMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(restored, message)
        XCTAssertTrue(restored.isIncomplete)

        let usage = SessionTokenUsage(
            inputTokens: value.usage.inputTokens,
            outputTokens: value.usage.outputTokens,
            reasoningTokens: value.usage.reasoningTokens
        )
        let draft = SessionEventDraft.assistantMessage(
            turn: value.turn,
            step: value.step,
            message: value.expectedEventData.objectValue?["message"] ?? .null,
            usage: usage,
            interrupted: true,
            sourceEventSeqs: value.sourceEventSeqs,
            time: value.eventTime
        )
        XCTAssertEqual(draft.type, SessionEventVocabulary.assistantMessage)
        XCTAssertEqual(draft.data, value.expectedEventData)
        XCTAssertEqual(draft.sourceEventSeqs, value.sourceEventSeqs)

        let event = try SessionEvent(
            type: draft.type,
            seq: value.eventSequence,
            time: draft.time,
            data: draft.data,
            sourceEventSeqs: draft.sourceEventSeqs,
            surfaceOp: draft.surfaceOp
        )
        XCTAssertTrue(event.assistantMessageData?.interrupted == true)
        let projected = try XCTUnwrap(
            SessionTrajectoryConversationProjection.messages(from: [event]).first
        )
        XCTAssertEqual(projected.id, messageID)
        XCTAssertEqual(projected.content, value.content)
        XCTAssertEqual(projected.reasoning, value.reasoning)
        XCTAssertTrue(projected.isIncomplete)
    }

    func testImageFixtureSeparatesDurableReferenceFromRequestProjection() throws {
        let fixture: ImageReferenceFixture = try load("image-reference-v1.json")
        try assertPinned(fixture.source, schemaVersion: fixture.schemaVersion)

        for image in fixture.images {
            let id = try XCTUnwrap(UUID(uuidString: image.attachment.id))
            let reference = AgentImageAttachmentRef(
                id: id,
                path: image.attachment.path,
                mimeType: image.attachment.mimeType,
                byteCount: image.attachment.byteCount
            )
            let message = AgentMessage.user(image.message, imageAttachments: [reference])
            let requestBytes = try XCTUnwrap(Data(base64Encoded: image.request.base64))
            let wire = ChatWireSerializer.makeMessages(
                systemPrompt: "fixture-system",
                messages: [message],
                imagePayloads: [
                    ModelImagePayload(
                        id: id,
                        mimeType: image.attachment.mimeType,
                        data: requestBytes,
                        fileID: image.request.fileID
                    )
                ]
            )
            XCTAssertEqual(
                try encodedJSON(wire[1]),
                image.expectedWire,
                "image request projection drifted for \(image.name)"
            )

            let persisted = try encodedJSON(message)
            let attachments: [JSONValue]
            if case let .array(values) = persisted.objectValue?["imageAttachments"] {
                attachments = values
            } else {
                return XCTFail("durable image attachment array is missing")
            }
            let attachment = try XCTUnwrap(attachments.first?.objectValue)
            XCTAssertEqual(attachment["id"], .string(image.attachment.id))
            XCTAssertEqual(attachment["path"], .string(image.attachment.path))
            XCTAssertEqual(attachment["mimeType"], .string(image.attachment.mimeType))
            XCTAssertEqual(attachment["byteCount"], .number(Double(image.attachment.byteCount)))
            XCTAssertFalse(String(data: try JSONEncoder().encode(message), encoding: .utf8)?.contains(image.request.base64) == true)
            XCTAssertNil(attachment["fileID"])
        }
    }

    func testReferenceFixturePinsFileAndCanonicalSessionSyntax() throws {
        let fixture: ImageReferenceFixture = try load("image-reference-v1.json")
        for file in fixture.fileMentions {
            XCTAssertEqual(
                HarnessReferenceSyntax.formatFileMention(path: file.path),
                file.expected
            )
        }

        let source = fixture.sessionReferences
        let parsed = try HarnessReferenceSyntax.parseSessionReferences(in: source.input)
        XCTAssertEqual(parsed.renderedText, source.expectedRendered)
        XCTAssertEqual(parsed.references.count, 3)

        let current = try XCTUnwrap(UUID(uuidString: source.currentSessionID))
        let normalized = try HarnessReferenceSyntax.normalizeSessionReferences(
            parsed.references,
            currentSessionID: current
        )
        XCTAssertEqual(normalized.count, source.expectedReferences.count)
        for (actual, expected) in zip(normalized, source.expectedReferences) {
            let sessionID = try XCTUnwrap(UUID(uuidString: expected.sessionID))
            XCTAssertEqual(actual.sessionID, sessionID)
            XCTAssertEqual(actual.label, expected.label)
            XCTAssertEqual(HarnessReferenceSyntax.encodeSessionURI(sessionID), expected.uri)
            XCTAssertEqual(
                HarnessReferenceSyntax.formatSessionMention(
                    sessionID: sessionID,
                    label: expected.label
                ),
                expected.mention
            )
        }
    }

    func testSubagentFixturePinsDescriptorV2AndMobileProjection() async throws {
        let fixture: SubagentJobsFixture = try load("subagent-jobs-v1.json")
        try assertPinned(fixture.source, schemaVersion: fixture.schemaVersion)
        XCTAssertEqual(fixture.subagent.descriptor.objectValue?["version"], .number(2))
        XCTAssertEqual(fixture.subagent.descriptor.objectValue?["mode"], .string("continuable"))

        let descriptorEvent = try SessionEvent(
            type: SessionEventVocabulary.subagentDescriptor,
            seq: 0,
            time: 1_777_777_777_000,
            data: fixture.subagent.descriptor
        )
        XCTAssertEqual(descriptorEvent.data, fixture.subagent.descriptor)
        XCTAssertTrue(SessionEventVocabulary.upstreamKnown.contains(descriptorEvent.type))

        let value = fixture.subagent.mobileProjection
        let registry = HarnessJobRegistry()
        let snapshot = try await registry.registerSubagent(
            id: value.id,
            parentSession: value.parentSession,
            label: value.label,
            model: value.model,
            contextMode: value.contextMode,
            persona: value.persona,
            toolFilter: value.toolFilter,
            reportDelivery: value.reportDelivery,
            maximumDepth: value.maximumDepth
        )
        XCTAssertEqual(snapshot.id, value.id)
        XCTAssertEqual(snapshot.parentSession, value.parentSession)
        XCTAssertEqual(snapshot.label, value.label)
        XCTAssertEqual(snapshot.model, value.model)
        XCTAssertEqual(snapshot.contextMode, value.contextMode)
        XCTAssertEqual(snapshot.delegationDepth, value.delegationDepth)
        XCTAssertEqual(snapshot.maximumDepth, value.maximumDepth)
        XCTAssertEqual(snapshot.persona, value.persona)
        XCTAssertEqual(snapshot.toolFilter, value.toolFilter)
        XCTAssertEqual(snapshot.reportDelivery, value.reportDelivery)
        XCTAssertEqual(snapshot.status, value.status)
    }

    func testJobsFixturePinsSnapshotAndCompletionNotice() throws {
        let fixture: SubagentJobsFixture = try load("subagent-jobs-v1.json")
        let snapshotData = try JSONEncoder().encode(fixture.job.snapshot)
        let decoded = try JSONDecoder().decode(HarnessJobSnapshot.self, from: snapshotData)
        XCTAssertEqual(decoded, fixture.job.snapshot)
        XCTAssertTrue(decoded.status.isTerminal)
        XCTAssertFalse(decoded.reported)

        let noticeData = try JSONEncoder().encode(fixture.job.completionNotice)
        let notice = try JSONDecoder().decode(HarnessJobCompletionNotice.self, from: noticeData)
        XCTAssertEqual(notice.text, fixture.job.expectedCompletionText)
        XCTAssertEqual(Optional(notice.ownerSession), decoded.ownerSession)
        XCTAssertEqual(notice.status, decoded.status)
        XCTAssertEqual(notice.finishedAt, decoded.finishedAt)
    }

    private func assertPinned(_ source: RC2FixtureSource, schemaVersion: Int) throws {
        XCTAssertEqual(schemaVersion, 1)
        XCTAssertEqual(source.project, "deepseek-ai/deepseek-harness")
        XCTAssertEqual(source.tag, "dsh-v0.1.1-rc.2")
        XCTAssertEqual(source.commit, Self.pinnedCommit)
        XCTAssertFalse(source.contracts.isEmpty)
    }

    private func encodedJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func load<T: Decodable>(_ filename: String) throws -> T {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("CompatibilityFixtures", isDirectory: true)
            .appendingPathComponent("deepseek", isDirectory: true)
            .appendingPathComponent(filename)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private struct RC2FixtureSource: Decodable {
    let project: String
    let tag: String
    let commit: String
    let contracts: [String]
}

private struct ReasoningCancelFixture: Decodable {
    let schemaVersion: Int
    let source: RC2FixtureSource
    let reasoningReplay: [ReasoningReplay]
    let cancelPrefix: CancelPrefix

    struct ReasoningReplay: Decodable {
        let name: String
        let assistant: Assistant
        let expectedWire: JSONValue

        struct Assistant: Decodable {
            let content: String
            let reasoning: String?
            let toolCalls: [ToolCall]
        }

        struct ToolCall: Decodable {
            let id: String
            let name: String
            let arguments: String
        }
    }

    struct CancelPrefix: Decodable {
        let messageID: String
        let turn: Int
        let step: Int
        let content: String
        let reasoning: String
        let sourceEventSeqs: [UInt64]
        let eventSequence: UInt64
        let eventTime: Int64
        let usage: Usage
        let expectedEventData: JSONValue

        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            let reasoningTokens: Int
        }
    }
}

private struct ImageReferenceFixture: Decodable {
    let schemaVersion: Int
    let source: RC2FixtureSource
    let images: [ImageCase]
    let fileMentions: [FileMention]
    let sessionReferences: SessionReferences

    struct ImageCase: Decodable {
        let name: String
        let message: String
        let attachment: Attachment
        let request: Request
        let expectedWire: JSONValue
    }

    struct Attachment: Decodable {
        let id: String
        let path: String
        let mimeType: String
        let byteCount: Int
    }

    struct Request: Decodable {
        let base64: String
        let fileID: String?
    }

    struct FileMention: Decodable {
        let path: String
        let expected: String
    }

    struct SessionReferences: Decodable {
        let currentSessionID: String
        let input: String
        let expectedRendered: String
        let expectedReferences: [ExpectedReference]
    }

    struct ExpectedReference: Decodable {
        let sessionID: String
        let label: String
        let uri: String
        let mention: String
    }
}

private struct SubagentJobsFixture: Decodable {
    let schemaVersion: Int
    let source: RC2FixtureSource
    let subagent: Subagent
    let job: Job

    struct Subagent: Decodable {
        let descriptor: JSONValue
        let mobileProjection: MobileProjection
    }

    struct MobileProjection: Decodable {
        let id: String
        let parentSession: String
        let label: String
        let model: String?
        let contextMode: LocalSubagentContextMode
        let delegationDepth: Int
        let maximumDepth: Int
        let persona: String?
        let toolFilter: LocalSubagentToolFilter?
        let reportDelivery: LocalSubagentReportDelivery
        let status: HarnessJobStatus
    }

    struct Job: Decodable {
        let snapshot: HarnessJobSnapshot
        let completionNotice: HarnessJobCompletionNotice
        let expectedCompletionText: String
    }
}
