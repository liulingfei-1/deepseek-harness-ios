import Foundation
#if os(iOS) && canImport(HarnessISH)
@preconcurrency import HarnessISH
#endif

enum ISHTerminalSignal: String, Codable, Sendable, CaseIterable {
    case interrupt = "SIGINT"
    case terminate = "SIGTERM"
    case kill = "SIGKILL"
    case stop = "SIGTSTP"
    case hangup = "SIGHUP"
}

enum ISHTerminalWaitReason: String, Codable, Sendable, Equatable {
    case stdinRead = "stdin_read"
    case inferredIdle = "inferred_idle"
    case timeout
    case sessionExit = "session_exit"
}

enum ISHTerminalSessionStatus: Codable, Sendable, Equatable {
    case running
    case exited(exitCode: Int?, signal: String?)
    case interrupted(reason: String)

    private enum CodingKeys: String, CodingKey { case kind, exitCode, signal, reason }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "running": self = .running
        case "exited":
            self = .exited(
                exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode),
                signal: try container.decodeIfPresent(String.self, forKey: .signal)
            )
        case "interrupted":
            self = .interrupted(
                reason: try container.decode(String.self, forKey: .reason)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unknown terminal status"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try container.encode("running", forKey: .kind)
        case let .exited(exitCode, signal):
            try container.encode("exited", forKey: .kind)
            try container.encodeIfPresent(exitCode, forKey: .exitCode)
            try container.encodeIfPresent(signal, forKey: .signal)
        case let .interrupted(reason):
            try container.encode("interrupted", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

struct ISHTerminalSessionSnapshot: Codable, Sendable, Equatable {
    let sessionID: String
    let ownerSession: String
    let name: String?
    let type: String
    let pid: Int?
    var status: ISHTerminalSessionStatus
}

struct ISHTerminalOpenRequest: Sendable, Equatable {
    let sessionID: String
    let ownerSession: String
    let type: String
    let name: String?
    let cwd: String?
}

struct ISHTerminalOpenedSession: Sendable {
    let backend: any ISHTerminalBackendSession
    let pid: Int?
    let motd: String
}

struct ISHTerminalSendResult: Sendable, Equatable {
    let viewport: String
    let waitReason: ISHTerminalWaitReason
    let sessionStatus: ISHTerminalSessionStatus
    let truncated: Bool
}

struct ISHTerminalReadResult: Sendable, Equatable {
    let text: String
    let totalLines: Int
    let lineBegin: Int
    let lineEnd: Int
    let truncated: Bool
}

struct ISHTerminalSignalResult: Sendable, Equatable {
    let delivered: Bool
    let targetProcessGroup: Int
}

enum ISHTerminalCloseOutcome: String, Sendable, Equatable {
    case closed
    case alreadyClosing = "already-closing"
}

enum ISHTerminalProviderError: LocalizedError, Sendable, Equatable {
    case invalidOwner
    case invalidType
    case invalidName
    case invalidWorkingDirectory
    case capacityReached(limit: Int)
    case unsupportedBackend(String)
    case unknownSession(String)
    case foreignSession(String)
    case sessionBusy(String)
    case interruptedSession(String)
    case backendContractUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidOwner: "terminal owner must be a non-empty session id"
        case .invalidType: "terminal type must be a non-empty string"
        case .invalidName: "terminal name is invalid"
        case .invalidWorkingDirectory: "terminal cwd is invalid"
        case let .capacityReached(limit): "terminal session limit reached for this owner (limit: \(limit))"
        case let .unsupportedBackend(type): "terminal backend is not registered: \(type)"
        case let .unknownSession(id): "unknown terminal session \(id)"
        case let .foreignSession(id): "terminal session \(id) belongs to another Agent session"
        case let .sessionBusy(id): "terminal session \(id) already has an active send"
        case let .interruptedSession(id): "terminal session \(id) was interrupted by app restart and cannot resume"
        case let .backendContractUnavailable(reason): reason
        }
    }
}

protocol ISHTerminalBackendSession: Sendable {
    func send(text: String, submit: Bool) async throws -> ISHTerminalSendResult
    func read(offset: Int, count: Int) async throws -> ISHTerminalReadResult
    func signal(_ signal: ISHTerminalSignal) async throws -> ISHTerminalSignalResult
    func close() async throws -> Bool
}

