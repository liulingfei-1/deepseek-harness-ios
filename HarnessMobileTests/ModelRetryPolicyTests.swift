import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class ModelRetryPolicyTests: XCTestCase {
    func testRuntimeRetriesTransientProviderFailureWithoutCommittingFailedAttempt() async throws {
        let counter = RetryRequestCounter()
        let recorder = RetryDraftRecorder()
        let runtime = AgentRuntime(
            client: RetryScriptClient(counter: counter),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                await recorder.append(draft)
                return nil
            }
        )

        try await runtime.run(
            history: [.user("hello")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requestCount = await counter.currentValue()
        XCTAssertEqual(requestCount, 2)
        let drafts = await recorder.drafts
        XCTAssertEqual(drafts.filter { $0.type == "llm/retry" }.count, 1)
        XCTAssertEqual(drafts.filter { $0.type == "llm/retry-started" }.count, 1)
        XCTAssertEqual(drafts.filter { $0.type == SessionEventVocabulary.assistantMessage }.count, 1)
    }

    func testRuntimeStopsAfterBoundedTransientRetries() async {
        let counter = RetryRequestCounter()
        let recorder = RetryDraftRecorder()
        let runtime = AgentRuntime(
            client: AlwaysFailingRetryClient(counter: counter),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                await recorder.append(draft)
                return nil
            }
        )

        do {
            try await runtime.run(
                history: [.user("hello")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            XCTFail("expected the final transient provider failure")
        } catch {
            XCTAssertNotNil(ModelRetryPolicy.failure(for: error))
        }

        let requestCount = await counter.currentValue()
        XCTAssertEqual(requestCount, 6)
        let drafts = await recorder.drafts
        XCTAssertEqual(drafts.filter { $0.type == "llm/retry" }.count, 5)
        XCTAssertEqual(drafts.filter { $0.type == "llm/retry-started" }.count, 5)
        XCTAssertTrue(drafts.filter { $0.type == SessionEventVocabulary.assistantMessage }.isEmpty)
    }

    func testDefaultsUseFiveRetriesAndTransientCodes() {
        XCTAssertEqual(ModelRetryPolicy.maxRetries, 5)
        XCTAssertEqual(
            ModelRetryPolicy.policyKey,
            #"["normal",5,["EMPTY_RESPONSE","RATE_LIMIT","SERVER","TIMEOUT","TRANSPORT"],500,10000,0.1]"#
        )
        XCTAssertTrue(ModelRetryPolicy.retryableCodes.contains("RATE_LIMIT"))
        XCTAssertTrue(ModelRetryPolicy.retryableCodes.contains("SERVER"))
        XCTAssertFalse(ModelRetryPolicy.retryableCodes.contains("INVALID_CREDENTIAL"))
    }

    func testProviderPolicyUsesOfficialNestedCodableShapeAndResolution() throws {
        let configuration = ProviderRetryPolicyConfiguration(
            mode: .normal,
            maxRetries: 2,
            retryableCodes: ["SERVER", "custom-code"],
            backoff: .init(
                initialDelayMs: 12.5,
                maxDelayMs: 250,
                jitterRatio: 0.25
            )
        )
        let data = try JSONEncoder().encode(configuration)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["initialDelayMilliseconds"])
        XCTAssertEqual((object["backoff"] as? [String: Any])?["initialDelayMs"] as? Double, 12.5)
        XCTAssertEqual(
            try JSONDecoder().decode(ProviderRetryPolicyConfiguration.self, from: data),
            configuration
        )

        let resolved = try ModelRetryPolicy.resolved(configuration)
        XCTAssertEqual(resolved.maxRetries, 2)
        XCTAssertEqual(resolved.retryableCodes, ["SERVER", "custom-code"])
        XCTAssertEqual(resolved.initialDelayMilliseconds, 12.5)
        XCTAssertTrue(resolved.policyKey.contains("custom-code"))
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProviderRetryPolicyConfiguration.self,
                from: Data(#"{"mode":"normal","maxRetries":null}"#.utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProviderRetryPolicyConfiguration.self,
                from: Data(#"{"mode":"normal","unknown":1}"#.utf8)
            )
        )
    }

    func testAlwaysPolicyFallsBackToLocalDelayForOversizedRetryAfter() throws {
        let policy = try ModelRetryPolicy.resolved(
            ProviderRetryPolicyConfiguration(
                mode: .always,
                backoff: .init(
                    initialDelayMs: 0.5,
                    maxDelayMs: 1,
                    jitterRatio: 1
                )
            )
        )
        let failure = ModelRetryPolicy.Failure(
            code: "INVALID_CREDENTIAL",
            message: "bad key",
            status: 401,
            retryAfterMilliseconds: 86_400_000
        )
        XCTAssertTrue(ModelRetryPolicy.permits(failure, retry: 99, policy: policy))
        XCTAssertEqual(
            ModelRetryPolicy.delayMilliseconds(
                retry: 1,
                failure: failure,
                policy: policy,
                random: 0
            ),
            0
        )
    }

    func testAlwaysPolicyContinuesBeyondFiveFailuresAndOmitsMaxRetries() async throws {
        let counter = RetryRequestCounter()
        let recorder = RetryDraftRecorder()
        let runtime = AgentRuntime(
            client: FailThenSucceedRetryClient(counter: counter, failureCount: 7),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                await recorder.append(draft)
                return nil
            }
        )
        var configuration = AgentConfiguration()
        configuration.retryPolicy = ProviderRetryPolicyConfiguration(
            mode: .always,
            backoff: .init(initialDelayMs: 0.001, maxDelayMs: 0.001, jitterRatio: 0)
        )

        try await runtime.run(
            history: [.user("hello")],
            configuration: configuration,
            apiKey: "test-only"
        )

        let requestCount = await counter.currentValue()
        XCTAssertEqual(requestCount, 8)
        let recordedDrafts = await recorder.drafts
        let retries = recordedDrafts.filter { $0.type == "llm/retry" }
        XCTAssertEqual(retries.count, 7)
        for retry in retries {
            XCTAssertEqual(retry.data.objectValue?["mode"], .string("always"))
            XCTAssertNil(retry.data.objectValue?["maxRetries"])
        }
    }

    func testAlwaysPolicyRetriesUnclassifiedAdapterFailure() async throws {
        let counter = RetryRequestCounter()
        let runtime = AgentRuntime(
            client: UnclassifiedThenSucceedRetryClient(counter: counter),
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in }
        )
        var configuration = AgentConfiguration()
        configuration.retryPolicy = ProviderRetryPolicyConfiguration(
            mode: .always,
            backoff: .init(initialDelayMs: 0.001, maxDelayMs: 0.001, jitterRatio: 0)
        )

        try await runtime.run(
            history: [.user("hello")],
            configuration: configuration,
            apiKey: "test-only"
        )

        let requestCount = await counter.currentValue()
        XCTAssertEqual(requestCount, 2)
    }

    func testEmptyAndPartialResponsesRetryWithoutCommittingFailedAssistant() async throws {
        for client in [RetryFailureKind.empty, .partial] {
            let counter = RetryRequestCounter()
            let recorder = RetryDraftRecorder()
            let runtime = AgentRuntime(
                client: RecoverableResponseClient(counter: counter, kind: client),
                registry: LocalToolRegistry(tools: []),
                approvalHandler: { _ in true },
                eventHandler: { _ in },
                sessionEventHandler: { draft in
                    await recorder.append(draft)
                    return nil
                }
            )
            try await runtime.run(
                history: [.user("hello")],
                configuration: AgentConfiguration(),
                apiKey: "test-only"
            )
            let requestCount = await counter.currentValue()
            XCTAssertEqual(requestCount, 2)
            let drafts = await recorder.drafts
            XCTAssertEqual(
                drafts.filter { $0.type == SessionEventVocabulary.assistantMessage }.count,
                1
            )
        }
    }

    func testProviderRetryAfterIsAcceptedOnlyWithinLocalBound() {
        let failure = ModelRetryPolicy.Failure(
            code: "RATE_LIMIT",
            message: "busy",
            status: 429,
            retryAfterMilliseconds: 2_000
        )
        XCTAssertEqual(ModelRetryPolicy.delayMilliseconds(retry: 1, failure: failure), 2_000)

        let overCap = ModelRetryPolicy.Failure(
            code: "RATE_LIMIT",
            message: "busy",
            status: 429,
            retryAfterMilliseconds: 86_400_000
        )
        XCTAssertFalse(ModelRetryPolicy.accepts(overCap))
        XCTAssertEqual(ModelRetryPolicy.delayMilliseconds(retry: 1, failure: overCap, random: 0.5), 500)
    }

    func testBackoffIsBoundedAndJitterIsDeterministic() {
        let failure = ModelRetryPolicy.Failure(code: "SERVER", message: "busy", status: 503, retryAfterMilliseconds: nil)
        XCTAssertEqual(ModelRetryPolicy.delayMilliseconds(retry: 1, failure: failure, random: 0.5), 500)
        XCTAssertEqual(ModelRetryPolicy.delayMilliseconds(retry: 2, failure: failure, random: 0.5), 1_000)
        XCTAssertEqual(ModelRetryPolicy.delayMilliseconds(retry: 99, failure: failure, random: 1), 10_000)
    }

    func testFailureClassificationUsesProviderHTTPStatus() throws {
        let error = ModelClientError.httpFailure(
            ModelProviderHTTPFailureMetadata(status: 429, code: "rate_limit", retryAfterMilliseconds: 750, requestID: "request"),
            "busy"
        )
        let failure = try XCTUnwrap(ModelRetryPolicy.failure(for: error))
        XCTAssertEqual(failure.code, "RATE_LIMIT")
        XCTAssertEqual(failure.retryAfterMilliseconds, 750)
        XCTAssertEqual(failure.status, 429)
        XCTAssertNil(ModelRetryPolicy.failure(for: ModelClientError.requestTooLarge))
        XCTAssertNil(ModelRetryPolicy.failure(for: AgentRuntimeError.invalidFinishSequence))
        XCTAssertEqual(
            ModelRetryPolicy.failure(for: URLError(.networkConnectionLost))?.code,
            "TRANSPORT"
        )
        XCTAssertNil(ModelRetryPolicy.failure(for: URLError(.cancelled)))
        let earlyData = ModelClientError.httpFailure(
            ModelProviderHTTPFailureMetadata(
                status: 425,
                code: nil,
                retryAfterMilliseconds: 1_000,
                requestID: nil
            ),
            "too early"
        )
        XCTAssertEqual(ModelRetryPolicy.failure(for: earlyData)?.code, "SERVER")
    }

    func testContextWindowFailureIsClassifiedForSingleCompactionRecovery() throws {
        let error = ModelClientError.httpFailure(
            ModelProviderHTTPFailureMetadata(
                status: 400,
                code: "context_length_exceeded",
                retryAfterMilliseconds: nil,
                requestID: nil
            ),
            "request too large for model context"
        )
        let failure = try XCTUnwrap(ModelRetryPolicy.failure(for: error))
        XCTAssertEqual(failure.code, ModelRetryPolicy.contextWindowExceededCode)
    }

    func testRuntimeCompactsOnceAfterContextOverflowBeforeRetrying() async throws {
        let script = ContextOverflowScript()
        let client = ContextOverflowClient(script: script)
        let drafts = RetryDraftRecorder()
        let runtime = AgentRuntime(
            client: client,
            registry: LocalToolRegistry(tools: []),
            approvalHandler: { _ in true },
            eventHandler: { _ in },
            sessionEventHandler: { draft in
                await drafts.append(draft)
                return nil
            }
        )
        let old = AgentMessage.user(String(repeating: "old context ", count: 600))
        try await runtime.run(
            history: [old, .assistant("old answer"), .user("current question")],
            configuration: AgentConfiguration(),
            apiKey: "test-only"
        )

        let requests = await script.requests
        // One provider request fails, one request generates the checkpoint,
        // and the compacted request is then retried successfully.
        XCTAssertEqual(requests.count, 3)
        XCTAssertLessThan(
            requests[2].messages.count,
            requests[0].messages.count
        )
        XCTAssertTrue(
            requests[1].messages.last?.content.contains("compaction engine") == true
        )
        let compactionTypes = await drafts.drafts
            .filter { $0.type.hasPrefix("compaction/") }
            .map(\.type)
        XCTAssertEqual(compactionTypes, ["compaction/start", "compaction/summary", "compaction/end"])
    }
}

