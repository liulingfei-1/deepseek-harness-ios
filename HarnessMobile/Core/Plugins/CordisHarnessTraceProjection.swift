import Foundation

enum CordisHarnessTraceProjection {
    static func value(_ value: any Sendable) -> JSONValue? {
        switch value {
        case let context as CordisAgentPreStepContext:
            return .object([
                "agentId": .string(context.agentID.uuidString),
                "runId": .string(context.runID.uuidString),
                "turn": .number(Double(context.turn)),
                "step": .number(Double(context.step)),
                "messages": messageArray(context.messages)
            ])
        case let decision as CordisAgentPreStepDecision:
            switch decision {
            case let .enter(messages):
                return .object([
                    "kind": .string("enter"),
                    "messages": messageArray(messages)
                ])
            case let .reject(reason):
                return .object([
                    "kind": .string("reject"),
                    "reason": .string(HarnessTraceRedactor.string(reason, maximumUTF8Bytes: 2_048))
                ])
            }
        case let context as CordisAgentRequestContext:
            return .object([
                "agentId": .string(context.agentID.uuidString),
                "runId": .string(context.runID.uuidString),
                "turn": .number(Double(context.turn)),
                "step": .number(Double(context.step)),
                "request": configuration(context.request.configuration)
            ])
        case let plan as CordisModelRequestPlan:
            return configuration(plan.configuration)
        case let context as CordisAgentRequestErrorContext:
            return .object([
                "agentId": .string(context.agentID.uuidString),
                "runId": .string(context.runID.uuidString),
                "turn": .number(Double(context.turn)),
                "step": .number(Double(context.step)),
                "providerId": .string(context.providerID),
                "model": .string(context.model),
                "error": .string(HarnessTraceRedactor.string(context.error, maximumUTF8Bytes: 4_096))
            ])
        case let action as CordisAgentRequestErrorAction:
            return .object(["kind": .string(action == .retry ? "retry" : "fail")])
        case let context as CordisLLMStreamContext:
            return .object([
                "agentId": .string(context.agentID.uuidString),
                "runId": .string(context.runID.uuidString),
                "turn": .number(Double(context.turn)),
                "step": .number(Double(context.step)),
                "request": .object([
                    "configuration": configuration(context.request.configuration),
                    "systemPrompt": .string(HarnessTraceRedactor.string(
                        context.request.systemPrompt,
                        maximumUTF8Bytes: 8 * 1_024
                    )),
                    "messages": messageArray(context.request.messages),
                    "tools": .array(context.request.tools.prefix(64).map(tool))
                ])
            ])
        case is CordisModelEventStream:
            return .object(["kind": .string("async-model-stream")])
        case let execution as CordisToolExecution:
            return toolExecution(execution)
        case let decision as CordisPreToolDecision:
            switch decision {
            case .allow:
                return .object(["kind": .string("allow")])
            case .ask:
                return .object(["kind": .string("ask")])
            case let .deny(reason):
                return .object([
                    "kind": .string("deny"),
                    "reason": .string(HarnessTraceRedactor.string(reason, maximumUTF8Bytes: 2_048))
                ])
            }
        case let result as CordisToolExecutionResult:
            return toolResult(result)
        case let context as CordisPostToolExecutionContext:
            return .object([
                "execution": toolExecution(context.execution),
                "result": toolResult(context.result)
            ])
        case let context as CordisAgentTurnStoppingContext:
            return .object([
                "agentId": .string(context.agentID.uuidString),
                "runId": .string(context.runID.uuidString),
                "turn": .number(Double(context.turn)),
                "step": .number(Double(context.step)),
                "messages": messageArray(context.messages)
            ])
        case let context as CordisMemoryRecordContext:
            return .object([
                "runId": .string(context.runID.uuidString),
                "step": .number(Double(context.step)),
                "messages": messageArray(context.messages)
            ])
        default:
            return nil
        }
    }

    private static func configuration(_ value: AgentConfiguration) -> JSONValue {
        .object([
            "providerId": .string(value.providerID.rawValue),
            "profileId": value.profileID.map(JSONValue.string) ?? .null,
            "baseURL": .string(HarnessTraceRedactor.string(value.baseURL, maximumUTF8Bytes: 2_048)),
            "model": .string(HarnessTraceRedactor.string(value.model, maximumUTF8Bytes: 512)),
            "reasoningMode": .string(value.reasoningMode.rawValue),
            "maxSteps": .number(Double(value.maxSteps)),
            "maxOutputTokens": .number(Double(value.maxOutputTokens))
        ])
    }

    private static func messageArray(_ messages: [AgentMessage]) -> JSONValue {
        let values = messages.suffix(64).map(message)
        return .array(values)
    }

    private static func message(_ value: AgentMessage) -> JSONValue {
        .object([
            "id": .string(value.id.uuidString),
            "role": .string(value.role.rawValue),
            "content": .string(HarnessTraceRedactor.string(value.content, maximumUTF8Bytes: 8 * 1_024)),
            "reasoning": value.reasoning.map {
                .string(HarnessTraceRedactor.string($0, maximumUTF8Bytes: 8 * 1_024))
            } ?? .null,
            "toolCalls": .array(value.toolCalls.prefix(32).map(toolCall)),
            "toolCallId": value.toolCallID.map(JSONValue.string) ?? .null,
            "toolName": value.toolName.map(JSONValue.string) ?? .null,
            "isToolError": value.isToolError.map(JSONValue.bool) ?? .null
        ])
    }

    private static func toolCall(_ value: AgentToolCall) -> JSONValue {
        .object([
            "id": .string(value.id),
            "name": .string(value.name),
            "arguments": .string(HarnessTraceRedactor.string(value.arguments, maximumUTF8Bytes: 8 * 1_024))
        ])
    }

    private static func tool(_ value: ModelToolDefinition) -> JSONValue {
        .object([
            "name": .string(value.name),
            "description": .string(HarnessTraceRedactor.string(value.description, maximumUTF8Bytes: 2_048)),
            "parameters": HarnessTraceRedactor.json(value.parameters)
        ])
    }

    private static func toolExecution(_ value: CordisToolExecution) -> JSONValue {
        .object([
            "agentId": .string(value.agentID.uuidString),
            "runId": .string(value.runID.uuidString),
            "turn": .number(Double(value.turn)),
            "step": .number(Double(value.step)),
            "call": toolCall(value.call),
            "arguments": HarnessTraceRedactor.json(.object(value.arguments)),
            "risk": .string(value.risk.rawValue),
            "summary": .string(HarnessTraceRedactor.string(value.summary, maximumUTF8Bytes: 2_048))
        ])
    }

    private static func toolResult(_ value: CordisToolExecutionResult) -> JSONValue {
        .object([
            "text": .string(HarnessTraceRedactor.string(value.text, maximumUTF8Bytes: 16 * 1_024)),
            "isError": .bool(value.isError)
        ])
    }
}
