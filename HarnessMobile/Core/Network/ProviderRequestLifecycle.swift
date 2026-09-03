import Foundation

/// Provider-owned OAuth grant persisted separately from API-key credentials.
/// The adapter only needs the access token; refresh metadata stays local to the
/// credential store and is never included in a model request.
struct ProviderOAuthCredential: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let tokenType: String
    let scope: String?

    init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer",
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
    }

    func validated() throws -> ProviderOAuthCredential {
        let access = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, access.utf8.count <= 16_384 else {
            throw ProviderOAuthCredentialError.invalidAccessToken
        }
        let refresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refresh, refresh.isEmpty || refresh.utf8.count > 16_384 {
            throw ProviderOAuthCredentialError.invalidRefreshToken
        }
        let type = tokenType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty,
              type.utf8.count <= 64,
              type.unicodeScalars.allSatisfy({ $0.value < 128 && !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw ProviderOAuthCredentialError.invalidTokenType
        }
        return ProviderOAuthCredential(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: expiresAt,
            tokenType: type,
            scope: scope?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(max(0, leeway))
    }

    var authorizationValue: String { "\(tokenType) \(accessToken)" }
}

enum ProviderOAuthCredentialError: LocalizedError, Sendable, Equatable {
    case invalidAccessToken
    case invalidRefreshToken
    case invalidTokenType
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken: "OAuth access token 无效。"
        case .invalidRefreshToken: "OAuth refresh token 无效。"
        case .invalidTokenType: "OAuth token type 无效。"
        case .missingRefreshToken: "OAuth 凭据没有 refresh token。"
        }
    }
}

/// Immutable dispatch identity captured before a provider request starts. The
/// adapter verifies the endpoint again at send time, so an altered route cannot
/// be silently substituted after a profile edit.
struct ProviderRequestRoute: Sendable, Equatable {
    let profileID: String?
    let generation: UInt64
    let endpoint: URL

    init(
        configuration: AgentConfiguration,
        profileID: String? = nil,
        generation: UInt64 = 0
    ) throws {
        self.profileID = profileID ?? configuration.profileID
        self.generation = generation
        endpoint = try configuration.chatCompletionsURL()
    }

    func validate(endpoint: URL) throws {
        guard self.endpoint == endpoint else {
            throw ProviderRequestRouteError.changedRoute(
                expected: self.endpoint.absoluteString,
                actual: endpoint.absoluteString
            )
        }
    }
}

enum ProviderRequestRouteError: LocalizedError, Sendable, Equatable {
    case changedRoute(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .changedRoute:
            "服务商请求路由在发送前发生变化；已取消请求，未使用备用路由。"
        }
    }
}

/// Coalesces a refresh operation per profile. The current mobile profile
/// contract stores API keys only; a future refreshable credential flow must use
/// this coordinator rather than issuing parallel refresh-token rotations.
actor ProviderRefreshSingleFlight<Value: Sendable> {
    private var inFlight: [String: Task<Value, Error>] = [:]

    func run(
        profileID: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let task = inFlight[profileID] {
            return try await task.value
        }
        let task = Task { try await operation() }
        inFlight[profileID] = task
        defer { inFlight.removeValue(forKey: profileID) }
        return try await task.value
    }
}

/// Resolves an OAuth access token and serializes refresh-token rotation per
/// profile. The closure is provider-specific; this coordinator owns only the
/// read-latest/refresh/write ordering shared by every adapter.
actor ProviderOAuthRefreshCoordinator {
    private let flight = ProviderRefreshSingleFlight<ProviderOAuthCredential?>()

    func accessToken(
        profileID: String,
        credentialStore: CredentialStore,
        reference: CredentialReference,
        expectedOrigin: String,
        refresh: @escaping @Sendable (ProviderOAuthCredential) async throws -> ProviderOAuthCredential
    ) async throws -> String? {
        guard let current = try await credentialStore.readOAuthCredential(
            for: reference,
            expectedOrigin: expectedOrigin
        ) else {
            return nil
        }
        if !current.isExpired() {
            return current.authorizationValue
        }
        let resolved = try await flight.run(profileID: profileID) {
            // Re-read inside the single-flight operation: another process or
            // request may have rotated the grant while this task was queued.
            guard let latest = try await credentialStore.readOAuthCredential(
                for: reference,
                expectedOrigin: expectedOrigin
            ) else {
                return nil
            }
            if !latest.isExpired() {
                return latest
            }
            guard latest.refreshToken != nil else {
                throw ProviderOAuthCredentialError.missingRefreshToken
            }
            let refreshed = try await refresh(latest).validated()
            try await credentialStore.saveOAuthCredential(
                refreshed,
                for: reference,
                origin: expectedOrigin
            )
            return refreshed
        }
        return resolved?.authorizationValue
    }
}

struct ProviderQuickTestResult: Sendable, Equatable {
    let route: ProviderRequestRoute
    let output: String
}

enum ProviderQuickTestError: LocalizedError, Sendable, Equatable {
    case unexpectedToolCall
    case incompleteFinish
    case emptyOutput
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .unexpectedToolCall:
            "快速测试收到工具调用，已停止。"
        case .incompleteFinish:
            "快速测试未正常完成。"
        case .emptyOutput:
            "快速测试未返回文本。"
        case .outputTooLarge:
            "快速测试输出超过限制。"
        }
    }
}

/// A provider connectivity check deliberately bypassing AgentRuntime, session
/// storage, trajectory, and tool registration. It still uses the production
/// streaming client, whose adapter owns the request wire format.
enum ProviderQuickTester {
    private static let maximumOutputBytes = 8 * 1_024

    static func run(
        client: any LLMStreamingClient,
        configuration: AgentConfiguration,
        apiKey: String,
        route: ProviderRequestRoute
    ) async throws -> ProviderQuickTestResult {
        let request = ModelRequest(
            configuration: configuration,
            apiKey: apiKey,
            systemPrompt: "Return exactly one short readiness confirmation. Do not call tools.",
            messages: [.user("Reply with a readiness confirmation.")],
            tools: [],
            route: route
        )
        var output = ""
        var finish: ModelFinishReason?
        for try await event in client.stream(request) {
            try Task.checkCancellation()
            switch event {
            case let .text(delta):
                output += delta
                guard output.utf8.count <= maximumOutputBytes else {
                    throw ProviderQuickTestError.outputTooLarge
                }
            case .reasoning, .reasoningSignature, .usage:
                continue
            case .toolCallDelta:
                throw ProviderQuickTestError.unexpectedToolCall
            case let .finish(reason):
                finish = reason
            }
        }
        guard finish == .stop else { throw ProviderQuickTestError.incompleteFinish }
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ProviderQuickTestError.emptyOutput }
        return ProviderQuickTestResult(route: route, output: normalized)
    }
}
