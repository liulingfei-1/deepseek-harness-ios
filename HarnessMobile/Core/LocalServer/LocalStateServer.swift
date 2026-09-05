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
                    "delete", "archive", "restore", "fork", "prompt", "cancel", "follow", "page", "search", "modelCatalog", "selectModel", "updateQueue", "attachment", "control"
                ]
            ),
            LocalStateAPIController(
                name: "skills",
                methods: ["list"]
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
    typealias BinaryUploadHandler = @Sendable (_ sessionID: String, _ name: String?, _ data: Data) async throws -> JSONValue

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
    private let binaryUploadHandler: BinaryUploadHandler?

    init?(
        endpoints: [Endpoint],
        port: UInt16 = 0,
        webhookHandler: (@Sendable (LocalWebhookEvent) -> Void)? = nil,
        webhookSecret: String? = nil,
        rpcHandler: RPCHandler? = nil,
        asyncRPCHandler: AsyncRPCHandler? = nil,
        streamRPCHandler: StreamRPCHandler? = nil,
        binaryUploadHandler: BinaryUploadHandler? = nil
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
        self.binaryUploadHandler = binaryUploadHandler
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
        guard tokens[0] == "GET" || tokens[0] == "HEAD" else {
            return (400, #"{"error":"unsupported request"}"#)
        }
        let isHead = tokens[0] == "HEAD"
        if pathString == "/health" {
            return (200, isHead ? "" : #"{"status":"ok"}"#)
        }
        if let endpoint = endpoints[pathString] {
            return (200, isHead ? "" : endpoint.handler())
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
            guard requestData.count <= 64 * 1024 * 1024 + 64 * 1024 else {
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
            let requestLine = headerText.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let requestTarget = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let isBinaryUpload = requestTarget.hasPrefix("/api/session/uploadFileBinary")
            let maximumBodyBytes = isBinaryUpload
                ? 64 * 1024 * 1024 + 64 * 1024
                : 64 * 1024
            guard contentLength <= maximumBodyBytes else {
                connection.cancel()
                return
            }
            guard requestData.count >= bodyStart + contentLength else {
                if !isComplete { self.receiveRequest(on: connection, buffer: requestData) }
                else { connection.cancel() }
                return
            }
            if isBinaryUpload, let binaryUploadHandler {
                let target = requestTarget
                let contentType = headerText
                    .split(separator: "\r\n")
                    .dropFirst()
                    .first(where: { $0.lowercased().hasPrefix("content-type:") })
                    .map { String($0.split(separator: ":", maxSplits: 1).dropFirst().joined(separator: ":")).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                guard contentType?.split(separator: ";", maxSplits: 1).first.map(String.init) == "application/octet-stream" else {
                    Self.send((415, "content type must be application/octet-stream"), on: connection)
                    return
                }
                guard let components = URLComponents(string: "http://127.0.0.1\(target)"),
                      let sessionID = components.queryItems?.first(where: { $0.name == "sessionId" })?.value,
                      !sessionID.isEmpty else {
                    Self.send((400, "{\"error\":\"sessionId is required\"}"), on: connection)
                    return
                }
                let name = components.queryItems?.first(where: { $0.name == "name" })?.value
                let bodyData = Data(requestData[bodyStart..<(bodyStart + contentLength)])
                Task {
                    do {
                        let value = try await binaryUploadHandler(sessionID, name, bodyData)
                        let encoded = Self.encodeJSON(.object([
                            "ok": .bool(true),
                            "value": value
                        ]))
                        Self.send((200, encoded), on: connection)
                    } catch {
                        let message = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
                        Self.send((200, "{\"ok\":false,\"error\":{\"code\":\"session/attachment-invalid\",\"message\":\"\(message)\",\"details\":{}}}"), on: connection)
                    }
                }
                return
            }
            let request = String(decoding: requestData, as: UTF8.self)
            self.webhookHandlerLock.lock()
            let webhookHandler = self.webhookHandler
            let webhookSecret = self.webhookSecret
            self.webhookHandlerLock.unlock()
            if let streamRPCHandler = self.streamRPCHandler,
               let rpcRequest = Self.rpcRequest(in: request),
               rpcRequest.method == "session/follow"
                || rpcRequest.method == "workspace/follow"
                || rpcRequest.method == "session/control" {
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
                        let mapped: (code: String, message: String)
                        if let rpcError = error as? LocalStateRPCError {
                            switch rpcError {
                            case let .sessionNotFound(sessionID):
                                mapped = ("session/not-found", "Session \(sessionID.uuidString) was not found.")
                            case let .attachmentInvalid(reason):
                                mapped = ("session/attachment-invalid", reason)
                            default:
                                mapped = ("gateway/internal", rpcError.localizedDescription)
                            }
                        } else {
                            mapped = ("gateway/internal", error.localizedDescription)
                        }
                        routed = Self.rpcErrorResponse(rpcID: rpcRequest.rpcID, code: mapped.code, message: mapped.message)
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

    private static func encodeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{\"ok\":false}" }
        return String(decoding: data, as: UTF8.self)
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
    case sessionNotFound(UUID)
    case attachmentInvalid(String)

    var errorDescription: String? {
        switch self {
        case let .methodNotFound(method): return "RPC method not found: \(method)"
        case .invalidProjection: return "RPC projection is invalid."
        case let .invalidPayload(field): return "RPC payload field is invalid: \(field)"
        case let .sessionNotFound(sessionID): return "Session \(sessionID.uuidString) was not found."
        case let .attachmentInvalid(reason): return reason
        }
    }
}

func localSessionControlBaseline(
    sessions: [ConversationSessionSummary],
    aggregate: SessionRunAggregateSnapshot,
    jobsBySession: [UUID: [HarnessJobSnapshot]] = [:]
) -> JSONValue {
    var queues: [String: JSONValue] = [:]
    var projections: [String: JSONValue] = [:]
    for session in sessions {
        let id = session.id.uuidString.lowercased()
        let presentation = aggregate.runs.first { $0.identity.sessionID == session.id }?.presentation
        let items = presentation?.queuedInputs.map { input in
            JSONValue.object([
                "id": .string(input.id.uuidString.lowercased()),
                "placement": .string(input.disposition == .steer ? "steering" : "queued"),
                "message": .object([
                    "id": .string(input.id.uuidString.lowercased()),
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(input.text)
                    ])])
                ])
            ])
        } ?? []
        queues[id] = .array(items)
        projections[id] = .object([
            "asOfSeq": .number(Double(session.revision)),
            "values": .object([
                "running": .bool(presentation != nil && presentation?.phase.isQuiescent == false),
                "queuedInputCount": .number(Double(items.count))
            ])
        ])
    }
    let jobValues = sessions.reduce(into: [String: JSONValue]()) { result, session in
        result[session.id.uuidString.lowercased()] = .array((jobsBySession[session.id] ?? []).map { job in
            .object([
                "id": .string(job.id), "kind": .string(job.kind), "label": .string(job.label),
                "status": .string(job.status.rawValue),
                "detail": job.detail.map(JSONValue.string) ?? .null,
                "startedAt": .number(Double(job.startedAt)),
                "finishedAt": job.finishedAt.map { .number(Double($0)) } ?? .null
            ])
        })
    }
    return .object([
        "type": .string("baseline"),
        "value": .object([
            "queues": .object(queues),
            "jobs": .object(jobValues),
            "projections": .object(projections)
        ])
    ])
}

/// Projects canonical assistant chunk events into the v2 process-local stream
/// contract. The attempt id is deterministic for a session/turn/step so a
/// reconnect can rebase without a second runtime-owned state store.
func localAssistantStreamBaseline(
    sessionID: UUID,
    events: [SessionEvent],
    active: Bool
) -> JSONValue {
    guard active else {
        return .object(["revision": .number(0)])
    }
    let lastMessageIndex = events.lastIndex(where: { $0.type == SessionEventVocabulary.assistantMessage }) ?? -1
    let chunks = events[(lastMessageIndex + 1)...].filter { $0.type == SessionEventVocabulary.assistantChunk }
    guard let first = chunks.first,
          let firstData = first.assistantChunkData else {
        return .object(["revision": .number(0)])
    }
    let attemptID = localAssistantAttemptID(sessionID: sessionID, turn: firstData.turn, step: firstData.step)
    let stream = localAssistantStreamRecords(chunks)
    return .object([
        "revision": .number(Double(stream.count + 1)),
        "activeAttempt": .object([
            "attemptId": .string(attemptID),
            "startedAfterSeq": .number(first.seq == 0 ? -1 : Double(first.seq - 1)),
            "turn": .number(Double(firstData.turn)),
            "step": .number(Double(firstData.step)),
            "nextIndex": .number(Double(stream.count)),
            "stream": .array(stream)
        ])
    ])
}

private func localAssistantStreamRecords(_ events: [SessionEvent]) -> [JSONValue] {
    var records: [[String: JSONValue]] = []
    for event in events {
        guard let chunk = event.assistantChunkData?.chunk.objectValue,
              let type = chunk["type"]?.stringValue else { continue }
        let index = localJSONNumber(chunk["index"]) ?? 0
        if type == "text-delta" || type == "reasoning-delta",
           let text = chunk["text"]?.stringValue {
            let recordType = type == "text-delta" ? "text-chunks" : "reasoning-chunks"
            if let last = records.indices.last,
               records[last]["type"] == .string(recordType),
               localJSONNumber(records[last]["index"]) == index,
               let previousTime = localJSONNumber(records[last]["_lastTime"]) {
                records[last]["dt"] = appendNumber(records[last]["dt"], Double(event.time) - previousTime)
                records[last]["texts"] = appendString(records[last]["texts"], text)
                records[last]["_lastTime"] = .number(Double(event.time))
            } else {
                records.append([
                    "type": .string(recordType), "time0": .number(Double(event.time)),
                    "index": .number(index), "dt": .array([]), "texts": .array([.string(text)]),
                    "_lastTime": .number(Double(event.time))
                ])
            }
        } else if type == "tool-call-delta",
                  let id = chunk["id"]?.stringValue,
                  let args = chunk["argumentsDelta"]?.stringValue {
            let name = chunk["name"]?.stringValue
            if let last = records.indices.last,
               records[last]["type"] == .string("tool-call-chunks"),
               localJSONNumber(records[last]["index"]) == index,
               records[last]["id"]?.stringValue == id,
               records[last]["name"]?.stringValue == name,
               let previousTime = localJSONNumber(records[last]["_lastTime"]) {
                records[last]["dt"] = appendNumber(records[last]["dt"], Double(event.time) - previousTime)
                records[last]["args"] = appendString(records[last]["args"], args)
                records[last]["_lastTime"] = .number(Double(event.time))
            } else {
                var record: [String: JSONValue] = [
                    "type": .string("tool-call-chunks"), "time0": .number(Double(event.time)),
                    "index": .number(index), "dt": .array([]), "id": .string(id),
                    "args": .array([.string(args)]), "_lastTime": .number(Double(event.time))
                ]
                if let name { record["name"] = .string(name) }
                records.append(record)
            }
        } else {
            records.append([
                "type": .string("chunk"), "time": .number(Double(event.time)),
                "chunk": .object(chunk)
            ])
        }
    }
    return records.map { record in
        var copy = record
        copy.removeValue(forKey: "_lastTime")
        return .object(copy)
    }
}

private func appendNumber(_ value: JSONValue?, _ item: Double) -> JSONValue {
    guard case let .array(values)? = value else { return .array([.number(item)]) }
    return .array(values + [.number(item)])
}

private func appendString(_ value: JSONValue?, _ item: String) -> JSONValue {
    guard case let .array(values)? = value else { return .array([.string(item)]) }
    return .array(values + [.string(item)])
}

private func localJSONNumber(_ value: JSONValue?) -> Double? {
    guard case let .number(number)? = value else { return nil }
    return number
}

/// Converts a durable assistant chunk/message suffix into ordered
/// start/chunk/end frames. This is intentionally a projection over the
/// canonical log; the next step can replace it with a native event bus.
func localAssistantStreamFrames(sessionID: UUID, events: [SessionEvent]) -> [JSONValue] {
    var result: [JSONValue] = []
    var currentKey: (turn: Int, step: Int)?
    var chunks: [SessionEvent] = []
    func flush(endEvent: SessionEvent? = nil) {
        guard let first = chunks.first, let firstData = first.assistantChunkData else { return }
        let attemptID = localAssistantAttemptID(sessionID: sessionID, turn: firstData.turn, step: firstData.step)
        result.append(.object(["type": .string("assistant-stream"), "frame": .object([
            "type": .string("start"), "attemptId": .string(attemptID), "revision": .number(1),
            "startedAfterSeq": .number(first.seq == 0 ? -1 : Double(first.seq - 1)),
            "turn": .number(Double(firstData.turn)), "step": .number(Double(firstData.step))
        ])]))
        for (index, event) in chunks.enumerated() {
            guard let data = event.assistantChunkData else { continue }
            result.append(.object(["type": .string("assistant-stream"), "frame": .object([
                "type": .string("chunk"), "attemptId": .string(attemptID),
                "revision": .number(Double(index + 2)), "index": .number(Double(index)),
                "time": .number(Double(event.time)), "chunk": data.chunk
            ])]))
        }
        if let endEvent {
            result.append(.object(["type": .string("assistant-stream"), "frame": .object([
                "type": .string("end"), "attemptId": .string(attemptID),
                "revision": .number(Double(chunks.count + 2)), "index": .number(Double(chunks.count)),
                "outcome": .object([
                    "kind": .string("committed"), "eventType": .string("assistant/message"),
                    "seq": .number(Double(endEvent.seq))
                ])
            ])]))
        }
        chunks.removeAll(keepingCapacity: true)
    }
    for event in events {
        if let data = event.assistantChunkData {
            let key = (data.turn, data.step)
            if currentKey.map({ $0.0 == key.0 && $0.1 == key.1 }) != true {
                flush()
                currentKey = key
            }
            chunks.append(event)
        } else if event.type == SessionEventVocabulary.assistantMessage, !chunks.isEmpty {
            flush(endEvent: event)
            currentKey = nil
        }
    }
    flush()
    return result
}

private func localAssistantAttemptID(sessionID: UUID, turn: Int, step: Int) -> String {
    "mobile:\(sessionID.uuidString.lowercased()):\(turn):\(step)"
}

func localSessionControlFrames(previous: JSONValue?, current: JSONValue) -> [JSONValue] {
    guard let previous, let oldValue = previous.objectValue?["value"]?.objectValue,
          let newValue = current.objectValue?["value"]?.objectValue else {
        return [current]
    }
    var frames: [JSONValue] = []
    let oldQueues = oldValue["queues"]?.objectValue ?? [:]
    let newQueues = newValue["queues"]?.objectValue ?? [:]
    for sessionID in newQueues.keys.sorted() where oldQueues[sessionID] != newQueues[sessionID] {
        frames.append(.object([
            "type": .string("queue"),
            "sessionId": .string(sessionID),
            "items": newQueues[sessionID] ?? .array([])
        ]))
    }
    let oldJobs = oldValue["jobs"]?.objectValue ?? [:]
    let newJobs = newValue["jobs"]?.objectValue ?? [:]
    for sessionID in newJobs.keys.sorted() where oldJobs[sessionID] != newJobs[sessionID] {
        frames.append(.object([
            "type": .string("jobs"),
            "sessionId": .string(sessionID),
            "jobs": newJobs[sessionID] ?? .array([])
        ]))
    }
    let oldProjections = oldValue["projections"]?.objectValue ?? [:]
    let newProjections = newValue["projections"]?.objectValue ?? [:]
    for sessionID in newProjections.keys.sorted() {
        guard oldProjections[sessionID] != newProjections[sessionID],
              let projection = newProjections[sessionID]?.objectValue,
              let values = projection["values"] else { continue }
        frames.append(.object([
            "type": .string("projection"),
            "sessionId": .string(sessionID),
            "key": .string("state"),
            "value": values,
            "seq": projection["asOfSeq"] ?? .number(0)
        ]))
    }
    return frames
}

/// Finds a durable image reference in the canonical session event stream.
/// The event payloads intentionally have several historical shapes, so this
/// walks JSON values and only decodes the stable `imageAttachments` entries.
func localReferencedImage(
    in events: [SessionEvent],
    attachmentID: UUID
) -> AgentImageAttachmentRef? {
    func scan(_ value: JSONValue) -> AgentImageAttachmentRef? {
        if let object = value.objectValue {
            if case let .array(items)? = object["imageAttachments"] {
                for item in items {
                    guard let fields = item.objectValue,
                          let rawID = fields["id"]?.stringValue,
                          UUID(uuidString: rawID) == attachmentID,
                          let path = fields["path"]?.stringValue,
                          let mimeType = fields["mimeType"]?.stringValue else { continue }
                    let byteCount = fields["byteCount"].flatMap { value -> Int? in
                        guard case let .number(number) = value,
                              number.isFinite,
                              number >= 0,
                              number <= Double(Int.max) else { return nil }
                        return Int(number)
                    } ?? 0
                    return AgentImageAttachmentRef(
                        id: attachmentID,
                        path: path,
                        mimeType: mimeType,
                        byteCount: byteCount
                    )
                }
            }
            for child in object.values {
                if let found = scan(child) { return found }
            }
        } else if case let .array(items) = value {
            for item in items {
                if let found = scan(item) { return found }
            }
        }
        return nil
    }
    for event in events {
        if let found = scan(event.data) { return found }
    }
    return nil
}

/// Produces the desktop-compatible backwards, message-aligned history page.
/// Consecutive whitelisted assistant deltas use the upstream chunkrow wire
/// shape; unknown/future variants remain raw event records.
func localSessionPagePayload(
    sessionID: UUID,
    events: [SessionEvent],
    throughSequence: Int,
    beforeSequence: Int? = nil,
    maxMessages: Int? = nil
) throws -> JSONValue {
    guard throughSequence >= -1 else { throw LocalStateRPCError.invalidPayload("throughSeq") }
    if let beforeSequence, beforeSequence < 0 { throw LocalStateRPCError.invalidPayload("beforeSeq") }
    let messageLimit = maxMessages ?? 50
    guard messageLimit > 0 else { throw LocalStateRPCError.invalidPayload("maxMessages") }
    let through: UInt64
    if throughSequence == -1 {
        through = UInt64.max
    } else {
        through = UInt64(throughSequence)
        guard let index = Int(exactly: through), index < events.count, events[index].seq == through else {
            throw LocalStateRPCError.invalidPayload("throughSeq")
        }
    }
    let end = throughSequence == -1 ? 0 : min(Int(through) + 1, beforeSequence ?? Int(through) + 1)
    var cut = 0
    var messageCount = 0
    if end > 0 {
        for index in stride(from: end - 1, through: 0, by: -1) {
            let event = events[index]
            guard (event.type == SessionEventVocabulary.userMessage || event.type == SessionEventVocabulary.assistantMessage),
                  event.surfaceOp == nil || event.surfaceOp == .append else { continue }
            messageCount += 1
            var groupStart = event.seq
            for source in event.sourceEventSeqs ?? [] where source < groupStart { groupStart = source }
            if messageCount >= messageLimit { cut = Int(min(groupStart, UInt64(end))); break }
        }
    }
    let records = try localSessionHistoryRecords(events: Array(events[cut..<end]))
    return .object([
        "sessionId": .string(sessionID.uuidString.lowercased()), "records": .array(records),
        "hasMore": .bool(cut > 0), "throughSeq": .number(throughSequence == -1 ? -1 : Double(through))
    ])
}

func localSessionSearchPayload(
    hits: [SessionQuerySessionHit],
    visibleSessionIDs: Set<UUID>,
    limit: Int = 20
) -> JSONValue {
    var seen = Set<UUID>()
    let accepted = hits.filter { hit in
        visibleSessionIDs.contains(hit.session.id) && seen.insert(hit.session.id).inserted
    }
    return .object([
        "items": .array(accepted.prefix(limit).map { hit in
            .object([
                "sessionId": .string(hit.session.id.uuidString.lowercased()),
                "snippet": .string(String(hit.snippet.prefix(240)))
            ])
        }),
        "hasMore": .bool(accepted.count > limit)
    ])
}

func localSessionModelCatalogPayload(
    profiles: [ProviderProfile],
    activeProfileID: String?,
    failures: [JSONValue] = []
) -> JSONValue {
    let groups: [JSONValue] = profiles.map { profile in
        .object([
            "id": .string(profile.id), "name": .string(profile.displayName),
            "models": .array(profile.models.map { model in
                var value: [String: JSONValue] = [
                    "id": .string(model.id), "name": .string(model.name ?? model.id)
                ]
                if let description = model.description { value["description"] = .string(description) }
                if let modes = model.reasoningModes, !modes.isEmpty {
                    var reasoning: [String: JSONValue] = [
                        "efforts": .array(modes.filter { $0 != .providerDefault }.map {
                            .object(["id": .string($0.rawValue), "name": .string($0.title)])
                        })
                    ]
                    if let defaultEffort = model.defaultReasoningMode,
                       defaultEffort != .providerDefault {
                        reasoning["defaultEffort"] = .string(defaultEffort.rawValue)
                    }
                    value["reasoning"] = .object(reasoning)
                }
                return .object(value)
            })
        ])
    }
    let selected = profiles.first { $0.id == activeProfileID } ?? profiles.first
    let fallback = selected ?? ProviderProfile.catalogDefault(for: .deepSeekOfficial)
    return .object([
        "default": .object([
            "provider": .string(fallback.providerID.rawValue),
            "model": .string(fallback.defaultModel),
            "reasoningEffort": fallback.reasoningMode == .providerDefault
                ? .null : .string(fallback.reasoningMode.rawValue)
        ]),
        "routableProviders": .array(profiles.map { .string($0.providerID.rawValue) }),
        "groups": .array(groups), "failures": .array(failures)
    ])
}

private func localSessionHistoryRecords(events: [SessionEvent]) throws -> [JSONValue] {
    var records: [JSONValue] = []
    var run: [SessionEvent] = []
    var kind: String?
    func flush() throws {
        guard !run.isEmpty else { return }
        if run.count >= 3, let kind {
            records.append(try localChunkRun(kind: kind, events: run))
        } else {
            records.append(contentsOf: try run.map(localRawHistoryRecord))
        }
        run.removeAll(keepingCapacity: true)
    }
    for event in events {
        guard let nextKind = localChunkKind(event) else {
            try flush()
            records.append(try localRawHistoryRecord(event))
            kind = nil
            continue
        }
        if !(kind == nextKind && run.last.map { localChunkContinues($0, event) } == true) {
            try flush()
            kind = nextKind
        }
        run.append(event)
    }
    try flush()
    return records
}

private func localRawHistoryRecord(_ event: SessionEvent) throws -> JSONValue {
        var wire: [String: JSONValue] = [
            "type": .string(event.type), "seq": .number(Double(event.seq)),
            "time": .number(Double(event.time)), "data": event.data
        ]
        if event.ignorable == true { wire["ignorable"] = .bool(true) }
        if let sources = event.sourceEventSeqs { wire["sourceEventSeqs"] = .array(sources.map { .number(Double($0)) }) }
        if let operation = event.surfaceOp {
            wire["surfaceOp"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(operation))
        }
    return .object(["type": .string("event"), "event": .object(wire)])
}

private func localChunkKind(_ event: SessionEvent) -> String? {
    guard event.type == SessionEventVocabulary.assistantChunk,
          case let .object(data) = event.data,
          localHasExactKeys(data, ["turn", "step", "chunk"]),
          case let .number(turn) = data["turn"], turn.isFinite,
          case let .number(step) = data["step"], step.isFinite,
          case let .object(chunk) = data["chunk"],
          case let .string(type) = chunk["type"],
          ["text-delta", "reasoning-delta", "tool-call-delta"].contains(type),
          case .number = chunk["index"] else { return nil }
    if type == "tool-call-delta" {
        guard (localHasExactKeys(chunk, ["type", "index", "id", "argumentsDelta"])
            || localHasExactKeys(chunk, ["type", "index", "id", "name", "argumentsDelta"])),
              case .string = chunk["id"], case .string = chunk["argumentsDelta"] else { return nil }
    } else {
        guard localHasExactKeys(chunk, ["type", "index", "text"]), case .string = chunk["text"] else { return nil }
    }
    return type
}

private func localHasExactKeys(_ object: [String: JSONValue], _ keys: [String]) -> Bool {
    object.count == keys.count && keys.allSatisfy { object[$0] != nil }
}

private func localChunkContinues(_ previous: SessionEvent, _ next: SessionEvent) -> Bool {
    let (_, timeOverflow) = next.time.subtractingReportingOverflow(previous.time)
    guard previous.seq + 1 == next.seq,
          let previousKind = localChunkKind(previous), previousKind == localChunkKind(next),
          case let .object(a) = previous.data, case let .object(b) = next.data,
          a["turn"] == b["turn"], a["step"] == b["step"],
          case let .object(ac) = a["chunk"], case let .object(bc) = b["chunk"],
          ac["index"] == bc["index"], !timeOverflow else { return false }
    if previousKind == "tool-call-delta" {
        return ac["id"] == bc["id"] && ac["name"] == bc["name"]
    }
    return true
}

private func localChunkRun(kind: String, events: [SessionEvent]) throws -> JSONValue {
    guard let first = events.first,
          case let .object(data) = first.data,
          case let .number(turn) = data["turn"],
          case let .number(step) = data["step"],
          case let .object(chunk) = data["chunk"],
          case let .number(index) = chunk["index"] else {
        throw LocalStateRPCError.invalidProjection
    }
    var runData: [String: JSONValue] = [
        "turn": .number(turn), "step": .number(step), "index": .number(index),
        "dt": .array(zip(events.dropFirst(), events).map {
            .number(Double($0.time.subtractingReportingOverflow($1.time).partialValue))
        })
    ]
    let rowType: String
    switch kind {
    case "text-delta":
        rowType = "text-chunks"
        runData["texts"] = .array(events.compactMap { event in
            guard case let .object(d) = event.data, case let .object(c) = d["chunk"], case let .string(text) = c["text"] else { return nil }
            return .string(text)
        })
    case "reasoning-delta":
        rowType = "reasoning-chunks"
        runData["texts"] = .array(events.compactMap { event in
            guard case let .object(d) = event.data, case let .object(c) = d["chunk"], case let .string(text) = c["text"] else { return nil }
            return .string(text)
        })
    case "tool-call-delta":
        rowType = "tool-call-chunks"
        guard case let .string(id) = chunk["id"] else { throw LocalStateRPCError.invalidProjection }
        runData["id"] = .string(id)
        if case let .string(name) = chunk["name"] { runData["name"] = .string(name) }
        runData["args"] = .array(events.compactMap { event in
            guard case let .object(d) = event.data, case let .object(c) = d["chunk"], case let .string(args) = c["argumentsDelta"] else { return nil }
            return .string(args)
        })
    default:
        throw LocalStateRPCError.invalidProjection
    }
    return .object([
        "type": .string("chunks"),
        "event": .object([
            "type": .string("chunkrow/\(rowType)"),
            "seq": .number(Double(first.seq)), "time": .number(Double(first.time)),
            "data": .object(runData)
        ])
    ])
}

/// Client seam used by native integrations and tests to exercise the actual
/// loopback listener rather than only the pure router.
struct LocalStateHTTPClient: Sendable {
    let baseURL: URL

    enum ConnectionState: String, Sendable, Equatable {
        case connecting
        case connected
        case disconnected
    }

    struct ConnectionSnapshot: Sendable, Equatable {
        let state: ConnectionState
        let generation: Int
    }

    init(port: UInt16) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func get(path: String) async throws -> String {
        try await request(path: path, method: "GET", body: nil, headers: [:])
    }

    func post(path: String, body: String, headers: [String: String] = [:]) async throws -> String {
        try await request(path: path, method: "POST", body: Data(body.utf8), headers: headers)
    }

    func uploadFile(
        sessionID: String,
        data: Data,
        name: String? = nil
    ) async throws -> JSONValue {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/session/uploadFileBinary"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        if let name { components.queryItems?.append(URLQueryItem(name: "name", value: name)) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalStateHTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalStateHTTPError.server(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
        }
        guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            throw LocalStateHTTPError.invalidResponse
        }
        guard envelope.objectValue?["ok"]?.booleanValue != false else {
            throw LocalStateHTTPError.server(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
        }
        return envelope
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
        payload: JSONValue = .object([:]),
        reconnect: Bool = false,
        maximumReconnectAttempts: Int = 5,
        onStateChange: (@Sendable (ConnectionSnapshot) -> Void)? = nil
    ) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var nextPayload = payload
                var reconnectAttempt = 0
                var generation = 0
                var lastState: ConnectionState?
                func emit(_ state: ConnectionState) {
                    guard lastState != state || state == .connected else { return }
                    lastState = state
                    if state == .connected { generation += 1 }
                    onStateChange?(ConnectionSnapshot(state: state, generation: generation))
                }
                do {
                    while !Task.isCancelled {
                        emit(.connecting)
                        do {
                            let body = try JSONEncoder().encode([
                                "type": JSONValue.string("client-request"),
                                "rpcId": JSONValue.string(rpcID),
                                "method": JSONValue.string(method),
                                "payload": nextPayload
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
                            emit(.connected)
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
                                if method == "session/follow",
                                   case let .number(cursor)? = value.objectValue?["cursor"] {
                                    var fields = nextPayload.objectValue ?? [:]
                                    fields["sinceSequence"] = .number(cursor)
                                    nextPayload = .object(fields)
                                }
                            }
                            guard reconnect else {
                                emit(.disconnected)
                                continuation.finish()
                                return
                            }
                        } catch {
                            emit(.disconnected)
                            guard reconnect, !Task.isCancelled else { throw error }
                        }
                        reconnectAttempt += 1
                        guard reconnectAttempt <= max(0, maximumReconnectAttempts) else {
                            continuation.finish()
                            return
                        }
                        let delay = min(10_000, 500 * (1 << min(reconnectAttempt - 1, 4)))
                        try await Task.sleep(for: .milliseconds(delay))
                    }
                    emit(.disconnected)
                    continuation.finish()
                } catch {
                    emit(.disconnected)
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
