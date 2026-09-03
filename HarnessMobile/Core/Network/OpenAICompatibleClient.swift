import Foundation

final class OpenAICompatibleClient: NSObject, LLMStreamingClient, ModelCatalogDiscovering, @unchecked Sendable {
    private static let maximumModelRequestBodyBytes = 24 * 1_024 * 1_024
    private let redirectDelegate: SameHostRedirectDelegate
    private let session: URLSession
    private let modelDiscoveryCache: ModelDiscoveryCache
    private let filesClient: DeepSeekFilesClient
    private let activeStreamLock = NSLock()
    private var activeStreams: [UUID: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation] = [:]

    static func acceptsTerminalMarkers(
        sawSemanticFinish: Bool,
        sawDone: Bool
    ) -> Bool {
        sawSemanticFinish || sawDone
    }

    static func isDoneMarker(_ payload: String) -> Bool {
        payload.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("[DONE]") == .orderedSame
    }

    init(
        filesClient: DeepSeekFilesClient,
        sessionConfiguration: URLSessionConfiguration? = nil,
        modelDiscoveryCache: ModelDiscoveryCache = ModelDiscoveryCache()
    ) {
        let configuration = sessionConfiguration ?? Self.makeSessionConfiguration()

        let redirectDelegate = SameHostRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        self.modelDiscoveryCache = modelDiscoveryCache
        self.filesClient = filesClient
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        super.init()
        HarnessLLMSessionRegistry.shared.register(session) { [weak self] reason in
            self?.failActiveStreamsForNetworkTransition(reason: reason)
        }
    }

