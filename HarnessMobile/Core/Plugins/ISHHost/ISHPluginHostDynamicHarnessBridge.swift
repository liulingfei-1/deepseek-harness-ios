import Foundation

enum ISHPluginHostHarnessBridgeError: LocalizedError, Sendable, Equatable {
    case duplicateBinding(String)
    case invalidResponse(String)
    case invocationFailed(String)
    case unsafeRequestMutation(String)

    var errorDescription: String? {
        switch self {
        case let .duplicateBinding(identity):
            return "Duplicate iSH harness binding: \(identity)"
        case let .invalidResponse(message):
            return "Invalid iSH harness response: \(message)"
        case let .invocationFailed(message):
            return "iSH harness invocation failed: \(message)"
        case let .unsafeRequestMutation(field):
            return "iSH harness plugins cannot change credential routing field \(field)."
        }
    }
}

/// Known cross-process extension points. Arbitrary `harness.handle` methods and
/// Cordis services remain manually invocable; only this allowlist is wired into
/// the native loop automatically.
private enum ISHHostedHarnessPoint: String, Sendable {
    case agentCreated = "agent/created"
    case agentDisposed = "agent/disposed"
    case agentStatus = "agent/status"
    case agentSessionStart = "agent/session-start"
    case agentError = "agent/error"
    case agentInboxInserted = "agent/inbox/inserted"
    case agentInboxClaimed = "agent/inbox/claimed"
    case agentInboxDiscarded = "agent/inbox/discarded"
    case agentInboxPreClaim = "agent/inbox/pre-claim"
    case memoryRecall = "memory/recall"
    case memoryRecord = "memory/record"
    case orchestrationPreStep = "orchestration/pre-step"
    case orchestrationRequest = "orchestration/request"
    case orchestrationRequestError = "orchestration/request-error"
    case orchestrationTurnStopping = "orchestration/turn-stopping"
    case agentPreStep = "agent/pre-step"
    case agentRequest = "agent/request"
    case agentRequestError = "agent/request-error"
    case agentTurnStopping = "agent/turn-stopping"
    /// The Swift side owns the provider stream and credentials. Host plugins
    /// receive only a start/event/terminal envelope and may acknowledge or
    /// rewrite individual events.
    case llmStream = "llm/stream"
    case sandboxPreExecute = "sandbox/pre-execute"
    case toolsPreExecute = "tools/pre-execute"
    case toolsExecute = "tools/execute"
    case toolsPostExecute = "tools/post-execute"
    /// This is not a standalone Host capability. It is invoked only while the
    /// native Code Mode producer is durably recording one child dispatch.
    case toolsCodeDispatchLog = "tools/code-dispatch-log"
    case toolsResult = "tools/result"
    case toolsChange = "tools/change"
}

private enum ISHHostedHarnessEndpoint: Sendable, Hashable {
    case handler(ISHPluginHostHandlerContribution)
    case service(
        contribution: ISHPluginHostServiceContribution,
        method: String
    )

    var identity: String {
        switch self {
        case let .handler(contribution):
            return "handler:\(contribution.pluginId):\(contribution.pluginRunId):\(contribution.method)"
        case let .service(contribution, method):
            return "service:\(contribution.pluginId):\(contribution.pluginRunId):\(contribution.name):\(method)"
        }
    }

    func request(sessionID: String, arguments: JSONValue) -> ISHPluginHostInvokeRequest {
        switch self {
        case let .handler(contribution):
            return .handler(
                sessionId: sessionID,
                pluginId: contribution.pluginId,
                pluginRunId: contribution.pluginRunId,
                method: contribution.method,
                arguments: arguments
            )
        case let .service(contribution, method):
            return .service(
                sessionId: sessionID,
                pluginId: contribution.pluginId,
                pluginRunId: contribution.pluginRunId,
                name: contribution.name,
                method: method,
                arguments: arguments
            )
        }
    }
}

private struct ISHHostedHarnessInvoker: Sendable {
    let endpoint: ISHHostedHarnessEndpoint
    let sessionID: String
    let client: ISHPluginHostClient
    let synchronizeMobileContext: @Sendable () async throws -> Void

    func invoke(
        arguments: JSONValue,
        synchronize: Bool = true
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        if synchronize {
            try await synchronizeMobileContext()
        }
        let response = try await client.invoke(
            endpoint.request(sessionID: sessionID, arguments: arguments)
        )
        guard let object = response.objectValue,
              case .bool(true)? = object["ok"] else {
            let message = response.objectValue?["message"]?.displayText
                ?? response.objectValue?["error"]?.displayText
                ?? response.displayText
            throw ISHPluginHostHarnessBridgeError.invocationFailed(message)
        }
        return object["value"] ?? .null
    }
}

enum ISHPluginHostDynamicHarnessBridge {
    static func register(
        contributions: ISHPluginHostContributions,
        sessionID: String,
        client: ISHPluginHostClient,
        synchronizeMobileContext: @escaping @Sendable () async throws -> Void = {},
        context: CordisPluginContext
    ) async throws {
        var bindings: [(ISHHostedHarnessPoint, ISHHostedHarnessEndpoint)] = []

        for contribution in contributions.handlers {
            guard let point = ISHHostedHarnessPoint(rawValue: contribution.method) else {
                continue
            }
            bindings.append((point, .handler(contribution)))
        }

        for contribution in contributions.services {
            for method in contribution.methods {
                guard let point = servicePoint(name: contribution.name, method: method) else {
                    continue
                }
                bindings.append((
                    point,
                    .service(contribution: contribution, method: method)
                ))
            }
        }

        var identities = Set<String>()
        for (point, endpoint) in bindings {
            guard identities.insert(endpoint.identity).inserted else {
                throw ISHPluginHostHarnessBridgeError.duplicateBinding(endpoint.identity)
            }
            try await register(
                point: point,
                endpoint: endpoint,
                sessionID: sessionID,
                client: client,
                synchronizeMobileContext: synchronizeMobileContext,
                context: context
            )
        }
    }

