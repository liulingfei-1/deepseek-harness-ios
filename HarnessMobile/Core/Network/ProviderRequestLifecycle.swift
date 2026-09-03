import Foundation

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