    override convenience init() {
        self.init(filesClient: DeepSeekFilesClient())
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Long DeepSeek reasoning requests can legitimately take more than a
        // minute before the first SSE byte, especially with a large context.
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    deinit {
        HarnessLLMSessionRegistry.shared.unregister(session)
        session.invalidateAndCancel()
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let streamID = UUID()
        return AsyncThrowingStream { [weak self] continuation in
            self?.registerActiveStream(continuation, id: streamID)
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.unregisterActiveStream(id: streamID) }
                do {
                    try await self.perform(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable [weak self] _ in
                self?.unregisterActiveStream(id: streamID)
                task.cancel()
            }
        }
    }

    private func registerActiveStream(
        _ continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation,
        id: UUID
    ) {
        activeStreamLock.lock()
        activeStreams[id] = continuation
        activeStreamLock.unlock()
    }

    private func unregisterActiveStream(id: UUID) {
        activeStreamLock.lock()
        activeStreams.removeValue(forKey: id)
        activeStreamLock.unlock()
    }

    private func failActiveStreamsForNetworkTransition(reason: String) {
        activeStreamLock.lock()
        let streams = Array(activeStreams.values)
        activeStreams.removeAll()
        activeStreamLock.unlock()
        for stream in streams {
            stream.finish(throwing: ModelClientError.networkPathChanged(reason))
        }
        session.reset(completionHandler: {})
    }

    func discoverModels(_ request: ModelDiscoveryRequest) async throws -> ModelCatalogSnapshot {
        let descriptor = ModelProviderCatalog.descriptor(for: request.configuration.providerID)
        guard descriptor.supportsRemoteModelDiscovery else {
            throw ModelDiscoveryError.unsupportedProvider(request.configuration.providerID)
        }
        let configuration = request.configuration
        let configuredOrigin = try configuration.credentialOrigin()
        guard configuredOrigin == request.trustedOrigin else {
            throw ModelDiscoveryError.untrustedOrigin
        }

        let adapter = try ModelProviderAdapterRegistry.adapter(for: configuration.providerID)
        let endpoint = try adapter.modelListURL(for: configuration)
        guard Self.isSameHTTPSOrigin(endpoint, try configuration.chatCompletionsURL()) else {
            throw ModelDiscoveryError.untrustedOrigin
        }

        let apiKey = try Self.normalizedDiscoveryAPIKey(request.apiKey)
        let cacheKey = ModelDiscoveryCacheKey(
            providerID: configuration.providerID,
            endpoint: endpoint,
            apiKey: apiKey
        )
        if !request.forceRefresh,
           let cached = await modelDiscoveryCache.load(
               key: cacheKey,
               adapterSchemaVersion: adapter.modelListSchemaVersion
           ) {
            return cached
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw ModelClientError.invalidResponse
        }
        guard let responseURL = httpResponse.url,
              Self.isSameHTTPSOrigin(endpoint, responseURL) else {
            bytes.task.cancel()
            throw ModelDiscoveryError.untrustedOrigin
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw try await makeHTTPError(
                response: httpResponse,
                bytes: bytes,
                adapter: adapter
            )
        }
        let data = try await readBoundedModelList(
            bytes: bytes,
            declaredLength: httpResponse.value(forHTTPHeaderField: "Content-Length")
        )
        let models = try adapter.decodeModelList(data)
        let fetchedAt = Date()
        try? await modelDiscoveryCache.store(
            key: cacheKey,
            adapterSchemaVersion: adapter.modelListSchemaVersion,
            fetchedAt: fetchedAt,
            models: models
        )
        return ModelCatalogSnapshot(
            providerID: configuration.providerID,
            source: .remote,
            catalogVersion: "remote-models-v\(adapter.modelListSchemaVersion)",
            fetchedAt: fetchedAt,
            models: models
        )
    }

    private func perform(
        _ request: ModelRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let configuration = try request.configuration.validated()
        let validatedRequest = ModelRequest(
            configuration: configuration,
            apiKey: request.apiKey,
            systemPrompt: request.systemPrompt,
            messages: request.messages,
            tools: request.tools,
            imagePayloads: request.imagePayloads
        )
        let adapter = try ModelProviderAdapterRegistry.adapter(for: configuration.providerID)
        switch adapter.streamingDialect {
        case .deepSeekChatCompletions:
            let prepared = await filesClient.prepare(validatedRequest)
            do {
                try await performOpenAI(
                    prepared,
                    adapter: adapter,
                    continuation: continuation
                )
            } catch {
                guard Self.shouldRetryInlineImages(after: error, request: prepared) else {
                    throw error
                }
                for payload in prepared.imagePayloads where payload.fileID != nil {
                    await filesClient.invalidate(payload, request: validatedRequest)
                }
                try await performOpenAI(
                    Self.inlineImageRequest(prepared),
                    adapter: adapter,
                    continuation: continuation
                )
            }
        case .openAIChatCompletions:
            try await performOpenAI(
                validatedRequest,
                adapter: adapter,
                continuation: continuation
            )
        case .anthropicMessages:
            try await performAnthropic(
                validatedRequest,
                adapter: adapter,
                continuation: continuation
            )
        }
    }

    static func shouldRetryInlineImages(after error: Error, request: ModelRequest) -> Bool {
        guard request.imagePayloads.contains(where: { $0.fileID != nil }) else { return false }
        guard case let ModelClientError.httpFailure(metadata, message) = error else { return false }
        guard [400, 404, 422].contains(metadata.status) else { return false }
        let text = "\(metadata.code ?? "") \(message)".lowercased()
        guard text.contains("file") else { return false }
        return ["expired", "not found", "not_found", "invalid", "unknown", "does not exist", "doesn't exist"]
            .contains(where: text.contains)
    }

    private static func inlineImageRequest(_ request: ModelRequest) -> ModelRequest {
        ModelRequest(
            configuration: request.configuration,
            apiKey: request.apiKey,
            systemPrompt: request.systemPrompt,
            messages: request.messages,
            tools: request.tools,
            imagePayloads: request.imagePayloads.map {
                ModelImagePayload(id: $0.id, mimeType: $0.mimeType, data: $0.data)
            }
        )
    }

    private func performOpenAI(
        _ request: ModelRequest,
        adapter: any ModelProviderAdapter,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try adapter.makeStreamingRequest(request)
        guard let encodedBody = urlRequest.httpBody else {
            throw ModelClientError.invalidResponse
        }
        guard encodedBody.count <= Self.maximumModelRequestBodyBytes else {
            throw ModelClientError.requestTooLarge
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw try await makeHTTPError(
                response: httpResponse,
                bytes: bytes,
                adapter: adapter
            )
        }
        guard let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
              contentType
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "text/event-stream" else {
            bytes.task.cancel()
            throw ModelClientError.unexpectedContentType
        }

        var sse = SSEEventDecoder()
        var sawSemanticFinish = false
        var sawDone = false
        var sawToolCallDelta = false
        try await withTaskCancellationHandler {
            streamLoop: for try await byte in bytes {
                try Task.checkCancellation()
                guard let payload = try sse.consume(byte: byte) else {
                    continue
                }
                if Self.isDoneMarker(payload) {
                    sawDone = true
                    break streamLoop
                }
                for event in try decodeEvents(payload) {
                    if case .finish = event {
                        if sawSemanticFinish {
                            // Gateways like OpenRouter re-emit finish_reason on
                            // the trailing usage-bearing chunk; the second
                            // finish is the same semantic stop, so drop it
                            // instead of failing the run downstream.
                            continue
                        }
                        sawSemanticFinish = true
                    }
                    if case .toolCallDelta = event {
                        sawToolCallDelta = true
                    }
                    continuation.yield(event)
                }
            }

            if !sawDone, let payload = try sse.finish() {
                if Self.isDoneMarker(payload) {
                    sawDone = true
                } else {
                    for event in try decodeEvents(payload) {
                        if case .finish = event {
                            if sawSemanticFinish {
                                continue
                            }
                            sawSemanticFinish = true
                        }
                        if case .toolCallDelta = event {
                            sawToolCallDelta = true
                        }
                        continuation.yield(event)
                    }
                }
            }
        } onCancel: {
            bytes.task.cancel()
        }

        // Some OpenAI-compatible gateways close after a semantic finish and
        // omit [DONE]; others send only [DONE]. Accept either terminal form,
        // but synthesize a constrained finish event for the latter so the
        // Agent loop still has an explicit terminal reason. A stream with
        // neither marker remains a truncated response.
        if sawDone, !sawSemanticFinish {
            continuation.yield(.finish(sawToolCallDelta ? .toolCalls : .stop))
            sawSemanticFinish = true
        }
        if !Self.acceptsTerminalMarkers(
            sawSemanticFinish: sawSemanticFinish,
            sawDone: sawDone
        ) {
            throw ModelClientError.incompleteStream
        }
    }

    private func performAnthropic(
        _ request: ModelRequest,
        adapter: any ModelProviderAdapter,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try adapter.makeStreamingRequest(request)
        guard let encodedBody = urlRequest.httpBody else {
            throw ModelClientError.invalidResponse
        }
        guard encodedBody.count <= Self.maximumModelRequestBodyBytes else {
            throw ModelClientError.requestTooLarge
        }

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw try await makeHTTPError(
                response: httpResponse,
                bytes: bytes,
                adapter: adapter
            )
        }
        guard let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
              contentType
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "text/event-stream" else {
            bytes.task.cancel()
            throw ModelClientError.unexpectedContentType
        }

        var sse = SSEEventDecoder()
        var decoder = AnthropicStreamDecoder()
        var sawSemanticFinish = false
        var sawMessageStop = false

        func consume(_ payload: String) throws {
            if AnthropicStreamDecoder.isMessageStop(payload) {
                sawMessageStop = true
            }
            for event in try decoder.decodeEvents(payload) {
                if case .finish = event {
                    sawSemanticFinish = true
                }
                continuation.yield(event)
            }
        }

        try await withTaskCancellationHandler {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard let payload = try sse.consume(byte: byte) else { continue }
                try consume(payload)
                if sawMessageStop { break }
            }
            if !sawMessageStop, let payload = try sse.finish() {
                try consume(payload)
            }
        } onCancel: {
            bytes.task.cancel()
        }

