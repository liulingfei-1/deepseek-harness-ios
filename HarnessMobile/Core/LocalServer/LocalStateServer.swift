import Foundation
import Network
import CryptoKit

struct LocalStateAPIController: Codable, Sendable, Equatable {
    let name: String
    let methods: [String]
}

struct LocalStateAPISchema: Codable, Sendable, Equatable {
    static let currentVersion = 1
    let version: Int
    let transport: String
    let controllers: [LocalStateAPIController]

    static let current = LocalStateAPISchema(
        version: currentVersion,
        transport: "loopback-http",
        controllers: [
            LocalStateAPIController(
                name: "session",
                methods: [
                    "list", "status", "create", "select", "switch", "rename",
                    "delete", "archive", "restore", "fork", "prompt", "cancel", "follow"
                ]
            ),
            LocalStateAPIController(
                name: "settings",
                methods: [
                    "schema", "describe", "provider/list", "provider/active",
                    "provider/activate", "provider/remove", "mutate", "update", "replace"
                ]
            ),
            LocalStateAPIController(
                name: "workspace",
                methods: [
                    "schema", "list", "files", "mounts",
                    "mount/setAccess", "mount/remove", "create", "rename", "delete",
                    "insertBefore", "insertSessionBefore", "archiveSession"
                ]
            )
        ]
    )

    static func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(current) else {
            return #"{"version":1,"transport":"loopback-http","controllers":[]}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}

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

/// Late-bound bridge avoids capturing AppModel before its initializer has
/// finished while still allowing the network queue to await main-actor RPCs.
final class LocalStateRPCBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: LocalStateServer.AsyncRPCHandler?

    func setHandler(_ handler: LocalStateServer.AsyncRPCHandler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        let handler = snapshotHandler()
        guard let handler else {
            throw LocalStateRPCError.methodNotFound(method)
        }
        return try await handler(method, payload)
    }

    func openStream(
        _ method: String,
        _ payload: JSONValue
    ) async throws -> AsyncThrowingStream<JSONValue, Error> {
        let handler = snapshotStreamHandler()
        guard let handler else {
            throw LocalStateRPCError.methodNotFound(method)
        }
        return try await handler(method, payload)
    }

    func setStreamHandler(
        _ handler: (@Sendable (String, JSONValue) async throws -> AsyncThrowingStream<JSONValue, Error>)?
    ) {
        lock.lock()
        streamHandler = handler
        lock.unlock()
    }

    private nonisolated func snapshotHandler() -> LocalStateServer.AsyncRPCHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private nonisolated func snapshotStreamHandler()
        -> (@Sendable (String, JSONValue) async throws -> AsyncThrowingStream<JSONValue, Error>)? {
        lock.lock()
        defer { lock.unlock() }
        return streamHandler
    }

    private var streamHandler: (@Sendable (String, JSONValue) async throws -> AsyncThrowingStream<JSONValue, Error>)?
}

/// A loopback-only HTTP state server (desktop `webserver`/`frontend-static`
/// parity). Listens on 127.0.0.1 with an ephemeral port and answers a small
/// set of GET endpoints; it never binds a remote interface, never reads
/// request bodies, and carries no credentials. The audited network boundary
/// list exempts this file because the listener is confined to the loopback
/// interface and cannot execute or forward anything remotely.
final class LocalStateServer: @unchecked Sendable {
    typealias RPCHandler = @Sendable (_ method: String, _ payload: JSONValue) throws -> JSONValue
    typealias AsyncRPCHandler = @Sendable (_ method: String, _ payload: JSONValue) async throws -> JSONValue
    typealias StreamRPCHandler = @Sendable (_ method: String, _ payload: JSONValue) async throws
        -> AsyncThrowingStream<JSONValue, Error>

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
    private var webhookSecret: String?
    private let rpcHandler: RPCHandler?
    private let asyncRPCHandler: AsyncRPCHandler?
    private let streamRPCHandler: StreamRPCHandler?

