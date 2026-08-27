import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionTrajectoryRepositoryTests: XCTestCase {
    func testSessionPersistenceSeamUsesCanonicalLogRevisionAndLifecycle() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence: any SessionPersistence = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()

        let before = try await persistence.persistenceSnapshot(sessionID: sessionID)
        XCTAssertEqual(before.revision.nextSequence, 0)
        _ = try await persistence.append(
            .turnStart(turn: 1, time: 1),
            sessionID: sessionID
        )
        _ = try await persistence.append(
            .turnEnd(turn: 1, reason: .string("completed"), time: 2),
            sessionID: sessionID
        )
        try await persistence.flush(sessionID: sessionID)

        let after = try await persistence.persistenceSnapshot(sessionID: sessionID)
        XCTAssertEqual(after.snapshot.events.count, 2)
        XCTAssertEqual(after.revision.streamID, sessionID.uuidString.lowercased())
        XCTAssertEqual(after.revision.nextSequence, 2)
        XCTAssertNotEqual(after.revision, before.revision)
        let listed = try await persistence.listSessionIDs()
        XCTAssertEqual(listed, [sessionID])

        try await persistence.delete(sessionID: sessionID)
        let afterDelete = try await persistence.listSessionIDs()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testWriteBehindSeparatesLogicalCursorFromDurableRevisionUntilFlush() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()

        _ = try await repository.append(.turnStart(turn: 1, time: 1), sessionID: sessionID)
        _ = try await repository.append(
            .turnEnd(turn: 1, reason: .string("completed"), time: 2),
            sessionID: sessionID
        )
        let pending = try await repository.persistenceSnapshot(sessionID: sessionID)
        XCTAssertEqual(pending.snapshot.cursor.nextSequence, 2)
        XCTAssertEqual(pending.revision.nextSequence, 0)

        let coldBeforeFlush = SessionTrajectoryRepository(root: root)
        let coldSnapshotBeforeFlush = try await coldBeforeFlush.persistenceSnapshot(sessionID: sessionID)
        XCTAssertEqual(coldSnapshotBeforeFlush.revision.nextSequence, 0)

        try await repository.flush(sessionID: sessionID)
        let durable = try await repository.persistenceSnapshot(sessionID: sessionID)
        XCTAssertEqual(durable.revision.nextSequence, 2)

        let reopened = SessionTrajectoryRepository(root: root)
        let recovered = try await reopened.persistenceSnapshot(sessionID: sessionID)
        XCTAssertEqual(recovered.snapshot.events.map(\.seq), [0, 1])
        XCTAssertEqual(recovered.revision.nextSequence, 2)
    }

    func testSyncEnvelopeExportsDurableSuffixAndAdmitsExactCanonicalEvents() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let source = SessionTrajectoryRepository(root: root.appendingPathComponent("source"))
        let destination = SessionTrajectoryRepository(root: root.appendingPathComponent("destination"))

        _ = try await source.append(.turnStart(turn: 1, time: 1), sessionID: sessionID)
        _ = try await source.append(
            .turnEnd(turn: 1, reason: .string("completed"), time: 2),
            sessionID: sessionID
        )
        let envelope = try await source.makeSyncEnvelope(
            sessionID: sessionID,
            baseSequence: .max,
            metadata: ["source": "device-a"]
        )

        XCTAssertEqual(envelope.events.map(\.seq), [0, 1])
        let admitted = try await destination.admitSyncEnvelope(envelope)
        let destinationEvents = try await destination.allEvents(sessionID: sessionID)
        XCTAssertEqual(admitted, envelope.events)
        XCTAssertEqual(destinationEvents, envelope.events)

        let emptySuffix = try await source.makeSyncEnvelope(sessionID: sessionID, baseSequence: 1)
        XCTAssertTrue(emptySuffix.events.isEmpty)
    }

    func testSyncAdmissionRejectsConcurrentBaseMismatchWithoutOverwritingHistory() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let source = SessionTrajectoryRepository(root: root.appendingPathComponent("source"))
        let destination = SessionTrajectoryRepository(root: root.appendingPathComponent("destination"))

        _ = try await source.append(.turnStart(turn: 1, time: 1), sessionID: sessionID)
        let envelope = try await source.makeSyncEnvelope(sessionID: sessionID, baseSequence: .max)
        _ = try await destination.append(.turnStart(turn: 99, time: 99), sessionID: sessionID)

        do {
            _ = try await destination.admitSyncEnvelope(envelope)
            XCTFail("A concurrent local append must reject the remote suffix")
        } catch let error as SessionTrajectoryRepositoryError {
            XCTAssertEqual(error, .syncBaseMismatch(expected: 1, actual: 0))
        }
        let events = try await destination.allEvents(sessionID: sessionID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].turnStartData?.turn, 99)
    }

    func testSyncAdmissionRejectsAssetsAndTombstonesUntilPoliciesExist() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let destination = SessionTrajectoryRepository(root: root)
        let event = try SessionEvent(
            type: SessionEventVocabulary.turnStart,
            seq: 0,
            time: 1,
            data: .object(["turn": .number(1)])
        )
        let asset = try HarnessSyncAssetReference(
            key: "attachment",
            relativePath: "attachments/a.txt",
            byteCount: 1
        )
        let assetEnvelope = try HarnessSyncEnvelope(
            sessionID: sessionID,
            baseSequence: .max,
            events: [event],
            assets: [asset]
        )
        let tombstone = try HarnessSyncTombstone(eventID: 1, deletedAt: 1)
        let tombstoneEnvelope = try HarnessSyncEnvelope(
            sessionID: sessionID,
            baseSequence: .max,
            events: [event],
            tombstones: [tombstone]
        )

        do {
            _ = try await destination.admitSyncEnvelope(assetEnvelope)
            XCTFail("Assets need an explicit transfer policy")
        } catch let error as SessionTrajectoryRepositoryError {
            XCTAssertEqual(error, .syncAssetsUnsupported)
        }
        do {
            _ = try await destination.admitSyncEnvelope(tombstoneEnvelope)
            XCTFail("Tombstones need an explicit reconciliation policy")
        } catch let error as SessionTrajectoryRepositoryError {
            XCTAssertEqual(error, .syncTombstonesUnsupported)
        }
        let destinationEvents = try await destination.allEvents(sessionID: sessionID)
        XCTAssertTrue(destinationEvents.isEmpty)
    }
    func testSessionsKeepIndependentStreamsAndIncrementalCursors() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let firstSession = UUID()
        let secondSession = UUID()

        let empty = try await repository.prepare(sessionID: firstSession)
        XCTAssertEqual(empty.nextTurn, 1)
        XCTAssertEqual(empty.requestHeaderReason, .initial)

        _ = try await repository.append(.turnStart(turn: 1, time: 1), sessionID: firstSession)
        _ = try await repository.append(
            .stepStart(turn: 1, step: 1, time: 2),
            sessionID: firstSession
        )
        _ = try await repository.append(
            .stepEnd(turn: 1, step: 1, time: 3),
            sessionID: firstSession
        )
        _ = try await repository.append(
            .turnEnd(
                turn: 1,
                reason: .object(["kind": .string("completed")]),
                time: 4
            ),
            sessionID: firstSession
        )

        let delta = try await repository.snapshot(
            sessionID: firstSession,
            after: empty.snapshot.cursor
        )
        XCTAssertEqual(delta.events.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(delta.metrics.turns, 1)

        let resumed = try await repository.prepare(sessionID: firstSession)
        XCTAssertEqual(resumed.nextTurn, 2)
        XCTAssertEqual(resumed.requestHeaderReason, .resume)

        let other = try await repository.prepare(sessionID: secondSession)
        XCTAssertEqual(other.snapshot.events, [])
        XCTAssertEqual(other.nextTurn, 1)
        let firstSnapshot = try await repository.snapshot(sessionID: firstSession)
        XCTAssertEqual(firstSnapshot.events.count, 4)
    }

    func testInterruptedTurnStillAdvancesNextTurnNumber() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()

        _ = try await repository.append(.turnStart(turn: 7, time: 1), sessionID: sessionID)

        let preparation = try await repository.prepare(sessionID: sessionID)
        XCTAssertEqual(preparation.nextTurn, 8)
        XCTAssertEqual(preparation.requestHeaderReason, .resume)

        // A live store is intentionally not cold-repaired. Reopening through a
        // fresh repository models the crash/restart boundary and performs the
        // synthetic interruption repair.
        let reopenedRepository = SessionTrajectoryRepository(root: root)
        let repaired = try await reopenedRepository.prepare(sessionID: sessionID)
        XCTAssertEqual(repaired.nextTurn, 8)
        XCTAssertEqual(repaired.snapshot.events.map(\.type), [
            SessionEventVocabulary.turnStart,
            SessionEventVocabulary.turnEnd
        ])
        let repeated = try await repository.prepare(sessionID: sessionID)
        XCTAssertEqual(repeated.snapshot.events.count, preparation.snapshot.events.count)
        XCTAssertEqual(repeated.nextTurn, 8)
    }

    func testPluginEventRegistrationAppliesToOpenedStreams() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        let draft = SessionEventDraft(
            type: "plugin/memory-snapshot",
            time: 1,
            data: .object(["revision": .number(1)])
        )

        _ = try await repository.prepare(sessionID: sessionID)
        do {
            _ = try await repository.append(draft, sessionID: sessionID)
            XCTFail("Unknown required plugin events must be rejected")
        } catch let error as SessionEventLogError {
            XCTAssertEqual(
                error,
                .unsupportedEventType(type: "plugin/memory-snapshot", sequence: 0)
            )
        }

        try await repository.registerKnownEventTypes(["plugin/memory-snapshot"])
        let event = try await repository.append(draft, sessionID: sessionID)
        XCTAssertEqual(event.seq, 0)
        XCTAssertEqual(event.type, "plugin/memory-snapshot")
    }

    func testDeleteStartsTheSessionWithAnEmptyStream() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()

        _ = try await repository.append(.turnStart(turn: 3, time: 1), sessionID: sessionID)
        try await repository.delete(sessionID: sessionID)

        let reset = try await repository.prepare(sessionID: sessionID)
        XCTAssertEqual(reset.snapshot.events, [])
        XCTAssertEqual(reset.nextTurn, 1)
        XCTAssertEqual(reset.requestHeaderReason, .initial)
    }

    func testConversationProjectionAppendsDurableSuffixAfterSessionSnapshot() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        let user = AgentMessage.user("inspect the workspace")
        let call = AgentToolCall(id: "call-1", name: "workspace_read", arguments: "{\"path\":\"README.md\"}")
        let assistant = AgentMessage.assistant(
            "I will inspect it.",
            reasoning: "Need the file contents.",
            toolCalls: [call],
            source: AgentModelSource(provider: "deepseek", model: "deepseek-chat").jsonValue
        )

        _ = try await repository.append(
            .userMessage(sessionUserMessage(user)),
            sessionID: sessionID
        )
        _ = try await repository.append(
            .assistantMessage(
                turn: 1,
                step: 1,
                message: sessionAssistantMessage(assistant)
            ),
            sessionID: sessionID
        )
        _ = try await repository.append(
            .toolResult(
                turn: 1,
                step: 1,
                message: sessionToolResultMessage(
                    callID: call.id,
                    output: "contents",
                    isError: false
                )
            ),
            sessionID: sessionID
        )

        let snapshot = try await repository.prepare(sessionID: sessionID).snapshot
        let pendingUser = AgentMessage.user("follow up before checkpoint")
        let reconciled = SessionTrajectoryConversationProjection.reconcile(
            sessionMessages: [user, pendingUser],
            events: snapshot.events
        )

        XCTAssertEqual(reconciled.map(\.role), [.user, .assistant, .tool, .user])
        XCTAssertEqual(reconciled[1].id, assistant.id)
        XCTAssertEqual(reconciled[1].reasoning, "Need the file contents.")
        XCTAssertEqual(reconciled[1].toolCalls, [call])
        XCTAssertEqual(reconciled[1].modelSource?.provider, "deepseek")
        XCTAssertEqual(reconciled[2].toolCallID, call.id)
        XCTAssertEqual(reconciled[2].toolName, call.name)
        XCTAssertEqual(reconciled[2].content, "contents")
        XCTAssertEqual(reconciled[2].isToolError, false)
        XCTAssertEqual(reconciled[3], pendingUser)
    }

    func testColdRecoveryProjectsUnknownToolOutcomeIntoNextHistory() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let writer = SessionTrajectoryRepository(root: root)
        let user = AgentMessage.user("perform the operation")
        let call = AgentToolCall(id: "call-interrupted", name: "side_effect", arguments: "{}")
        let assistant = AgentMessage.assistant("", toolCalls: [call])

        _ = try await writer.append(.turnStart(turn: 1, time: 1), sessionID: sessionID)
        _ = try await writer.append(
            .userMessage(sessionUserMessage(user), time: 2),
            sessionID: sessionID
        )
        _ = try await writer.append(.stepStart(turn: 1, step: 1, time: 3), sessionID: sessionID)
        _ = try await writer.append(
            .assistantMessage(
                turn: 1,
                step: 1,
                message: sessionAssistantMessage(assistant),
                time: 4
            ),
            sessionID: sessionID
        )
        _ = try await writer.append(
            .toolCall(
                turn: 1,
                step: 1,
                callID: call.id,
                name: call.name,
                arguments: call.arguments,
                time: 5
            ),
            sessionID: sessionID
        )
        try await writer.flush(sessionID: sessionID)

        let reopened = SessionTrajectoryRepository(root: root)
        let repaired = try await reopened.prepare(sessionID: sessionID)
        let history = SessionTrajectoryConversationProjection.reconcile(
            sessionMessages: [user, assistant],
            events: repaired.snapshot.events
        )

        XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool])
        let result = try XCTUnwrap(history.last)
        XCTAssertEqual(result.toolCallID, call.id)
        XCTAssertEqual(result.isToolError, true)
        XCTAssertTrue(result.content.contains("outcome is unknown"))
        XCTAssertEqual(ConversationCompactor.repairIncompleteToolTurn(history), history)
    }

    func testConversationProjectionDoesNotRestoreAbandonedEditedBranch() async throws {
        let original = AgentMessage.user("original request")
        let oldReply = AgentMessage.assistant("old reply")
        let edited = AgentMessage(
            id: original.id,
            role: .user,
            content: "edited request"
        )
        let events = try [
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 0,
                time: 1,
                data: sessionUserMessage(original),
                surfaceOp: .append
            ),
            SessionEvent(
                type: SessionEventVocabulary.assistantMessage,
                seq: 1,
                time: 2,
                data: .object([
                    "turn": .number(1),
                    "step": .number(1),
                    "message": sessionAssistantMessage(oldReply)
                ]),
                surfaceOp: .append
            )
        ]

        let reconciled = SessionTrajectoryConversationProjection.reconcile(
            sessionMessages: [edited],
            events: events
        )
        XCTAssertEqual(reconciled, [edited])
    }

    func testConversationProjectionAppliesDurableCompactionReplacement() throws {
        let oldUser = AgentMessage.user("old request")
        let oldReply = AgentMessage.assistant("old reply")
        let checkpoint = AgentMessage.user("<compacted-summary>state</compacted-summary>")
        let current = AgentMessage.user("continue")
        let events = try [
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 0,
                time: 1,
                data: sessionUserMessage(oldUser),
                surfaceOp: .append
            ),
            SessionEvent(
                type: SessionEventVocabulary.assistantMessage,
                seq: 1,
                time: 2,
                data: .object([
                    "turn": .number(1),
                    "step": .number(1),
                    "message": sessionAssistantMessage(oldReply)
                ]),
                surfaceOp: .append
            ),
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 2,
                time: 3,
                data: sessionUserMessage(checkpoint),
                sourceEventSeqs: [0, 1],
                surfaceOp: .replace(start: 0, end: 1)
            ),
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 3,
                time: 4,
                data: sessionUserMessage(current),
                surfaceOp: .append
            )
        ]

        let projected = SessionTrajectoryConversationProjection.messages(from: events)
        XCTAssertEqual(projected.map(\.id), [checkpoint.id, current.id])
        XCTAssertEqual(projected.map(\.content), [checkpoint.content, current.content])
        XCTAssertEqual(projected.map(\.role), [.user, .user])
        XCTAssertEqual(
            SessionTrajectoryConversationProjection.replacementRangeForPrefix(
                count: 1,
                events: events
            ),
            2...2
        )
    }

    func testForkProjectionStopsAtLastCompletedTurn() throws {
        let completedUser = AgentMessage.user("completed request")
        let completedReply = AgentMessage.assistant("completed reply")
        let openUser = AgentMessage.user("currently running request")
        let openCall = AgentToolCall(
            id: "open-call",
            name: "read",
            arguments: #"{"path":"README.md"}"#
        )
        let openReply = AgentMessage.assistant("", toolCalls: [openCall])
        let events = try [
            SessionEvent(
                type: SessionEventVocabulary.turnStart,
                seq: 0,
                time: 1,
                data: .object(["turn": .number(1)])
            ),
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 1,
                time: 2,
                data: sessionUserMessage(completedUser),
                surfaceOp: .append
            ),
            SessionEvent(
                type: SessionEventVocabulary.assistantMessage,
                seq: 2,
                time: 3,
                data: .object([
                    "turn": .number(1),
                    "step": .number(1),
                    "message": sessionAssistantMessage(completedReply)
                ]),
                surfaceOp: .append
            ),
            SessionEvent(
                type: SessionEventVocabulary.turnEnd,
                seq: 3,
                time: 4,
                data: .object([
                    "turn": .number(1),
                    "reason": .object(["kind": .string("completed")])
                ])
            ),
            SessionEvent(
                type: SessionEventVocabulary.turnStart,
                seq: 4,
                time: 5,
                data: .object(["turn": .number(2)])
            ),
            SessionEvent(
                type: SessionEventVocabulary.userMessage,
                seq: 5,
                time: 6,
                data: sessionUserMessage(openUser),
                surfaceOp: .append
            ),
            SessionEvent(
                type: SessionEventVocabulary.assistantMessage,
                seq: 6,
                time: 7,
                data: .object([
                    "turn": .number(2),
                    "step": .number(1),
                    "message": sessionAssistantMessage(openReply)
                ]),
                surfaceOp: .append
            )
        ]

        let seed = SessionTrajectoryConversationProjection
            .messagesThroughLastCompletedTurn(from: events)
        XCTAssertEqual(seed.map(\.id), [completedUser.id, completedReply.id])
        XCTAssertFalse(seed.contains(where: { $0.id == openUser.id || $0.id == openReply.id }))
        XCTAssertEqual(
            SessionTrajectoryConversationProjection
                .messagesThroughLastCompletedTurn(from: Array(events.prefix(3))),
            []
        )
    }

    func testConversationProjectionRetainsNonImageFileAttachmentMetadata() throws {
        let attachment = AgentFileAttachmentRef(
            id: UUID(uuidString: "9DFA7394-C5BC-407B-918A-47E2F18A906A")!,
            path: "Attachments/9dfa7394-c5bc-407b-918a-47e2f18a906a.pdf",
            mimeType: "application/pdf",
            byteCount: 128,
            displayName: "brief.pdf",
            expiresAt: .distantFuture
        )
        let message = AgentMessage.user(
            "Please inspect this document.",
            fileAttachments: [attachment]
        )
        let event = try SessionEvent(
            type: SessionEventVocabulary.userMessage,
            seq: 0,
            time: 1,
            data: sessionUserMessage(message),
            surfaceOp: .append
        )

        let projected = SessionTrajectoryConversationProjection.messages(from: [event])

        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected[0].id, message.id)
        XCTAssertEqual(projected[0].content, message.content)
        XCTAssertEqual(projected[0].fileAttachments, [attachment])
    }

    private func sessionUserMessage(_ message: AgentMessage) -> JSONValue {
        var value: [String: JSONValue] = [
            "id": .string(message.id.uuidString),
            "role": .string("user"),
            "content": .array([textBlock(message.content)]),
            "source": message.source ?? .object(["kind": .string("user")])
        ]
        if !message.imageAttachments.isEmpty {
            value["imageAttachments"] = .array(message.imageAttachments.map { attachment in
                .object([
                    "id": .string(attachment.id.uuidString),
                    "path": .string(attachment.path),
                    "mimeType": .string(attachment.mimeType),
                    "byteCount": .number(Double(attachment.byteCount))
                ])
            })
        }
        if !message.fileAttachments.isEmpty {
            value["fileAttachments"] = .array(message.fileAttachments.map { attachment in
                .object([
                    "id": .string(attachment.id.uuidString),
                    "path": .string(attachment.path),
                    "mimeType": .string(attachment.mimeType),
                    "byteCount": .number(Double(attachment.byteCount)),
                    "displayName": .string(attachment.displayName),
                    "expiresAt": .string(ISO8601DateFormatter().string(from: attachment.expiresAt))
                ])
            })
        }
        return .object(value)
    }

    private func sessionAssistantMessage(_ message: AgentMessage) -> JSONValue {
        var content: [JSONValue] = []
        if let reasoning = message.reasoning {
            content.append(.object(["type": .string("reasoning"), "text": .string(reasoning)]))
        }
        if !message.content.isEmpty { content.append(textBlock(message.content)) }
        content.append(contentsOf: message.toolCalls.map { call in
            .object([
                "type": .string("tool-call"),
                "id": .string(call.id),
                "name": .string(call.name),
                "arguments": .string(call.arguments)
            ])
        })
        return .object([
            "id": .string(message.id.uuidString),
            "role": .string("assistant"),
            "content": .array(content),
            "source": message.source ?? .object([
                "kind": .string("model"),
                "provider": .string("deepseek"),
                "model": .string("deepseek-chat")
            ])
        ])
    }

    private func sessionToolResultMessage(
        callID: String,
        output: String,
        isError: Bool
    ) -> JSONValue {
        .object([
            "id": .string(UUID().uuidString),
            "role": .string("user"),
            "content": .array([
                .object([
                    "type": .string("tool-result"),
                    "toolCallId": .string(callID),
                    "content": .array([textBlock(output)]),
                    "isError": .bool(isError)
                ])
            ]),
            "source": .object(["kind": .string("tool"), "callId": .string(callID)])
        ])
    }

    private func textBlock(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-trajectory-repository-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