private actor RetryRequestCounter {
    private(set) var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    func currentValue() -> Int { value }
}

private struct RetryScriptClient: LLMStreamingClient {
    let counter: RetryRequestCounter

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await counter.next() == 1 {
                    continuation.finish(throwing: ModelClientError.httpFailure(
                        ModelProviderHTTPFailureMetadata(
                            status: 503,
                            code: "overloaded",
                            retryAfterMilliseconds: nil,
                            requestID: nil
                        ),
                        "busy"
                    ))
                } else {
                    continuation.yield(.text("recovered"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
        }
    }
}

private struct AlwaysFailingRetryClient: LLMStreamingClient {
    let counter: RetryRequestCounter

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                _ = await counter.next()
                continuation.finish(throwing: ModelClientError.httpFailure(
                    ModelProviderHTTPFailureMetadata(
                        status: 503,
                        code: "overloaded",
                        retryAfterMilliseconds: 1,
                        requestID: nil
                    ),
                    "busy"
                ))
            }
        }
    }
}

private struct FailThenSucceedRetryClient: LLMStreamingClient {
    let counter: RetryRequestCounter
    let failureCount: Int

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await counter.next() <= failureCount {
                    continuation.finish(throwing: ModelClientError.requestTooLarge)
                } else {
                    continuation.yield(.text("recovered"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
        }
    }
}

private struct UnclassifiedThenSucceedRetryClient: LLMStreamingClient {
    private struct AdapterFailure: LocalizedError {
        var errorDescription: String? { "adapter failed before classification" }
    }

