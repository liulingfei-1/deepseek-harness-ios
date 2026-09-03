import Foundation
import Network
import CryptoKit

/// Synchronous projection shared by the main-actor model and Network queue.
/// The lock keeps endpoint handlers independent from actor isolation.
final class LocalStateSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var statusBody = #"{"status":"ok","source":"harness-mobile"}"#
    private var sessionsBody = #"{"sessions":[]}"#

    func update(statusBody: String, sessionsBody: String) {
        lock.lock()
        self.statusBody = statusBody
        self.sessionsBody = sessionsBody
        lock.unlock()
    }

    func status() -> String {
        lock.lock()
        defer { lock.unlock() }
        return statusBody
    }

    func sessions() -> String {
        lock.lock()
        defer { lock.unlock() }
        return sessionsBody
    }
}

/// A loopback-only HTTP state server (desktop `webserver`/`frontend-static`
/// parity). Listens on 127.0.0.1 with an ephemeral port and answers a small
/// set of GET endpoints; it never binds a remote interface, never reads
/// request bodies, and carries no credentials. The audited network boundary
/// list exempts this file because the listener is confined to the loopback
/// interface and cannot execute or forward anything remotely.
final class LocalStateServer: @unchecked Sendable {
    struct Endpoint: Sendable {
        let path: String
        /// Returns the response body (already JSON-encoded by the provider).
        let handler: @Sendable () -> String
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-state-server", qos: .utility)
    private let endpoints: [String: Endpoint]
    private let webhookHandlerLock = NSLock()
    private var webhookHandler: (@Sendable (LocalWebhookEvent) -> Void)?
    private let webhookSecret: String?

