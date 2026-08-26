import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class SessionStoreTests: XCTestCase {
    func testAppIntentInboxAdmitsConcurrentDistinctRequestsInFIFOStorage() async throws {
        let fileURL = makeInboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = AppIntentInboxStore(fileURL: fileURL)
        let requests = try (0..<12).map { index in
            try AppIntentInboxRequest(
                action: .sendPrompt,
                prompt: "parallel request \(index)"
            )
        }
        let accepted = try await withThrowingTaskGroup(of: Bool.self) { group in
            for request in requests {
                group.addTask {
                    try await store.enqueue(request)
                }
            }
            var result: [Bool] = []
            for try await didAccept in group {
                result.append(didAccept)
            }
            return result
        }

        XCTAssertEqual(accepted.filter { $0 }.count, requests.count)
        let pending = try await store.pendingRequests()
        XCTAssertEqual(Set(pending.map(\.id)), Set(requests.map(\.id)))
        XCTAssertEqual(pending.count, requests.count)
    }

    func testAppIntentInboxRejectsDuplicateRequestIDAndConsumesOnlyOnceAfterRestart() async throws {
        let fileURL = makeInboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let request = try AppIntentInboxRequest(
            id: UUID(),
            action: .sendPrompt,
            prompt: "durable request"
        )
        let first = AppIntentInboxStore(fileURL: fileURL)
        let firstEnqueue = try await first.enqueue(request)
        let duplicateEnqueue = try await first.enqueue(request)
        XCTAssertTrue(firstEnqueue)
        XCTAssertFalse(duplicateEnqueue)

        let restarted = AppIntentInboxStore(fileURL: fileURL)
        let consumed = try await restarted.consumeNext()
        let exhausted = try await restarted.consumeNext()
        let replayEnqueue = try await restarted.enqueue(request)
        XCTAssertEqual(consumed?.id, request.id)
        XCTAssertEqual(consumed?.action, request.action)
        XCTAssertEqual(consumed?.sessionID, request.sessionID)
        XCTAssertEqual(consumed?.prompt, request.prompt)
        XCTAssertNil(exhausted)
        XCTAssertFalse(replayEnqueue)
    }

    func testAppIntentInboxRejectsCorruptAndUnsupportedSnapshots() async throws {
        let fileURL = makeInboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        try Data("not json".utf8).write(to: fileURL)
        let corrupt = AppIntentInboxStore(fileURL: fileURL)
        do {
            _ = try await corrupt.pendingRequests()
            XCTFail("Corrupt inbox data must fail closed")
        } catch let error as AppIntentInboxError {
            XCTAssertEqual(error, .unreadableStore)
        }

        let unsupported = #"{"consumedRequestIDs":[],"pending":[],"runningSessionIDs":[],"version":99}"#
        try Data(unsupported.utf8).write(to: fileURL, options: .atomic)
        let versioned = AppIntentInboxStore(fileURL: fileURL)
        do {
            _ = try await versioned.pendingRequests()
            XCTFail("Unknown inbox versions must fail closed")
        } catch let error as AppIntentInboxError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }
    }

    func testAppIntentInboxPersistsRunningSessionProjection() async throws {
        let fileURL = makeInboxURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let firstID = UUID()
        let secondID = UUID()
        let store = AppIntentInboxStore(fileURL: fileURL)
        try await store.updateRunningSessions([firstID, secondID])
        let firstIsRunning = try await store.isSessionRunning(firstID)
        let secondIsRunning = try await store.isSessionRunning(secondID)
        XCTAssertTrue(firstIsRunning)
        XCTAssertTrue(secondIsRunning)

        let restarted = AppIntentInboxStore(fileURL: fileURL)
        let restartedFirstIsRunning = try await restarted.isSessionRunning(firstID)
        XCTAssertTrue(restartedFirstIsRunning)
        try await restarted.updateRunningSessions([secondID])
        let firstIsStopped = try await restarted.isSessionRunning(firstID)
        let secondRemainsRunning = try await restarted.isSessionRunning(secondID)
        XCTAssertFalse(firstIsStopped)
        XCTAssertTrue(secondRemainsRunning)
    }

    func testLoadRepairsTrailingAssistantToolCallWithoutResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSessionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let validUser = AgentMessage.user("hello")
        let incomplete = AgentMessage.assistant(
            "",
            toolCalls: [
                AgentToolCall(id: "call-1", name: "device_time", arguments: "{}")
            ]
        )
        try await store.save([validUser, incomplete])

        let firstLoad = try await store.load()
        let secondLoad = try await store.load()
        XCTAssertEqual(firstLoad.map(\.id), [validUser.id])
        XCTAssertEqual(firstLoad.map(\.content), ["hello"])
        XCTAssertEqual(secondLoad.map(\.id), [validUser.id])
        XCTAssertEqual(secondLoad.map(\.content), ["hello"])
    }

    func testCreatesSwitchesAndDeletesFourPersistentLogicalSessions() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        var sessions: [ConversationSession] = []
        for index in 1...4 {
            sessions.append(
                try await store.createSession(
                    title: "Session \(index)",
                    makeActive: index == 1
                )
            )
        }
        let initialSummaries = try await store.listSessions()
        XCTAssertEqual(initialSummaries.count, 4)

        let fourth = try await store.switchActiveSession(to: sessions[3].id)
        XCTAssertEqual(fourth.id, sessions[3].id)
        try await store.checkpointActiveSession(
            ConversationCheckpoint(messages: [.user("fourth conversation")])
        )

        let reloaded = SessionStore(root: root)
        let persisted = try await reloaded.loadState()
        XCTAssertEqual(persisted.sessions.count, 4)
        XCTAssertEqual(persisted.activeSessionID, sessions[3].id)
        XCTAssertEqual(persisted.activeSession?.messages.map(\.content), ["fourth conversation"])

        let replacementID = try await reloaded.deleteSession(id: sessions[3].id)
        XCTAssertEqual(replacementID, sessions[2].id)
        let remainingSummaries = try await reloaded.listSessions()
        XCTAssertEqual(remainingSummaries.count, 3)

        _ = try await reloaded.deleteSession(id: sessions[0].id)
        _ = try await reloaded.deleteSession(id: sessions[1].id)
        let finalActiveID = try await reloaded.deleteSession(id: sessions[2].id)
        XCTAssertNil(finalActiveID)
        let noActiveSession = try await reloaded.activeSession()
        XCTAssertNil(noActiveSession)
    }

    func testCheckpointAtomicallyPersistsMessagesGoalPlanAndTodo() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let session = try await store.createSession(title: "Structured state")
        let state = ConversationWorkState(
            goal: ConversationGoal(title: "Ship the local persistence layer", status: .active),
            plan: [
                ConversationPlanStep(title: "Design snapshot", status: .completed),
                ConversationPlanStep(title: "Verify migration", status: .active)
            ],
            todos: [
                ConversationTodoItem(title: "Run SwiftPM tests"),
                ConversationTodoItem(title: "Report integration API", status: .blocked)
            ]
        )
        var controls = ConversationControlState(
            interactionMode: .plan,
            modelConfiguration: ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        )
        _ = try controls.enqueue("continue after restart")
        let checkpointed = try await store.checkpointSession(
            id: session.id,
            checkpoint: ConversationCheckpoint(
                messages: [.user("persist everything at one boundary")],
                workState: state,
                controlState: controls
            )
        )
        XCTAssertEqual(checkpointed.revision, 1)

        // A non-empty checkpoint starts the conversation and therefore locks
        // the preset for the rest of this session's lifecycle.
        controls.lockAgentPreset()

        let reloaded = try await SessionStore(root: root).session(id: session.id)
        XCTAssertEqual(reloaded.messages.map(\.content), ["persist everything at one boundary"])
        XCTAssertEqual(reloaded.workState, state)
        XCTAssertEqual(reloaded.controlState, controls)
        XCTAssertEqual(reloaded.revision, 1)

        let data = try Data(contentsOf: root.appendingPathComponent("current-session.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 4)
        XCTAssertNotNil(object["activeSessionID"])
        XCTAssertEqual((object["sessions"] as? [[String: Any]])?.count, 1)
    }

    func testMigratesLegacySnapshotAndRepairsIncompleteToolTurn() async throws {
        struct LegacySnapshot: Encodable {
            let version: Int
            let messages: [AgentMessage]
            let updatedAt: Date
        }

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let validUser = AgentMessage.user("legacy user")
        let incomplete = AgentMessage.assistant(
            "",
            toolCalls: [AgentToolCall(id: "legacy-call", name: "device_time", arguments: "{}")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            LegacySnapshot(
                version: 1,
                messages: [validUser, incomplete],
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        try data.write(to: root.appendingPathComponent("current-session.json"))

        let store = SessionStore(root: root)
        let migrated = try await store.loadState()
        XCTAssertEqual(migrated.sessions.count, 1)
        XCTAssertEqual(migrated.activeSession?.messages.map(\.id), [validUser.id])
        XCTAssertEqual(migrated.activeSession?.workState, ConversationWorkState())

        let migratedData = try Data(
            contentsOf: root.appendingPathComponent("current-session.json")
        )
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: migratedData) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["version"] as? Int, 4)
        XCTAssertNotNil(migratedObject["activeSessionID"])

        let secondLoad = try await SessionStore(root: root).loadState()
        XCTAssertEqual(secondLoad.activeSessionID, migrated.activeSessionID)
        XCTAssertEqual(secondLoad.activeSession?.messages.map(\.id), [validUser.id])
    }

    func testClearActiveSessionPreservesOtherSessionsAndStructuredState() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let first = try await store.createSession(title: "First")
        try await store.checkpointActiveSession(
            ConversationCheckpoint(messages: [.user("first")])
        )
        let second = try await store.createSession(
            title: "Second",
            workState: ConversationWorkState(goal: ConversationGoal(title: "Keep me"))
        )
        try await store.checkpointActiveSession(
            ConversationCheckpoint(
                messages: [.user("second")],
                workState: ConversationWorkState(goal: ConversationGoal(title: "Keep me"))
            )
        )

        let cleared = try await store.clearActiveSession()
        XCTAssertEqual(cleared?.id, second.id)
        XCTAssertEqual(cleared?.messages, [])
        XCTAssertEqual(cleared?.workState.goal?.title, "Keep me")
        let preservedFirst = try await store.session(id: first.id)
        XCTAssertEqual(preservedFirst.messages.map(\.content), ["first"])
    }

    func testForkDeepCopiesTranscriptAndStructuredStateWithoutQueuedInputs() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let source = try await store.createSession(title: "Investigate plugin host")
        let call = AgentToolCall(
            id: "call-fetch",
            name: "shell",
            arguments: #"{"command":"curl example.com"}"#
        )
        let event = AgentToolEvent(
            call: call,
            summary: "检查网络",
            status: .succeeded,
            output: [
                AgentToolOutputChunk(channel: .stdout, text: "HTTP 200")
            ],
            result: "ok",
            startedAt: .now,
            finishedAt: .now
        )
        let workState = ConversationWorkState(
            goal: ConversationGoal(title: "修复插件市场", status: .active),
            plan: [ConversationPlanStep(title: "复现", status: .completed)],
            todos: [ConversationTodoItem(title: "验证真机", status: .pending)]
        )
        var controls = ConversationControlState(interactionMode: .plan)
        _ = try controls.enqueue("继续验证")
        _ = try await store.checkpointSession(
            id: source.id,
            checkpoint: ConversationCheckpoint(
                messages: [
                    .user("市场打不开"),
                    .assistant("", toolCalls: [call], toolEvents: [event]),
                    .tool(callID: call.id, name: call.name, content: "ok")
                ],
                workState: workState,
                controlState: controls
            )
        )

        let fork = try await store.forkSession(id: source.id)
        let persistedSource = try await store.session(id: source.id)
        let stateAfterFork = try await store.loadState()
        XCTAssertEqual(fork.forkedFromSessionID, source.id)
        XCTAssertEqual(fork.title, "Investigate plugin host 副本")
        XCTAssertEqual(fork.messages.map(\.content), ["市场打不开", "", "ok"])
        XCTAssertEqual(fork.messages.map(\.createdAt), persistedSource.messages.map(\.createdAt))
        XCTAssertNotEqual(
            fork.messages.map(\.id),
            persistedSource.messages.map(\.id)
        )
        XCTAssertEqual(fork.messages[1].toolCalls, [call])
        XCTAssertNotEqual(
            fork.messages[1].toolEvents.first?.id,
            persistedSource.messages[1].toolEvents.first?.id
        )
        XCTAssertNotEqual(
            fork.messages[1].toolEvents.first?.output.first?.id,
            persistedSource.messages[1].toolEvents.first?.output.first?.id
        )
        XCTAssertEqual(fork.workState.goal?.title, workState.goal?.title)
        XCTAssertNotEqual(fork.workState.goal?.id, workState.goal?.id)
        XCTAssertNotEqual(fork.workState.plan.first?.id, workState.plan.first?.id)
        XCTAssertNotEqual(fork.workState.todos.first?.id, workState.todos.first?.id)
        XCTAssertEqual(fork.controlState.interactionMode, .plan)
        XCTAssertTrue(fork.controlState.queuedInputs.isEmpty)
        XCTAssertEqual(stateAfterFork.activeSessionID, fork.id)

        _ = try await store.clearActiveSession()
        let clearedFork = try await store.session(id: fork.id)
        let preservedSource = try await store.session(id: source.id)
        XCTAssertTrue(clearedFork.messages.isEmpty)
        XCTAssertEqual(
            preservedSource.messages.map(\.content),
            ["市场打不开", "", "ok"]
        )
    }

    func testArchiveRestoreAndActiveSelectionPersist() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let first = try await store.createSession(title: "First")
        _ = try await store.checkpointActiveSession(
            ConversationCheckpoint(messages: [.assistant("done")])
        )
        let second = try await store.createSession(title: "Second")

        let replacement = try await store.archiveSession(id: second.id)
        XCTAssertEqual(replacement, first.id)
        var state = try await SessionStore(root: root).loadState()
        XCTAssertEqual(state.activeSessionID, first.id)
        XCTAssertNotNil(state.sessions.first(where: { $0.id == second.id })?.archivedAt)

        do {
            _ = try await store.switchActiveSession(to: second.id)
            XCTFail("Archived sessions must be restored before opening")
        } catch let error as SessionStoreError {
            guard case .sessionArchived(second.id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let restored = try await store.restoreSession(id: second.id)
        let switched = try await store.switchActiveSession(to: second.id)
        XCTAssertNil(restored.archivedAt)
        XCTAssertEqual(switched.id, second.id)

        _ = try await store.archiveSession(id: first.id)
        _ = try await store.archiveSession(id: second.id)
        state = try await store.loadState()
        XCTAssertNil(state.activeSessionID)
        XCTAssertTrue(state.sessions.allSatisfy(\.isArchived))

        _ = try await store.restoreSession(id: first.id)
        let restoredState = try await store.loadState()
        XCTAssertEqual(restoredState.activeSessionID, first.id)
    }

    func testSearchMatchesTitlesAndLatestMessageBodyIncludingArchivedSessions() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionStore(root: root)
        let titleMatch = try await store.createSession(title: "Release Notes")
        _ = try await store.checkpointActiveSession(
            ConversationCheckpoint(messages: [.assistant("No matching body")])
        )
        let bodyMatch = try await store.createSession(title: "Diagnostics")
        _ = try await store.checkpointActiveSession(
            ConversationCheckpoint(
                messages: [.assistant("Plugin market certificate FETCH failed on device")]
            )
        )
        let archivedMatch = try await store.createSession(title: "Older diagnostics")
        _ = try await store.checkpointActiveSession(
            ConversationCheckpoint(messages: [.assistant("A previous fetch failed request")])
        )
        _ = try await store.archiveSession(id: archivedMatch.id)

        let titleResults = try await store.searchSessions(query: "release")
        XCTAssertEqual(titleResults.map(\.session.id), [titleMatch.id])
        XCTAssertTrue(try XCTUnwrap(titleResults.first).titleMatched)

        let bodyResults = try await store.searchSessions(query: "fetch FAILED")
        let activeBodyResults = try await store.searchSessions(
            query: "fetch failed",
            includeArchived: false
        )
        XCTAssertEqual(Set(bodyResults.map(\.session.id)), [bodyMatch.id, archivedMatch.id])
        XCTAssertTrue(bodyResults.allSatisfy { $0.titleMatched == false })
        XCTAssertTrue(bodyResults.allSatisfy { $0.matchSnippet?.localizedCaseInsensitiveContains("fetch failed") == true })
        XCTAssertEqual(Set(activeBodyResults.map(\.session.id)), [bodyMatch.id])
    }

    func testMigratesVersion3SessionsWithArchiveAndForkDefaults() async throws {
        struct LegacySession: Encodable {
            let id: UUID
            let title: String
            let messages: [AgentMessage]
            let workState: ConversationWorkState
            let controlState: ConversationControlState
            let createdAt: Date
            let updatedAt: Date
            let revision: Int
        }
        struct LegacySnapshot: Encodable {
            let version: Int
            let activeSessionID: UUID?
            let sessions: [LegacySession]
            let updatedAt: Date
        }

        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(
            LegacySnapshot(
                version: 3,
                activeSessionID: id,
                sessions: [
                    LegacySession(
                        id: id,
                        title: "Version 3",
                        messages: [.assistant("migrate")],
                        workState: ConversationWorkState(),
                        controlState: ConversationControlState(),
                        createdAt: now,
                        updatedAt: now,
                        revision: 2
                    )
                ],
                updatedAt: now
            )
        )
        .write(to: root.appendingPathComponent("current-session.json"))

        let migrated = try await SessionStore(root: root).loadState()
        XCTAssertEqual(migrated.activeSessionID, id)
        XCTAssertNil(migrated.activeSession?.archivedAt)
        XCTAssertNil(migrated.activeSession?.forkedFromSessionID)

        let data = try Data(contentsOf: root.appendingPathComponent("current-session.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 4)
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessSessionTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeInboxURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessIntentInboxTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("app-intent-inbox.json")
    }
}
