import Foundation

enum LocalWorkflowLifecycleEvent: Sendable, Equatable {
    case runStart(runID: String, name: String)
    case phase(runID: String, title: String)
    case log(runID: String, message: String)
    case agentStart(
        runID: String,
        sequence: Int,
        label: String,
        phase: String?,
        childID: String,
        parentID: String,
        depth: Int,
        startedAtMilliseconds: Int64
    )
    case agentEnd(
        runID: String,
        sequence: Int,
        outcome: String,
        durationMilliseconds: Int64,
        error: String?
    )
    case runEnd(runID: String, stopReason: String)

    var runID: String {
        switch self {
        case let .runStart(runID, _), let .phase(runID, _), let .log(runID, _),
             let .agentStart(runID, _, _, _, _, _, _, _), let .agentEnd(runID, _, _, _, _),
             let .runEnd(runID, _):
            runID
        }
    }

    var sessionEvent: SessionEventDraft? {
        switch self {
        case let .runStart(runID, name):
            return SessionEventDraft(
                type: "tool-workflow/run-start",
                data: .object([
                    "runId": .string(runID),
                    "name": .string(name)
                ])
            )
        case .phase, .log:
            // Upstream phase/log events are observe-only. The durable parent
            // Session contract records only run/member start/end pairs.
            return nil
        case let .agentStart(runID, sequence, label, phase, childID, parentID, depth, startedAt):
            var data: [String: JSONValue] = [
                "runId": .string(runID),
                "seq": .number(Double(sequence)),
                "label": .string(label),
                "childId": .string(childID),
                "parentId": .string(parentID),
                "depth": .number(Double(depth)),
                "startedAtMilliseconds": .number(Double(startedAt))
            ]
            if let phase { data["phase"] = .string(phase) }
            return SessionEventDraft(
                type: "tool-workflow/agent-start",
                data: .object(data)
            )
        case let .agentEnd(runID, sequence, outcome, durationMilliseconds, error):
            var data: [String: JSONValue] = [
                    "runId": .string(runID),
                    "seq": .number(Double(sequence)),
                    "outcome": .string(outcome),
                    "durationMilliseconds": .number(Double(durationMilliseconds))
                ]
            if let error, !error.isEmpty {
                data["error"] = .string(String(error.prefix(2_048)))
            }
            return SessionEventDraft(type: "tool-workflow/agent-end", data: .object(data))
        case let .runEnd(runID, stopReason):
            return SessionEventDraft(
                type: "tool-workflow/run-end",
                data: .object([
                    "runId": .string(runID),
                    "stopReason": .string(stopReason)
                ])
            )
        }
    }
}

typealias LocalWorkflowLifecycleSink = @Sendable (LocalWorkflowLifecycleEvent) async throws -> Void

struct WorkflowAgentCall: Sendable, Equatable {
    let requestID: String
    let sequence: Int
    let prompt: String
    let label: String
    let phase: String?
    let model: String?
    let providerBundleID: AgentProviderBundleID?
    let outputSchema: JSONValue?

    init(
        requestID: String,
        sequence: Int,
        prompt: String,
        label: String,
        phase: String?,
        model: String?,
        providerBundleID: AgentProviderBundleID? = nil,
        outputSchema: JSONValue? = nil
    ) {
        self.requestID = requestID
        self.sequence = sequence
        self.prompt = prompt
        self.label = label
        self.phase = phase
        self.model = model
        self.providerBundleID = providerBundleID
        self.outputSchema = outputSchema
    }
}

struct WorkflowAgentDispatchResult: Sendable, Equatable {
    let value: JSONValue
    let error: String?
}

struct WorkflowScriptExecutionRequest: Sendable, Equatable {
    let runID: String
    let script: String
    let args: JSONValue
}

struct WorkflowScriptExecutionResult: Sendable, Equatable {
    let value: JSONValue
    let agentsStarted: Int
}

typealias LocalWorkflowScriptExecutor = @Sendable (
    WorkflowScriptExecutionRequest,
    @escaping @Sendable () async -> Void,
    @escaping @Sendable (WorkflowAgentCall) async -> WorkflowAgentDispatchResult,
    @escaping @Sendable (String) async -> Void,
    @escaping @Sendable (String) async -> Void,
    @escaping @Sendable (AgentToolOutputChunk) async -> Void
) async throws -> WorkflowScriptExecutionResult

enum WorkflowToolSuite {
    static let names: Set<String> = ["workflow"]
    static let promptSection = CordisPromptSection(
        name: "tool:workflow",
        order: 115,
        text: "Use workflow only when the user explicitly asks for a workflow or the task needs large multi-agent fan-out. For one or two focused delegations, prefer subagent. Mobile workflow runs in the foreground on this iPhone and cannot resume after app termination."
    )