        // Anthropic normally emits both message_delta(stop_reason) and
        // message_stop. A few compatible gateways omit one of them; a
        // semantic stop is still a complete response, while message_stop
        // without a stop reason is safely interpreted as a normal stop.
        if sawMessageStop, !sawSemanticFinish {
            continuation.yield(.finish(.stop))
            sawSemanticFinish = true
        }
        if !Self.acceptsTerminalMarkers(
            sawSemanticFinish: sawSemanticFinish,
            sawDone: sawMessageStop
        ) {
            throw ModelClientError.incompleteStream
        }
    }

    func decodeEvents(_ payload: String) throws -> [LLMStreamEvent] {
        guard payload.utf8.count <= 1_048_576 else {
            throw ModelClientError.eventTooLarge
        }
        guard let data = payload.data(using: .utf8) else {
            throw ModelClientError.malformedEvent
        }

        let chunk: ChatStreamChunk
        do {
            chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
        } catch {
            throw ModelClientError.malformedEvent
        }

        var events: [LLMStreamEvent] = []
        for choice in chunk.choices ?? [] {
            guard choice.index == 0 else {
                throw ModelClientError.unexpectedChoice
            }
            if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            } else if let reasoning = OpenAICompatibleWireSerializer.alternateReasoningDelta(
                in: payload
            ) {
                events.append(.reasoning(reasoning))
            }
            if let content = choice.delta?.content, !content.isEmpty {
                events.append(.text(content))
            }
            for call in choice.delta?.toolCalls ?? [] {
                events.append(
                    .toolCallDelta(
                        index: call.index,
                        id: call.id,
                        type: call.type,
                        name: call.function?.name,
                        arguments: call.function?.arguments ?? ""
                    )
                )
            }
            if let rawReason = choice.finishReason {
                events.append(.finish(ModelFinishReason(rawValue: rawReason) ?? .unknown))
            }
        }

        if let usage = chunk.usage {
            events.append(.usage(try decodeUsage(usage)))
        }
        return events
    }

    static func encodeOpenAIRequestBody(_ request: ModelRequest) throws -> Data {
        try OpenAICompatibleWireSerializer.encode(request)
    }

    private func decodeUsage(_ usage: ChatStreamChunk.Usage) throws -> ModelTokenUsage {
        let prompt = usage.promptTokens ?? 0
        let completion = usage.completionTokens ?? 0
        let total: Int
        if let reportedTotal = usage.totalTokens {
            total = reportedTotal
        } else {
            let (sum, overflow) = prompt.addingReportingOverflow(completion)
            guard !overflow else {
                throw ModelClientError.invalidUsage
            }
            total = sum
        }

        // DeepSeek and OpenAI-compatible gateways sometimes include both
        // their own cache field and OpenAI's `prompt_tokens_details`. A zero
        // in one field must not mask a positive value in the other field.
        let cacheCandidates = [
            usage.promptCacheHitTokens,
            usage.promptTokensDetails?.cachedTokens
        ].compactMap { $0 }
        let cached = cacheCandidates.max()
        let uncached: Int?
        if let reportedMiss = usage.promptCacheMissTokens {
            uncached = reportedMiss
        } else if let cached {
            uncached = max(0, prompt - cached)
        } else {
            uncached = nil
        }
        let reasoning = usage.completionTokensDetails?.reasoningTokens
        let reportedValues = [prompt, completion, total, cached, uncached, reasoning].compactMap { $0 }
        guard reportedValues.allSatisfy({
            (0...Self.maximumReportedTokenCount).contains($0)
        }) else {
            throw ModelClientError.invalidUsage
        }
        if let cached, let uncached,
           cached.addingReportingOverflow(uncached).overflow
            || cached + uncached > prompt {
            throw ModelClientError.invalidUsage
        }

        return ModelTokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            cachedPromptTokens: cached,
            reasoningTokens: reasoning,
            uncachedPromptTokens: uncached
        )
    }

    private static let maximumReportedTokenCount = 100_000_000
    private static let maximumModelListBytes = 4 * 1_024 * 1_024

    private func readBoundedModelList(
        bytes: URLSession.AsyncBytes,
        declaredLength: String?
    ) async throws -> Data {
        if let declaredLength,
           let length = Int(declaredLength),
           length > Self.maximumModelListBytes {
            bytes.task.cancel()
            throw ModelDiscoveryError.responseTooLarge
        }

        var data = Data()
        if let declaredLength, let length = Int(declaredLength), length > 0 {
            data.reserveCapacity(min(length, Self.maximumModelListBytes))
        }
        do {
            try await withTaskCancellationHandler {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < Self.maximumModelListBytes else {
                        bytes.task.cancel()
                        throw ModelDiscoveryError.responseTooLarge
                    }
                    data.append(byte)
                }
            } onCancel: {
                bytes.task.cancel()
            }
        } catch is CancellationError {
            bytes.task.cancel()
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        return data
    }

    private static func normalizedDiscoveryAPIKey(_ rawValue: String?) throws -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= 16_384,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7F
              }) else {
            throw ModelDiscoveryError.invalidCredential
        }
        return value
    }

    static func isSameHTTPSOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == "https",
              rhs.scheme?.lowercased() == "https",
              lhs.user == nil,
              lhs.password == nil,
              rhs.user == nil,
              rhs.password == nil,
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return (lhs.port ?? 443) == (rhs.port ?? 443)
    }

    private func makeHTTPError(
        response: HTTPURLResponse,
        bytes: URLSession.AsyncBytes,
        adapter: any ModelProviderAdapter
    ) async throws -> ModelClientError {
        var body = Data()
        body.reserveCapacity(4_096)
        for try await byte in bytes {
            if body.count >= 64 * 1_024 {
                break
            }
            body.append(byte)
        }

        let envelope = try? JSONDecoder().decode(ChatAPIErrorEnvelope.self, from: body)
        let message = envelope?.error.message
            ?? String(data: body.prefix(2_048), encoding: .utf8)
            ?? "请求失败"
        let metadata = Self.providerFailureMetadata(
            response: response,
            code: adapter.httpFailureCode(
                status: response.statusCode,
                errorCode: envelope?.error.code?.stringValue,
                errorType: envelope?.error.type,
                message: message
            ),
            requestID: adapter.requestID(from: response)
        )
        return .httpFailure(metadata, message)
    }

    static func providerFailureMetadata(
        response: HTTPURLResponse,
        errorCode: String?,
        errorType: String?,
        now: Date = .now
    ) -> ModelProviderHTTPFailureMetadata {
        providerFailureMetadata(
            response: response,
            code: errorCode ?? errorType,
            requestID: response.value(forHTTPHeaderField: "X-Request-ID")
                ?? response.value(forHTTPHeaderField: "X-DeepSeek-Request-ID"),
            now: now
        )
    }

    static func providerFailureMetadata(
        response: HTTPURLResponse,
        code: String?,
        requestID: String?,
        now: Date = .now
    ) -> ModelProviderHTTPFailureMetadata {
        ModelProviderHTTPFailureMetadata(
            status: response.statusCode,
            code: normalizedMetadataValue(code, maximumUTF8Bytes: 256),
            retryAfterMilliseconds: retryAfterMilliseconds(
                response.value(forHTTPHeaderField: "Retry-After"),
                now: now
            ),
            requestID: normalizedMetadataValue(requestID, maximumUTF8Bytes: 1_024)
        )
    }

    /// Parse both RFC 7231 delta-seconds and HTTP-date Retry-After values.
    /// Invalid, zero, negative, or unreasonably large values are ignored.
    static func retryAfterMilliseconds(
        _ value: String?,
        now: Date = .now
    ) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        let milliseconds: Int?
        if let seconds = Int64(value), seconds > 0 {
            let (result, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
            milliseconds = overflow ? nil : Int(exactly: result)
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            guard let date = formatter.date(from: value) else { return nil }
            let interval = date.timeIntervalSince(now)
            guard interval > 0, interval.isFinite else { return nil }
            let rounded = interval * 1_000
            milliseconds = rounded <= Double(Int.max) ? Int(rounded.rounded()) : nil
        }

        guard let milliseconds,
              milliseconds > 0,
              milliseconds <= 86_400_000 else {
            return nil
        }
        return milliseconds
    }

    private static func normalizedMetadataValue(
        _ rawValue: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7F
              }) else {
            return nil
        }
        return value
    }
}

