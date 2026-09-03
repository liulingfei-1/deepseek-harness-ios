import Foundation

/// Client side of the Agent Client Protocol (ACP) for driving one remote
/// subagent session over a line-framed JSON-RPC transport (desktop parity:
/// `subagent-acp` against `@agentclientprotocol/sdk` 1.4.0, PROTOCOL_VERSION
/// = 1). The wire layer is pure and fully unit-tested; a transport injects
/// inbound lines and receives outbound lines (stdio subprocess on iSH, or any
/// bridge). Permission requests are auto-answered by policy, mirroring the
/// desktop's `PermissionPolicy`.
enum ACPWire {
    static let protocolVersion = 1

    // MARK: Outbound requests

    static func initializeRequest(id: Int) -> String {
        encode([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .number(Double(protocolVersion)),
                "clientCapabilities": .object([:])
            ])
        ])
    }

    static func newSessionRequest(id: Int, cwd: String) -> String {
        encode([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/new"),
            "params": .object([
                "cwd": .string(cwd),
                "mcpServers": .array([])
            ])
        ])
    }

    static func promptRequest(id: Int, sessionId: String, text: String) -> String {
        encode([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("session/prompt"),
            "params": .object([
                "sessionId": .string(sessionId),
                "prompt": .array([
                    .object(["type": .string("text"), "text": .string(text)])
                ])
            ])
        ])
    }

    static func cancelNotification(sessionId: String) -> String {
        encode([
            "jsonrpc": .string("2.0"),
            "method": .string("session/cancel"),
            "params": .object(["sessionId": .string(sessionId)])
        ])
    }

    /// Answers a `session/request_permission` server request. `allow` picks
    /// the first option whose kind is allow_once/allow_always; without one it
    /// answers `cancelled` so the child does not proceed (desktop parity).
    static func permissionResponse(id: Int, policy: PermissionPolicy, options: [JSONValue]) -> String {
        let outcome: JSONValue
        if policy == .allow {
            let allow = options.first { option in
                option.objectValue?["kind"]?.stringValue == "allow_once"
                    || option.objectValue?["kind"]?.stringValue == "allow_always"
            }
            if let optionID = allow?.objectValue?["optionId"] {
                outcome = .object(["outcome": .string("selected"), "optionId": optionID])
            } else {
                outcome = .object(["outcome": .string("cancelled")])
            }
        } else {
            outcome = .object(["outcome": .string("cancelled")])
        }
        return encode([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "result": .object(["outcome": outcome])
        ])
    }

    // MARK: Inbound parsing

    enum Inbound: Equatable {
        case response(id: Int, result: JSONValue?)
        case error(id: Int, message: String)
        case serverRequest(id: Int, method: String, params: JSONValue?)
        case sessionUpdate(sessionId: String?, update: String, text: String?)
    }

    static func parseInbound(_ line: String) -> Inbound? {
        guard let object = parseObject(line) else { return nil }
        let method = object["method"]?.stringValue
        if let id = intValue(object["id"]) {
            if let error = object["error"]?.objectValue?["message"]?.stringValue {
                return .error(id: id, message: error)
            }
            if object.keys.contains("result") {
                return .response(id: id, result: object["result"])
            }
            if let method {
                return .serverRequest(id: id, method: method, params: object["params"])
            }
        }
        if method == "session/update" {
            let update = object["params"]?.objectValue?["update"]?.objectValue
            return .sessionUpdate(
                sessionId: object["params"]?.objectValue?["sessionId"]?.stringValue,
                update: update?["sessionUpdate"]?.stringValue ?? "",
                text: update?["content"]?.objectValue?["text"]?.stringValue
            )
        }
        return nil
    }

    /// Closed ACP stop-reason vocabulary mapped to the mobile subagent
    /// outcomes: unknown variants and `max_turn_requests` are failures, never
    /// a silent success.
    static func stopOutcome(fromResult result: JSONValue?) -> ACPSubagentOutcome {
        let reason = result?.objectValue?["stopReason"]?.stringValue
        switch reason {
        case "end_turn": return .completed
        case "max_tokens": return .maxTokens
        case "refusal": return .refusal
        case "cancelled": return .aborted
        default: return .error
        }
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Forward slashes stay literal ("session/new", "/workspace"); keys are
        // sorted for deterministic frames in tests and logs.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    private static func encode(_ object: [String: JSONValue]) -> String {
        guard let data = try? encoder.encode(JSONValue.object(object)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseObject(_ line: String) -> [String: JSONValue]? {
        guard let data = line.data(using: .utf8),
              case let .object(object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return object
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value else { return nil }
        return Int(number)
    }
}

enum PermissionPolicy: String, Sendable, Equatable {
    case allow
    case reject
}

enum ACPSubagentOutcome: String, Sendable, Equatable {
    case completed
    case maxTokens = "max-tokens"
    case refusal
    case aborted
    case error
}

/// Drives one remote ACP subagent session over an injected line transport.
/// The lifecycle matches the desktop client: initialize → session/new →
/// session/prompt (streaming agent_message_chunk text) → terminal stop
/// reason; permission requests are auto-answered by policy.
final class ACPSubagentClient: @unchecked Sendable {
    private let transport: ACPLineTransport
    private let cwd: String
    private let permissionPolicy: PermissionPolicy

    private(set) var outcome: ACPSubagentOutcome?
    private(set) var outputText = ""
    private var sessionId: String?
    private var nextID = 1
    private var finished = false

    init(transport: ACPLineTransport, cwd: String, permissionPolicy: PermissionPolicy = .allow) {
        self.transport = transport
        self.cwd = cwd
        self.permissionPolicy = permissionPolicy
        transport.onLine = { [weak self] line in
            self?.handle(line: line)
        }
    }

    /// Starts the session and sends the prompt; the transport delivers the
    /// lifecycle asynchronously.
    func run(prompt: String) {
        send(ACPWire.initializeRequest(id: nextID))
        nextID += 1
        pendingStage = .initialize
        pendingPrompt = prompt
    }

    func cancel() {
        guard let sessionId, !finished else { return }
        send(ACPWire.cancelNotification(sessionId: sessionId))
    }

    // MARK: Lifecycle

    private enum Stage {
        case initialize
        case newSession
        case prompt
        case idle
    }

    private var pendingStage: Stage = .idle
    private var pendingPrompt: String?

    private func handle(line: String) {
        switch ACPWire.parseInbound(line) {
        case let .response(id, result):
            respondTo(responseID: id, result: result)
        case let .serverRequest(id, method, params):
            if method == "session/request_permission" {
                let options: [JSONValue] = {
                    guard case let .array(array)? = params?.objectValue?["options"] else { return [] }
                    return array
                }()
                send(ACPWire.permissionResponse(
                    id: id,
                    policy: permissionPolicy,
                    options: options
                ))
            }
        case let .sessionUpdate(_, update, text):
            if update == "agent_message_chunk", let text {
                outputText += text
            }
        case .error:
            outcome = .error
            finished = true
        case nil:
            break
        }
    }

    private func respondTo(responseID: Int, result: JSONValue?) {
        switch pendingStage {
        case .initialize where responseID == 1:
            send(ACPWire.newSessionRequest(id: nextID, cwd: cwd))
            nextID += 1
            pendingStage = .newSession
        case .newSession where responseID == 2:
            sessionId = result?.objectValue?["sessionId"]?.stringValue
            guard let sessionId, let prompt = pendingPrompt else {
                outcome = .error
                finished = true
                return
            }
            send(ACPWire.promptRequest(id: nextID, sessionId: sessionId, text: prompt))
            nextID += 1
            pendingStage = .prompt
        case .prompt:
            outcome = ACPWire.stopOutcome(fromResult: result)
            finished = true
            pendingStage = .idle
        default:
            break
        }
    }

    private func send(_ line: String) {
        transport.send(line)
    }
}

/// Line-framed transport seam: one JSON-RPC message per line.
protocol ACPLineTransport: AnyObject, Sendable {
    var onLine: @Sendable (String) -> Void { get set }
    func send(_ line: String)
}