    static func makeTools(
        store: WorkspaceStore,
        runner: LocalSubagentRunner?,
        registry: any HarnessJobManaging,
        ownerSession: String,
        maximumDepth: Int = 3,
        lifecycleSink: @escaping LocalWorkflowLifecycleSink = { _ in }
    ) -> [any LocalAgentTool] {
        let scriptExecutor = ISHWorkflowScriptExecutor(
            store: store,
            sessionID: ownerSession
        )
        return [
            LocalWorkflowTool(
                runner: runner,
                registry: registry,
                ownerSession: ownerSession,
                maximumDepth: maximumDepth,
                lifecycleSink: lifecycleSink,
                scriptExecutor: scriptExecutor.execute
            )
        ]
    }
}

struct LocalWorkflowTool: LocalAgentTool {
    private static let maximumScriptBytes = 24 * 1_024
    private static let maximumMetaTextBytes = 2 * 1_024
    private static let maximumResultBytes = 50 * 1_024

    let runner: LocalSubagentRunner?
    let registry: any HarnessJobManaging
    let ownerSession: String
    let maximumDepth: Int
    /// Injectable for deterministic tests; production keeps the RC.8 mobile
    /// foreground child deadline at ten minutes.
    let childTimeoutMilliseconds: Int
    let childTerminationGraceMilliseconds: Int
    let lifecycleSink: LocalWorkflowLifecycleSink
    let scriptExecutor: LocalWorkflowScriptExecutor

    init(
        runner: LocalSubagentRunner?,
        registry: any HarnessJobManaging,
        ownerSession: String,
        maximumDepth: Int = 3,
        childTimeoutMilliseconds: Int = 600_000,
        childTerminationGraceMilliseconds: Int = 5_000,
        lifecycleSink: @escaping LocalWorkflowLifecycleSink,
        scriptExecutor: @escaping LocalWorkflowScriptExecutor
    ) {
        self.runner = runner
        self.registry = registry
        self.ownerSession = ownerSession
        self.maximumDepth = maximumDepth
        self.childTimeoutMilliseconds = childTimeoutMilliseconds
        self.childTerminationGraceMilliseconds = childTerminationGraceMilliseconds
        self.lifecycleSink = lifecycleSink
        self.scriptExecutor = scriptExecutor
    }