    let counter: RetryRequestCounter

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await counter.next() == 1 {
                    continuation.finish(throwing: AdapterFailure())
                } else {
                    continuation.yield(.text("recovered"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
        }
    }
}

private enum RetryFailureKind: Sendable {
    case empty
    case partial
}

private struct RecoverableResponseClient: LLMStreamingClient {
    let counter: RetryRequestCounter
    let kind: RetryFailureKind

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                if await counter.next() == 1 {
                    switch kind {
                    case .empty:
                        continuation.yield(.finish(.stop))
                        continuation.finish()
                    case .partial:
                        continuation.yield(.text("discarded partial"))
                        continuation.finish(throwing: ModelClientError.incompleteStream)
                    }
                } else {
                    continuation.yield(.text("recovered"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
        }
    }
}

private actor RetryDraftRecorder {
    private(set) var drafts: [SessionEventDraft] = []

    func append(_ draft: SessionEventDraft) {
        drafts.append(draft)
    }
}

private actor ContextOverflowScript {
    private(set) var requests: [ModelRequest] = []

    func next(_ request: ModelRequest) -> Bool {
        let shouldFail = requests.isEmpty
        requests.append(request)
        return shouldFail
    }
}

private struct ContextOverflowClient: LLMStreamingClient {
    let script: ContextOverflowScript

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let shouldFail = await script.next(request)
                if shouldFail {
                    continuation.finish(throwing: ModelClientError.httpFailure(
                        ModelProviderHTTPFailureMetadata(
                            status: 400,
                            code: "context_length_exceeded",
                            retryAfterMilliseconds: nil,
                            requestID: nil
                        ),
                        "request too large for model context"
                    ))
                } else {
                    continuation.yield(.text("compacted response"))
                    continuation.yield(.finish(.stop))
                    continuation.finish()
                }
            }
        }
    }
}