    private static func servicePoint(
        name: String,
        method: String
    ) -> ISHHostedHarnessPoint? {
        switch (name, method) {
        case ("memory", "recall"):
            return .memoryRecall
        case ("memory", "record"):
            return .memoryRecord
        case ("sandbox", "preExecute"), ("sandbox", "pre-execute"):
            return .sandboxPreExecute
        case ("orchestration", "preStep"), ("orchestration", "pre-step"):
            return .orchestrationPreStep
        case ("orchestration", "request"):
            return .orchestrationRequest
        case ("orchestration", "requestError"), ("orchestration", "request-error"):
            return .orchestrationRequestError
        case ("orchestration", "turnStopping"), ("orchestration", "turn-stopping"):
            return .orchestrationTurnStopping
        case ("agent", "preStep"), ("agent", "pre-step"):
            return .agentPreStep
        case ("agent", "request"):
            return .agentRequest
        case ("agent", "requestError"), ("agent", "request-error"):
            return .agentRequestError
        case ("agent", "turnStopping"), ("agent", "turn-stopping"):
            return .agentTurnStopping
        case ("llm", "stream"), ("llm", "streamEvent"), ("llm", "stream-event"):
            return .llmStream
        case ("agent", "created"):
            return .agentCreated
        case ("agent", "disposed"):
            return .agentDisposed
        case ("agent", "status"):
            return .agentStatus
        case ("agent", "sessionStart"), ("agent", "session-start"):
            return .agentSessionStart
        case ("agent", "error"):
            return .agentError
        case ("agent", "inboxInserted"), ("agent", "inbox-inserted"):
            return .agentInboxInserted
        case ("agent", "inboxClaimed"), ("agent", "inbox-claimed"):
            return .agentInboxClaimed
        case ("agent", "inboxDiscarded"), ("agent", "inbox-discarded"):
            return .agentInboxDiscarded
        case ("agent", "inboxPreClaim"), ("agent", "inbox-pre-claim"):
            return .agentInboxPreClaim
        case ("inbox", "preClaim"), ("inbox", "pre-claim"):
            return .agentInboxPreClaim
        case ("tools", "result"):
            return .toolsResult
        case ("tools", "change"):
            return .toolsChange
        case ("tools", "codeDispatchLog"), ("tools", "code-dispatch-log"):
            return .toolsCodeDispatchLog
        default:
            return nil
        }
    }