typealias ISHTerminalBackendFactory = @Sendable (
    ISHTerminalOpenRequest
) async throws -> ISHTerminalOpenedSession

protocol ISHTerminalProviding: Sendable {
    func open(
        ownerSession: String,
        type: String,
        name: String?,
        cwd: String?
    ) async throws -> (snapshot: ISHTerminalSessionSnapshot, motd: String)
    func send(
        ownerSession: String,
        sessionID: String,
        text: String,
        submit: Bool
    ) async throws -> ISHTerminalSendResult
    func read(
        ownerSession: String,
        sessionID: String,
        offset: Int,
        count: Int
    ) async throws -> ISHTerminalReadResult
    func signal(
        ownerSession: String,
        sessionID: String,
        signal: ISHTerminalSignal
    ) async throws -> ISHTerminalSignalResult
    func close(
        ownerSession: String,
        sessionID: String
    ) async throws -> ISHTerminalCloseOutcome
    func list(ownerSession: String) async -> [ISHTerminalSessionSnapshot]
}

/// Owner-scoped registry equivalent to upstream `ctx.terminals`. It contains
/// no execution backend itself. A future genuine HarnessISH PTY bridge can be
/// registered without changing the six model tool contracts.
actor ISHTerminalSessionProvider: ISHTerminalProviding {
    private struct PersistedState: Codable {
        let version: Int
        let nextID: Int
        let sessions: [ISHTerminalSessionSnapshot]
    }

    private struct Record {
        var snapshot: ISHTerminalSessionSnapshot
        let backend: (any ISHTerminalBackendSession)?
        var sendActive: Bool
        var closing: Bool
    }

    private let factories: [String: ISHTerminalBackendFactory]
    private let maximumSessionsPerOwner: Int
    private let persistenceURL: URL?
    private var nextID: Int
    private var records: [String: Record]

    init(
        factories: [String: ISHTerminalBackendFactory] = [:],
        maximumSessionsPerOwner: Int = 8,
        persistenceURL: URL? = nil
    ) {
        precondition(maximumSessionsPerOwner > 0)
        self.factories = factories
        self.maximumSessionsPerOwner = maximumSessionsPerOwner
        self.persistenceURL = persistenceURL
        let restored = persistenceURL.flatMap(Self.load)
        nextID = restored?.nextID ?? 0
        records = [:]
        for var snapshot in restored?.sessions ?? [] {
            if snapshot.status == .running {
                snapshot.status = .interrupted(
                    reason: "app restart interrupted the on-device terminal process"
                )
            }
            records[snapshot.sessionID] = Record(
                snapshot: snapshot,
                backend: nil,
                sendActive: false,
                closing: false
            )
        }
    }

    func open(
        ownerSession: String,
        type: String,
        name: String?,
        cwd: String?
    ) async throws -> (snapshot: ISHTerminalSessionSnapshot, motd: String) {
        let owner = try Self.owner(ownerSession)
        let type = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, type.utf8.count <= 128 else { throw ISHTerminalProviderError.invalidType }
        if let name, name.utf8.count > 256 { throw ISHTerminalProviderError.invalidName }
        if let cwd, cwd.isEmpty || cwd.utf8.count > 4 * 1_024 {
            throw ISHTerminalProviderError.invalidWorkingDirectory
        }
        let activeCount = records.values.filter {
            $0.snapshot.ownerSession == owner && $0.snapshot.status == .running
        }.count
        guard activeCount < maximumSessionsPerOwner else {
            throw ISHTerminalProviderError.capacityReached(limit: maximumSessionsPerOwner)
        }
        guard let factory = factories[type] else {
            throw ISHTerminalProviderError.unsupportedBackend(type)
        }
        nextID += 1
        let id = "terminal-\(nextID)"
        let request = ISHTerminalOpenRequest(
            sessionID: id,
            ownerSession: owner,
            type: type,
            name: name,
            cwd: cwd
        )
        let opened = try await factory(request)
        do {
            try Task.checkCancellation()
        } catch {
            _ = try? await opened.backend.close()
            throw error
        }
        let snapshot = ISHTerminalSessionSnapshot(
            sessionID: id,
            ownerSession: owner,
            name: name,
            type: type,
            pid: opened.pid,
            status: .running
        )
        records[id] = Record(
            snapshot: snapshot,
            backend: opened.backend,
            sendActive: false,
            closing: false
        )
        persistNow()
        return (snapshot, opened.motd)
    }

    func send(
        ownerSession: String,
        sessionID: String,
        text: String,
        submit: Bool
    ) async throws -> ISHTerminalSendResult {
        let backend = try beginSend(ownerSession: ownerSession, sessionID: sessionID)
        do {
            let result = try await backend.send(text: text, submit: submit)
            finishSend(sessionID: sessionID, status: result.sessionStatus)
            return result
        } catch {
            finishSend(sessionID: sessionID, status: nil)
            throw error
        }
    }

    func read(
        ownerSession: String,
        sessionID: String,
        offset: Int,
        count: Int
    ) async throws -> ISHTerminalReadResult {
        let backend = try liveBackend(ownerSession: ownerSession, sessionID: sessionID)
        return try await backend.read(offset: offset, count: count)
    }

    func signal(
        ownerSession: String,
        sessionID: String,
        signal: ISHTerminalSignal
    ) async throws -> ISHTerminalSignalResult {
        let backend = try liveBackend(ownerSession: ownerSession, sessionID: sessionID)
        return try await backend.signal(signal)
    }

    func close(
        ownerSession: String,
        sessionID: String
    ) async throws -> ISHTerminalCloseOutcome {
        let owner = try Self.owner(ownerSession)
        guard var record = records[sessionID] else {
            throw ISHTerminalProviderError.unknownSession(sessionID)
        }
        guard record.snapshot.ownerSession == owner else {
            throw ISHTerminalProviderError.foreignSession(sessionID)
        }
        if record.closing { return .alreadyClosing }
        record.closing = true
        records[sessionID] = record
        guard let backend = record.backend else {
            records.removeValue(forKey: sessionID)
            persistNow()
            return .closed
        }
        do {
            _ = try await backend.close()
            records.removeValue(forKey: sessionID)
            persistNow()
            return .closed
        } catch {
            records[sessionID]?.closing = false
            throw error
        }
    }

    func list(ownerSession: String) -> [ISHTerminalSessionSnapshot] {
        guard let owner = try? Self.owner(ownerSession) else { return [] }
        return records.values
            .map(\.snapshot)
            .filter { $0.ownerSession == owner }
            .sorted { $0.sessionID.localizedStandardCompare($1.sessionID) == .orderedAscending }
    }

    private func beginSend(
        ownerSession: String,
        sessionID: String
    ) throws -> any ISHTerminalBackendSession {
        let owner = try Self.owner(ownerSession)
        guard var record = records[sessionID] else {
            throw ISHTerminalProviderError.unknownSession(sessionID)
        }
        guard record.snapshot.ownerSession == owner else {
            throw ISHTerminalProviderError.foreignSession(sessionID)
        }
        guard let backend = record.backend else {
            throw ISHTerminalProviderError.interruptedSession(sessionID)
        }
        guard !record.sendActive else { throw ISHTerminalProviderError.sessionBusy(sessionID) }
        record.sendActive = true
        records[sessionID] = record
        return backend
    }

    private func finishSend(sessionID: String, status: ISHTerminalSessionStatus?) {
        guard var record = records[sessionID] else { return }
        record.sendActive = false
        if let status { record.snapshot.status = status }
        records[sessionID] = record
        persistNow()
    }

    private func liveBackend(
        ownerSession: String,
        sessionID: String
    ) throws -> any ISHTerminalBackendSession {
        let owner = try Self.owner(ownerSession)
        guard let record = records[sessionID] else {
            throw ISHTerminalProviderError.unknownSession(sessionID)
        }
        guard record.snapshot.ownerSession == owner else {
            throw ISHTerminalProviderError.foreignSession(sessionID)
        }
        guard let backend = record.backend else {
            throw ISHTerminalProviderError.interruptedSession(sessionID)
        }
        return backend
    }

    private static func owner(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else {
            throw ISHTerminalProviderError.invalidOwner
        }
        return normalized
    }

    private func persistNow() {
        guard let persistenceURL else { return }
        let state = PersistedState(
            version: 1,
            nextID: nextID,
            sessions: records.values.map(\.snapshot).sorted { $0.sessionID < $1.sessionID }
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: persistenceURL, options: [.atomic])
    }

    private static func load(_ url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url), data.count <= 1 * 1_024 * 1_024 else {
            return nil
        }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }
}