    let definition = ModelToolDefinition(
        name: "workflow",
        description: "Run a foreground JavaScript orchestration workflow entirely on this iPhone. The isolated script receives only agent(), parallel(), pipeline(), phase(), log(), and args. Child model calls use the configured native provider outside iSH; API keys never enter the script sandbox. Mobile limits: 3 concurrent children, 12 total children, 64 items per parallel/pipeline call, 10-minute run. agent(prompt, {label, phase, model, provider, schema}) supports an installed local Profile Bundle override and JSON Schema validation.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "script": .object([
                    "type": .string("string"),
                    "description": .string("Plain JavaScript async function body. Use top-level await and end with return <JSON value>. Do not include export/meta declarations.")
                ]),
                "meta": .object([
                    "type": .string("object"),
                    "description": .string("Workflow identity and optional progress phases."),
                    "properties": .object([
                        "name": .object(["type": .string("string")]),
                        "description": .object(["type": .string("string")]),
                        "whenToUse": .object(["type": .string("string")]),
                        "phases": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "title": .object(["type": .string("string")]),
                                    "detail": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("title")]),
                                "additionalProperties": .bool(false)
                            ])
                        ])
                    ]),
                    "required": .array([.string("name"), .string("description")]),
                    "additionalProperties": .bool(false)
                ]),
                "args": .object([
                    "type": .string("object"),
                    "description": .string("Optional JSON object exposed to the script as args."),
                    "additionalProperties": .bool(true)
                ])
            ]),
            "required": .array([.string("script"), .string("meta")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["script", "meta", "args"])
        _ = try arguments.requiredString(
            "script",
            maximumUTF8Bytes: Self.maximumScriptBytes
        )
        guard let meta = arguments["meta"]?.objectValue else {
            throw LocalToolError.invalidArguments
        }
        try meta.requireOnlyKeys(["name", "description", "whenToUse", "phases"])
        _ = try meta.requiredString("name", maximumUTF8Bytes: 128)
        _ = try meta.requiredString(
            "description",
            maximumUTF8Bytes: Self.maximumMetaTextBytes
        )
        if let whenToUse = meta["whenToUse"] {
            guard let value = whenToUse.stringValue,
                  value.utf8.count <= Self.maximumMetaTextBytes else {
                throw LocalToolError.invalidArguments
            }
        }
        if let phases = meta["phases"] {
            guard case let .array(items) = phases, items.count <= 32 else {
                throw LocalToolError.invalidArguments
            }
            for item in items {
                guard let phase = item.objectValue else {
                    throw LocalToolError.invalidArguments
                }
                try phase.requireOnlyKeys(["title", "detail"])
                _ = try phase.requiredString("title", maximumUTF8Bytes: 256)
                if let detail = phase["detail"] {
                    guard let value = detail.stringValue,
                          value.utf8.count <= Self.maximumMetaTextBytes else {
                        throw LocalToolError.invalidArguments
                    }
                }
            }
        }
        if let args = arguments["args"], args.objectValue == nil {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let name = arguments["meta"]?.objectValue?["name"]?.stringValue ?? "workflow"
        return "运行本机工作流：\(String(name.prefix(80)))"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workflow:\(ownerSession)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments) { _ in }
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try validate(arguments: arguments)
        guard let runner else {
            throw LocalToolError.pluginDenied("手机 workflow 子 Agent 运行器尚未就绪。")
        }
        let script = try arguments.requiredString(
            "script",
            maximumUTF8Bytes: Self.maximumScriptBytes
        )
        guard let meta = arguments["meta"]?.objectValue,
              let name = meta["name"]?.stringValue else {
            throw LocalToolError.invalidArguments
        }
        let runID = UUID().uuidString.lowercased()
        let recordsLifecycle = CodeModeExecutionScope.context == nil
        let children = WorkflowChildSet()
        let recorder = WorkflowLifecycleEmitter(
            enabled: recordsLifecycle,
            sink: lifecycleSink
        )

        do {
            let result = try await scriptExecutor(
                WorkflowScriptExecutionRequest(
                    runID: runID,
                    script: script,
                    args: arguments["args"] ?? .object([:])
                ),
                {
                    await recorder.start(runID: runID, name: name)
                },
                { call in
                    await dispatchAgent(
                        call,
                        runID: runID,
                        runner: runner,
                        children: children,
                        recorder: recorder,
                        onOutput: onOutput
                    )
                },
                { title in
                    await recorder.emit(.phase(runID: runID, title: title))
                    await onOutput(.init(channel: .progress, text: "Workflow phase: \(title)\n"))
                },
                { message in
                    await recorder.emit(.log(runID: runID, message: message))
                    await onOutput(.init(channel: .progress, text: "Workflow: \(message)\n"))
                },
                onOutput
            )
            // A child dispatch deliberately converts ordinary branch failures
            // into null values for parallel/pipeline. Cancellation is
            // different: preserve it at the workflow boundary so the parent
            // cannot publish a false successful completion after cancellation.
            try Task.checkCancellation()
            let encoded = try JSONEncoder().encode(result.value)
            guard encoded.count <= Self.maximumResultBytes else {
                throw LocalToolError.resultTooLarge
            }
            await recorder.finish(runID: runID, stopReason: "completed")
            return JSONValue.object([
                "runId": .string(runID),
                "agentsStarted": .number(Double(result.agentsStarted)),
                "result": result.value
            ]).displayText
        } catch is CancellationError {
            await interruptChildren(children, reason: "workflow cancelled")
            await recorder.finish(runID: runID, stopReason: "cancelled")
            throw CancellationError()
        } catch {
            await interruptChildren(children, reason: "workflow failed")
            await recorder.finish(runID: runID, stopReason: "error")
            throw error
        }
    }

    private func dispatchAgent(
        _ call: WorkflowAgentCall,
        runID: String,
        runner: @escaping LocalSubagentRunner,
        children: WorkflowChildSet,
        recorder: WorkflowLifecycleEmitter,
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async -> WorkflowAgentDispatchResult {
        let childID = UUID().uuidString.lowercased()
        let startedAt = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        var didAnnounceStart = false
        do {
            let child = try await registry.registerSubagent(
                id: childID,
                parentSession: ownerSession,
                label: call.label,
                model: call.model,
                providerBundleID: nil,
                contextMode: .fresh,
                persona: nil,
                toolFilter: nil,
                reportDelivery: .wakeup,
                maximumDepth: maximumDepth
            )
            await children.insert(childID)
            let request = LocalSubagentRequest(
                childAddress: childID,
                prompt: call.prompt,
                label: call.label,
                model: call.model,
                providerBundleID: call.providerBundleID,
                delegationDepth: child.delegationDepth,
                maximumDepth: child.maximumDepth,
                outputSchema: call.outputSchema,
                runInBackground: false,
                isContinuation: false
            )
            let jobID = try await registry.startSubagentActivation(id: childID) { emit in
                let output = try await runner(request) { _ in }
                await emit(output)
                return HarnessJobOutcome(
                    status: .completed,
                    detail: "workflow child settled",
                    output: output
                )
            }
            await recorder.emit(.agentStart(
                runID: runID,
                sequence: call.sequence,
                label: call.label,
                phase: call.phase,
                childID: childID,
                parentID: runID,
                depth: child.delegationDepth,
                startedAtMilliseconds: startedAt
            ))
            didAnnounceStart = true
            await onOutput(.init(
                channel: .progress,
                text: "Workflow child \(call.sequence) started: \(call.label)\n"
            ))
            let waited = try await registry.wait(
                id: jobID,
                timeoutMilliseconds: childTimeoutMilliseconds,
                ownerSession: ownerSession
            )
            var timedOut = false
            if !waited.status.isTerminal {
                timedOut = true
                _ = try? await registry.interruptSubagent(
                    id: childID,
                    requesterSession: ownerSession,
                    reason: "workflow child timed out"
                )
                // Interrupt is cooperative. Give the activation a short,
                // bounded window to publish its terminal state before reading
                // it; otherwise a stopping snapshot is mistaken for success.
                _ = try? await registry.wait(
                    id: jobID,
                    timeoutMilliseconds: childTerminationGraceMilliseconds,
                    ownerSession: ownerSession
                )
            }
            let read = try await registry.read(id: jobID, ownerSession: ownerSession)
            let outcome: String
            let value: JSONValue
            if read.snapshot.status == .completed, !timedOut {
                outcome = "completed"
                value = .string(read.text)
            } else if read.snapshot.status == .killed || read.snapshot.status == .stopping {
                outcome = "cancelled"
                value = .null
            } else {
                outcome = "failed"
                value = .null
            }
            await recorder.emit(.agentEnd(
                runID: runID,
                sequence: call.sequence,
                outcome: outcome,
                durationMilliseconds: max(0, Int64((Date().timeIntervalSince1970 * 1_000).rounded()) - startedAt),
                error: outcome == "completed" ? nil : String(read.text.prefix(2_048))
            ))
            await onOutput(.init(
                channel: outcome == "completed" ? .progress : .stderr,
                text: "Workflow child \(call.sequence) \(outcome): \(call.label) [duration_ms=\(max(0, Int64((Date().timeIntervalSince1970 * 1_000).rounded()) - startedAt))]\n"
            ))
            // A child that was created and reached a terminal state is an
            // ordinary orchestration failure. The JS contract represents it
            // as null so one failed branch does not abort parallel work.
            return WorkflowAgentDispatchResult(value: value, error: nil)
        } catch is CancellationError {
            _ = try? await registry.interruptSubagent(
                id: childID,
                requesterSession: ownerSession,
                reason: "workflow cancelled"
            )
            if didAnnounceStart {
                await recorder.emit(.agentEnd(
                    runID: runID,
                    sequence: call.sequence,
                    outcome: "cancelled",
                    durationMilliseconds: max(0, Int64((Date().timeIntervalSince1970 * 1_000).rounded()) - startedAt),
                    error: "workflow cancelled"
                ))
            }
            return WorkflowAgentDispatchResult(value: .null, error: "workflow cancelled")
        } catch {
            if didAnnounceStart {
                await recorder.emit(.agentEnd(
                    runID: runID,
                    sequence: call.sequence,
                    outcome: "failed",
                    durationMilliseconds: max(0, Int64((Date().timeIntervalSince1970 * 1_000).rounded()) - startedAt),
                    error: error.localizedDescription
                ))
            }
            return WorkflowAgentDispatchResult(
                value: .null,
                error: error.localizedDescription
            )
        }
    }

    private func interruptChildren(_ children: WorkflowChildSet, reason: String) async {
        for childID in await children.values {
            _ = try? await registry.interruptSubagent(
                id: childID,
                requesterSession: ownerSession,
                reason: reason
            )
        }
    }
}