private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let originalURL = task.originalRequest?.url,
              let redirectURL = request.url,
              OpenAICompatibleClient.isSameHTTPSOrigin(originalURL, redirectURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum ModelClientError: LocalizedError, Sendable {
    case emptyResponse
    case invalidResponse
    case httpFailure(ModelProviderHTTPFailureMetadata, String)
    case requestTooLarge
    case eventTooLarge
    case unexpectedContentType
    case unexpectedChoice
    case malformedEvent
    case invalidUsage
    case incompleteStream
    case networkPathChanged(String)
    case streamError(String)
    case providerStreamFailure(code: String?, message: String)
    case invalidToolTranscript(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "模型返回了没有文本、思考内容或工具调用的空响应。"
        case .invalidResponse:
            return "模型服务返回了无效响应。"
        case let .httpFailure(metadata, message):
            var description = "模型服务错误 \(metadata.status)：\(message)"
            if let code = metadata.code, !code.isEmpty {
                description += " [code=\(code)]"
            }
            if let requestID = metadata.requestID, !requestID.isEmpty {
                description += " [request_id=\(requestID)]"
            }
            if let retryAfterMilliseconds = metadata.retryAfterMilliseconds {
                description += " [retry_after_ms=\(retryAfterMilliseconds)]"
            }
            return description
        case .requestTooLarge:
            return "模型请求超过 24 MiB 上限，请移除较早图片或开始新会话。"
        case .eventTooLarge:
            return "模型流式事件超过 1 MiB 上限。"
        case .unexpectedContentType:
            return "模型服务未返回 text/event-stream。"
        case .unexpectedChoice:
            return "模型服务返回了未请求的多候选响应。"
        case .malformedEvent:
            return "模型服务返回了无法解析的流式事件。"
        case .invalidUsage:
            return "模型服务返回了无效的 Token 用量。"
        case .incompleteStream:
            return "模型响应在完成前中断。"
        case let .networkPathChanged(reason):
            return "网络路径已变化，当前模型流已终止：\(reason)"
        case let .streamError(message):
            return "模型流式响应失败：\(message)"
        case let .providerStreamFailure(code, message):
            if let code, !code.isEmpty {
                return "模型流式响应失败：\(message) [code=\(code)]"
            }
            return "模型流式响应失败：\(message)"
        case let .invalidToolTranscript(message):
            return "工具调用历史无效：\(message)"
        }
    }

    var providerHTTPFailure: ModelProviderHTTPFailureMetadata? {
        guard case let .httpFailure(metadata, _) = self else { return nil }
        return metadata
    }
}

struct ModelProviderHTTPFailureMetadata: Sendable, Equatable {
    let status: Int
    let code: String?
    let retryAfterMilliseconds: Int?
    let requestID: String?

    var isRetryable: Bool {
        status == 408 || status == 409 || status == 425 || status == 429 || status >= 500
    }
}

enum ModelDiscoveryError: LocalizedError, Sendable, Equatable {
    case unsupportedProvider(ModelProviderID)
    case untrustedOrigin
    case invalidCredential
    case responseTooLarge
    case malformedResponse
    case tooManyModels

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(providerID):
            let provider = ModelProviderCatalog.descriptor(for: providerID)
            return "当前版本不能从 \(provider.displayName) 远端获取模型列表。"
        case .untrustedOrigin:
            return "模型发现只能访问当前 API 密钥已绑定的 HTTPS origin。"
        case .invalidCredential:
            return "API 密钥包含不能用于 HTTP Authorization 标头的字符。"
        case .responseTooLarge:
            return "模型列表响应超过 4 MiB 上限。"
        case .malformedResponse:
            return "模型服务返回的模型列表缺少有效 data 数组。"
        case .tooManyModels:
            return "模型服务返回的模型数量超过 10000 个上限。"
        }
    }
}
