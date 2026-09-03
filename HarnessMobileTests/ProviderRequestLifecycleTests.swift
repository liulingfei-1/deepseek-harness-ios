import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ProviderRequestLifecycleTests: XCTestCase {
    func testTenConcurrentRefreshesForOneProfileShareOneOperation() async throws {
        let flight = ProviderRefreshSingleFlight<String>()
        let counter = RefreshCounter()

        let results = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await flight.run(profileID: "openai-work") {
                        await counter.increment()
                        try await Task.sleep(for: .milliseconds(30))
                        return "rotated-token"
                    }
                }
            }
            var results: [String] = []
            for try await value in group {
                results.append(value)
            }
            return results
        }

        XCTAssertEqual(results, Array(repeating: "rotated-token", count: 10))
        let refreshCount = await counter.currentValue()
        XCTAssertEqual(refreshCount, 1)
    }

    func testOAuthCredentialRoundTripsAndExpiresWithLeeway() throws {
        let credential = ProviderOAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_000),
            scope: "models"
        )
        let data = try JSONEncoder().encode(credential)
        let decoded = try JSONDecoder().decode(ProviderOAuthCredential.self, from: data)
        XCTAssertEqual(decoded, credential)
        XCTAssertTrue(credential.isExpired(at: Date(timeIntervalSince1970: 950), leeway: 60))
        XCTAssertFalse(credential.isExpired(at: Date(timeIntervalSince1970: 900), leeway: 60))
        XCTAssertEqual(credential.authorizationValue, "Bearer access")
    }

    func testOAuthRefreshCoordinatorReReadsAndSharesRotation() async throws {
        let store = CredentialStore(
            service: "com.llf.harnessmobile.oauth-tests.\(UUID().uuidString)"
        )
        let reference = CredentialReference(rawValue: "provider.openai.oauth")
        let origin = "https://api.openai.com:443"
        try await store.saveOAuthCredential(
            ProviderOAuthCredential(
                accessToken: "expired",
                refreshToken: "refresh",
                expiresAt: Date(timeIntervalSince1970: 1)
            ),
            for: reference,
            origin: origin
        )
        let refreshCount = RefreshCounter()
        let coordinator = ProviderOAuthRefreshCoordinator()

        let values = try await withThrowingTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await coordinator.accessToken(
                        profileID: "openai",
                        credentialStore: store,
                        reference: reference,
                        expectedOrigin: origin
                    ) { current in
                        await refreshCount.increment()
                        XCTAssertEqual(current.refreshToken, "refresh")
                        return ProviderOAuthCredential(
                            accessToken: "fresh",
                            refreshToken: "rotated",
                            expiresAt: Date().addingTimeInterval(3_600)
                        )
                    }
                }
            }
            var values: [String?] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(values, Array(repeating: "Bearer fresh", count: 10))
        let refreshes = await refreshCount.currentValue()
        XCTAssertEqual(refreshes, 1)
        let stored = try await store.readOAuthCredential(for: reference, expectedOrigin: origin)
        XCTAssertEqual(stored?.accessToken, "fresh")
        XCTAssertEqual(stored?.refreshToken, "rotated")
    }

    func testQuickTestUsesSingleAdapterRequestWithoutToolsOrConversationState() async throws {
        let client = QuickTestClient(events: [.text("ready"), .finish(.stop)])
        var configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        configuration.profileID = "openai-work"
        let route = try ProviderRequestRoute(configuration: configuration, generation: 7)

        let result = try await ProviderQuickTester.run(
            client: client,
            configuration: configuration,
            apiKey: "test-only",
            route: route
        )

        XCTAssertEqual(result.output, "ready")
        XCTAssertEqual(result.route, route)
        let requests = client.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].tools, [])
        XCTAssertEqual(requests[0].messages.count, 1)
        XCTAssertEqual(requests[0].messages[0].role, .user)
        XCTAssertEqual(requests[0].messages[0].content, "Reply with a readiness confirmation.")
        XCTAssertEqual(requests[0].route, route)
    }

    func testAdapterRejectsRouteSnapshotMismatchWithoutFallback() throws {
        let configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        let request = ModelRequest(
            configuration: configuration,
            apiKey: "test-only",
            systemPrompt: "system",
            messages: [.user("hello")],
            tools: [],
            route: try ProviderRequestRoute(
                configuration: AgentConfiguration(
                    providerID: .openAI,
                    baseURL: "https://other.example/v1",
                    model: configuration.model,
                    reasoningMode: .providerDefault
                ),
                profileID: "openai-work",
                generation: 9
            )
        )

        XCTAssertThrowsError(try OpenAIChatCompletionsAdapter().makeStreamingRequest(request)) { error in
            XCTAssertEqual(
                error as? ProviderRequestRouteError,
                .changedRoute(
                    expected: "https://other.example/v1/chat/completions",
                    actual: "https://api.openai.com/v1/chat/completions"
                )
            )
        }
    }

    func testAgentRuntimeCapturesRouteAfterRequestAssembly() async throws {
        let client = QuickTestClient(events: [.text("ready"), .finish(.stop)])
        var configuration = ModelProviderCatalog.applying(.openAI, to: AgentConfiguration())
        configuration.profileID = "openai-work"
        let expectedConfiguration = configuration
        let expectedRoute = try ProviderRequestRoute(
            configuration: expectedConfiguration,
            generation: 12
        )
        let runtime = AgentRuntime(
            client: client,
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            providerRequestRouteProvider: { suppliedConfiguration in
                XCTAssertEqual(suppliedConfiguration, expectedConfiguration)
                return expectedRoute
            }
        )

        try await runtime.run(
            history: [.user("hello")],
            configuration: configuration,
            apiKey: "test-only"
        )

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].route, expectedRoute)
    }
}

private actor RefreshCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func currentValue() -> Int { value }
}

private final class QuickTestClient: LLMStreamingClient, @unchecked Sendable {
    private let events: [LLMStreamEvent]
    private let lock = NSLock()
    private var capturedRequests: [ModelRequest] = []

    init(events: [LLMStreamEvent]) {
        self.events = events
    }

    var requests: [ModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}