/// Upstream recording is observational and fail-open for execution, but once
/// one append fails it must stop emitting that run so the durable log remains
/// either absent or a legal continuous prefix.
private actor WorkflowLifecycleEmitter {
    private let enabled: Bool
    private let sink: LocalWorkflowLifecycleSink
    private var started = false
    private var disabled = false

    init(enabled: Bool, sink: @escaping LocalWorkflowLifecycleSink) {
        self.enabled = enabled
        self.sink = sink
    }

    func start(runID: String, name: String) async {
        guard enabled, !started else { return }
        started = true
        await emit(.runStart(runID: runID, name: name))
    }

    func emit(_ event: LocalWorkflowLifecycleEvent) async {
        guard enabled, started, !disabled else { return }
        do {
            try await sink(event)
        } catch {
            disabled = true
        }
    }

    func finish(runID: String, stopReason: String) async {
        guard started else { return }
        await emit(.runEnd(runID: runID, stopReason: stopReason))
    }
}

private actor WorkflowChildSet {
    private var ids = Set<String>()
    func insert(_ id: String) { ids.insert(id) }
    var values: [String] { Array(ids) }
}

struct ISHWorkflowScriptExecutor: Sendable {
    private static let maximumConcurrentAgents = 3
    private static let maximumTotalAgents = 12
    private static let maximumItemsPerCall = 64

    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String

