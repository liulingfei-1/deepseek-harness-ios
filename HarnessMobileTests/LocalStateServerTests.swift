import Foundation
import CryptoKit
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the loopback state-server contract at the routing layer (pure,
/// no live connection): GET health/status/unknown paths, non-GET and
/// malformed requests. The network shell itself is exercised on-device
/// through the audited loopback listener.
final class LocalStateServerTests: XCTestCase {
    private func makeEndpoints() -> [String: LocalStateServer.Endpoint] {
        [
            "/status": LocalStateServer.Endpoint(path: "/status", handler: { #"{"status":"ok","turns":3}"# })
        ]
    }

    func testRouteServesHealthAndStatusEndpoints() {
        let endpoints = makeEndpoints()
        let health = LocalStateServer.route(
            request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: endpoints
        )
        XCTAssertEqual(health.status, 200)
        XCTAssertTrue(health.body.contains(#""status":"ok""#))

        let status = LocalStateServer.route(
            request: "GET /status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: endpoints
        )
        XCTAssertEqual(status.status, 200)
        XCTAssertTrue(status.body.contains("turns"))

        let head = LocalStateServer.route(
            request: "HEAD /status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: endpoints
        )
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.body, "")
    }

    func testAPISchemaAndSessionAliasExposeControllerSurface() throws {
        let schema = LocalStateServer.route(
            request: "GET /api/schema HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: [
                "/api/schema": .init(path: "/api/schema", handler: { LocalStateAPISchema.json() }),
                "/api/session": .init(path: "/api/session", handler: { #"{"sessions":[{"id":"one"}]}"# })
            ]
        )
        XCTAssertEqual(schema.status, 200)
        let decoded = try JSONDecoder().decode(
            LocalStateAPISchema.self,
            from: Data(schema.body.utf8)
        )
        XCTAssertEqual(decoded.version, LocalStateAPISchema.currentVersion)
        XCTAssertEqual(decoded.transport, "loopback-http")
        XCTAssertTrue(decoded.controllers.contains {
            $0.name == "session"
                && $0.methods.contains("list")
                && $0.methods.contains("create")
                && $0.methods.contains("prompt")
        })

        let alias = LocalStateServer.route(
            request: "GET /api/session HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: [
                "/api/session": .init(path: "/api/session", handler: { #"{"sessions":[{"id":"one"}]}"# })
            ]
        )
        XCTAssertEqual(alias.status, 200)
        XCTAssertTrue(alias.body.contains("one"))
    }

    func testReferencedImageRequiresSessionEventReference() {
        let id = UUID()
        let ref = AgentImageAttachmentRef(
            id: id,
            path: "Attachments/\(id.uuidString).png",
            mimeType: "image/png",
            byteCount: 3
        )
        let event = try? SessionEvent(
            type: SessionEventVocabulary.userMessage,
            seq: 0,
            time: 0,
            data: .object([
                "imageAttachments": .array([
                    .object([
                        "id": .string(id.uuidString.lowercased()),
                        "path": .string(ref.path),
                        "mimeType": .string(ref.mimeType),
                        "byteCount": .number(3)
                    ])
                ])
            ])
        )
        XCTAssertEqual(localReferencedImage(in: [event].compactMap { $0 }, attachmentID: id), ref)
        XCTAssertNil(localReferencedImage(in: [event].compactMap { $0 }, attachmentID: UUID()))
    }

    func testSessionControlFramesEmitBaselineAndQueueReplacement() throws {
        let sessionID = UUID()
        let summary = ConversationSessionSummary(
            id: sessionID,
            title: "control",
            messageCount: 0,
            createdAt: .now,
            updatedAt: .now,
            revision: 0,
            archivedAt: nil,
            forkedFromSessionID: nil,
            queuedInputCount: 1,
            isResumable: true
        )
        let identity = RunIdentity(sessionID: sessionID, runID: UUID(), generation: 1)
        var presentation = SessionRunPresentation(identity: identity)
        presentation.queuedInputs = [try QueuedAgentInput(text: "next")]
        let run = SessionRunSnapshot(
            identity: identity,
            trajectorySessionID: sessionID,
            phase: .running,
            createdGeneration: 1,
            backgroundLeaseTokens: [],
            presentation: presentation
        )
        let baseline = localSessionControlBaseline(
            sessions: [summary],
            aggregate: SessionRunAggregateSnapshot(runs: [run])
        )
        XCTAssertEqual(baseline.objectValue?["type"], .string("baseline"))
        var emptyPresentation = SessionRunPresentation(identity: identity)
        emptyPresentation.queuedInputs = []
        let changed = localSessionControlBaseline(
            sessions: [summary],
            aggregate: SessionRunAggregateSnapshot(runs: [
                SessionRunSnapshot(
                    identity: identity,
                    trajectorySessionID: sessionID,
                    phase: .running,
                    createdGeneration: 1,
                    backgroundLeaseTokens: [],
                    presentation: emptyPresentation
                )
            ])
        )
        let frames = localSessionControlFrames(previous: baseline, current: changed)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].objectValue?["type"], .string("queue"))
        XCTAssertEqual(frames[0].objectValue?["sessionId"], .string(sessionID.uuidString.lowercased()))
    }

    func testRouteServesConnectionRPCEnvelopeAndCorrelatesID() throws {
        let request = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            + #"{"type":"client-request","rpcId":"rpc-1","method":"session/status","payload":{}}"#
        let result = LocalStateServer.route(
            request: request,
            endpoints: [:],
            webhookHandler: nil,
            rpcHandler: { method, _ in
                XCTAssertEqual(method, "session/status")
                return .object(["running": .bool(true)])
            }
        )
        XCTAssertEqual(result.status, 200)
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.body.utf8))
        XCTAssertEqual(value.objectValue?["type"]?.stringValue, "server-response")
        XCTAssertEqual(value.objectValue?["rpcId"]?.stringValue, "rpc-1")
        let ok = try XCTUnwrap(value.objectValue?["result"]?.objectValue?["ok"])
        XCTAssertEqual(ok, JSONValue.bool(true))
        let running = try XCTUnwrap(
            value.objectValue?["result"]?.objectValue?["value"]?.objectValue?["running"]
        )
        XCTAssertEqual(running, JSONValue.bool(true))
    }

    func testRPCSchemaAdvertisesProviderActivation() throws {
        let request = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            + #"{"type":"client-request","rpcId":"schema-1","method":"settings/schema","payload":{}}"#
        let result = LocalStateServer.route(
            request: request,
            endpoints: [:],
            webhookHandler: nil,
            rpcHandler: { method, _ in
                guard method == "settings/schema" else { throw LocalStateRPCError.methodNotFound(method) }
                return .object([
                    "methods": .array([.string("describe"), .string("provider/activate")])
                ])
            }
        )
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.body.utf8))
        let resultObject = try XCTUnwrap(value.objectValue?["result"]?.objectValue)
        XCTAssertEqual(resultObject["ok"], JSONValue.bool(true))
        let resultValue = try XCTUnwrap(resultObject["value"]?.objectValue)
        XCTAssertEqual(
            resultValue["methods"],
            JSONValue.array([.string("describe"), .string("provider/activate")])
        )
    }

    func testRPCSchemaAdvertisesControllerMutationsAndFollow() throws {
        let request = "POST /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            + #"{"type":"client-request","rpcId":"schema-2","method":"workspace/schema","payload":{}}"#
        let result = LocalStateServer.route(
            request: request,
            endpoints: [:],
            webhookHandler: nil,
            rpcHandler: { method, _ in
                guard method == "workspace/schema" else {
                    throw LocalStateRPCError.methodNotFound(method)
                }
                return .object([
                    "methods": .array([
                        .string("mount/setAccess"), .string("mount/remove"),
                        .string("session/follow"), .string("settings/mutate")
                    ])
                ])
            }
        )
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.body.utf8))
        let resultValue = try XCTUnwrap(
            value.objectValue?["result"]?.objectValue?["value"]?.objectValue
        )
        XCTAssertEqual(
            resultValue["methods"],
            JSONValue.array([
                .string("mount/setAccess"), .string("mount/remove"),
                .string("session/follow"), .string("settings/mutate")
            ])
        )
    }

    func testRouteReturns404ForUnknownPath() {
        let result = LocalStateServer.route(
            request: "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: makeEndpoints()
        )
        XCTAssertEqual(result.status, 404)
        XCTAssertTrue(result.body.contains("not found"))
    }

    func testRouteRejectsNonGetAndMalformedRequests() {
        let endpoints = makeEndpoints()
        let post = LocalStateServer.route(
            request: "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
            endpoints: endpoints
        )
        XCTAssertEqual(post.status, 400)

        let garbage = LocalStateServer.route(request: "garbage", endpoints: endpoints)
        XCTAssertEqual(garbage.status, 400)
    }

    func testServerBindsLoopbackAndReportsPort() {
        let server = LocalStateServer(endpoints: [
            .init(path: "/status", handler: { #"{"status":"ok"}"# })
        ])
        XCTAssertNotNil(server, "loopback listener must construct")
        server?.start()
        defer { server?.stop() }
        // The ephemeral port is assigned asynchronously once the listener
        // reaches its ready state; poll briefly instead of assuming it is
        // set synchronously after start().
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertGreaterThan(assignedPort, 0, "loopback listener must bind an ephemeral port")
    }

    func testLiveHTTPClientReadsLoopbackEndpoint() async throws {
        let server = LocalStateServer(endpoints: [
            .init(path: "/status", handler: { #"{"status":"live","turns":7}"# }),
            .init(path: "/sessions", handler: { #"{"sessions":[{"id":"session-live","running":true}]}"# })
        ])
        XCTAssertNotNil(server)
        server?.start()
        defer { server?.stop() }
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(assignedPort, 0)
        let body = try await LocalStateHTTPClient(port: assignedPort).get(path: "/status")
        XCTAssertTrue(body.contains(#""status":"live""#))
        let sessions = try await LocalStateHTTPClient(port: assignedPort).get(path: "/sessions")
        XCTAssertTrue(sessions.contains("session-live"))
        do {
            _ = try await LocalStateHTTPClient(port: assignedPort).get(path: "status")
            XCTFail("relative paths must be rejected")
        } catch let error as LocalStateHTTPError {
            XCTAssertEqual(error, .invalidPath)
        }
    }

    func testLiveHTTPClientAwaitsAsyncRPCHandler() async throws {
        let server = LocalStateServer(
            endpoints: [],
            asyncRPCHandler: { method, payload in
                XCTAssertEqual(method, "session/create")
                XCTAssertEqual(payload.objectValue?["title"]?.stringValue, "from-rpc")
                try await Task.sleep(for: .milliseconds(5))
                return .object(["accepted": .bool(true)])
            }
        )
        XCTAssertNotNil(server)
        server?.start()
        defer { server?.stop() }
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(assignedPort, 0)
        let value = try await LocalStateHTTPClient(port: assignedPort).callRPC(
            rpcID: "async-1",
            method: "session/create",
            payload: .object(["title": .string("from-rpc")])
        )
        XCTAssertEqual(value.objectValue?["accepted"], .bool(true))
    }

    func testLiveHTTPClientReceivesSnapshotFirstSSEStream() async throws {
        let server = LocalStateServer(
            endpoints: [],
            streamRPCHandler: { method, _ in
                XCTAssertEqual(method, "session/follow")
                return AsyncThrowingStream { continuation in
                    continuation.yield(.object(["type": .string("snapshot")]))
                    continuation.yield(.object(["type": .string("event")]))
                    continuation.finish()
                }
            }
        )
        XCTAssertNotNil(server)
        server?.start()
        defer { server?.stop() }
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(assignedPort, 0)
        let stream = LocalStateHTTPClient(port: assignedPort).callRPCStream(
            rpcID: "stream-1",
            method: "session/follow"
        )
        var values: [JSONValue] = []
        for try await value in stream { values.append(value) }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0].objectValue?["type"], .string("snapshot"))
        XCTAssertEqual(values[1].objectValue?["type"], .string("event"))
    }

    func testLiveHTTPClientReceivesSessionControlBaseline() async throws {
        let server = LocalStateServer(
            endpoints: [],
            streamRPCHandler: { method, _ in
                XCTAssertEqual(method, "session/control")
                return AsyncThrowingStream { continuation in
                    continuation.yield(.object([
                        "type": .string("baseline"),
                        "value": .object([
                            "queues": .object([:]),
                            "jobs": .object([:]),
                            "projections": .object([:])
                        ])
                    ]))
                    continuation.finish()
                }
            }
        )
        XCTAssertNotNil(server)
        server?.start()
        defer { server?.stop() }
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(assignedPort, 0)
        let stream = LocalStateHTTPClient(port: assignedPort).callRPCStream(
            rpcID: "control-1",
            method: "session/control"
        )
        var values: [JSONValue] = []
        for try await value in stream { values.append(value) }
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].objectValue?["type"], .string("baseline"))
    }

    func testLiveHTTPClientReconnectsAndResumesSessionCursor() async throws {
        let counter = ReconnectingStreamCounter()
        let server = LocalStateServer(
            endpoints: [],
            streamRPCHandler: { method, payload in
                XCTAssertEqual(method, "session/follow")
                let generation = await counter.next()
                let cursor = payload.objectValue?["sinceSequence"]?.numberValueForTests ?? 0
                return AsyncThrowingStream { continuation in
                    continuation.yield(.object([
                        "type": .string("snapshot"),
                        "generation": .number(Double(generation)),
                        "cursor": .number(cursor + 1)
                    ]))
                    continuation.finish()
                }
            }
        )
        XCTAssertNotNil(server)
        server?.start()
        defer { server?.stop() }
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(assignedPort, 0)
        let stream = LocalStateHTTPClient(port: assignedPort).callRPCStream(
            method: "session/follow",
            payload: .object(["sessionId": .string("session-1")]),
            reconnect: true,
            maximumReconnectAttempts: 1
        )
        var values: [JSONValue] = []
        for try await value in stream { values.append(value) }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.map { $0.objectValue?["generation"]?.numberValueForTests }, [1, 2])
        XCTAssertEqual(values.map { $0.objectValue?["cursor"]?.numberValueForTests }, [1, 2])
    }

    func testWorkspaceFollowFramesEmitBaselineAndOrderedIncrements() throws {
        let first = JSONValue.object([
            "workspaces": .array([
                .object(["id": .string("a"), "title": .string("A")]),
                .object(["id": .string("b"), "title": .string("B")])
            ]),
            "archivedSessionIds": .array([])
        ])
        let baseline = workspaceFollowFrames(previous: nil, current: first)
        XCTAssertEqual(baseline.count, 1)
        XCTAssertEqual(baseline[0].objectValue?["type"], JSONValue.string("baseline"))
        guard case let .array(items)? = baseline[0].objectValue?["value"]?.objectValue?["items"] else {
            return XCTFail("baseline must include workspace items")
        }
        XCTAssertEqual(items.count, 2)

        let second = JSONValue.object([
            "workspaces": .array([
                .object(["id": .string("b"), "title": .string("B2")]),
                .object(["id": .string("c"), "title": .string("C")])
            ]),
            "archivedSessionIds": .array([.string("session-1")])
        ])
        let increments = workspaceFollowFrames(previous: first, current: second)
        XCTAssertEqual(increments.map { $0.objectValue?["type"]?.stringValue }, ["upsert", "upsert", "remove", "order", "archived"])
        XCTAssertEqual(
            increments[0].objectValue?["workspace"]?.objectValue?["workspaceId"],
            JSONValue.string("b")
        )
        XCTAssertEqual(
            increments[1].objectValue?["workspace"]?.objectValue?["workspaceId"],
            JSONValue.string("c")
        )
        XCTAssertEqual(increments[2].objectValue?["workspaceId"], JSONValue.string("a"))
    }

    func testSessionPageIsMessageAlignedAndPacksRawWireEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-page-\(UUID().uuidString)", isDirectory: true)
        let repository = SessionTrajectoryRepository(root: root)
        let sessionID = UUID()
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.turnStart, data: .object(["turn": .number(1)])),
            sessionID: sessionID
        )
        _ = try await repository.append(
            SessionEventDraft(type: SessionEventVocabulary.userMessage, data: .string("hello")),
            sessionID: sessionID
        )
        for text in ["h", "i", "!"] {
            _ = try await repository.append(
                SessionEventDraft(
                    type: SessionEventVocabulary.assistantChunk,
                    data: .object([
                        "turn": .number(1), "step": .number(0),
                        "chunk": .object([
                            "type": .string("text-delta"), "index": .number(0), "text": .string(text)
                        ])
                    ])
                ),
                sessionID: sessionID
            )
        }
        _ = try await repository.append(
            SessionEventDraft(
                type: SessionEventVocabulary.assistantMessage,
                data: .string("hi"),
                sourceEventSeqs: [2, 3, 4]
            ),
            sessionID: sessionID
        )
        let events = try await repository.allEvents(sessionID: sessionID)
        let page = try localSessionPagePayload(
            sessionID: sessionID,
            events: events,
            throughSequence: 5,
            maxMessages: 1
        )
        guard case let .array(records)? = page.objectValue?["records"] else {
            return XCTFail("page must include records")
        }
        XCTAssertEqual(records.first?.objectValue?["type"], JSONValue.string("chunks"))
        XCTAssertEqual(records.first?.objectValue?["event"]?.objectValue?["type"], JSONValue.string("chunkrow/text-chunks"))
        XCTAssertEqual(records.last?.objectValue?["event"]?.objectValue?["seq"]?.numberValueForTests, 5)
        XCTAssertEqual(page.objectValue?["hasMore"], JSONValue.bool(true))

        let older = try localSessionPagePayload(
            sessionID: sessionID,
            events: events,
            throughSequence: 5,
            beforeSequence: 2,
            maxMessages: 1
        )
        if case let .array(olderRecords)? = older.objectValue?["records"] {
            XCTAssertEqual(olderRecords.count, 1)
        } else {
            XCTFail("older page must include records")
        }
        XCTAssertThrowsError(try localSessionPagePayload(
            sessionID: sessionID,
            events: events,
            throughSequence: 99
        ))
    }

    func testSessionSearchPayloadDeduplicatesAndBoundsSnippets() {
        let first = UUID()
        let second = UUID()
        let record = { (id: UUID, title: String) in
            SessionQuerySessionRecord(
                id: id, title: title, createdAt: 0, updatedAt: 1,
                indexedThroughSequence: 1, eventCount: 1, searchableEventCount: 1
            )
        }
        let hits = [
            SessionQuerySessionHit(session: record(first, "first"), matchCount: 2, matchedEventSequence: 1, snippet: String(repeating: "x", count: 300)),
            SessionQuerySessionHit(session: record(first, "first"), matchCount: 1, matchedEventSequence: 0, snippet: "duplicate"),
            SessionQuerySessionHit(session: record(second, "second"), matchCount: 1, matchedEventSequence: 2, snippet: "ok")
        ]
        let payload = localSessionSearchPayload(hits: hits, visibleSessionIDs: [first, second], limit: 1)
        guard case let .array(items)? = payload.objectValue?["items"] else {
            return XCTFail("search payload must contain items")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].objectValue?["snippet"]?.stringValue?.count, 240)
        XCTAssertEqual(payload.objectValue?["hasMore"], JSONValue.bool(true))
    }

    func testSessionModelCatalogPayloadExposesRoutableProfiles() {
        let profile = ProviderProfile.catalogDefault(for: .deepSeekOfficial)
        let payload = localSessionModelCatalogPayload(
            profiles: [profile],
            activeProfileID: profile.id
        )
        XCTAssertEqual(payload.objectValue?["default"]?.objectValue?["provider"], .string("deepseek-official"))
        guard case let .array(routable)? = payload.objectValue?["routableProviders"] else {
            return XCTFail("catalog must include routable providers")
        }
        XCTAssertEqual(routable, [.string("deepseek-official")])
        guard case let .array(groups)? = payload.objectValue?["groups"],
              let first = groups.first?.objectValue else {
            return XCTFail("catalog must include provider group")
        }
        XCTAssertEqual(first["id"], .string(profile.id))
        if case let .array(models)? = first["models"] {
            XCTAssertFalse(models.isEmpty)
        } else {
            XCTFail("catalog group must include models")
        }
    }

    func testLiveHTTPClientPostsWebhookAfterSecretIsConfigured() async throws {
        let server = LocalStateServer(endpoints: [])
        XCTAssertNotNil(server)
        server?.start()
        defer { server?.stop() }
        server?.setWebhookSecret("live-secret")
        var assignedPort: UInt16 = 0
        for _ in 0..<40 {
            if let port = server?.port, port > 0 {
                assignedPort = port
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(assignedPort, 0)
        let payload = #"{"action":"opened"}"#
        let key = SymmetricKey(data: Data("live-secret".utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        let response = try await LocalStateHTTPClient(port: assignedPort).post(
            path: "/webhook/github",
            body: payload,
            headers: [
                "X-GitHub-Delivery": "live-delivery",
                "X-GitHub-Event": "issues",
                "X-Hub-Signature-256": "sha256=\(signature)"
            ]
        )
        XCTAssertTrue(response.contains(#""accepted":true"#))
    }

    func testGitHubWebhookParserValidatesEnvelopeAndDeduplicates() async {
        let parsed = LocalWebhookParser.github(
            deliveryID: "delivery-1",
            eventName: "push",
            payload: .object(["ref": .string("refs/heads/main")])
        )
        XCTAssertEqual(parsed?.eventName, "push")
        XCTAssertNil(LocalWebhookParser.github(
            deliveryID: "",
            eventName: "push",
            payload: .object([:])
        ))

        let deduplicator = LocalWebhookDeduplicator()
        let first = await deduplicator.accept("delivery-1")
        let second = await deduplicator.accept("delivery-1")
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testProviderNeutralWebhookRouteAndRuleRegistryPersist() async throws {
        let payload: JSONValue = .object(["action": .string("created")])
        let event = try XCTUnwrap(LocalWebhookParser.parse(
            providerKind: "acme",
            deliveryID: "acme-1",
            eventName: "created",
            payload: payload
        ))
        let rule = try LocalWebhookRule(
            id: "acme-created",
            providerKind: "acme",
            eventName: "created",
            prompt: "处理 {event} {delivery} {payload}",
            maximumAttempts: 3,
            wakeActiveSession: true
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("webhook-rules-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("rules.json")
        let registry = LocalWebhookRuleRegistry(storageURL: url)
        try await registry.upsert(rule)
        let matching = await registry.matching(event)
        XCTAssertEqual(matching, [rule])
        let reloaded = LocalWebhookRuleRegistry(storageURL: url)
        let listed = await reloaded.list()
        XCTAssertEqual(listed, [rule])
        try? FileManager.default.removeItem(at: directory)
    }

    func testGenericWebhookRouteUsesWebhookHeaders() {
        nonisolated(unsafe) var received: LocalWebhookEvent?
        let result = LocalStateServer.route(
            request: "POST /webhook/acme HTTP/1.1\r\n"
                + "X-Webhook-Delivery: acme-2\r\n"
                + "X-Webhook-Event: created\r\n\r\n"
                + #"{"ok":true}"#,
            endpoints: [:],
            webhookHandler: { received = $0 }
        )
        XCTAssertEqual(result.status, 202)
        XCTAssertEqual(received?.providerKind, "acme")
        XCTAssertEqual(received?.eventName, "created")
    }

    func testWebhookDeduplicatorCanRequeueFailedAdmission() async {
        let deduplicator = LocalWebhookDeduplicator()
        let first = await deduplicator.claim("retry-me")
        XCTAssertTrue(first)
        let duplicate = await deduplicator.claim("retry-me")
        XCTAssertFalse(duplicate)
        await deduplicator.requeue("retry-me")
        let retried = await deduplicator.claim("retry-me")
        XCTAssertTrue(retried)
    }

    func testSnapshotStorePublishesConcurrentEndpointBodies() {
        let store = LocalStateSnapshotStore()
        store.update(
            statusBody: #"{"status":"ok","sessionCount":2}"#,
            sessionsBody: #"{"sessions":[{"id":"one"}]}"#
        )
        XCTAssertTrue(store.status().contains(#""sessionCount":2"#))
        XCTAssertTrue(store.sessions().contains(#""id":"one"#))
    }

    func testRouteAcceptsGitHubWebhookPostAndInvokesHandler() {
        nonisolated(unsafe) var received: LocalWebhookEvent?
        let request = "POST /webhook/github HTTP/1.1\r\n"
            + "X-GitHub-Delivery: delivery-2\r\n"
            + "X-GitHub-Event: issues\r\n"
            + "Content-Type: application/json\r\n\r\n"
            + #"{"action":"opened"}"#
        let result = LocalStateServer.route(
            request: request,
            endpoints: [:],
            webhookHandler: { received = $0 }
        )
        XCTAssertEqual(result.status, 202)
        XCTAssertEqual(received?.deliveryID, "delivery-2")
        XCTAssertEqual(received?.eventName, "issues")
    }

    func testWebhookDeduplicatorRestoresAcceptedIDsAfterReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageURL = directory.appendingPathComponent("deliveries.json")
        let first = LocalWebhookDeduplicator(storageURL: storageURL)
        let firstAcceptance = await first.accept("delivery-persisted")
        XCTAssertTrue(firstAcceptance)

        let reloaded = LocalWebhookDeduplicator(storageURL: storageURL)
        let duplicateAcceptance = await reloaded.accept("delivery-persisted")
        let newAcceptance = await reloaded.accept("delivery-new")
        XCTAssertFalse(duplicateAcceptance)
        XCTAssertTrue(newAcceptance)
    }

    func testRouteValidatesOptionalGitHubHMACSignature() {
        let body = #"{"action":"opened"}"#
        let key = SymmetricKey(data: Data("test-secret".utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: key)
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        let request = "POST /webhook/github HTTP/1.1\r\n"
            + "X-GitHub-Delivery: delivery-3\r\n"
            + "X-GitHub-Event: issues\r\n"
            + "X-Hub-Signature-256: sha256=\(signature)\r\n\r\n"
            + body
        let accepted = LocalStateServer.route(
            request: request,
            endpoints: [:],
            webhookHandler: nil,
            webhookSecret: "test-secret"
        )
        XCTAssertEqual(accepted.status, 202)

        let invalidSignature = (signature.first == "0" ? "1" : "0") + String(signature.dropFirst())
        let rejected = LocalStateServer.route(
            request: request.replacingOccurrences(of: signature, with: invalidSignature),
            endpoints: [:],
            webhookHandler: nil,
            webhookSecret: "test-secret"
        )
        XCTAssertEqual(rejected.status, 401)
    }
}

private actor ReconnectingStreamCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private extension JSONValue {
    var numberValueForTests: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }
}
