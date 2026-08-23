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
        let outboundQueuedBytes: Int
        let outboundWriteInFlight: Bool
        let rejectedWriteCount: Int
        let automaticRestartCount: Int
        let lastTransportFailure: String?
        let stderrTail: String
    }

    private struct PendingRequest {
        let method: ISHPluginHostRPCMethod
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct OutboundFrame: Sendable {
        let data: Data
        let requestID: String
    }

    private enum TransportEvent: Sendable {
        // Every callback is tagged with the transport instance that emitted
        // it. iSH can deliver an old process' exit callback after a rejected
        // write has already started a replacement process; without this tag an
        // obsolete exit can mark the fresh Host as exited and fail its new
        // pending requests.
        case stdout(UInt64, Data)
        case stderr(UInt64, Data)
        case exited(UInt64, ISHPluginHostTransportExit)
    }

    private static let maximumRequestBytes = 512 * 1_024
    private static let maximumStderrBytes = 32 * 1_024
    private static let maximumContextEventBatchBytes = 200 * 1_024
    private static let maximumContextEventBatchCount = 128
    private static let defaultRejectedWriteBackoff: [Duration] = [
        .milliseconds(120),
        .milliseconds(400),
        .milliseconds(800),
        .milliseconds(1_600),
        .seconds(3)
    ]
    // The iSH bridge accepts roughly 1 MiB of pending stdin. Keeping a
    // slightly larger client-side queue bounds memory while allowing a few
    // context batches to wait for the bridge to drain.
    private static let maximumOutboundQueueBytes = 2 * 1_024 * 1_024

    private let transport: any ISHPluginHostTransport
    private let requestTimeout: Duration
    private let rejectedWriteBackoff: [Duration]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var state: State = .stopped
    private var framer = ISHPluginHostNDJSONFramer()
    private var nextRequestID: UInt64 = 1
    private var pending: [String: PendingRequest] = [:]
    private var stderrTail = Data()
    private var rejectedWriteCount = 0
    private var automaticRestartCount = 0
    private var lastTransportFailure: String?
    private var synchronizedEventCounts: [String: Int] = [:]
    private var synchronizedSkillDocuments: [String: Data] = [:]
    private var transportEventContinuation: AsyncStream<TransportEvent>.Continuation?
    private var transportEventTask: Task<Void, Never>?
    private var outboundQueue: [OutboundFrame] = []
    private var outboundQueueHead = 0
    private var outboundQueueBytes = 0
    private var outboundWriteInFlight = false
    private var outboundDrainTask: Task<Void, Never>?
    private var outboundGeneration: UInt64 = 0
    private var transportGeneration: UInt64 = 0

    init(
        transport: any ISHPluginHostTransport,
        requestTimeout: Duration = .seconds(120),
        rejectedWriteBackoff: [Duration] = ISHPluginHostClient.defaultRejectedWriteBackoff
    ) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.rejectedWriteBackoff = rejectedWriteBackoff
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
        synchronizedEventCounts.removeAll(keepingCapacity: true)
        synchronizedSkillDocuments.removeAll(keepingCapacity: true)
        resetOutboundQueue()
        transportGeneration &+= 1
        let transportGeneration = transportGeneration
        let eventContinuation = startTransportEventConsumer(generation: transportGeneration)
        do {
            let pid = try await transport.start(
                onStdout: { data in
                    eventContinuation.yield(.stdout(transportGeneration, data))
                },
                onStderr: { data in
                    eventContinuation.yield(.stderr(transportGeneration, data))
                },
                onExit: { exit in
                    eventContinuation.yield(.exited(transportGeneration, exit))
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
        synchronizedEventCounts.removeAll(keepingCapacity: true)
        synchronizedSkillDocuments.removeAll(keepingCapacity: true)
        resetOutboundQueue()
        failAll(with: CancellationError())
        stopTransportEventConsumer()
        await transport.stop()
    }

    func diagnostics() -> Diagnostics {
        Diagnostics(
            state: state,
            pendingRequestCount: pending.count,
            outboundQueuedBytes: outboundQueueBytes,
            outboundWriteInFlight: outboundWriteInFlight,
            rejectedWriteCount: rejectedWriteCount,
            automaticRestartCount: automaticRestartCount,
            lastTransportFailure: lastTransportFailure,
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

    func synchronizeContext(
        sessionId: String,
        events: [ISHPluginHostContextEvent],
        skills: [MobileSkillDefinition]
    ) async throws -> ISHPluginHostContextSyncResponse {
        var cursor = synchronizedEventCounts[sessionId] ?? 0
        guard cursor <= events.count else {
            throw ISHPluginHostError.invalidState(
                "The native trajectory became shorter than the synchronized Plugin Host session."
            )
        }

        let wireSkills = skills.map(ISHPluginHostSkillDefinition.init)
        let skillDocument = try encoder.encode(wireSkills)
        let skillsChanged = synchronizedSkillDocuments[sessionId] != skillDocument
        var finalResponse: ISHPluginHostContextSyncResponse?
        var shouldSynchronizeSkills = skillsChanged
        repeat {
            let batch = Self.contextEventBatch(events, startingAt: cursor)
            let response = try await call(
                .contextSync,
                params: ISHPluginHostContextSyncRequest(
                    sessionId: sessionId,
                    startingAtSeq: UInt64(cursor),
                    events: batch,
                    skills: shouldSynchronizeSkills ? wireSkills : nil
                ),
                as: ISHPluginHostContextSyncResponse.self,
                timeout: .seconds(120)
            )
            guard response.totalEvents == cursor + batch.count else {
                throw ISHPluginHostError.invalidState(
                    "Plugin Host context synchronization returned an inconsistent event count."
                )
            }
            cursor = response.totalEvents
            synchronizedEventCounts[sessionId] = cursor
            if shouldSynchronizeSkills {
                synchronizedSkillDocuments[sessionId] = skillDocument
            }
            finalResponse = response
            shouldSynchronizeSkills = false
        } while cursor < events.count

        guard let finalResponse else {
            throw ISHPluginHostError.invalidState(
                "Plugin Host context synchronization produced no response."
            )
        }
        return finalResponse
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
                enqueueOutboundFrame(OutboundFrame(data: encoded, requestID: id))
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

    private static func contextEventBatch(
        _ events: [ISHPluginHostContextEvent],
        startingAt cursor: Int
    ) -> [ISHPluginHostContextEvent] {
        guard cursor < events.count else { return [] }
        let encoder = JSONEncoder()
        var output: [ISHPluginHostContextEvent] = []
        output.reserveCapacity(min(maximumContextEventBatchCount, events.count - cursor))
        var encodedBytes = 0
        for event in events[cursor...] {
            let eventBytes = (try? encoder.encode(event).count) ?? maximumContextEventBatchBytes
            if !output.isEmpty,
               (output.count >= maximumContextEventBatchCount
                || encodedBytes + eventBytes > maximumContextEventBatchBytes) {
                break
            }
            output.append(event)
            encodedBytes += eventBytes
        }
        return output
    }

    private func enqueueOutboundFrame(_ frame: OutboundFrame) {
        guard outboundQueueBytes + frame.data.count <= Self.maximumOutboundQueueBytes else {
            failRequest(
                id: frame.requestID,
                with: ISHPluginHostError.invalidState(
                    "The plugin host outbound queue is full; the request was not sent."
                )
            )
            return
        }
        outboundQueue.append(frame)
        outboundQueueBytes += frame.data.count
        scheduleOutboundDrain()
    }

    private func scheduleOutboundDrain() {
        guard !outboundWriteInFlight else { return }
        outboundWriteInFlight = true
        let generation = outboundGeneration
        outboundDrainTask = Task { [weak self] in
            await self?.drainOutboundQueue(generation: generation)
        }
    }

    private func drainOutboundQueue(generation: UInt64) async {
        while generation == outboundGeneration, !Task.isCancelled {
            guard outboundQueueHead < outboundQueue.count else { break }
            let frame = outboundQueue[outboundQueueHead]

            // A cancelled or timed-out request no longer needs a wire frame.
            // Dropping it here prevents stale context batches from occupying
            // the iSH stdin queue after the caller has gone away.
            guard pending[frame.requestID] != nil else {
                removeFirstOutboundFrame()
                continue
            }

            await send(
                frame.data,
                requestID: frame.requestID,
                generation: generation
            )
            guard generation == outboundGeneration else { return }
            removeFirstOutboundFrame()
        }

        guard generation == outboundGeneration else { return }
        outboundWriteInFlight = false
        outboundDrainTask = nil
        if outboundQueueHead < outboundQueue.count {
            scheduleOutboundDrain()
        }
    }

    private func removeFirstOutboundFrame() {
        guard outboundQueueHead < outboundQueue.count else { return }
        let frame = outboundQueue[outboundQueueHead]
        outboundQueueHead += 1
        outboundQueueBytes = max(0, outboundQueueBytes - frame.data.count)
        if outboundQueueHead == outboundQueue.count {
            outboundQueue.removeAll(keepingCapacity: true)
            outboundQueueHead = 0
        } else if outboundQueueHead >= 64,
                  outboundQueueHead * 2 >= outboundQueue.count {
            outboundQueue.removeFirst(outboundQueueHead)
            outboundQueueHead = 0
        }
    }

    private func resetOutboundQueue() {
        outboundGeneration &+= 1
        outboundDrainTask?.cancel()
        outboundDrainTask = nil
        outboundQueue.removeAll(keepingCapacity: true)
        outboundQueueHead = 0
        outboundQueueBytes = 0
        outboundWriteInFlight = false
    }

    private func send(
        _ data: Data,
        requestID: String,
        generation: UInt64
    ) async {
        var hostRestartAttempt = 0
        while hostRestartAttempt <= 1 {
            // A newly started transport already passed its stdin readiness
            // probe, so a short post-restart window is sufficient. The longer
            // first window still absorbs ordinary iSH backpressure.
            let backoffCount = hostRestartAttempt == 0
                ? rejectedWriteBackoff.count
                : min(2, rejectedWriteBackoff.count)
            for attempt in 0...backoffCount {
                guard generation == outboundGeneration,
                      pending[requestID] != nil,
                      !Task.isCancelled else {
                    failRequest(id: requestID, with: CancellationError())
                    return
                }
                do {
                    try await transport.write(data)
                    return
                } catch let error as ISHPluginHostError where error == .transportRejectedWrite {
                    rejectedWriteCount += 1
                    let method = pending[requestID]?.method.rawValue ?? "unknown"
                    lastTransportFailure = "stdin write rejected for \(method) (attempt \(attempt + 1), host \(hostRestartAttempt + 1))"
                    guard attempt < backoffCount else {
                        if hostRestartAttempt == 0 {
                            do {
                                try await restartTransportPreservingOutboundQueue(
                                    generation: generation,
                                    cause: error
                                )
                                hostRestartAttempt += 1
                                break
                            } catch {
                                lastTransportFailure = "automatic host restart failed: \(error.localizedDescription)"
                                await invalidateTransport(after: error)
                                return
                            }
                        }
                        // writeStdin returned false for every attempt, so this
                        // frame is known not to have entered Node. It is safe to
                        // fail it after one bounded Host restart; no mutation is
                        // replayed after an ambiguous successful write.
                        await invalidateTransport(after: error)
                        return
                    }
                    do {
                        try await Task.sleep(for: rejectedWriteBackoff[attempt])
                    } catch {
                        failRequest(id: requestID, with: CancellationError())
                        return
                    }
                } catch {
                    lastTransportFailure = error.localizedDescription
                    await invalidateTransport(after: error)
                    return
                }
            }
        }
    }

    /// Restarts only after writeStdin explicitly rejected the current frame.
    /// The outbound queue and pending continuations remain intact, allowing the
    /// current frame and later unsent frames to drain against the fresh Node
    /// process. Requests whose write succeeded are never replayed here.
    private func restartTransportPreservingOutboundQueue(
        generation: UInt64,
        cause: Error
    ) async throws {
        guard generation == outboundGeneration else { throw CancellationError() }
        state = .stopped
        stopTransportEventConsumer()
        await transport.stop()
        guard generation == outboundGeneration else { throw CancellationError() }

        state = .starting
        framer = ISHPluginHostNDJSONFramer()
        synchronizedEventCounts.removeAll(keepingCapacity: true)
        synchronizedSkillDocuments.removeAll(keepingCapacity: true)
        transportGeneration &+= 1
        let transportGeneration = transportGeneration
        let eventContinuation = startTransportEventConsumer(generation: transportGeneration)
        do {
            let pid = try await transport.start(
                onStdout: { data in eventContinuation.yield(.stdout(transportGeneration, data)) },
                onStderr: { data in eventContinuation.yield(.stderr(transportGeneration, data)) },
                onExit: { exit in
                    eventContinuation.yield(.exited(transportGeneration, exit))
                    eventContinuation.finish()
                }
            )
            guard generation == outboundGeneration else {
                throw CancellationError()
            }
            guard case .starting = state else {
                throw ISHPluginHostError.invalidState(
                    "The plugin host exited during automatic recovery."
                )
            }
            state = .running(pid: pid)
            automaticRestartCount += 1
            lastTransportFailure = "restarted plugin host after \(cause.localizedDescription)"
        } catch {
            state = .stopped
            stopTransportEventConsumer()
            await transport.stop()
            throw error
        }
    }

    private func invalidateTransport(after error: Error) async {
        resetOutboundQueue()
        state = .stopped
        failAll(with: error)
        stopTransportEventConsumer()
        await transport.stop()
    }

    private func startTransportEventConsumer(generation: UInt64) -> AsyncStream<TransportEvent>.Continuation {
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
        case let .stdout(generation, data):
            guard generation == transportGeneration else { return }
            await receiveStdout(data)
        case let .stderr(generation, data):
            guard generation == transportGeneration else { return }
            receiveStderr(data)
        case let .exited(generation, exit):
            guard generation == transportGeneration else { return }
            receiveExit(exit)
        }
    }

    private func receiveStdout(_ data: Data) async {
        do {
            for line in try framer.append(data) {
                try receiveLine(line)
            }
        } catch {
            resetOutboundQueue()
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
        resetOutboundQueue()
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
        resetOutboundQueue()
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