// MARK: - Native iSH backend

/// A small, bounded output relay for the OpenMinis persistent process bridge.
/// The bridge invokes callbacks outside Swift concurrency; this class only
/// forwards immutable chunks to the actor and never touches actor state.
#if os(iOS) && canImport(HarnessISH)
private final class ISHTerminalOutputRelay: @unchecked Sendable {
    weak var backend: ISHInteractiveTerminalBackend?

    func receive(_ data: Data, isStandardError: Bool) {
        let channel: ISHOutputChannel = isStandardError ? .stderr : .stdout
        let backend = backend
        Task { await backend?.append(data: data, channel: channel) }
    }
}

private final class ISHTerminalExitRelay: @unchecked Sendable {
    weak var backend: ISHInteractiveTerminalBackend?

    func receive(_ result: ISHShellExecutionResult) {
        let backend = backend
        Task {
            await backend?.markExited(
                exitCode: Int(result.exitCode),
                errorCode: result.error.rawValue
            )
        }
    }
}

/// Persistent `/bin/sh -i` session backed by the already vendored OpenMinis
/// bridge. Output is kept as a bounded line buffer so long sessions cannot
/// grow the App process without limit.
private actor ISHInteractiveTerminalBackend: ISHTerminalBackendSession {
    private let process: ISHShellProcess
    private var chunks: [(channel: ISHOutputChannel, text: String)] = []
    private var bufferedBytes = 0
    private var status: ISHTerminalSessionStatus = .running
    private let maximumBufferedBytes = 256 * 1_024

    init(process: ISHShellProcess) {
        self.process = process
    }

    func append(data: Data, channel: ISHOutputChannel) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else { return }
        chunks.append((channel, text))
        bufferedBytes += text.utf8.count
        while bufferedBytes > maximumBufferedBytes, !chunks.isEmpty {
            let removed = chunks.removeFirst()
            bufferedBytes -= removed.text.utf8.count
        }
    }

    func markExited(exitCode: Int, errorCode: Int) {
        guard case .running = status else { return }
        status = .exited(
            exitCode: ISHExitStatus.normalized(exitCode),
            signal: errorCode == 0 ? nil : "ISH-(errorCode)"
        )
    }

    func send(text: String, submit: Bool) async throws -> ISHTerminalSendResult {
        guard case .running = status, process.isRunning else {
            throw ISHTerminalProviderError.interruptedSession("persistent iSH process")
        }
        var payload = text.data(using: .utf8) ?? Data()
        if submit { payload.append(Data("\n".utf8)) }
        guard process.writeStdin(payload) else {
            throw ISHTerminalProviderError.backendContractUnavailable(
                "iSH terminal stdin rejected the write (process exited or queue is full)."
            )
        }
        // Give the guest a short scheduling window without making model calls
        // wait for an arbitrary command completion.
        try? await Task.sleep(for: .milliseconds(35))
        return ISHTerminalSendResult(
            viewport: viewportTail(),
            waitReason: .inferredIdle,
            sessionStatus: status,
            truncated: bufferedBytes >= maximumBufferedBytes
        )
    }

    func read(offset: Int, count: Int) async throws -> ISHTerminalReadResult {
        guard offset >= 0, count >= 1, count <= 2_000 else {
            throw ISHTerminalProviderError.backendContractUnavailable(
                "terminal read offset/count is outside the supported range"
            )
        }
        let lines = chunks
            .flatMap { $0.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        let start = min(offset, lines.count)
        let end = min(start + count, lines.count)
        return ISHTerminalReadResult(
            text: lines[start..<end].joined(separator: "\n"),
            totalLines: lines.count,
            lineBegin: start,
            lineEnd: end,
            truncated: bufferedBytes >= maximumBufferedBytes
        )
    }

    func signal(_ signal: ISHTerminalSignal) async throws -> ISHTerminalSignalResult {
        guard case .running = status else {
            return ISHTerminalSignalResult(delivered: false, targetProcessGroup: Int(process.pid))
        }
        switch signal {
        case .interrupt:
            _ = process.writeStdin(Data([0x03]))
        case .stop:
            _ = process.writeStdin(Data([0x1A]))
        case .hangup:
            process.closeStdin()
        case .terminate, .kill:
            process.terminate()
        }
        return ISHTerminalSignalResult(delivered: true, targetProcessGroup: Int(process.pid))
    }

    func close() async throws -> Bool {
        process.terminate()
        return true
    }

    private func viewportTail() -> String {
        let text = chunks.map(\.text).joined()
        let scalars = Array(text.unicodeScalars.suffix(8_192))
        return String(String.UnicodeScalarView(scalars))
    }
}
#endif

