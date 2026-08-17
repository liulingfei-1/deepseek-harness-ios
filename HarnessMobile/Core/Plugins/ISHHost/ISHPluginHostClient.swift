import Foundation

actor ISHPluginHostClient {
    enum State: Sendable, Equatable {
        case stopped
        case starting
        case running(pid: Int32)
        case exited(code: Int, errorCode: Int)
    }

    struct Diagnostics: Sendable, Equatable {
        let state: State
        let pendingRequestCount: Int
        let stderrTail: String
    }

    private struct PendingRequest {
        let method: ISHPluginHostRPCMethod
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private enum TransportEvent: Sendable {
        case stdout(Data)
        case stderr(Data)
        case exited(ISHPluginHostTransportExit)
    }

    private static let maximumRequestBytes = 512 * 1_024
    private static let maximumStderrBytes = 32 * 1_024

    private let transport: any ISHPluginHostTransport
    private let requestTimeout: Duration
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var state: State = .stopped
    private var framer = ISHPluginHostNDJSONFramer()
    private var nextRequestID: UInt64 = 1
    private var pending: [String: PendingRequest] = [:]
    private var stderrTail = Data()
    private var transportEventContinuation: AsyncStream<TransportEvent>.Continuation?
    private var transportEventTask: Task<Void, Never>?

    init(
        transport: any ISHPluginHostTransport,
        requestTimeout: Duration = .seconds(120)
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func start() async throws {
        switch state {
        case .running:
            return
        case .starting:
            throw ISHPluginHostError.invalidState("The plugin host is already starting.")
        case .stopped, .exited:
            break
        }

        state = .starting
        framer = ISHPluginHostNDJSONFramer()
        stderrTail.removeAll(keepingCapacity: true)
        let eventContinuation = startTransportEventConsumer()
        do {
            let pid = try await transport.start(
                onStdout: { data in
                    eventContinuation.yield(.stdout(data))
                },
                onStderr: { data in
                    eventContinuation.yield(.stderr(data))
                },
                onExit: { exit in
                    eventContinuation.yield(.exited(exit))
                    eventContinuation.finish()
                }
            )
            switch state {
            case .starting:
                state = .running(pid: pid)
            case let .exited(code, errorCode):
                throw ISHPluginHostError.transportExited(code: code, errorCode: errorCode)
            case .stopped:
                throw ISHPluginHostError.invalidState("The plugin host stopped while it was starting.")
            case .running:
                throw ISHPluginHostError.invalidState("The plugin host entered an invalid running state while starting.")
            }
        } catch {
            if case .starting = state {
                state = .stopped
            }
            stopTransportEventConsumer()
            throw error
        }
    }

    func stop() async {
        state = .stopped
        failAll(with: CancellationError())
        stopTransportEventConsumer()
        await transport.stop()
    }

    func diagnostics() -> Diagnostics {
        Diagnostics(
            state: state,
            pendingRequestCount: pending.count,
            stderrTail: String(decoding: stderrTail, as: UTF8.self)
        )
    }

    func ping() async throws -> ISHPluginHostPing {
        try await call(.ping, params: EmptyParams(), as: ISHPluginHostPing.self)
    }

    func inventory(sessionId: String? = nil) async throws -> ISHPluginHostInventory {
        try await call(
            .inventory,
            params: ISHPluginHostInventoryRequest(sessionId: sessionId),
            as: ISHPluginHostInventory.self
        )
    }

    func define(_ request: ISHPluginHostDefineRequest) async throws -> ISHPluginHostDefineReceipt {
        try await call(.define, params: request, as: ISHPluginHostDefineReceipt.self)
    }

    func run(_ request: ISHPluginHostRunRequest) async throws -> ISHPluginHostRunResponse {
        try await call(.run, params: request, as: ISHPluginHostRunResponse.self)
    }

    func stopPlugin(_ request: ISHPluginHostPluginRequest) async throws -> ISHPluginHostStopResponse {
        try await call(.stop, params: request, as: ISHPluginHostStopResponse.self)
    }

    func undefine(_ request: ISHPluginHostPluginRequest) async throws -> ISHPluginHostUndefineResponse {
        try await call(.undefine, params: request, as: ISHPluginHostUndefineResponse.self)
    }

    func contributions(sessionId: String? = nil) async throws -> ISHPluginHostContributions {
        try await call(
            .contributions,
            params: ISHPluginHostContributionsRequest(sessionId: sessionId),
            as: ISHPluginHostContributions.self
        )
    }

    func settings() async throws -> ISHPluginSettingsSnapshot {
        try await call(
            .settingsDescribe,
            params: EmptyParams(),
            as: ISHPluginSettingsSnapshot.self
        )
    }

    func mutateSettings(
        _ request: ISHPluginSettingsMutateRequest
    ) async throws -> ISHPluginSettingsNamespace {
        try await call(
            .settingsMutate,
            params: request,
            as: ISHPluginSettingsNamespace.self
        )
    }

    func updateSettings(
        _ request: ISHPluginSettingsUpdateRequest
    ) async throws -> ISHPluginSettingsNamespace {
        try await call(
            .settingsUpdate,
            params: request,
            as: ISHPluginSettingsNamespace.self
        )
    }

    func replaceSettings(
        _ request: ISHPluginSettingsReplaceRequest
    ) async throws -> ISHPluginSettingsNamespace {
        try await call(
            .settingsReplace,
            params: request,
            as: ISHPluginSettingsNamespace.self
        )
    }

    func marketCatalog(forceRefresh: Bool = false) async throws -> ISHMarketplaceCatalog {
        try await call(
            .marketCatalog,
            params: ISHMarketplaceCatalogRequest(forceRefresh: forceRefresh),
            as: ISHMarketplaceCatalog.self,
            timeout: .seconds(90)
        )
    }

    func marketplacePlugins() async throws -> ISHMarketplacePluginList {
        try await call(
            .pluginList,
            params: EmptyParams(),
            as: ISHMarketplacePluginList.self
        )
    }

    func prepareNativeMarketplacePlugin(
        source: ISHMarketplacePluginSource
    ) async throws -> ISHMarketplacePluginPrepareNativeResponse {
        try await call(
            .pluginPrepareNative,
            params: ISHMarketplacePluginPrepareNativeRequest(source: source),
            as: ISHMarketplacePluginPrepareNativeResponse.self,
            timeout: .seconds(300)
        )
    }

    func discardPreparedNativeMarketplacePlugin(
        token: String
    ) async throws -> ISHMarketplacePluginDiscardPreparedNativeResponse {
        try await call(
            .pluginDiscardPreparedNative,
            params: ISHMarketplacePluginDiscardPreparedNativeRequest(preparedToken: token),
            as: ISHMarketplacePluginDiscardPreparedNativeResponse.self,
            timeout: .seconds(30)
        )
    }

    func installMarketplacePlugin(
        _ request: ISHMarketplacePluginInstallRequest
    ) async throws -> ISHMarketplacePluginInstallResponse {
        try await call(
            .pluginInstall,
            params: request,
            as: ISHMarketplacePluginInstallResponse.self,
            timeout: .seconds(1_800)
        )
    }

    func setMarketplacePluginEnabled(
        _ request: ISHMarketplacePluginSetEnabledRequest
    ) async throws -> ISHMarketplacePluginMutationResponse {
        try await call(
            .pluginSetEnabled,
            params: request,
            as: ISHMarketplacePluginMutationResponse.self,
            timeout: .seconds(180)
        )
    }

    func uninstallMarketplacePlugin(
        id: String
    ) async throws -> ISHMarketplacePluginUninstallResponse {
        try await call(
            .pluginUninstall,
            params: ISHMarketplacePluginUninstallRequest(id: id),
            as: ISHMarketplacePluginUninstallResponse.self,
            timeout: .seconds(1_800)
        )
    }

    func clearMarketplaceCache(includeNpm: Bool = false) async throws -> ISHMarketplaceCacheClearResponse {
        try await call(
            .pluginCacheClear,
            params: ISHMarketplaceCacheClearRequest(includeNpm: includeNpm),
            as: ISHMarketplaceCacheClearResponse.self,
            timeout: .seconds(300)
        )
    }

    func invoke(_ invocation: ISHPluginHostInvokeRequest) async throws -> JSONValue {
        try await request(method: .invoke, params: try Self.jsonValue(from: invocation))
    }

    func request(
        method: ISHPluginHostRPCMethod,
        params: JSONValue = .object([:]),
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard case .running = state else {
            throw ISHPluginHostError.invalidState("The plugin host must be running before an RPC request is sent.")
        }
        try ISHPluginHostCredentialFirewall.validate(params)

        let id = String(nextRequestID)
        nextRequestID &+= 1
        let wire = ISHPluginHostRPCRequest(id: id, method: method, params: params)
        let encoded = try encoder.encode(wire) + Data([0x0A])
        guard encoded.count <= Self.maximumRequestBytes else {
            throw ISHPluginHostError.requestTooLarge(maximumBytes: Self.maximumRequestBytes)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let effectiveTimeout = timeout ?? requestTimeout
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: effectiveTimeout)
                    } catch {
                        return
                    }
                    await self?.timeoutRequest(id: id)
                }
                pending[id] = PendingRequest(
                    method: method,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.send(encoded, requestID: id)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    private func call<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: ISHPluginHostRPCMethod,
        params: Params,
        as resultType: Result.Type,
        timeout: Duration? = nil
    ) async throws -> Result {
        let result = try await request(
            method: method,
            params: try Self.jsonValue(from: params),
            timeout: timeout
        )
        return try Self.decode(resultType, from: result)
    }

    private func send(_ data: Data, requestID: String) async {
        do {
            try await transport.write(data)
        } catch {
            failRequest(id: requestID, with: error)
        }
    }

    private func startTransportEventConsumer() -> AsyncStream<TransportEvent>.Continuation {
        stopTransportEventConsumer()
        let (stream, continuation) = AsyncStream<TransportEvent>.makeStream()
        transportEventContinuation = continuation
        transportEventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.receiveTransportEvent(event)
            }
        }
        return continuation
    }

    private func stopTransportEventConsumer() {
        transportEventContinuation?.finish()
        transportEventContinuation = nil
        transportEventTask?.cancel()
        transportEventTask = nil
    }

    private func receiveTransportEvent(_ event: TransportEvent) async {
        switch event {
        case let .stdout(data):
            await receiveStdout(data)
        case let .stderr(data):
            receiveStderr(data)
        case let .exited(exit):
            receiveExit(exit)
        }
    }

    private func receiveStdout(_ data: Data) async {
        do {
            for line in try framer.append(data) {
                try receiveLine(line)
            }
        } catch {
            failAll(with: error)
            state = .stopped
            stopTransportEventConsumer()
            await transport.stop()
        }
    }

    private func receiveLine(_ line: Data) throws {
        let response: ISHPluginHostRPCResponse
        do {
            response = try decoder.decode(ISHPluginHostRPCResponse.self, from: line)
        } catch {
            throw ISHPluginHostError.invalidProtocol("The plugin host emitted invalid JSON-RPC: \(error.localizedDescription)")
        }
        guard response.jsonrpc == "2.0" else {
            throw ISHPluginHostError.invalidProtocol("The plugin host emitted an unsupported JSON-RPC version.")
        }
        guard let id = response.id, let request = pending.removeValue(forKey: id) else {
            return
        }
        request.timeoutTask.cancel()
        if let error = response.error {
            request.continuation.resume(
                throwing: ISHPluginHostError.remote(
                    code: error.code,
                    message: error.message,
                    data: error.data
                )
            )
            return
        }
        request.continuation.resume(returning: response.result ?? .null)
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrTail.append(data)
        if stderrTail.count > Self.maximumStderrBytes {
            stderrTail = Data(stderrTail.suffix(Self.maximumStderrBytes))
        }
    }

    private func receiveExit(_ exit: ISHPluginHostTransportExit) {
        guard state != .stopped else { return }
        state = .exited(code: exit.exitCode, errorCode: exit.errorCode)
        failAll(
            with: ISHPluginHostError.transportExited(
                code: exit.exitCode,
                errorCode: exit.errorCode
            )
        )
    }

    private func timeoutRequest(id: String) async {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        let timeout = ISHPluginHostError.timedOut(method: request.method)
        request.continuation.resume(throwing: timeout)

        // Marketplace mutations are serialized inside the Node Host. Once a
        // request misses its deadline, leaving that process alive can make
        // later ping/list calls queue indefinitely behind a stalled download
        // or npm process. Recycle the isolated Host so the next operation
        // starts from a clean local process instead of inheriting that queue.
        state = .stopped
        failAll(with: timeout)
        stopTransportEventConsumer()
        await transport.stop()
    }

    private func cancelRequest(id: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func failRequest(id: String, with error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failAll(with error: Error) {
        let requests = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private static func jsonValue<Value: Encodable>(from value: Value) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct EmptyParams: Codable, Sendable {}