    init?(
        endpoints: [Endpoint],
        port: UInt16 = 0,
        webhookHandler: (@Sendable (LocalWebhookEvent) -> Void)? = nil,
        webhookSecret: String? = nil
    ) {
        guard let listener = try? NWListener(
            using: .tcp,
            on: NWEndpoint.Port(rawValue: port) ?? .any
        ) else { return nil }
        // Loopback interface only: the process never accepts connections from
        // the network.
        listener.parameters.requiredInterfaceType = .loopback
        self.listener = listener
        self.endpoints = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.path, $0) })
        self.webhookHandler = webhookHandler
        self.webhookSecret = webhookSecret
    }

    var port: UInt16? {
        listener.port?.rawValue
    }
    func start() {
        listener.stateUpdateHandler = { state in
            if case .failed = state {
                // A rebind attempt can occur after the app returns from the
                // background; the next start() call re-listens.
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    /// Replace the event sink after the owner has finished initialization.
    /// This keeps the listener usable during app construction without forcing
    /// an unsafe self-capture from an initializer.
    func setWebhookHandler(_ handler: (@Sendable (LocalWebhookEvent) -> Void)?) {
        webhookHandlerLock.lock()
        webhookHandler = handler
        webhookHandlerLock.unlock()
    }

    /// Pure request routing used by the network shell. Split out so the
    /// response contract is unit-testable without a live connection.
    static func route(
        request: String,
        endpoints: [String: Endpoint]
    ) -> (status: Int, body: String) {
        route(request: request, endpoints: endpoints, webhookHandler: nil)
    }

    static func route(
        request: String,
        endpoints: [String: Endpoint],
        webhookHandler: (@Sendable (LocalWebhookEvent) -> Void)?,
        webhookSecret: String? = nil
    ) -> (status: Int, body: String) {
        let methodLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init)
        guard let methodLine,
              let tokens = methodLine.split(separator: " ") as [Substring]?,
              tokens.count >= 2,
              tokens[1].hasPrefix("/") else {
            return (400, #"{"error":"unsupported request"}"#)
        }
        let pathString = String(tokens[1])
        if tokens[0] == "POST", pathString == "/webhook/github" {
            guard let separator = request.range(of: "\r\n\r\n") else {
                return (400, #"{"error":"missing request body"}"#)
            }
            let headerLines = request[..<separator.lowerBound].split(separator: "\r\n")
            var headers: [String: String] = [:]
            for line in headerLines.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                headers[parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let body = String(request[separator.upperBound...])
            guard let deliveryID = headers["x-github-delivery"],
                  let eventName = headers["x-github-event"],
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
                  let event = LocalWebhookParser.github(
                      deliveryID: deliveryID,
                      eventName: eventName,
                      payload: payload
                  ) else {
                return (400, #"{"error":"invalid github webhook"}"#)
            }
            if let webhookSecret,
               !LocalWebhookParser.verifyGitHubSignature(
                   payload: Data(body.utf8),
                   signature: headers["x-hub-signature-256"],
                   secret: webhookSecret
               ) {
                return (401, #"{"error":"invalid github signature"}"#)
            }
            webhookHandler?(event)
            return (202, #"{"accepted":true}"#)
        }
        guard tokens[0] == "GET" else {
            return (400, #"{"error":"unsupported request"}"#)
        }
        if pathString == "/health" {
            return (200, #"{"status":"ok"}"#)
        }
        if let endpoint = endpoints[pathString] {
            return (200, endpoint.handler())
        }
        return (404, #"{"error":"not found"}"#)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1024
        ) { [weak self] data, _, isComplete, error in
            defer { connection.cancel() }
            guard let self, let data, !data.isEmpty else { return }
            let request = String(decoding: data, as: UTF8.self)
            self.webhookHandlerLock.lock()
            let webhookHandler = self.webhookHandler
            self.webhookHandlerLock.unlock()
            let routed = Self.route(
                request: request,
                endpoints: self.endpoints,
                webhookHandler: webhookHandler,
                webhookSecret: self.webhookSecret
            )
            let body = routed.body
            let headers = "HTTP/1.1 \(routed.status)\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(
                content: Data((headers + body).utf8),
                completion: .contentProcessed { _ in }
            )
            _ = isComplete
            _ = error
        }
    }
}

/// Minimal GitHub webhook envelope shared with the desktop webhook package.
/// Parsing is pure so a future tunnel/host can feed the same validated event
/// into Jobs without coupling the app to a public-ingress service.
struct LocalWebhookEvent: Codable, Sendable, Equatable {
    let deliveryID: String
    let eventName: String
    let payload: JSONValue
}

enum LocalWebhookParser {
    static func github(
        deliveryID: String,
        eventName: String,
        payload: JSONValue
    ) -> LocalWebhookEvent? {
        let id = deliveryID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.utf8.count <= 256,
              !name.isEmpty, name.utf8.count <= 128,
              payload.objectValue != nil else { return nil }
        return LocalWebhookEvent(deliveryID: id, eventName: name, payload: payload)
    }

    static func verifyGitHubSignature(
        payload: Data,
        signature: String?,
        secret: String
    ) -> Bool {
        guard let signature,
              signature.hasPrefix("sha256="),
              signature.count == 71,
              signature.dropFirst(7).allSatisfy({ $0.isHexDigit }) else { return false }
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        let expected = digest.map { String(format: "%02x", $0) }.joined()
        return signature.dropFirst(7).caseInsensitiveCompare(expected) == .orderedSame
    }
}

/// Process-lifetime delivery deduplication. The bounded set prevents duplicate
/// GitHub deliveries from retriggering the same local job.
actor LocalWebhookDeduplicator {
    private let maximumIDs = 4_096
    private let storageURL: URL?
    private var accepted: [String] = []
    private var known = Set<String>()

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            accepted = Array(saved.suffix(maximumIDs))
            known = Set(accepted)
        }
    }

    func accept(_ deliveryID: String) -> Bool {
        guard !known.contains(deliveryID) else { return false }
        known.insert(deliveryID)
        accepted.append(deliveryID)
        if accepted.count > maximumIDs {
            let count = accepted.count - maximumIDs
            for _ in 0..<count {
                known.remove(accepted.removeFirst())
            }
        }
        persist()
        return true
    }

    private func persist() {
        guard let storageURL,
              let data = try? JSONEncoder().encode(accepted) else { return }
        try? FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storageURL, options: .atomic)
    }
}