enum ISHTerminalBackendFactoryBuilder {
    /// Builds the real phone-local backend. On non-iOS/test hosts the factory
    /// is still returned, but opening a session fails closed as unsupported.
    static func make(
        workspaceURL: @escaping @Sendable () async throws -> URL,
        coordinator: ISHSandboxCoordinator = .shared
    ) -> ISHTerminalBackendFactory {
        { request in
#if os(iOS) && canImport(HarnessISH)
            let workspace = try await workspaceURL()
            try await coordinator.prepare(workspaceURL: workspace)
            let environment = [
                "HOME": "/root",
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM": "xterm-256color",
                "HARNESS_TERMINAL_ON_DEVICE": "1"
            ]
            let backend = try await ISHInteractiveTerminalBackend.open(
                request: request,
                environment: environment
            )
            return ISHTerminalOpenedSession(
                backend: backend.backend,
                pid: backend.pid,
                motd: backend.motd
            )
#else
            _ = request
            throw ISHTerminalProviderError.unsupportedBackend("iSH PTY is unavailable in this build")
#endif
        }
    }
}

#if os(iOS) && canImport(HarnessISH)
private extension ISHInteractiveTerminalBackend {
    static func open(
        request: ISHTerminalOpenRequest,
        environment: [String: String]
    ) async throws -> (backend: ISHInteractiveTerminalBackend, pid: Int?, motd: String) {
        let outputRelay = ISHTerminalOutputRelay()
        let exitRelay = ISHTerminalExitRelay()
        guard let process = ISHShellExecutor.startPersistentExecutable(
            "/bin/sh",
            arguments: ["-i"],
            environment: environment,
            fsContext: 0,
            outputCallback: outputRelay.receive,
            completion: exitRelay.receive
        ) else {
            throw ISHTerminalProviderError.backendContractUnavailable(
                "iSH could not start the persistent shell process"
            )
        }
        let backend = ISHInteractiveTerminalBackend(process: process)
        outputRelay.backend = backend
        exitRelay.backend = backend
        if let cwd = request.cwd, !cwd.isEmpty {
            _ = process.writeStdin(Data("cd -- \(shellQuote(cwd))\n".utf8))
        }
        return (backend, Int(process.pid), "iSH persistent shell ready (terminal \(request.sessionID))")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif

// MARK: - Agent tools

enum ISHTerminalToolSuite {
    static let names: Set<String> = [
        "terminal_open", "terminal_read", "terminal_send",
        "terminal_signal", "terminal_list", "terminal_close"
    ]

    static func makeTools(
        provider: any ISHTerminalProviding,
        ownerSession: String
    ) -> [any LocalAgentTool] {
        [
            ISHTerminalOpenTool(provider: provider, ownerSession: ownerSession),
            ISHTerminalReadTool(provider: provider, ownerSession: ownerSession),
            ISHTerminalSendTool(provider: provider, ownerSession: ownerSession),
            ISHTerminalSignalTool(provider: provider, ownerSession: ownerSession),
            ISHTerminalListTool(provider: provider, ownerSession: ownerSession),
            ISHTerminalCloseTool(provider: provider, ownerSession: ownerSession)
        ]
    }
}

private struct ISHTerminalOpenTool: LocalAgentTool {
    let provider: any ISHTerminalProviding
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "terminal_open",
        description: "在手机本机 iSH 中打开一个持久终端会话。会话只属于当前 Agent，会在 App 重启后明确标记为 interrupted。",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "type": .object(["type": .string("string"), "description": .string("后端类型，当前使用 ish-shell。")]),
                "name": .object(["type": .string("string")]),
                "cwd": .object(["type": .string("string"), "description": .string("/workspace 下的工作目录。")])
            ]),
            "required": .array([.string("type")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .destructive
    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["type", "name", "cwd"])
        let type = try arguments.requiredString("type", maximumUTF8Bytes: 128)
        guard type == "ish-shell" else { throw LocalToolError.invalidArguments }
    }
    func summary(arguments: [String: JSONValue]) -> String { "打开手机持久终端" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["ish-terminal:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await provider.open(
            ownerSession: ownerSession,
            type: "ish-shell",
            name: arguments["name"]?.stringValue,
            cwd: arguments["cwd"]?.stringValue
        )
        return JSONValue.object([
            "session_id": .string(result.snapshot.sessionID),
            "status": .string("running"),
            "pid": result.snapshot.pid.map { .number(Double($0)) } ?? .null,
            "motd": .string(result.motd)
        ]).displayText
    }
}

