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
    case sandboxPreExecute = "sandbox/pre-execute"
    case toolsPreExecute = "tools/pre-execute"
    case toolsExecute = "tools/execute"
    case toolsPostExecute = "tools/post-execute"
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

    func invoke(arguments: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
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
        case ("tools", "result"):
            return .toolsResult
        case ("tools", "change"):
            return .toolsChange
        default:
            return nil
        }
    }

    private static func register(
        point: ISHHostedHarnessPoint,
        endpoint: ISHHostedHarnessEndpoint,
        sessionID: String,
        client: ISHPluginHostClient,
        context: CordisPluginContext
    ) async throws {
        let invoker = ISHHostedHarnessInvoker(
            endpoint: endpoint,
            sessionID: sessionID,
            client: client
        )
        let label = "ish.\(endpoint.identity)"

        switch point {
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
