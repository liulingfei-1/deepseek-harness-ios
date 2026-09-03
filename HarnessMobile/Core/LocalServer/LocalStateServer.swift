import Foundation
import Network

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

    init?(endpoints: [Endpoint], port: UInt16 = 0) {
        guard let listener = try? NWListener(
            using: .tcp,
            on: NWEndpoint.Port(rawValue: port) ?? .any
        ) else { return nil }
        // Loopback interface only: the process never accepts connections from
        // the network.
        listener.parameters.requiredInterfaceType = .loopback
        self.listener = listener
        self.endpoints = Dictionary(uniqueKeysWithValues: endpoints.map { ($0.path, $0) })
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

    /// Pure request routing used by the network shell. Split out so the
    /// response contract is unit-testable without a live connection.
    static func route(
        request: String,
        endpoints: [String: Endpoint]
    ) -> (status: Int, body: String) {
        let methodLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init)
        guard let methodLine,
              let tokens = methodLine.split(separator: " ") as [Substring]?,
              tokens.count >= 2,
              tokens[0] == "GET",
              tokens[1].hasPrefix("/") else {
            return (400, #"{"error":"unsupported request"}"#)
        }
        let pathString = String(tokens[1])
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
            let routed = Self.route(request: request, endpoints: self.endpoints)
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
}

/// Process-lifetime delivery deduplication. The bounded set prevents duplicate
/// GitHub deliveries from retriggering the same local job.
actor LocalWebhookDeduplicator {
    private let maximumIDs = 4_096
    private var accepted: [String] = []
    private var known = Set<String>()

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
        return true
    }
}