private struct ISHTerminalReadTool: LocalAgentTool {
    let provider: any ISHTerminalProviding
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "terminal_read",
        description: "读取手机持久终端的有界输出，按行分页。",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "session_id": .object(["type": .string("string")]),
                "offset": .object(["type": .string("integer"), "minimum": .number(0)]),
                "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(2_000)])
            ]),
            "required": .array([.string("session_id")]), "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .localState
    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["session_id", "offset", "count"])
        _ = try arguments.requiredString("session_id", maximumUTF8Bytes: 128)
        try validateInteger(arguments["offset"], defaultValue: 0, range: 0...1_000_000)
        try validateInteger(arguments["count"], defaultValue: 200, range: 1...2_000)
    }
    func summary(arguments: [String: JSONValue]) -> String { "读取持久终端输出" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["ish-terminal:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await provider.read(
            ownerSession: ownerSession,
            sessionID: try arguments.requiredString("session_id", maximumUTF8Bytes: 128),
            offset: int(arguments["offset"]) ?? 0,
            count: int(arguments["count"]) ?? 200
        )
        return JSONValue.object([
            "text": .string(result.text), "total_lines": .number(Double(result.totalLines)),
            "line_begin": .number(Double(result.lineBegin)), "line_end": .number(Double(result.lineEnd)),
            "truncated": .bool(result.truncated)
        ]).displayText
    }
}