    init?(
        endpoints: [Endpoint],
        port: UInt16 = 0,
        webhookHandler: (@Sendable (LocalWebhookEvent) -> Void)? = nil,
        webhookSecret: String? = nil,
        rpcHandler: RPCHandler? = nil,
        asyncRPCHandler: AsyncRPCHandler? = nil,
        streamRPCHandler: StreamRPCHandler? = nil
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
        self.rpcHandler = rpcHandler
        self.asyncRPCHandler = asyncRPCHandler
        self.streamRPCHandler = streamRPCHandler
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

    func setWebhookSecret(_ secret: String?) {
        webhookHandlerLock.lock()
        webhookSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        webhookSecret: String? = nil,
        rpcHandler: RPCHandler? = nil
    ) -> (status: Int, body: String) {
        let methodLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init)
        guard let methodLine,
              let tokens = methodLine.split(separator: " ") as [Substring]?,
              tokens.count >= 2,
              tokens[1].hasPrefix("/") else {
            return (400, #"{"error":"unsupported request"}"#)
        }
        let pathString = String(tokens[1])
        if tokens[0] == "POST", pathString.hasPrefix("/webhook/") {
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
            let pathComponents = pathString.split(separator: "/")
            guard pathComponents.count == 2 else {
                return (404, #"{"error":"not found"}"#)
            }
            let providerKind = String(pathComponents[1]).lowercased()
            guard let deliveryID = headers[providerKind == "github" ? "x-github-delivery" : "x-webhook-delivery"]
                    ?? headers["x-github-delivery"],
                  let eventName = headers[providerKind == "github" ? "x-github-event" : "x-webhook-event"]
                    ?? headers["x-github-event"],
                  let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
                  let event = LocalWebhookParser.parse(
                      providerKind: providerKind,
                      deliveryID: deliveryID,
                      eventName: eventName,
                      payload: payload
                  ) else {
                return (400, #"{"error":"invalid github webhook"}"#)
            }
            if providerKind == "github", let webhookSecret,
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
        if tokens[0] == "POST", pathString == "/api" {
            guard let separator = request.range(of: "\r\n\r\n"),
                  let message = try? JSONDecoder().decode(
                      [String: JSONValue].self,
                      from: Data(request[separator.upperBound...].utf8)
                  ),
                  message["type"]?.stringValue == "client-request",
                  let rpcID = message["rpcId"]?.stringValue,
                  let method = message["method"]?.stringValue,
                  !rpcID.isEmpty,
                  !method.isEmpty else {
                return Self.rpcErrorResponse(
                    rpcID: nil,
                    code: "gateway/invalid-request",
                    message: "invalid RPC request"
                )
            }
            guard let rpcHandler else {
                return Self.rpcErrorResponse(
                    rpcID: rpcID,
                    code: "gateway/not-found",
                    message: "RPC method is not registered"
                )
            }
            do {
                return Self.rpcSuccessResponse(
                    rpcID: rpcID,
                    value: try rpcHandler(method, message["payload"] ?? .null)
                )
            } catch {
                return Self.rpcErrorResponse(
                    rpcID: rpcID,
                    code: "gateway/internal",
                    message: error.localizedDescription
                )
            }
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
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var requestData = buffer
            requestData.append(data)
            guard requestData.count <= 64 * 1024 else {
                connection.cancel()
                return
            }
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = requestData.range(of: separator) else {
                if !isComplete { self.receiveRequest(on: connection, buffer: requestData) }
                else { connection.cancel() }
                return
            }
            let headerData = requestData[..<headerEnd.lowerBound]
            let headerText = String(decoding: headerData, as: UTF8.self)
            let contentLength = headerText
                .split(separator: "\r\n")
                .dropFirst()
                .compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2,
                          parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            .caseInsensitiveCompare("Content-Length") == .orderedSame else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .first ?? 0
            let bodyStart = headerEnd.upperBound
            guard requestData.count >= bodyStart + contentLength else {
                if !isComplete { self.receiveRequest(on: connection, buffer: requestData) }
                else { connection.cancel() }
                return
            }
            let request = String(decoding: requestData, as: UTF8.self)
            self.webhookHandlerLock.lock()
            let webhookHandler = self.webhookHandler
            let webhookSecret = self.webhookSecret
            self.webhookHandlerLock.unlock()
            if let streamRPCHandler = self.streamRPCHandler,
               let rpcRequest = Self.rpcRequest(in: request),
               rpcRequest.method == "session/follow" || rpcRequest.method == "workspace/follow" {
                self.stream(rpcRequest, using: streamRPCHandler, on: connection)
                return
            }
            if let asyncRPCHandler = self.asyncRPCHandler,
               let rpcRequest = Self.rpcRequest(in: request) {
                Task {
                    let routed: (status: Int, body: String)
                    do {
                        routed = Self.rpcSuccessResponse(
                            rpcID: rpcRequest.rpcID,
                            value: try await asyncRPCHandler(rpcRequest.method, rpcRequest.payload)
                        )
                    } catch {
                        routed = Self.rpcErrorResponse(
                            rpcID: rpcRequest.rpcID,
                            code: "gateway/internal",
                            message: error.localizedDescription
                        )
                    }
                    Self.send(routed, on: connection)
                }
                return
            }
            let routed = Self.route(
                request: request,
                endpoints: self.endpoints,
                webhookHandler: webhookHandler,
                webhookSecret: webhookSecret,
                rpcHandler: self.rpcHandler
            )
            let body = routed.body
            let headers = "HTTP/1.1 \(routed.status)\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(
                content: Data((headers + body).utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
            _ = error
        }
    }

    private func stream(
        _ request: (rpcID: String, method: String, payload: JSONValue),
        using handler: @escaping StreamRPCHandler,
        on connection: NWConnection
    ) {
        let task = Task {
            do {
                let frames = try await handler(request.method, request.payload)
                try await Self.sendStreamHeaders(on: connection)
                for try await frame in frames {
                    try Task.checkCancellation()
                    let value = Self.rpcSuccessResponse(rpcID: request.rpcID, value: frame)
                    try await Self.sendSSE(value.body, on: connection)
                }
                try await Self.sendChunk("0\r\n\r\n", on: connection)
                connection.cancel()
            } catch {
                connection.cancel()
            }
        }
        connection.stateUpdateHandler = { state in
            if case .failed = state { task.cancel() }
            if case .cancelled = state { task.cancel() }
        }
    }

    private static func sendStreamHeaders(on connection: NWConnection) async throws {
        let headers = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "Connection: keep-alive\r\n\r\n"
        try await sendChunk(headers, on: connection, includeChunkFraming: false)
    }

    private static func sendSSE(_ body: String, on connection: NWConnection) async throws {
        let escaped = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "data: \($0)" }
            .joined(separator: "\n")
        try await sendChunk("\(escaped)\n\n", on: connection)
    }

    private static func sendChunk(
        _ text: String,
        on connection: NWConnection,
        includeChunkFraming: Bool = true
    ) async throws {
        let data: Data
        if includeChunkFraming {
            let payload = Data(text.utf8)
            data = Data("\(String(payload.count, radix: 16))\r\n".utf8) + payload + Data("\r\n".utf8)
        } else {
            data = Data(text.utf8)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private static func send(_ routed: (status: Int, body: String), on connection: NWConnection) {
        let body = routed.body
        let headers = "HTTP/1.1 \(routed.status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(
            content: Data((headers + body).utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private static func rpcRequest(in request: String) -> (rpcID: String, method: String, payload: JSONValue)? {
        guard request.hasPrefix("POST /api "),
              let separator = request.range(of: "\r\n\r\n"),
              let message = try? JSONDecoder().decode(
                  [String: JSONValue].self,
                  from: Data(request[separator.upperBound...].utf8)
              ),
              message["type"]?.stringValue == "client-request",
              let rpcID = message["rpcId"]?.stringValue,
              let method = message["method"]?.stringValue,
              !rpcID.isEmpty,
              !method.isEmpty else {
            return nil
        }
        return (rpcID, method, message["payload"] ?? .null)
    }

    private static func rpcSuccessResponse(rpcID: String, value: JSONValue) -> (status: Int, body: String) {
        encodeRPC(.object([
            "type": .string("server-response"),
            "rpcId": .string(rpcID),
            "result": .object(["ok": .bool(true), "value": value])
        ]))
    }

    private static func rpcErrorResponse(rpcID: String?, code: String, message: String) -> (status: Int, body: String) {
        var response: [String: JSONValue] = [
            "type": .string("server-response"),
            "result": .object([
                "ok": .bool(false),
                "error": .object([
                    "code": .string(code),
                    "message": .string(message),
                    "details": .object([:])
                ])
            ])
        ]
        if let rpcID { response["rpcId"] = .string(rpcID) }
        return encodeRPC(.object(response))
    }

    private static func encodeRPC(_ value: JSONValue) -> (status: Int, body: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return (500, #"{"error":"serialization failure"}"#)
        }
        return (200, String(decoding: data, as: UTF8.self))
    }
}

enum LocalStateHTTPError: Error, Sendable, Equatable {
    case invalidPath
    case invalidResponse
    case server(status: Int, body: String)
}

enum LocalStateRPCError: LocalizedError, Sendable, Equatable {
    case methodNotFound(String)
    case invalidProjection
    case invalidPayload(String)

    var errorDescription: String? {
        switch self {
        case let .methodNotFound(method): return "RPC method not found: \(method)"
        case .invalidProjection: return "RPC projection is invalid."
        case let .invalidPayload(field): return "RPC payload field is invalid: \(field)"
        }
    }
}

/// Client seam used by native integrations and tests to exercise the actual
/// loopback listener rather than only the pure router.
struct LocalStateHTTPClient: Sendable {
    let baseURL: URL

    init(port: UInt16) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func get(path: String) async throws -> String {
        try await request(path: path, method: "GET", body: nil, headers: [:])
    }

    func post(path: String, body: String, headers: [String: String] = [:]) async throws -> String {
        try await request(path: path, method: "POST", body: Data(body.utf8), headers: headers)
    }

    func callRPC(
        rpcID: String = UUID().uuidString.lowercased(),
        method: String,
        payload: JSONValue = .object([:])
    ) async throws -> JSONValue {
        let body = try JSONEncoder().encode([
            "type": JSONValue.string("client-request"),
            "rpcId": JSONValue.string(rpcID),
            "method": JSONValue.string(method),
            "payload": payload
        ])
        let response = try await post(
            path: "/api",
            body: String(decoding: body, as: UTF8.self)
        )
        guard let data = response.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: data),
              envelope.objectValue?["type"]?.stringValue == "server-response",
              envelope.objectValue?["rpcId"]?.stringValue == rpcID,
              let result = envelope.objectValue?["result"] else {
            throw LocalStateHTTPError.invalidResponse
        }
        guard result.objectValue?["ok"]?.booleanValue == true,
              let value = result.objectValue?["value"] else {
            let message = result.objectValue?["error"]?.objectValue?["message"]?.stringValue ?? "RPC failed"
            throw LocalStateHTTPError.server(status: 200, body: message)
        }
        return value
    }

    /// Consumes the SSE form of a streaming RPC. Each yielded value is the
    /// decoded `value` from a correlated server-response envelope.
    func callRPCStream(
        rpcID: String = UUID().uuidString.lowercased(),
        method: String,
        payload: JSONValue = .object([:])
    ) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode([
                        "type": JSONValue.string("client-request"),
                        "rpcId": JSONValue.string(rpcID),
                        "method": JSONValue.string(method),
                        "payload": payload
                    ])
                    var request = URLRequest(url: baseURL.appendingPathComponent("api"))
                    request.httpMethod = "POST"
                    request.httpBody = body
                    request.timeoutInterval = 86_400
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw LocalStateHTTPError.invalidResponse
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let data = Data(line.dropFirst(6).utf8)
                        guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: data),
                              envelope.objectValue?["type"]?.stringValue == "server-response",
                              envelope.objectValue?["rpcId"]?.stringValue == rpcID,
                              let result = envelope.objectValue?["result"] else {
                            throw LocalStateHTTPError.invalidResponse
                        }
                        guard result.objectValue?["ok"]?.booleanValue == true,
                              let value = result.objectValue?["value"] else {
                            throw LocalStateHTTPError.invalidResponse
                        }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func request(
        path: String,
        method: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> String {
        guard path.first == "/", !path.contains("?"), !path.contains("#") else {
            throw LocalStateHTTPError.invalidPath
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalStateHTTPError.invalidResponse
        }
        let body = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(http.statusCode) else {
            throw LocalStateHTTPError.server(status: http.statusCode, body: body)
        }
        return body
    }
}

/// Minimal GitHub webhook envelope shared with the desktop webhook package.
/// Parsing is pure so a future tunnel/host can feed the same validated event
/// into Jobs without coupling the app to a public-ingress service.
struct LocalWebhookEvent: Codable, Sendable, Equatable {
    let providerKind: String
    let deliveryID: String
    let eventName: String
    let payload: JSONValue

    init(
        providerKind: String = "github",
        deliveryID: String,
        eventName: String,
        payload: JSONValue
    ) {
        self.providerKind = providerKind
        self.deliveryID = deliveryID
        self.eventName = eventName
        self.payload = payload
    }
}

enum LocalWebhookParser {
    static func parse(
        providerKind: String,
        deliveryID: String,
        eventName: String,
        payload: JSONValue
    ) -> LocalWebhookEvent? {
        let provider = providerKind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let id = deliveryID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, provider.utf8.count <= 64,
              !id.isEmpty, id.utf8.count <= 256,
              !name.isEmpty, name.utf8.count <= 128,
              payload.objectValue != nil else { return nil }
        return LocalWebhookEvent(
            providerKind: provider,
            deliveryID: id,
            eventName: name,
            payload: payload
        )
    }

    static func github(
        deliveryID: String,
        eventName: String,
        payload: JSONValue
    ) -> LocalWebhookEvent? {
        parse(
            providerKind: "github",
            deliveryID: deliveryID,
            eventName: eventName,
            payload: payload
        )
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

    func claim(_ deliveryID: String) -> Bool {
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

    /// Marks a claimed delivery as durably handled. Kept separate from claim
    /// so a failed Job admission can safely be retried by the sender.
    func complete(_: String) { persist() }

    /// Releases a claim after admission failed; the next delivery may retry.
    func requeue(_ deliveryID: String) {
        guard known.remove(deliveryID) != nil else { return }
        accepted.removeAll { $0 == deliveryID }
        persist()
    }

    /// Backwards-compatible one-shot API for callers that do not need retry.
    func accept(_ deliveryID: String) -> Bool { claim(deliveryID) }

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

/// Projects the workspace controller baseline/increment vocabulary from the
/// existing durable workspace projection. The polling caller supplies the
/// previous full projection so reconnects remain snapshot-first.
func workspaceFollowFrames(previous: JSONValue?, current: JSONValue) -> [JSONValue] {
    guard let currentObject = current.objectValue,
          case let .array(currentWorkspaces)? = currentObject["workspaces"],
          case let .array(currentArchived)? = currentObject["archivedSessionIds"] else {
        return []
    }

    func workspaceView(_ value: JSONValue) -> JSONValue? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue else { return nil }
        var view = object
        view.removeValue(forKey: "id")
        view["workspaceId"] = .string(id)
        return .object(view)
    }

    let currentViews = currentWorkspaces.compactMap(workspaceView)
    let currentByID = Dictionary(uniqueKeysWithValues: currentViews.compactMap { value in
        value.objectValue?["workspaceId"]?.stringValue.map { ($0, value) }
    })
    let currentOrder = currentViews.compactMap { $0.objectValue?["workspaceId"]?.stringValue }
    let baseline = JSONValue.object([
        "items": .array(currentViews),
        "archivedSessionIds": .array(currentArchived)
    ])

    guard let previous,
          let previousObject = previous.objectValue,
          case let .array(previousWorkspaces)? = previousObject["workspaces"],
          case let .array(previousArchived)? = previousObject["archivedSessionIds"] else {
        return [.object(["type": .string("baseline"), "value": baseline])]
    }

    let previousViews = previousWorkspaces.compactMap(workspaceView)
    let previousByID = Dictionary(uniqueKeysWithValues: previousViews.compactMap { value in
        value.objectValue?["workspaceId"]?.stringValue.map { ($0, value) }
    })
    let previousOrder = previousViews.compactMap { $0.objectValue?["workspaceId"]?.stringValue }
    var frames: [JSONValue] = []
    for value in currentViews {
        guard let id = value.objectValue?["workspaceId"]?.stringValue,
              previousByID[id] != value else { continue }
        frames.append(.object(["type": .string("upsert"), "workspace": value]))
    }
    for id in previousByID.keys where currentByID[id] == nil {
        frames.append(.object(["type": .string("remove"), "workspaceId": .string(id)]))
    }
    if currentOrder != previousOrder {
        frames.append(.object([
            "type": .string("order"),
            "workspaceIds": .array(currentOrder.map(JSONValue.string))
        ]))
    }
    if currentArchived != previousArchived {
        frames.append(.object([
            "type": .string("archived"),
            "archivedSessionIds": .array(currentArchived)
        ]))
    }
    return frames
}
