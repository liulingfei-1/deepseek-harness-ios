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
            .init(path: "/status", handler: { #"{"status":"live","turns":7}"# })
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
        do {
            _ = try await LocalStateHTTPClient(port: assignedPort).get(path: "status")
            XCTFail("relative paths must be rejected")
        } catch let error as LocalStateHTTPError {
            XCTAssertEqual(error, .invalidPath)
        }
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