private struct ISHTerminalSendTool: LocalAgentTool {
    let provider: any ISHTerminalProviding
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "terminal_send",
        description: "向手机持久终端写入文本；submit=true 时追加回车。",
        parameters: .object([
            "type": .string("object"), "properties": .object([
                "session_id": .object(["type": .string("string")]),
                "text": .object(["type": .string("string"), "maxLength": .number(65_536)]),
                "submit": .object(["type": .string("boolean")])
            ]), "required": .array([.string("session_id"), .string("text")]), "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .destructive
    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["session_id", "text", "submit"])
        _ = try arguments.requiredString("session_id", maximumUTF8Bytes: 128)
        _ = try arguments.requiredString("text", maximumUTF8Bytes: 64 * 1_024)
        if let submit = arguments["submit"], terminalBool(submit) == nil { throw LocalToolError.invalidArguments }
    }
    func summary(arguments: [String: JSONValue]) -> String { "写入持久终端" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["ish-terminal:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await provider.send(
            ownerSession: ownerSession,
            sessionID: try arguments.requiredString("session_id", maximumUTF8Bytes: 128),
            text: try arguments.requiredString("text", maximumUTF8Bytes: 64 * 1_024),
            submit: arguments["submit"].flatMap(terminalBool) ?? true
        )
        return JSONValue.object([
            "viewport": .string(result.viewport), "wait_reason": .string(result.waitReason.rawValue),
            "status": .string(statusText(result.sessionStatus)), "truncated": .bool(result.truncated)
        ]).displayText
    }
}

