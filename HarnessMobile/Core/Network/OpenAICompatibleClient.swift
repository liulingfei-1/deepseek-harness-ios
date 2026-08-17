import Foundation

final class OpenAICompatibleClient: NSObject, LLMStreamingClient, ModelCatalogDiscovering, @unchecked Sendable {
    private let redirectDelegate: SameHostRedirectDelegate
    private let session: URLSession
    private let modelDiscoveryCache: ModelDiscoveryCache

    override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil

        let redirectDelegate = SameHostRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        modelDiscoveryCache = ModelDiscoveryCache()
        session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
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
            throw try await makeHTTPError(status: httpResponse.statusCode, bytes: bytes)
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
            tools: request.tools
        )
        switch ModelProviderCatalog.descriptor(for: configuration.providerID).wireProtocol {
        case .openAIChatCompletions:
            try await performOpenAI(validatedRequest, continuation: continuation)
        case .anthropicMessages:
            try await performAnthropic(validatedRequest, continuation: continuation)
        }
    }

    private func performOpenAI(
        _ request: ModelRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let configuration = request.configuration
        let endpoint = try configuration.chatCompletionsURL()
        let body = ChatWireSerializer.makeRequest(request)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")
        let encodedBody = try JSONEncoder().encode(body)
        guard encodedBody.count <= 4 * 1_024 * 1_024 else {
            throw ModelClientError.requestTooLarge
        }
        urlRequest.httpBody = encodedBody

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw try await makeHTTPError(status: httpResponse.statusCode, bytes: bytes)
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
        try await withTaskCancellationHandler {
            streamLoop: for try await byte in bytes {
                try Task.checkCancellation()
                guard let payload = try sse.consume(byte: byte) else {
                    continue
                }
                if payload == "[DONE]" {
                    sawDone = true
                    break streamLoop
                }
                for event in try decodeEvents(payload) {
                    if case .finish = event {
                        sawSemanticFinish = true
                    }
                    continuation.yield(event)
                }
            }

            if !sawDone, let payload = try sse.finish() {
                if payload == "[DONE]" {
                    sawDone = true
                } else {
                    for event in try decodeEvents(payload) {
                        if case .finish = event {
                            sawSemanticFinish = true
                        }
                        continuation.yield(event)
                    }
                }
            }
        } onCancel: {
            bytes.task.cancel()
        }

        if !sawSemanticFinish || !sawDone {
            throw ModelClientError.incompleteStream
        }
    }

    private func performAnthropic(
        _ request: ModelRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let endpoint = try request.configuration.chatCompletionsURL()
        let body = try AnthropicWireSerializer.makeRequest(request)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let encodedBody = try JSONEncoder().encode(body)
        guard encodedBody.count <= 4 * 1_024 * 1_024 else {
            throw ModelClientError.requestTooLarge
        }
        urlRequest.httpBody = encodedBody

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw try await makeHTTPError(status: httpResponse.statusCode, bytes: bytes)
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

        if !sawSemanticFinish || !sawMessageStop {
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

        let cached = usage.promptTokensDetails?.cachedTokens
            ?? usage.promptCacheHitTokens
        let reasoning = usage.completionTokensDetails?.reasoningTokens
        let reportedValues = [prompt, completion, total, cached, reasoning].compactMap { $0 }
        guard reportedValues.allSatisfy({
            (0...Self.maximumReportedTokenCount).contains($0)
        }) else {
            throw ModelClientError.invalidUsage
        }

        return ModelTokenUsage(
            promptTokens: prompt,
            completionTokens: completion,
            totalTokens: total,
            cachedPromptTokens: cached,
            reasoningTokens: reasoning
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

    private static func isSameHTTPSOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
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
        status: Int,
        bytes: URLSession.AsyncBytes
    ) async throws -> ModelClientError {
        var body = Data()
        body.reserveCapacity(4_096)
        for try await byte in bytes {
            if body.count >= 64 * 1_024 {
                break
            }
            body.append(byte)
        }

        if let envelope = try? JSONDecoder().decode(ChatAPIErrorEnvelope.self, from: body) {
            return .httpStatus(status, envelope.error.message)
        }
        let fallback = String(data: body.prefix(2_048), encoding: .utf8) ?? "请求失败"
        return .httpStatus(status, fallback)
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
              Self.isSameHTTPSOrigin(originalURL, redirectURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func isSameHTTPSOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == "https",
              rhs.scheme?.lowercased() == "https",
              lhs.user == nil,
              lhs.password == nil,
              rhs.user == nil,
              rhs.password == nil,
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectiveHTTPSPort(lhs) == effectiveHTTPSPort(rhs)
    }

    private static func effectiveHTTPSPort(_ url: URL) -> Int {
        url.port ?? 443
    }
}

enum ModelClientError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
    case requestTooLarge
    case eventTooLarge
    case unexpectedContentType
    case unexpectedChoice
    case malformedEvent
    case invalidUsage
    case incompleteStream
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "模型服务返回了无效响应。"
        case let .httpStatus(status, message):
            return "模型服务错误 \(status)：\(message)"
        case .requestTooLarge:
            return "模型请求超过 4 MiB 上限，请开始新会话。"
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
        case let .streamError(message):
            return "模型流式响应失败：\(message)"
        }
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