    init(
        store: WorkspaceStore,
        coordinator: ISHSandboxCoordinator = .shared,
        sessionID: String
    ) {
        self.store = store
        self.coordinator = coordinator
        self.sessionID = sessionID
    }

    func execute(
        _ request: WorkflowScriptExecutionRequest,
        started: @escaping @Sendable () async -> Void,
        dispatch: @escaping @Sendable (WorkflowAgentCall) async -> WorkflowAgentDispatchResult,
        phase: @escaping @Sendable (String) async -> Void,
        log: @escaping @Sendable (String) async -> Void,
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> WorkflowScriptExecutionResult {
        let workspaceURL = try await store.rootURL()
        let mounts = try await store.activeMountBindings()
        await coordinator.setWorkspaceMounts(mounts)
        let runDirectory = workspaceURL
            .appendingPathComponent(".harness-mobile", isDirectory: true)
            .appendingPathComponent("workflow-runs", isDirectory: true)
            .appendingPathComponent(request.runID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let wrapper = Self.wrapJavaScript(
            body: request.script,
            args: request.args,
            maximumConcurrentAgents: Self.maximumConcurrentAgents,
            maximumTotalAgents: Self.maximumTotalAgents,
            maximumItemsPerCall: Self.maximumItemsPerCall
        )
        let encoded = Data(wrapper.utf8).base64EncodedString()
        let guestDirectory = "/workspace/.harness-mobile/workflow-runs/\(request.runID)"
        let command = "mkdir -p '\(Self.shellEscaped(guestDirectory))'; export DSH_WORKFLOW_DIR='\(Self.shellEscaped(guestDirectory))'; printf '%s' '\(encoded)' | base64 -d | node"
        let parser = WorkflowMarkerParser()
        let tracker = WorkflowDispatchTracker()

        do {
            let result = try await coordinator.execute(
                sessionID: "\(sessionID).workflow.\(request.runID)",
                command: command,
                workspaceURL: workspaceURL,
                timeout: 600,
                maximumOutputBytes: 192 * 1_024,
                policy: ISHSandboxExecutionPolicy(
                    mode: .dangerFullAccess,
                    workspaceRoot: workspaceURL
                ),
                onOutput: { chunk in
                    if chunk.channel == .stderr {
                        await onOutput(.init(channel: .stderr, text: chunk.text))
                        return
                    }
                    let batch = await parser.append(chunk.text)
                    for marker in batch.markers {
                        switch marker {
                        case .started:
                            await started()
                        case let .agent(call):
                            await tracker.launch {
                                let response = await dispatch(call)
                                let wrote = await Self.writeResponse(
                                    requestID: call.requestID,
                                    result: response,
                                    directory: runDirectory
                                )
                                if !wrote {
                                    await onOutput(.init(
                                        channel: .stderr,
                                        text: "Workflow child \(call.sequence) response could not be written.\n"
                                    ))
                                }
                            }
                        case let .phase(title):
                            await phase(title)
                        case let .log(message):
                            await log(message)
                        case .result:
                            break
                        }
                    }
                    if !batch.visibleText.isEmpty {
                        await onOutput(.init(channel: .stdout, text: batch.visibleText))
                    }
                }
            )
            try await tracker.waitForAll()
            if let protocolError = await parser.protocolError {
                throw WorkflowToolError.protocolFailure(protocolError)
            }
            guard result.exitCode == 0 else {
                let message = Self.cleanRuntimeOutput(result.stderr)
                throw WorkflowToolError.programFailed(
                    message.isEmpty
                        ? "JavaScript exited with code \(result.exitCode)"
                        : message
                )
            }
            guard let completion = await parser.completion else {
                throw WorkflowToolError.protocolFailure("workflow result marker was missing")
            }
            return completion
        } catch {
            await tracker.cancelAll()
            throw error
        }
    }

    static func wrapJavaScript(
        body: String,
        args: JSONValue,
        maximumConcurrentAgents: Int,
        maximumTotalAgents: Int,
        maximumItemsPerCall: Int
    ) -> String {
        let argsData = (try? JSONEncoder().encode(args)) ?? Data("{}".utf8)
        let argsBase64 = argsData.base64EncodedString()
        return #"""
        'use strict';
        const vm = require('node:vm');
        const fs = require('node:fs');
        const path = require('node:path');
        const crypto = require('node:crypto');
        const runDir = process.env.DSH_WORKFLOW_DIR;
        const argsValue = JSON.parse(Buffer.from('__ARGS_BASE64__', 'base64').toString('utf8'));
        const MAX_CONCURRENT = __MAX_CONCURRENT__;
        const MAX_TOTAL = __MAX_TOTAL__;
        const MAX_ITEMS = __MAX_ITEMS__;
        let started = 0;
        let active = 0;
        let currentPhase;
        const waiters = [];

        class WorkflowFatalError extends Error {
          constructor(code, message) { super(`${code}: ${message}`); this.code = code; }
        }
        const fatal = (code, message) => { throw new WorkflowFatalError(code, message); };
        const emit = value => process.stdout.write('__DSH_WORKFLOW__' + JSON.stringify(value) + '\n');
        const materialize = (value, label, seen = new Set()) => {
          if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
          if (typeof value === 'number') {
            if (!Number.isFinite(value)) fatal('INVALID_ARGUMENT', `${label} contains a non-finite number`);
            return value;
          }
          if (typeof value !== 'object') fatal('INVALID_ARGUMENT', `${label} must be plain JSON data`);
          if (seen.has(value)) fatal('INVALID_ARGUMENT', `${label} contains a cycle`);
          seen.add(value);
          try {
            if (Array.isArray(value)) {
              const output = [];
              for (let index = 0; index < value.length; index += 1) {
                if (!Object.prototype.hasOwnProperty.call(value, index)) {
                  fatal('INVALID_ARGUMENT', `${label} contains a sparse array`);
                }
                output.push(materialize(value[index], `${label}[${index}]`, seen));
              }
              return output;
            }
            const proto = Object.getPrototypeOf(value);
            if (proto !== null && (!proto.constructor || proto.constructor.name !== 'Object')) {
              fatal('INVALID_ARGUMENT', `${label} contains a non-plain object`);
            }
            if (Object.getOwnPropertySymbols(value).length !== 0) {
              fatal('INVALID_ARGUMENT', `${label} contains symbol keys`);
            }
            const output = {};
            for (const key of Object.keys(value)) {
              output[key] = materialize(value[key], `${label}.${key}`, seen);
            }
            return output;
          } finally {
            seen.delete(value);
          }
        };
        const boundedText = (value, label, max = 49152) => {
          if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value, 'utf8') > max) {
            fatal('INVALID_ARGUMENT', `${label} must be a non-empty bounded string`);
          }
          return value;
        };
        const acquire = async () => {
          if (active < MAX_CONCURRENT) { active += 1; return; }
          await new Promise(resolve => waiters.push(resolve));
          active += 1;
        };
        const release = () => {
          active -= 1;
          const next = waiters.shift();
          if (next) next();
        };
        const waitResponse = async id => {
          if (typeof id !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
            fatal('AGENT_RESULT', 'child dispatch id is invalid');
          }
          const responsePath = path.join(runDir, id + '.json');
          for (let attempt = 0; attempt < 60000; attempt += 1) {
            try {
              const response = JSON.parse(fs.readFileSync(responsePath, 'utf8'));
              try { fs.unlinkSync(responsePath); } catch (_) {}
              return response;
            } catch (error) {
              if (error && error.code !== 'ENOENT') throw error;
              await new Promise(resolve => setTimeout(resolve, 10));
            }
          }
          fatal('AGENT_RESULT', 'child dispatch timed out');
        };
        const readOptions = raw => {
          if (raw === undefined) return {};
          const opts = materialize(raw, 'agent() options');
          if (!opts || Array.isArray(opts) || typeof opts !== 'object') {
            fatal('INVALID_ARGUMENT', 'agent() options must be an object');
          }
          const supported = new Set(['label', 'phase', 'model', 'provider', 'schema']);
          for (const key of Object.keys(opts)) {
            if (!supported.has(key)) fatal('UNSUPPORTED_OPTION', `agent() option "${key}" is not supported`);
          }
          for (const key of ['label', 'phase', 'model', 'provider']) {
            if (opts[key] !== undefined && typeof opts[key] !== 'string') {
              fatal('INVALID_ARGUMENT', `agent() option "${key}" must be a string`);
            }
          }
          if (opts.schema !== undefined) {
            const schema = materialize(opts.schema, 'agent() schema');
            if (!schema || Array.isArray(schema) || typeof schema !== 'object') {
              fatal('INVALID_ARGUMENT', 'agent() schema must be a JSON object');
            }
            opts.schema = schema;
          }
          return opts;
        };
        const agent = async (rawPrompt, rawOptions) => {
          const prompt = boundedText(rawPrompt, 'agent() prompt');
          const options = readOptions(rawOptions);
          if (started >= MAX_TOTAL) fatal('AGENT_CAP', `workflow reached its ${MAX_TOTAL}-agent limit`);
          started += 1;
          const sequence = started;
          await acquire();
          try {
            const id = crypto.randomUUID();
            const label = options.label || prompt.replace(/\s+/g, ' ').slice(0, 80);
            emit({kind: 'agent', id, sequence, prompt, label, phase: options.phase || currentPhase, model: options.model, provider: options.provider, schema: options.schema});
            const response = await waitResponse(id);
            if (!response.ok) fatal('AGENT_START', String(response.error || 'child agent failed to start'));
            return response.value === undefined ? null : response.value;
          } finally {
            release();
          }
        };
        const parallel = async thunks => {
          if (!Array.isArray(thunks)) fatal('INVALID_ARGUMENT', 'parallel() requires an array of functions');
          if (thunks.length > MAX_ITEMS) fatal('ITEM_CAP', `parallel() accepts at most ${MAX_ITEMS} items`);
          thunks.forEach((thunk, index) => {
            if (typeof thunk !== 'function') fatal('INVALID_ARGUMENT', `parallel() item ${index} is not a function`);
          });
          return Promise.all(thunks.map(async thunk => {
            try { return await thunk(); }
            catch (error) { if (error instanceof WorkflowFatalError) throw error; return null; }
          }));
        };
        const pipeline = async (items, ...stages) => {
          if (!Array.isArray(items)) fatal('INVALID_ARGUMENT', 'pipeline() requires an item array');
          if (items.length > MAX_ITEMS) fatal('ITEM_CAP', `pipeline() accepts at most ${MAX_ITEMS} items`);
          if (stages.length === 0 || stages.some(stage => typeof stage !== 'function')) {
            fatal('INVALID_ARGUMENT', 'pipeline() requires one or more function stages');
          }
          return Promise.all(items.map(async (item, index) => {
            let value = item;
            for (const stage of stages) {
              try { value = await stage(value, item, index); }
              catch (error) { if (error instanceof WorkflowFatalError) throw error; return null; }
            }
            return value;
          }));
        };
        const phase = title => {
          currentPhase = boundedText(title, 'phase()', 2048);
          emit({kind: 'phase', title: currentPhase});
        };
        const log = message => emit({kind: 'log', message: boundedText(message, 'log()', 4096)});
        const context = vm.createContext(
          {agent, parallel, pipeline, phase, log, args: argsValue},
          {codeGeneration: {strings: false, wasm: false}}
        );
        const body = Buffer.from('__BODY_BASE64__', 'base64').toString('utf8');
        const source = `(async () => {\n${body}\n})()`;
        (async () => {
          try {
            const script = new vm.Script(source, {filename: 'workflow.js'});
            emit({kind: 'start'});
            const value = await script.runInContext(context, {timeout: 1000});
            const result = value === undefined ? null : materialize(value, 'workflow result');
            emit({kind: 'result', ok: true, agentsStarted: started, value: result});
          } catch (error) {
            const code = error && error.code ? error.code : 'SCRIPT_ERROR';
            emit({kind: 'result', ok: false, agentsStarted: started, error: `${code}: ${String(error && error.message || error)}`});
            process.exitCode = 1;
          }
        })();
        """#
            .replacingOccurrences(of: "__ARGS_BASE64__", with: argsBase64)
            .replacingOccurrences(of: "__MAX_CONCURRENT__", with: String(maximumConcurrentAgents))
            .replacingOccurrences(of: "__MAX_TOTAL__", with: String(maximumTotalAgents))
            .replacingOccurrences(of: "__MAX_ITEMS__", with: String(maximumItemsPerCall))
            .replacingOccurrences(
                of: "__BODY_BASE64__",
                with: Data(body.utf8).base64EncodedString()
            )
    }

    private static func writeResponse(
        requestID: String,
        result: WorkflowAgentDispatchResult,
        directory: URL
    ) async -> Bool {
        guard UUID(uuidString: requestID) != nil else { return false }
        var object: [String: JSONValue] = [
            "ok": .bool(result.error == nil),
            "value": result.value
        ]
        if let error = result.error { object["error"] = .string(error) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(
                to: directory.appendingPathComponent(requestID + ".json"),
                options: .atomic
            )
            return true
        } catch {
            return false
        }
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func cleanRuntimeOutput(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("__DSH_WORKFLOW__") }
            .joined(separator: "\n")
    }
}

private enum WorkflowMarker: Sendable, Equatable {
    case started
    case agent(WorkflowAgentCall)
    case phase(String)
    case log(String)
    case result(WorkflowScriptExecutionResult)
}

private struct WorkflowMarkerBatch: Sendable, Equatable {
    let markers: [WorkflowMarker]
    let visibleText: String
}

private actor WorkflowMarkerParser {
    private var buffer = ""
    private(set) var completion: WorkflowScriptExecutionResult?
    private(set) var protocolError: String?

    func append(_ text: String) -> WorkflowMarkerBatch {
        buffer += text
        var markers: [WorkflowMarker] = []
        var visible: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.hasPrefix("__DSH_WORKFLOW__") else {
                visible.append(line)
                continue
            }
            let payload = String(line.dropFirst("__DSH_WORKFLOW__".count))
            guard let data = payload.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let record = value.objectValue,
                  let kind = record["kind"]?.stringValue else {
                protocolError = "malformed workflow marker"
                continue
            }
            switch kind {
            case "start":
                markers.append(.started)
            case "agent":
                guard let id = record["id"]?.stringValue,
                      UUID(uuidString: id) != nil,
                      let sequence = Self.integer(record["sequence"]),
                      sequence > 0,
                      let prompt = record["prompt"]?.stringValue,
                      let label = record["label"]?.stringValue else {
                    protocolError = "malformed workflow agent marker"
                    continue
                }
                let providerBundleID = record["provider"]?.stringValue.flatMap(AgentProviderBundleID.init(rawValue:))
                if record["provider"]?.stringValue != nil, providerBundleID == nil {
                    protocolError = "unsupported workflow provider bundle"
                    continue
                }
                let outputSchema = record["schema"]
                if let outputSchema {
                    do { try LocalSubagentStructuredOutput.validateSchema(outputSchema) }
                    catch {
                        protocolError = "invalid workflow schema: \(error.localizedDescription)"
                        continue
                    }
                }
                markers.append(.agent(WorkflowAgentCall(
                    requestID: id,
                    sequence: sequence,
                    prompt: prompt,
                    label: label,
                    phase: record["phase"]?.stringValue,
                    model: record["model"]?.stringValue,
                    providerBundleID: providerBundleID,
                    outputSchema: outputSchema
                )))
            case "phase":
                guard let title = record["title"]?.stringValue else {
                    protocolError = "malformed workflow phase marker"
                    continue
                }
                markers.append(.phase(title))
            case "log":
                guard let message = record["message"]?.stringValue else {
                    protocolError = "malformed workflow log marker"
                    continue
                }
                markers.append(.log(message))
            case "result":
                guard record["ok"] == .bool(true),
                      let count = Self.integer(record["agentsStarted"]),
                      let result = record["value"] else {
                    protocolError = record["error"]?.stringValue ?? "workflow script failed"
                    continue
                }
                let completion = WorkflowScriptExecutionResult(
                    value: result,
                    agentsStarted: count
                )
                self.completion = completion
                markers.append(.result(completion))
            default:
                protocolError = "unknown workflow marker kind: \(kind)"
            }
        }
        return WorkflowMarkerBatch(
            markers: markers,
            visibleText: visible.isEmpty ? "" : visible.joined(separator: "\n") + "\n"
        )
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case let .number(number)? = value,
              number.isFinite,
              number.rounded() == number,
              number >= 0,
              number <= Double(Int.max) else { return nil }
        return Int(number)
    }
}

private actor WorkflowDispatchTracker {
    private var tasks: [Task<Void, Never>] = []

    func launch(_ operation: @escaping @Sendable () async -> Void) {
        tasks.append(Task { await operation() })
    }

    func waitForAll() async throws {
        let current = tasks
        for task in current {
            try Task.checkCancellation()
            await task.value
        }
        try Task.checkCancellation()
        tasks.removeAll(keepingCapacity: false)
    }

    func cancelAll() async {
        let current = tasks
        current.forEach { $0.cancel() }
        for task in current { await task.value }
        tasks.removeAll(keepingCapacity: false)
    }
}

private enum WorkflowToolError: LocalizedError {
    case programFailed(String)
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case let .programFailed(message):
            "workflow JavaScript failed: \(message)"
        case let .protocolFailure(message):
            "workflow protocol failed: \(message)"
        }
    }
}