private struct ISHTerminalSignalTool: LocalAgentTool {
    let provider: any ISHTerminalProviding
    let ownerSession: String
    let definition = ModelToolDefinition(
        name: "terminal_signal", description: "向手机持久终端发送 SIGINT、SIGTERM、SIGKILL、SIGTSTP 或 SIGHUP。",
        parameters: .object([
            "type": .string("object"), "properties": .object([
                "session_id": .object(["type": .string("string")]),
                "signal": .object(["type": .string("string"), "enum": .array(ISHTerminalSignal.allCases.map { .string($0.rawValue) })])
            ]), "required": .array([.string("session_id"), .string("signal")]), "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .destructive
    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["session_id", "signal"])
        _ = try arguments.requiredString("session_id", maximumUTF8Bytes: 128)
        guard let raw = arguments["signal"]?.stringValue, ISHTerminalSignal(rawValue: raw) != nil else { throw LocalToolError.invalidArguments }
    }
    func summary(arguments: [String: JSONValue]) -> String { "控制持久终端进程" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["ish-terminal:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await provider.signal(
            ownerSession: ownerSession,
            sessionID: try arguments.requiredString("session_id", maximumUTF8Bytes: 128),
            signal: ISHTerminalSignal(rawValue: arguments["signal"]!.stringValue!)!
        )
        return JSONValue.object(["delivered": .bool(result.delivered), "process_group": .number(Double(result.targetProcessGroup))]).displayText
    }
}

private struct ISHTerminalListTool: LocalAgentTool {
    let provider: any ISHTerminalProviding
    let ownerSession: String
    let definition = ModelToolDefinition(name: "terminal_list", description: "列出当前 Agent 拥有的手机持久终端会话。", parameters: .object(["type": .string("object"), "properties": .object([:]), "additionalProperties": .bool(false)]))
    let risk: ToolRisk = .localState
    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys([]) }
    func summary(arguments: [String: JSONValue]) -> String { "列出持久终端" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["ish-terminal:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        let sessions = await provider.list(ownerSession: ownerSession)
        let data = try JSONEncoder().encode(sessions)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct ISHTerminalCloseTool: LocalAgentTool {
    let provider: any ISHTerminalProviding
    let ownerSession: String
    let definition = ModelToolDefinition(name: "terminal_close", description: "关闭当前 Agent 拥有的手机持久终端会话。", parameters: .object([
        "type": .string("object"), "properties": .object(["session_id": .object(["type": .string("string")])]),
        "required": .array([.string("session_id")]), "additionalProperties": .bool(false)
    ]))
    let risk: ToolRisk = .destructive
    func validate(arguments: [String: JSONValue]) throws { try arguments.requireOnlyKeys(["session_id"]); _ = try arguments.requiredString("session_id", maximumUTF8Bytes: 128) }
    func summary(arguments: [String: JSONValue]) -> String { "关闭持久终端" }
    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> { ["ish-terminal:\(ownerSession)"] }
    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let result = try await provider.close(ownerSession: ownerSession, sessionID: try arguments.requiredString("session_id", maximumUTF8Bytes: 128))
        return JSONValue.object(["status": .string(result.rawValue)]).displayText
    }
}

private func int(_ value: JSONValue?) -> Int? {
    guard case let .number(number)? = value, number.rounded() == number else { return nil }
    return Int(number)
}

private func validateInteger(_ value: JSONValue?, defaultValue: Int, range: ClosedRange<Int>) throws {
    guard value == nil || (int(value).map(range.contains) ?? false) else { throw LocalToolError.invalidArguments }
    _ = defaultValue
}

private func statusText(_ status: ISHTerminalSessionStatus) -> String {
    switch status {
    case .running: return "running"
    case .exited: return "exited"
    case .interrupted: return "interrupted"
    }
}

private func terminalBool(_ value: JSONValue) -> Bool? {
    guard case let .bool(result) = value else { return nil }
    return result
}
