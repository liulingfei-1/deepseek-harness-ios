import Foundation

private struct MCPOutgoingRequest: Encodable {
    let jsonrpc = "2.0"
    let id: MCPRequestID
    let method: String
    let params: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

private struct MCPOutgoingNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

private struct MCPIncomingEnvelope: Decodable {
    let jsonrpc: String
    let id: MCPRequestID?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: MCPRemoteError?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(MCPRequestID.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        // decodeIfPresent treats JSON null as absence. Decode explicitly when
        // the key exists so a valid null result remains distinguishable from a
        // response that forgot both result and error.
        if container.contains(.result) {
            result = try container.decode(JSONValue.self, forKey: .result)
        } else {
            result = nil
        }
        error = try container.decodeIfPresent(MCPRemoteError.self, forKey: .error)
    }
}

/// Native MCP stdio client. It owns the JSON-RPC lifecycle but delegates all
/// actual byte execution to an injected local transport.
actor MCPStdioClient {
    private enum State: Sendable {
        case idle
        case running
        case stopping
        case stopped
    }

    private struct PendingRequest {
        let method: String
        let toolName: String?
        let continuation: CheckedContinuation<JSONValue, Error>
        var sent = false
        var timeoutTask: Task<Void, Never>?
    }

    private let configuration: MCPClientConfiguration
    private let transport: any MCPStdioTransport
    private let authorization: any MCPAuthorizationChecking
    private let eventSink: MCPEventSink
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var state: State = .idle
    private var processID: Int32?
    private var framer: MCPNDJSONFramer
    private var nextRequestNumber = 1
    private var pending: [String: PendingRequest] = [:]
    private var initializeResult: MCPInitializeResult?
    private var toolsByRawName: [String: MCPToolDefinition] = [:]
    private var rawNameByPublicName: [String: String] = [:]
    private var stderrTail = ""

    init(
        configuration: MCPClientConfiguration,
        transport: any MCPStdioTransport,
        authorization: any MCPAuthorizationChecking = MCPDenyAllAuthorization(),
        eventSink: @escaping MCPEventSink = { _ in }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.authorization = authorization
        self.eventSink = eventSink
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.framer = MCPNDJSONFramer(maximumLineBytes: configuration.limits.maximumInboundFrameBytes)
    }

    /// Starts the local server, performs MCP initialization, then drains all
    /// `tools/list` pages before publishing a complete tool generation.
    @discardableResult
    func start() async throws -> MCPInitializeResult {
        try configuration.validate()
        switch state {
        case .running:
            guard let initializeResult else {
                throw MCPClientError.invalidState("客户端正在启动")
            }
            return initializeResult
        case .idle, .stopped:
            break
        case .stopping:
            throw MCPClientError.invalidState("客户端正在停止")
        }

        state = .running
        do {
            processID = try await transport.start(
                onStdout: { [weak self] data in
                    Task { [weak self] in await self?.receiveStdout(data) }
                },
                onStderr: { [weak self] data in
                    Task { [weak self] in await self?.receiveStderr(data) }
                },
                onExit: { [weak self] exit in
                    Task { [weak self] in await self?.receiveExit(exit) }
                }
            )

            let params = try encodeJSONValue(
                MCPInitializeParams()
            )
            let rawResult = try await request(
                method: "initialize",
                params: params,
                toolName: nil,
                timeout: configuration.toolCallTimeout
            )
            let initialized = try decode(MCPInitializeResult.self, from: rawResult)
            try await sendNotification(method: "notifications/initialized", params: nil)

            let discovered = try await discoverTools()
            toolsByRawName = Dictionary(uniqueKeysWithValues: discovered.map { ($0.name, $0) })
            rawNameByPublicName = Dictionary(uniqueKeysWithValues: discovered.map {
                (MCPToolNames.publicName(serverName: configuration.server.serverName, rawName: $0.name), $0.name)
            })
            initializeResult = initialized
            return initialized
        } catch {
            let failure = normalize(error)
            state = .stopping
            await transport.stop()
            state = .stopped
            await failAll(failure)
            throw failure
        }
    }

    func stop() async {
        guard state != .stopped else { return }
        state = .stopping
        await transport.stop()
        state = .stopped
        await failAll(.transportEOF)
        processID = nil
    }

    func discoveredTools() -> [MCPToolDefinition] {
        toolsByRawName.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func modelToolDefinitions() -> [ModelToolDefinition] {
        discoveredTools().map {
            $0.modelDefinition(serverName: configuration.server.serverName)
        }
    }

    func diagnostics() -> MCPClientDiagnostics {
        let stateDescription: MCPClientDiagnostics.State
        switch state {
        case .idle: stateDescription = .idle
        case .running: stateDescription = .running
        case .stopping: stateDescription = .stopping
        case .stopped: stateDescription = .stopped
        }
        return MCPClientDiagnostics(
            state: stateDescription,
            processID: processID,
            pendingRequestCount: pending.count,
            toolCount: toolsByRawName.count,
            stderrTail: stderrTail
        )
    }

    func callTool(
        rawName: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPToolCallResult {
        guard state == .running, initializeResult != nil else {
            throw MCPClientError.invalidState("客户端尚未完成 initialize")
        }
        guard let tool = toolsByRawName[rawName] else {
            throw MCPClientError.toolNotFound(rawName)
        }

        do {
            try await authorization.authorize(
                serverName: configuration.server.serverName,
                tool: tool,
                arguments: arguments
            )
        } catch {
            let failure = normalize(error)
            await emit(.failure(
                serverName: configuration.server.serverName,
                requestID: nil,
                method: "tools/call",
                toolName: rawName,
                error: failure
            ))
            throw failure
        }

        let argumentsValue = JSONValue.object(arguments)
        let argumentsBytes = try encodedBytes(argumentsValue)
        guard argumentsBytes.count <= configuration.limits.maximumArgumentsPayloadBytes else {
            let failure = MCPClientError.payloadTooLarge(
                kind: "arguments",
                maximumBytes: configuration.limits.maximumArgumentsPayloadBytes
            )
            await emit(.failure(
                serverName: configuration.server.serverName,
                requestID: nil,
                method: "tools/call",
                toolName: rawName,
                error: failure
            ))
            throw failure
        }

        let params = JSONValue.object([
            "name": .string(rawName),
            "arguments": argumentsValue
        ])
        let rawResult = try await request(
            method: "tools/call",
            params: params,
            toolName: rawName,
            timeout: configuration.toolCallTimeout
        )
        let resultBytes = try encodedBytes(rawResult)
        guard resultBytes.count <= configuration.limits.maximumResultPayloadBytes else {
            throw MCPClientError.payloadTooLarge(
                kind: "result",
                maximumBytes: configuration.limits.maximumResultPayloadBytes
            )
        }
        return try decode(MCPToolCallResult.self, from: rawResult)
    }

    func callPublicTool(
        name: String,
        arguments: [String: JSONValue]
    ) async throws -> MCPToolCallResult {
        guard let rawName = rawNameByPublicName[name] else {
            throw MCPClientError.toolNotFound(name)
        }
        return try await callTool(rawName: rawName, arguments: arguments)
    }

    private func discoverTools() async throws -> [MCPToolDefinition] {
        var cursor: String?
        var seenCursors = Set<String>()
        var discovered: [MCPToolDefinition] = []
        var names = Set<String>()

        while true {
            let params = cursor.map { JSONValue.object(["cursor": .string($0)]) }
            let rawPage = try await request(
                method: "tools/list",
                params: params,
                toolName: nil,
                timeout: configuration.toolCallTimeout
            )
            let pageBytes = try encodedBytes(rawPage)
            guard pageBytes.count <= configuration.limits.maximumToolListPayloadBytes else {
                throw MCPClientError.payloadTooLarge(
                    kind: "tools/list",
                    maximumBytes: configuration.limits.maximumToolListPayloadBytes
                )
            }
            let page = try decode(MCPToolsListResult.self, from: rawPage)
            for tool in page.tools {
                guard !tool.name.isEmpty, tool.name.utf8.count <= 512,
                      !tool.name.contains("\0"), !tool.name.contains("\n"), !tool.name.contains("\r") else {
                    throw MCPClientError.invalidJSONRPC("tools/list 含有非法工具名称")
                }
                guard names.insert(tool.name).inserted else {
                    throw MCPClientError.invalidJSONRPC("tools/list 重复工具 (tool.name)")
                }
                discovered.append(tool)
                guard discovered.count <= configuration.limits.maximumToolCount else {
                    throw MCPClientError.payloadTooLarge(
                        kind: "tool list",
                        maximumBytes: configuration.limits.maximumToolCount
                    )
                }
            }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            guard next.utf8.count <= configuration.limits.maximumCursorBytes else {
                throw MCPClientError.payloadTooLarge(
                    kind: "cursor",
                    maximumBytes: configuration.limits.maximumCursorBytes
                )
            }
            guard seenCursors.insert(next).inserted else {
                throw MCPClientError.invalidJSONRPC("tools/list cursor 循环")
            }
            cursor = next
        }
        return discovered
    }

    private func request(
        method: String,
        params: JSONValue?,
        toolName: String?,
        timeout: Duration
    ) async throws -> JSONValue {
        guard state == .running else {
            throw MCPClientError.invalidState("stdio 通道未运行")
        }
        let requestID = String(nextRequestNumber)
        nextRequestNumber += 1
        let request = MCPOutgoingRequest(
            id: .string(requestID),
            method: method,
            params: params
        )
        var data = try encoder.encode(request)
        data.append(0x0A)
        guard data.count <= configuration.limits.maximumOutboundFrameBytes else {
            throw MCPClientError.frameTooLarge(maximumBytes: configuration.limits.maximumOutboundFrameBytes)
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: MCPClientError.cancelled)
                    return
                }
                pending[requestID] = PendingRequest(
                    method: method,
                    toolName: toolName,
                    continuation: continuation
                )
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(requestID)
                }
                pending[requestID]?.timeoutTask = timeoutTask
                Task { [weak self, requestID, method, toolName, requestData = data] in
                    await self?.sendRequest(
                        id: requestID,
                        method: method,
                        toolName: toolName,
                        data: requestData
                    )
                }
            }
        }, onCancel: { [weak self] in
            Task { [weak self] in await self?.cancelRequest(requestID) }
        })
    }

    private func sendRequest(
        id: String,
        method: String,
        toolName: String?,
        data: Data
    ) async {
        guard pending[id] != nil else { return }
        pending[id]?.sent = true
        await emit(.request(
            serverName: configuration.server.serverName,
            requestID: id,
            method: method,
            toolName: toolName,
            byteCount: data.count
        ))
        guard pending[id] != nil else { return }
        do {
            try await transport.write(data)
        } catch {
            let failure = normalize(error)
            await settle(id: id, error: failure)
            state = .stopped
            await transport.stop()
        }
    }

    private func sendNotification(method: String, params: JSONValue?) async throws {
        let notification = MCPOutgoingNotification(method: method, params: params)
        var data = try encoder.encode(notification)
        data.append(0x0A)
        guard data.count <= configuration.limits.maximumOutboundFrameBytes else {
            throw MCPClientError.frameTooLarge(maximumBytes: configuration.limits.maximumOutboundFrameBytes)
        }
        do {
            try await transport.write(data)
        } catch {
            throw normalize(error)
        }
    }

    private func receiveStdout(_ data: Data) async {
        guard state != .stopped else { return }
        do {
            let lines = try framer.append(data)
            for line in lines {
                try await receiveLine(line)
            }
        } catch {
            await failSession(normalize(error))
        }
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        stderrTail.append(text)
        if stderrTail.utf8.count > 8 * 1_024 {
            stderrTail = String(stderrTail.suffix(8 * 1_024))
        }
    }

    private func receiveExit(_ exit: MCPTransportExit) async {
        guard state != .stopping, state != .stopped else {
            processID = nil
            return
        }
        processID = nil
        state = .stopped
        let failure: MCPClientError = exit.errorCode == 0 && exit.exitCode == 0
            ? .transportEOF
            : .transportFailure("exitCode=\(exit.exitCode), errorCode=\(exit.errorCode)")
        await failAll(failure)
    }

    private func receiveLine(_ line: Data) async throws {
        let envelope: MCPIncomingEnvelope
        do {
            envelope = try decoder.decode(MCPIncomingEnvelope.self, from: line)
        } catch {
            throw MCPClientError.malformedJSON
        }
        guard envelope.jsonrpc == "2.0" else {
            throw MCPClientError.invalidJSONRPC("jsonrpc 必须是 2.0")
        }

        if let method = envelope.method {
            guard envelope.id == nil else {
                throw MCPClientError.invalidJSONRPC("不支持服务端请求")
            }
            _ = method
            _ = envelope.params
            return
        }

        guard let id = envelope.id else {
            throw MCPClientError.invalidJSONRPC("响应缺少 id")
        }
        let key = id.stringValue
        guard let request = pending[key] else {
            throw MCPClientError.invalidJSONRPC("响应 id 不匹配")
        }
        guard (envelope.result == nil) != (envelope.error == nil) else {
            throw MCPClientError.invalidJSONRPC("响应必须恰好包含 result 或 error")
        }

        if let remote = envelope.error {
            let failure = MCPClientError.remote(code: remote.code, message: remote.message, data: remote.data)
            await settle(id: key, error: failure)
            await emit(.failure(
                serverName: configuration.server.serverName,
                requestID: key,
                method: request.method,
                toolName: request.toolName,
                error: failure
            ))
            return
        }

        guard let result = envelope.result else {
            throw MCPClientError.invalidJSONRPC("响应 result 缺失")
        }
        let resultBytes = try encodedBytes(result)
        guard resultBytes.count <= configuration.limits.maximumResultPayloadBytes else {
            let failure = MCPClientError.payloadTooLarge(
                kind: "result",
                maximumBytes: configuration.limits.maximumResultPayloadBytes
            )
            await settle(id: key, error: failure)
            await emit(.failure(
                serverName: configuration.server.serverName,
                requestID: key,
                method: request.method,
                toolName: request.toolName,
                error: failure
            ))
            return
        }
        await settle(id: key, result: result)
        await emit(.result(
            serverName: configuration.server.serverName,
            requestID: key,
            method: request.method,
            toolName: request.toolName,
            byteCount: resultBytes.count
        ))
    }

    private func timeoutRequest(_ id: String) async {
        guard let request = pending[id] else { return }
        if request.sent {
            try? await sendCancellationNotification(id: id, reason: "timeout")
        }
        let failure = MCPClientError.timedOut(method: request.method)
        await settle(id: id, error: failure)
        await emit(.failure(
            serverName: configuration.server.serverName,
            requestID: id,
            method: request.method,
            toolName: request.toolName,
            error: failure
        ))
    }

    private func cancelRequest(_ id: String) async {
        guard let request = pending[id] else { return }
        if request.sent {
            try? await sendCancellationNotification(id: id, reason: "cancelled")
        }
        await settle(id: id, error: MCPClientError.cancelled)
        await emit(.cancellation(
            serverName: configuration.server.serverName,
            requestID: id,
            method: request.method,
            toolName: request.toolName
        ))
        state = .stopping
        await transport.stop()
        state = .stopped
        await failAll(.cancelled)
    }

    private func sendCancellationNotification(id: String, reason: String) async throws {
        try await sendNotification(
            method: "notifications/cancelled",
            params: .object([
                "requestId": .string(id),
                "reason": .string(reason)
            ])
        )
    }

    private func settle(id: String, result: JSONValue) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(returning: result)
    }

    private func settle(id: String, error: MCPClientError) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask?.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failAll(_ error: MCPClientError) async {
        let requests = pending
        pending.removeAll()
        for (id, request) in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
            await emit(.failure(
                serverName: configuration.server.serverName,
                requestID: id,
                method: request.method,
                toolName: request.toolName,
                error: error
            ))
        }
    }

    private func failSession(_ error: MCPClientError) async {
        state = .stopping
        await transport.stop()
        state = .stopped
        await failAll(error)
        processID = nil
    }

    private func emit(_ event: MCPClientEvent) async {
        await eventSink(event)
    }

    private func normalize(_ error: Error) -> MCPClientError {
        if let error = error as? MCPClientError { return error }
        if error is CancellationError { return .cancelled }
        return .transportFailure(String(describing: error))
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        do {
            return try decoder.decode(type, from: encodedBytes(value))
        } catch {
            throw MCPClientError.invalidJSONRPC("结果结构不符合预期")
        }
    }

    private func encodedBytes(_ value: JSONValue) throws -> Data {
        try encoder.encode(value)
    }
}

struct MCPClientDiagnostics: Sendable, Equatable {
    enum State: String, Sendable, Equatable {
        case idle
        case running
        case stopping
        case stopped
    }

    let state: State
    let processID: Int32?
    let pendingRequestCount: Int
    let toolCount: Int
    let stderrTail: String
}

private func encodeJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
}