    private static func register(
        point: ISHHostedHarnessPoint,
        endpoint: ISHHostedHarnessEndpoint,
        sessionID: String,
        client: ISHPluginHostClient,
        synchronizeMobileContext: @escaping @Sendable () async throws -> Void,
        context: CordisPluginContext
    ) async throws {
        let invoker = ISHHostedHarnessInvoker(
            endpoint: endpoint,
            sessionID: sessionID,
            client: client,
            synchronizeMobileContext: synchronizeMobileContext
        )
        let label = "ish.\(endpoint.identity)"

        switch point {
        case .agentInboxPreClaim:
            try await registerInboxPreClaim(
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .memoryRecall:
            try await registerPreStep(
                CordisAgentLoopCheckpoints.memoryRecall,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .orchestrationPreStep:
            try await registerPreStep(
                CordisAgentLoopCheckpoints.orchestrationPreStep,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .agentPreStep:
            try await registerPreStep(
                CordisAgentLoopCheckpoints.preStep,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .orchestrationRequest:
            try await registerRequest(
                CordisAgentLoopCheckpoints.orchestrationRequest,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .agentRequest:
            try await registerRequest(
                CordisAgentLoopCheckpoints.request,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .llmStream:
            try await registerLLMStream(
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .orchestrationRequestError:
            try await registerRequestError(
                CordisAgentLoopCheckpoints.orchestrationRequestError,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .agentRequestError:
            try await registerRequestError(
                CordisAgentLoopCheckpoints.requestError,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .sandboxPreExecute:
            try await registerSandbox(
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .toolsPreExecute:
            try await registerToolDecision(
                CordisAgentLoopCheckpoints.toolsPreExecute,
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .toolsExecute:
            try await registerToolExecute(
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .toolsPostExecute:
            try await registerToolPostExecute(
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .toolsCodeDispatchLog:
            try await registerCodeDispatchLog(
                point: point,
                invoker: invoker,
                label: label,
                context: context
            )
        case .agentCreated:
            try await registerEvent(
                CordisAgentLoopEvents.agentCreated,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                agentIdentityInput(input, checkpoint: point.rawValue)
            }
        case .agentDisposed:
            try await registerEvent(
                CordisAgentLoopEvents.agentDisposed,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                agentIdentityInput(input, checkpoint: point.rawValue)
            }
        case .agentStatus:
            try await registerEvent(
                CordisAgentLoopEvents.agentStatus,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                agentStatusInput(input, checkpoint: point.rawValue)
            }
        case .agentSessionStart:
            try await registerEvent(
                CordisAgentLoopEvents.agentSessionStart,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                agentSessionStartInput(input, checkpoint: point.rawValue)
            }
        case .agentError:
            try await registerEvent(
                CordisAgentLoopEvents.agentError,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                agentErrorInput(input, checkpoint: point.rawValue)
            }
        case .agentInboxInserted:
            try await registerEvent(
                CordisAgentLoopEvents.agentInboxInserted,
                invoker: invoker,
                label: label,
                context: context
            ) { input in inboxInsertedInput(input, checkpoint: point.rawValue) }
        case .agentInboxClaimed:
            try await registerEvent(
                CordisAgentLoopEvents.agentInboxClaimed,
                invoker: invoker,
                label: label,
                context: context
            ) { input in inboxClaimedInput(input, checkpoint: point.rawValue) }
        case .agentInboxDiscarded:
            try await registerEvent(
                CordisAgentLoopEvents.agentInboxDiscarded,
                invoker: invoker,
                label: label,
                context: context
            ) { input in inboxDiscardedInput(input, checkpoint: point.rawValue) }
        case .toolsResult:
            try await registerEvent(
                CordisAgentLoopEvents.toolsResult,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                toolResultInput(input, checkpoint: point.rawValue)
            }
        case .toolsChange:
            try await registerEvent(
                CordisAgentLoopEvents.toolsChange,
                invoker: invoker,
                label: label,
                context: context
            ) { _ in
                .object(["checkpoint": .string(point.rawValue)])
            }
        case .memoryRecord:
            try await registerEvent(
                CordisAgentLoopCheckpoints.memoryRecord,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                memoryRecordInput(input, checkpoint: point.rawValue)
            }
        case .agentTurnStopping:
            try await registerEvent(
                CordisAgentLoopCheckpoints.turnStopping,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                turnStoppingInput(input, checkpoint: point.rawValue)
            }
        case .orchestrationTurnStopping:
            try await registerEvent(
                CordisAgentLoopCheckpoints.orchestrationTurnStopping,
                invoker: invoker,
                label: label,
                context: context
            ) { input in
                turnStoppingInput(input, checkpoint: point.rawValue)
            }
        }
    }

    private static func registerPreStep(
        _ checkpoint: CordisCheckpointKey<
            CordisAgentPreStepContext,
            CordisAgentPreStepDecision
        >,
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            checkpoint,
            invoker: invoker,
            label: label,
            context: context,
            encode: { preStepInput($0, checkpoint: point.rawValue) },
            decode: { value, _ in try preStepDecision(value) },
            onFailure: { _, next in try await next() }
        )
    }

    private static func registerInboxPreClaim(
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            CordisAgentLoopCheckpoints.inboxPreClaim,
            invoker: invoker,
            label: label,
            context: context,
            encode: { inboxPreClaimInput($0, checkpoint: point.rawValue) },
            decode: { value, input in try inboxPreClaimDecision(value, original: input) },
            onFailure: { _, next in try await next() }
        )
    }

    private static func registerRequest(
        _ checkpoint: CordisCheckpointKey<
            CordisAgentRequestContext,
            CordisModelRequestPlan
        >,
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await context.intercept(checkpoint, label: label) { input, next in
            let current = try await next()
            do {
                let value = try await invoker.invoke(
                    arguments: requestInput(
                        input,
                        request: current,
                        checkpoint: point.rawValue
                    )
                )
                return try requestPlan(value, original: current) ?? current
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Host request policy is optional. A stopped or replaced
                // contribution must not take the native model loop down.
                return current
            }
        }
    }

    /// Bridges the native AsyncThrowingStream without handing the provider
    /// client, credentials, or transport session to iSH. Each event is acknowledged by
    /// the Host before it is yielded downstream, which gives dynamic Host
    /// plugins real backpressure and an explicit cancellation boundary.
    private static func registerLLMStream(
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await context.intercept(
            CordisAgentLoopCheckpoints.llmStream,
            label: label
        ) { input, next in
            let upstream = try await next()
            let streamID = UUID().uuidString.lowercased()
            do {
                let response = try await invoker.invoke(
                    arguments: llmStreamInput(
                        input,
                        checkpoint: point.rawValue,
                        streamID: streamID,
                        phase: "start",
                        event: nil
                    )
                )
                try llmStreamStartDecision(response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The Host hook is optional. A stale or unavailable dynamic
                // generation must not take down the native model request.
                return upstream
            }
            return observeLLMStream(
                upstream,
                input: input,
                streamID: streamID,
                point: point,
                invoker: invoker
            )
        }
    }

    private static func observeLLMStream(
        _ upstream: CordisModelEventStream,
        input: CordisLLMStreamContext,
        streamID: String,
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker
    ) -> CordisModelEventStream {
        let (stream, continuation) = CordisModelEventStream.makeStream()
        let task = Task {
            do {
                for try await event in upstream {
                    try Task.checkCancellation()
                    let decision: LLMStreamDecision
                    do {
                        let response = try await invoker.invoke(
                            arguments: llmStreamInput(
                                input,
                                checkpoint: point.rawValue,
                                streamID: streamID,
                                phase: "event",
                                event: event
                            ),
                            synchronize: false
                        )
                        decision = try llmStreamDecision(response)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Preserve the model stream on malformed/stale Host
                        // responses; dynamic hooks are fail-open per boundary.
                        continuation.yield(event)
                        continue
                    }
                    switch decision {
                    case .next:
                        continuation.yield(event)
                    case .drop:
                        break
                    case let .replace(replacement):
                        continuation.yield(replacement)
                    }
                }
                await sendLLMTerminal(
                    phase: "finish",
                    input: input,
                    streamID: streamID,
                    point: point,
                    invoker: invoker
                )
                continuation.finish()
            } catch is CancellationError {
                await sendLLMTerminal(
                    phase: "cancel",
                    input: input,
                    streamID: streamID,
                    point: point,
                    invoker: invoker
                )
                continuation.finish(throwing: CancellationError())
            } catch {
                await sendLLMTerminal(
                    phase: "error",
                    input: input,
                    streamID: streamID,
                    point: point,
                    invoker: invoker,
                    error: bounded(String(describing: error), maximum: 8_192)
                )
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        return stream
    }

    private static func sendLLMTerminal(
        phase: String,
        input: CordisLLMStreamContext,
        streamID: String,
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        error: String? = nil
    ) async {
        var payload = llmStreamInput(
            input,
            checkpoint: point.rawValue,
            streamID: streamID,
            phase: phase,
            event: nil
        )
        if case var .object(object) = payload, let error {
            object["error"] = .string(error)
            payload = .object(object)
        }
        // Terminal notifications are best effort and deliberately detached
        // from cancellation so a cancelled model task cannot retain a Host
        // invocation indefinitely.
        await Task.detached {
            _ = try? await invoker.invoke(arguments: payload, synchronize: false)
        }.value
    }

    private static func registerRequestError(
        _ checkpoint: CordisCheckpointKey<
            CordisAgentRequestErrorContext,
            CordisAgentRequestErrorAction
        >,
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            checkpoint,
            invoker: invoker,
            label: label,
            context: context,
            encode: { requestErrorInput($0, checkpoint: point.rawValue) },
            decode: { value, _ in try requestErrorAction(value) },
            onFailure: { _, next in try await next() }
        )
    }

    private static func registerSandbox(
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            CordisAgentLoopCheckpoints.sandboxPreExecute,
            invoker: invoker,
            label: label,
            context: context,
            encode: { toolExecutionInput($0, checkpoint: point.rawValue) },
            decode: { value, _ in try toolDecision(value) },
            onFailure: { message, _ in
                .deny(reason: "iSH 沙箱策略不可用，已拒绝执行：\(bounded(message, maximum: 512))")
            }
        )
    }

    private static func registerToolDecision(
        _ checkpoint: CordisCheckpointKey<CordisToolExecution, CordisPreToolDecision>,
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            checkpoint,
            invoker: invoker,
            label: label,
            context: context,
            encode: { toolExecutionInput($0, checkpoint: point.rawValue) },
            decode: { value, _ in try toolDecision(value) },
            onFailure: { _, next in try await next() }
        )
    }

    private static func registerToolExecute(
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            CordisAgentLoopCheckpoints.toolsExecute,
            invoker: invoker,
            label: label,
            context: context,
            encode: { toolExecutionInput($0, checkpoint: point.rawValue) },
            decode: { value, _ in try toolResult(value) },
            onFailure: { message, _ in
                CordisToolExecutionResult(
                    text: bridgeErrorResult(message),
                    isError: true
                )
            }
        )
    }

    private static func registerToolPostExecute(
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await registerCheckpoint(
            CordisAgentLoopCheckpoints.toolsPostExecute,
            invoker: invoker,
            label: label,
            context: context,
            encode: { postToolInput($0, checkpoint: point.rawValue) },
            decode: { value, _ in try toolResult(value) },
            onFailure: { _, next in try await next() }
        )
    }

    private static func registerCodeDispatchLog(
        point: ISHHostedHarnessPoint,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext
    ) async throws {
        try await context.intercept(
            CordisAgentLoopCheckpoints.toolsCodeDispatchLog,
            label: label
        ) { input, next in
            let current = try await next()
            do {
                let value = try await invoker.invoke(
                    arguments: codeDispatchLogInput(
                        input,
                        result: current,
                        checkpoint: point.rawValue
                    )
                )
                return try toolResult(value) ?? current
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Logging and presentation hooks are optional. A stale or
                // failed Host generation must not erase the native child
                // result or turn a successful Code Mode run into a failure.
                return current
            }
        }
    }

    private static func registerCheckpoint<Input: Sendable, Output: Sendable>(
        _ checkpoint: CordisCheckpointKey<Input, Output>,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext,
        encode: @escaping @Sendable (Input) -> JSONValue,
        decode: @escaping @Sendable (JSONValue, Input) throws -> Output?,
        onFailure: @escaping @Sendable (
            String,
            CordisCheckpointNext<Output>
        ) async throws -> Output
    ) async throws {
        try await context.intercept(checkpoint, label: label) { input, next in
            do {
                let value = try await invoker.invoke(arguments: encode(input))
                if let replacement = try decode(value, input) {
                    return replacement
                }
                return try await next()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return try await onFailure(String(describing: error), next)
            }
        }
    }

    private static func registerEvent<Input: Sendable>(
        _ event: CordisEventKey<Input>,
        invoker: ISHHostedHarnessInvoker,
        label: String,
        context: CordisPluginContext,
        encode: @escaping @Sendable (Input) -> JSONValue
    ) async throws {
        try await context.on(event, label: label) { input in
            do {
                _ = try await invoker.invoke(arguments: encode(input))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A stopped or replaced Host contribution is isolated to its
                // own event listener. The native loop remains available.
            }
        }
    }

    private static func preStepInput(
        _ input: CordisAgentPreStepContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "messages": .array(input.messages.map(messageValue))
        ])
    }

    private static func inboxPreClaimInput(
        _ input: CordisAgentInboxPreClaimContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "boundary": .string(input.boundary == .nextStep ? "next-step" : "next-turn"),
            "workspaceBoundary": .string(input.workspaceBoundary),
            "message": .object([
                "id": .string(input.message.id.uuidString.lowercased()),
                "source": .string(input.source),
                "text": .string(input.message.text),
                "disposition": .string(input.message.disposition.rawValue),
                "createdAtMilliseconds": .number(
                    input.message.createdAt.timeIntervalSince1970 * 1_000
                )
            ])
        ])
    }

    private static func requestInput(
        _ input: CordisAgentRequestContext,
        request: CordisModelRequestPlan,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "request": requestValue(request)
        ])
    }

    private enum LLMStreamDecision: Sendable {
        case next
        case drop
        case replace(LLMStreamEvent)
    }

    private static func llmStreamInput(
        _ input: CordisLLMStreamContext,
        checkpoint: String,
        streamID: String,
        phase: String,
        event: LLMStreamEvent?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "checkpoint": .string(checkpoint),
            "phase": .string(phase),
            "streamId": .string(streamID),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "request": .object([
                "configuration": .object([
                    "providerId": .string(input.request.configuration.providerID.rawValue),
                    "profileId": input.request.configuration.profileID.map(JSONValue.string) ?? .null,
                    "baseURL": .string(bounded(input.request.configuration.baseURL, maximum: 2_048)),
                    "model": .string(bounded(input.request.configuration.model, maximum: 512)),
                    "reasoningMode": .string(input.request.configuration.reasoningMode.rawValue),
                    "maxSteps": .number(Double(input.request.configuration.maxSteps)),
                    "maxOutputTokens": .number(Double(input.request.configuration.maxOutputTokens))
                ]),
                "systemPrompt": .string(bounded(input.request.systemPrompt, maximum: 8 * 1_024)),
                "messages": .array(input.request.messages.prefix(128).map(messageValue)),
                "tools": .array(input.request.tools.prefix(64).map(toolValue))
            ])
        ]
        if let event {
            object["event"] = streamEventValue(event)
        }
        return .object(object)
    }

    private static func streamEventValue(_ event: LLMStreamEvent) -> JSONValue {
        switch event {
        case let .text(text):
            return .object(["kind": .string("text"), "text": .string(bounded(text, maximum: 32 * 1_024))])
        case let .reasoning(text):
            return .object(["kind": .string("reasoning"), "text": .string(bounded(text, maximum: 32 * 1_024))])
        case let .toolCallDelta(index, id, type, name, arguments):
            return .object([
                "kind": .string("toolCallDelta"),
                "index": .number(Double(index)),
                "id": id.map(JSONValue.string) ?? .null,
                "type": type.map(JSONValue.string) ?? .null,
                "name": name.map(JSONValue.string) ?? .null,
                "arguments": .string(bounded(arguments, maximum: 32 * 1_024))
            ])
        case let .usage(usage):
            return .object([
                "kind": .string("usage"),
                "promptTokens": .number(Double(usage.promptTokens)),
                "completionTokens": .number(Double(usage.completionTokens)),
                "totalTokens": .number(Double(usage.totalTokens)),
                "cachedPromptTokens": usage.cachedPromptTokens.map { .number(Double($0)) } ?? .null,
                "uncachedPromptTokens": usage.uncachedPromptTokens.map { .number(Double($0)) } ?? .null,
                "reasoningTokens": usage.reasoningTokens.map { .number(Double($0)) } ?? .null
            ])
        case let .finish(reason):
            return .object(["kind": .string("finish"), "reason": .string(reason.rawValue)])
        }
    }

    private static func llmStreamStartDecision(_ value: JSONValue) throws {
        let object = try responseObject(value)
        let kind = try responseKind(object)
        guard kind == "next" || kind == "observe" else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "llm/stream start kind must be next or observe"
            )
        }
    }

    private static func llmStreamDecision(_ value: JSONValue) throws -> LLMStreamDecision {
        let object = try responseObject(value)
        switch try responseKind(object) {
        case "next", "observe":
            return .next
        case "drop":
            return .drop
        case "replace":
            guard let replacement = object["event"] else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "llm/stream replace requires event"
                )
            }
            return .replace(try streamEvent(replacement))
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "llm/stream event kind must be next, drop, or replace"
            )
        }
    }

    private static func streamEvent(_ value: JSONValue) throws -> LLMStreamEvent {
        guard let object = value.objectValue,
              let kind = object["kind"]?.stringValue else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "llm/stream event must be an object with kind"
            )
        }
        switch kind {
        case "text":
            return .text(try requiredString(object, "text", allowEmpty: true))
        case "reasoning":
            return .reasoning(try requiredString(object, "text", allowEmpty: true))
        case "toolCallDelta":
            guard let index = try optionalInteger(object["index"]) else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "llm/stream toolCallDelta index must be an integer"
                )
            }
            return .toolCallDelta(
                index: index,
                id: object["id"]?.stringValue,
                type: object["type"]?.stringValue,
                name: object["name"]?.stringValue,
                arguments: try requiredString(object, "arguments", allowEmpty: true)
            )
        case "usage":
            guard let prompt = try optionalInteger(object["promptTokens"]),
                  let completion = try optionalInteger(object["completionTokens"]),
                  let total = try optionalInteger(object["totalTokens"]) else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "llm/stream usage requires promptTokens, completionTokens, and totalTokens"
                )
            }
            return .usage(ModelTokenUsage(
                promptTokens: prompt,
                completionTokens: completion,
                totalTokens: total,
                cachedPromptTokens: try optionalInteger(object["cachedPromptTokens"]),
                reasoningTokens: try optionalInteger(object["reasoningTokens"]),
                uncachedPromptTokens: try optionalInteger(object["uncachedPromptTokens"])
            ))
        case "finish":
            guard let rawReason = object["reason"]?.stringValue,
                  let reason = ModelFinishReason(rawValue: rawReason) else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "llm/stream finish reason is invalid"
                )
            }
            return .finish(reason)
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "unsupported llm/stream event kind (kind)"
            )
        }
    }

    private static func requestErrorInput(
        _ input: CordisAgentRequestErrorContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "providerId": .string(input.providerID),
            "model": .string(input.model),
            "error": .string(bounded(input.error, maximum: 8_192))
        ])
    }

    private static func toolExecutionInput(
        _ input: CordisToolExecution,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "call": .object([
                "id": .string(input.call.id),
                "name": .string(input.call.name),
                "arguments": .object(input.arguments)
            ]),
            "risk": .string(input.risk.rawValue),
            "summary": .string(input.summary)
        ])
    }

    private static func postToolInput(
        _ input: CordisPostToolExecutionContext,
        checkpoint: String
    ) -> JSONValue {
        guard case let .object(execution) = toolExecutionInput(
            input.execution,
            checkpoint: checkpoint
        ) else {
            return .null
        }
        var object = execution
        object["result"] = .object([
            "text": .string(input.result.text),
            "isError": .bool(input.result.isError)
        ])
        return .object(object)
    }

    private static func codeDispatchLogInput(
        _ input: CordisCodeDispatchLogContext,
        result: CordisToolExecutionResult,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "parentCallId": .string(input.parentCallID),
            "dispatchCallId": .string(input.dispatchCallID),
            "toolName": .string(input.toolName),
            "result": .object([
                "text": .string(result.text),
                "isError": .bool(result.isError),
                "value": result.value ?? .null
            ])
        ])
    }

    private static func toolResultInput(
        _ input: CordisToolResultContext,
        checkpoint: String
    ) -> JSONValue {
        postToolInput(
            CordisPostToolExecutionContext(
                execution: input.execution,
                result: input.result
            ),
            checkpoint: checkpoint
        )
    }

    private static func agentIdentityInput(
        _ input: CordisAgentIdentityContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased())
        ])
    }

    private static func agentStatusInput(
        _ input: CordisAgentStatusContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "status": .string(input.status.rawValue)
        ])
    }

    private static func agentSessionStartInput(
        _ input: CordisAgentSessionStartContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "source": .string(input.source.rawValue)
        ])
    }

    private static func agentErrorInput(
        _ input: CordisAgentErrorContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "error": .string(bounded(input.error, maximum: 8_192))
        ])
    }

    private static func inboxMessageValue(_ message: QueuedAgentInput) -> JSONValue {
        .object([
            "id": .string(message.id.uuidString.lowercased()),
            "text": .string(bounded(message.text, maximum: QueuedAgentInput.maximumTextUTF8Bytes)),
            "disposition": .string(message.disposition.rawValue),
            "createdAtMilliseconds": .number(message.createdAt.timeIntervalSince1970 * 1_000)
        ])
    }

    private static func inboxInsertedInput(
        _ input: CordisAgentInboxInsertedContext,
        checkpoint: String
    ) -> JSONValue {
        inboxLifecycleInput(
            agentID: input.agentID,
            runID: input.runID,
            message: input.message,
            source: input.source,
            boundary: input.boundary,
            checkpoint: checkpoint,
            turn: nil,
            reason: nil
        )
    }

    private static func inboxClaimedInput(
        _ input: CordisAgentInboxClaimedContext,
        checkpoint: String
    ) -> JSONValue {
        inboxLifecycleInput(
            agentID: input.agentID,
            runID: input.runID,
            message: input.message,
            source: input.source,
            boundary: input.boundary,
            checkpoint: checkpoint,
            turn: nil,
            reason: nil
        )
    }

    private static func inboxDiscardedInput(
        _ input: CordisAgentInboxDiscardedContext,
        checkpoint: String
    ) -> JSONValue {
        inboxLifecycleInput(
            agentID: input.agentID,
            runID: input.runID,
            message: input.message,
            source: input.source,
            boundary: input.boundary,
            checkpoint: checkpoint,
            turn: nil,
            reason: input.reason
        )
    }

    private static func inboxLifecycleInput(
        agentID: UUID,
        runID: UUID,
        message: QueuedAgentInput,
        source: String,
        boundary: QueuedInputBoundary,
        checkpoint: String,
        turn: Int?,
        reason: String?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "checkpoint": .string(checkpoint),
            "agentId": .string(agentID.uuidString.lowercased()),
            "runId": .string(runID.uuidString.lowercased()),
            "source": .string(bounded(source, maximum: 256)),
            "boundary": .string(boundary == .nextStep ? "next-step" : "turn-stopping"),
            "message": inboxMessageValue(message)
        ]
        if let turn {
            object["turn"] = .number(Double(turn))
        }
        if let reason {
            object["reason"] = .string(bounded(reason, maximum: 512))
        }
        return .object(object)
    }

    private static func memoryRecordInput(
        _ input: CordisMemoryRecordContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "runId": .string(input.runID.uuidString.lowercased()),
            "step": .number(Double(input.step)),
            "messages": .array(input.messages.map(messageValue))
        ])
    }

    private static func turnStoppingInput(
        _ input: CordisAgentTurnStoppingContext,
        checkpoint: String
    ) -> JSONValue {
        .object([
            "checkpoint": .string(checkpoint),
            "agentId": .string(input.agentID.uuidString.lowercased()),
            "runId": .string(input.runID.uuidString.lowercased()),
            "turn": .number(Double(input.turn)),
            "step": .number(Double(input.step)),
            "messages": .array(input.messages.map(messageValue))
        ])
    }

    private static func requestValue(_ request: CordisModelRequestPlan) -> JSONValue {
        .object([
            "configuration": .object([
                "providerId": .string(request.configuration.providerID.rawValue),
                "baseUrl": .string(request.configuration.baseURL),
                "model": .string(request.configuration.model),
                "reasoningMode": .string(request.configuration.reasoningMode.rawValue),
                "maxSteps": .number(Double(request.configuration.maxSteps)),
                "maxOutputTokens": .number(Double(request.configuration.maxOutputTokens))
            ])
        ])
    }

    private static func messageValue(_ message: AgentMessage) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(message.id.uuidString.lowercased()),
            "role": .string(message.role.rawValue),
            "content": .string(message.content),
            "createdAtMilliseconds": .number(message.createdAt.timeIntervalSince1970 * 1_000),
            "toolCalls": .array(message.toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "arguments": .string(call.arguments)
                ])
            })
        ]
        if let reasoning = message.reasoning {
            object["reasoning"] = .string(reasoning)
        }
        if let toolCallID = message.toolCallID {
            object["toolCallId"] = .string(toolCallID)
        }
        if let toolName = message.toolName {
            object["toolName"] = .string(toolName)
        }
        if let isToolError = message.isToolError {
            object["isToolError"] = .bool(isToolError)
        }
        return .object(object)
    }

    private static func toolValue(_ tool: ModelToolDefinition) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters
        ])
    }

    private static func preStepDecision(_ value: JSONValue) throws -> CordisAgentPreStepDecision? {
        let object = try responseObject(value)
        switch try responseKind(object) {
        case "next":
            return nil
        case "enter":
            return .enter(try messages(object["messages"]))
        case "reject":
            return .reject(reason: try requiredString(object, "reason"))
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "pre-step kind must be next, enter, or reject"
            )
        }
    }

    private static func inboxPreClaimDecision(
        _ value: JSONValue,
        original: CordisAgentInboxPreClaimContext
    ) throws -> CordisAgentInboxPreClaimDecision? {
        let object = try responseObject(value)
        let allowed = Set([
            "kind", "text", "messageId", "source", "workspaceBoundary",
            "boundary", "disposition"
        ])
        if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "inbox pre-claim cannot mutate field \(unknown)"
            )
        }

        try requireInvariant(
            object,
            key: "messageId",
            expected: original.message.id.uuidString.lowercased()
        )
        try requireInvariant(object, key: "source", expected: original.source)
        try requireInvariant(
            object,
            key: "workspaceBoundary",
            expected: original.workspaceBoundary
        )
        try requireInvariant(
            object,
            key: "boundary",
            expected: original.boundary == .nextStep ? "next-step" : "next-turn"
        )
        try requireInvariant(
            object,
            key: "disposition",
            expected: original.message.disposition.rawValue
        )

        switch try responseKind(object) {
        case "next":
            guard object.keys.allSatisfy({ $0 == "kind" }) else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "next inbox decision cannot include mutations"
                )
            }
            return nil
        case "claim":
            let text = object["text"]?.stringValue ?? original.message.text
            let validated = try QueuedAgentInput(
                id: original.message.id,
                text: text,
                disposition: original.message.disposition,
                createdAt: original.message.createdAt
            )
            return .claim(text: validated.text)
        case "rewrite":
            let text = try requiredString(object, "text")
            let validated = try QueuedAgentInput(
                id: original.message.id,
                text: text,
                disposition: original.message.disposition,
                createdAt: original.message.createdAt
            )
            return .claim(text: validated.text)
        case "discard":
            guard object["text"] == nil else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "discard inbox decision cannot include text"
                )
            }
            return .discard
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "inbox pre-claim kind must be next, claim, rewrite, or discard"
            )
        }
    }

    private static func requireInvariant(
        _ object: [String: JSONValue],
        key: String,
        expected: String
    ) throws {
        guard let value = object[key] else { return }
        guard value.stringValue == expected else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "inbox pre-claim cannot change \(key)"
            )
        }
    }

    private static func requestPlan(
        _ value: JSONValue,
        original: CordisModelRequestPlan
    ) throws -> CordisModelRequestPlan? {
        let object = try responseObject(value)
        let kind = try responseKind(object)
        if kind == "next" { return nil }
        guard kind == "request" || kind == "replace" else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "request kind must be next, request, or replace"
            )
        }
        let body = object["request"]?.objectValue ?? object
        var configuration = original.configuration
        if let replacement = body["configuration"]?.objectValue {
            if let provider = replacement["providerId"]?.stringValue,
               provider != configuration.providerID.rawValue {
                throw ISHPluginHostHarnessBridgeError.unsafeRequestMutation("providerId")
            }
            if let baseURL = replacement["baseUrl"]?.stringValue,
               baseURL != configuration.baseURL {
                throw ISHPluginHostHarnessBridgeError.unsafeRequestMutation("baseUrl")
            }
            if let model = replacement["model"]?.stringValue {
                configuration.model = model
            }
            if let rawMode = replacement["reasoningMode"]?.stringValue,
               let mode = ReasoningMode(rawValue: rawMode) {
                configuration.reasoningMode = mode
            }
            if let maxSteps = try optionalInteger(replacement["maxSteps"]) {
                configuration.maxSteps = maxSteps
            }
            if let maxOutputTokens = try optionalInteger(replacement["maxOutputTokens"]) {
                configuration.maxOutputTokens = maxOutputTokens
            }
        }
        configuration = try configuration.validated()

        return CordisModelRequestPlan(configuration: configuration)
    }

    private static func requestErrorAction(
        _ value: JSONValue
    ) throws -> CordisAgentRequestErrorAction? {
        let object = try responseObject(value)
        switch try responseKind(object) {
        case "next":
            return nil
        case "retry":
            return .retry
        case "fail":
            return .fail
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "request-error kind must be next, retry, or fail"
            )
        }
    }

    private static func toolDecision(_ value: JSONValue) throws -> CordisPreToolDecision? {
        let object = try responseObject(value)
        switch try responseKind(object) {
        case "next":
            return nil
        case "allow":
            return .allow
        case "ask":
            return .ask
        case "deny":
            return .deny(reason: try requiredString(object, "reason"))
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "tool decision kind must be next, allow, ask, or deny"
            )
        }
    }

    private static func toolResult(_ value: JSONValue) throws -> CordisToolExecutionResult? {
        let object = try responseObject(value)
        switch try responseKind(object) {
        case "next":
            return nil
        case "result":
            guard case let .bool(isError)? = object["isError"] else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "tool result isError must be boolean"
                )
            }
            return CordisToolExecutionResult(
                text: try requiredString(object, "text", allowEmpty: true),
                isError: isError
            )
        default:
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "tool result kind must be next or result"
            )
        }
    }

    private static func responseObject(_ value: JSONValue) throws -> [String: JSONValue] {
        guard let object = value.objectValue else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse("expected an object")
        }
        return object
    }

    private static func responseKind(_ object: [String: JSONValue]) throws -> String {
        try requiredString(object, "kind")
    }

    private static func requiredString(
        _ object: [String: JSONValue],
        _ key: String,
        allowEmpty: Bool = false
    ) throws -> String {
        guard let value = object[key]?.stringValue,
              allowEmpty || !value.isEmpty else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "\(key) must be \(allowEmpty ? "a" : "a non-empty") string"
            )
        }
        return value
    }

    private static func messages(_ value: JSONValue?) throws -> [AgentMessage] {
        guard case let .array(values)? = value else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse("messages must be an array")
        }
        return try values.map(message)
    }

    private static func message(_ value: JSONValue) throws -> AgentMessage {
        guard let object = value.objectValue,
              let rawRole = object["role"]?.stringValue,
              let role = AgentRole(rawValue: rawRole),
              let content = object["content"]?.stringValue else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "each message needs role and content"
            )
        }
        let id = object["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
        let createdAt: Date
        if case let .number(milliseconds)? = object["createdAtMilliseconds"],
           milliseconds.isFinite {
            createdAt = Date(timeIntervalSince1970: milliseconds / 1_000)
        } else {
            createdAt = .now
        }
        let toolCalls: [AgentToolCall]
        if case let .array(values)? = object["toolCalls"] {
            toolCalls = try values.map { raw in
                guard let call = raw.objectValue else {
                    throw ISHPluginHostHarnessBridgeError.invalidResponse(
                        "toolCalls entries must be objects"
                    )
                }
                return AgentToolCall(
                    id: try requiredString(call, "id"),
                    name: try requiredString(call, "name"),
                    arguments: try requiredString(call, "arguments", allowEmpty: true)
                )
            }
        } else {
            toolCalls = []
        }
        let isToolError: Bool?
        if case let .bool(value)? = object["isToolError"] {
            isToolError = value
        } else {
            isToolError = nil
        }
        return AgentMessage(
            id: id,
            role: role,
            content: content,
            reasoning: object["reasoning"]?.stringValue,
            toolCalls: toolCalls,
            toolCallID: object["toolCallId"]?.stringValue,
            toolName: object["toolName"]?.stringValue,
            isToolError: isToolError,
            createdAt: createdAt
        )
    }

    private static func tools(_ value: JSONValue?) throws -> [ModelToolDefinition] {
        guard case let .array(values)? = value else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse("tools must be an array")
        }
        return try values.map { raw in
            guard let object = raw.objectValue,
                  let parameters = object["parameters"] else {
                throw ISHPluginHostHarnessBridgeError.invalidResponse(
                    "each tool needs name, description, and parameters"
                )
            }
            return ModelToolDefinition(
                name: try requiredString(object, "name"),
                description: try requiredString(object, "description", allowEmpty: true),
                parameters: parameters
            )
        }
    }

    private static func optionalInteger(_ value: JSONValue?) throws -> Int? {
        guard let value else { return nil }
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            throw ISHPluginHostHarnessBridgeError.invalidResponse(
                "expected an integer"
            )
        }
        return Int(number)
    }

    private static func bridgeErrorResult(_ message: String) -> String {
        JSONValue.object([
            "error": .object([
                "code": .string("ish_harness_bridge_failed"),
                "message": .string(bounded(message, maximum: 4_096))
            ])
        ]).displayText
    }

    private static func bounded(_ text: String, maximum: Int) -> String {
        String(text.prefix(maximum))
    }
}
