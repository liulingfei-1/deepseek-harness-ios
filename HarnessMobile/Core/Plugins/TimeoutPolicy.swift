import Foundation

/// Cooperative per-tool timeout guard ported from the vendored
/// `guard/timeout-policy` package. A timeout only signals the tool and waits
/// for the execution bridge to reach quiescence; it never abandons a promise.
enum TimeoutPolicy {
    static let pluginID: CordisPluginID = "core.timeout-policy"
    static let toolTimeoutCode = "TOOL_TIMEOUT"

    static func pluginDefinition() -> CordisPluginDefinition {
        CordisPluginDefinition(
            id: pluginID,
            version: "1",
            dependencies: [CordisAgentServiceKeys.tools.name]
        ) { context in
            let tools = try await context.service(CordisAgentServiceKeys.tools)
            _ = try await context.intercept(
                CordisAgentLoopCheckpoints.toolsExecute,
                label: "timeout-policy/tools-execute"
            ) { input, next in
                guard let timeoutMs = await tools.tool(named: input.call.name)?.definition.timeoutMs else {
                    return try await next()
                }
                guard timeoutMs > 0 else {
                    throw TimeoutPolicyError.invalidTimeout(tool: input.call.name, value: timeoutMs)
                }

                let upstream = input.signal
                let deadline = ToolCancellationSignal(parent: upstream)
                input.replacingSignal(deadline)
                let timer = Task { @Sendable in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                        _ = deadline.cancel(reason: .timeout(code: toolTimeoutCode))
                    } catch is CancellationError {
                        // The operation settled before the deadline.
                    } catch {
                        // Timer failure cannot manufacture a tool timeout.
                    }
                }
                defer {
                    timer.cancel()
                    // Post-execute listeners must observe the caller's signal,
                    // matching the upstream Cordis wrapper's finally block.
                    input.replacingSignal(upstream)
                }

                do {
                    let result = try await next()
                    return deadline.reason?.isOwnedTimeout == true
                        ? timeoutResult(timeoutMs: timeoutMs)
                        : result
                } catch {
                    // A cooperative tool commonly throws CancellationError when
                    // its child task is cancelled. Only our own deadline maps it
                    // to TOOL_TIMEOUT; an outer/user cancellation remains thrown.
                    if deadline.reason?.isOwnedTimeout == true {
                        return timeoutResult(timeoutMs: timeoutMs)
                    }
                    throw error
                }
            }
        }
    }

    static func timeoutResult(timeoutMs: Int) -> CordisToolExecutionResult {
        let message = "tool call timed out after \(timeoutMs)ms"
        return CordisToolExecutionResult(
            text: "Error: \(message)",
            isError: true,
            value: .object([
                "error": .object([
                    "name": .string("ToolTimeoutError"),
                    "code": .string(toolTimeoutCode)
                ]),
                "message": .string(message)
            ]),
            errorCode: toolTimeoutCode
        )
    }
}

private extension ToolCancellationReason {
    var isOwnedTimeout: Bool {
        if case .timeout(code: TimeoutPolicy.toolTimeoutCode) = self {
            return true
        }
        return false
    }
}

enum TimeoutPolicyError: LocalizedError, Sendable, Equatable {
    case invalidTimeout(tool: String, value: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidTimeout(tool, value):
            return "timeout-policy requires a positive timeoutMs for \(tool), got \(value)."
        }
    }
}
