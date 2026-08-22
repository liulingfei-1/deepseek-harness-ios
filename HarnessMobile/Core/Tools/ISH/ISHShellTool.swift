import Foundation

struct ISHShellExecuteTool: LocalAgentTool {
    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String
    let jobRegistry: any HarnessJobManaging

    let definition = ModelToolDefinition(
        name: "shell_execute",
        description: "Execute a shell command inside the on-device iSH ARM64 Alpine sandbox. The command never runs on a remote server. The working directory is /workspace; user-mounted folders are available at /workspace/mounts/<name> with their configured read-only or read-write policy. Arbitrary shell is classified as destructive and requires explicit Harness approval even in full-access mode; only an exact long-term shell/workspace grant suppresses later prompts.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell script to pass to /bin/sh on the phone.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(3_600),
                    "description": .string("Optional timeout. Defaults to 300 seconds and may be shortened under background, low-power, or thermal pressure.")
                ]),
                "run_in_background": .object([
                    "type": .string("boolean"),
                    "description": .string("Start the command as an on-device background job and return its job id. Defaults to false.")
                ])
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false)
        ])
    )
    // An unrestricted guest shell can delete workspace data, install code,
    // and initiate network side effects. Classify the boundary, not the
    // apparent command text, because shell parsing cannot safely prove an
    // arbitrary script benign.
    let risk: ToolRisk = .destructive

    init(
        store: WorkspaceStore,
        coordinator: ISHSandboxCoordinator = .shared,
        sessionID: String,
        jobRegistry: any HarnessJobManaging = HarnessJobRegistry()
    ) {
        self.store = store
        self.coordinator = coordinator
        self.sessionID = sessionID
        self.jobRegistry = jobRegistry
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["command", "timeout_seconds", "run_in_background"])
        _ = try arguments.requiredString(
            "command",
            maximumUTF8Bytes: 64 * 1_024
        )
        if let value = arguments["timeout_seconds"] {
            guard case let .number(number) = value,
                  number.rounded() == number,
                  (1...3_600).contains(Int(number)) else {
                throw LocalToolError.invalidArguments
            }
        }
        if let value = arguments["run_in_background"], Self.bool(value) == nil {
            throw LocalToolError.invalidArguments
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let command = arguments["command"]?.stringValue ?? ""
        let firstLine = command.split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init) ?? command
        return "在手机 iSH 中执行：\(String(firstLine.prefix(120)))"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        _ = try arguments.requiredString(
            "command",
            maximumUTF8Bytes: 64 * 1_024
        )
        return ["ish-sandbox:/workspace"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments) { _ in }
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try validate(arguments: arguments)
        let command = try arguments.requiredString(
            "command",
            maximumUTF8Bytes: 64 * 1_024
        )
        let timeout: TimeInterval
        if case let .number(value)? = arguments["timeout_seconds"] {
            timeout = value
        } else {
            timeout = 300
        }
        let workspaceURL = try await store.rootURL()
        let mounts = try await store.activeMountBindings()
        await coordinator.setWorkspaceMounts(mounts)
        if arguments["run_in_background"].flatMap(Self.bool) == true {
            let executionSessionID = "\(sessionID).job.\(UUID().uuidString.lowercased())"
            let id = try await jobRegistry.start(
                kind: "bash",
                label: String(command.prefix(2_000)),
                ownerSession: sessionID,
                outputLimitBytes: 112 * 1_024
            ) { emit in
                let result = try await coordinator.execute(
                    sessionID: executionSessionID,
                    command: command,
                    workspaceURL: workspaceURL,
                    timeout: timeout,
                    maximumOutputBytes: 112 * 1_024,
                    policy: ISHSandboxExecutionPolicy(
                        mode: .dangerFullAccess,
                        workspaceRoot: workspaceURL
                    ),
                    onOutput: { chunk in
                        await emit(chunk.text)
                    }
                )
                return HarnessJobOutcome(
                    status: .completed,
                    detail: "exit code: \(result.exitCode)"
                )
            }
            return JSONValue.object([
                "kind": .string("background"),
                "jobId": .string(id)
            ]).displayText
        }
        let result = try await coordinator.execute(
            sessionID: sessionID,
            command: command,
            workspaceURL: workspaceURL,
            timeout: timeout,
            maximumOutputBytes: 112 * 1_024,
            policy: ISHSandboxExecutionPolicy(
                mode: .dangerFullAccess,
                workspaceRoot: workspaceURL
            ),
            onOutput: { chunk in
                await onOutput(
                    AgentToolOutputChunk(
                        channel: chunk.channel == .stderr ? .stderr : .stdout,
                        text: chunk.text
                    )
                )
            }
        )
        return JSONValue.object([
            "exit_code": .number(Double(result.exitCode)),
            "pid": .number(Double(result.pid)),
            "duration_ms": .number((result.duration * 1_000).rounded()),
            "stdout": .string(Self.bounded(result.stdout, maximumBytes: 56 * 1_024)),
            "stderr": .string(Self.bounded(result.stderr, maximumBytes: 56 * 1_024))
        ]).displayText
    }

    private static func bounded(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        result.reserveCapacity(maximumBytes)
        var used = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard used + bytes <= maximumBytes else { break }
            result.unicodeScalars.append(scalar)
            used += bytes
        }
        return result + "\n[output truncated for model context]"
    }

    private static func bool(_ value: JSONValue) -> Bool? {
        guard case let .bool(result) = value else { return nil }
        return result
    }
}

/// Local projection of DSH's `code-runtime` seam. The program is piped into an
/// interpreter inside the on-device iSH guest; no source or execution request
/// is forwarded to a server or a downloaded native runtime.
struct ISHCodeExecuteTool: LocalAgentTool {
    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "code_execute",
        description: "Run a bounded Python, JavaScript, or POSIX shell program inside the phone's iSH guest. The code executes locally with /workspace as its working directory and returns structured stdout, stderr, and exit status.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "language": .object([
                    "type": .string("string"),
                    "enum": .array([.string("python"), .string("javascript"), .string("shell")]),
                    "description": .string("Interpreter to use: python, javascript, or shell.")
                ]),
                "code": .object([
                    "type": .string("string"),
                    "description": .string("Program source. It is passed to the selected interpreter through stdin.")
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(3_600),
                    "description": .string("Optional local execution timeout. Defaults to 300 seconds.")
                ])
            ]),
            "required": .array([.string("language"), .string("code")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sideEffect

    init(
        store: WorkspaceStore,
        coordinator: ISHSandboxCoordinator = .shared,
        sessionID: String
    ) {
        self.store = store
        self.coordinator = coordinator
        self.sessionID = sessionID
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["language", "code", "timeout_seconds"])
        let language = try arguments.requiredString("language", maximumUTF8Bytes: 32)
        guard ["python", "javascript", "shell"].contains(language) else {
            throw LocalToolError.invalidEnumValue(
                field: "language",
                value: language,
                allowed: ["python", "javascript", "shell"]
            )
        }
        _ = try arguments.requiredString(
            "code",
            maximumUTF8Bytes: 64 * 1_024
        )
        if let value = arguments["timeout_seconds"] {
            guard case let .number(number) = value,
                  number.isFinite,
                  number.rounded() == number,
                  (1...3_600).contains(Int(number)) else {
                throw LocalToolError.invalidArguments
            }
        }
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "在手机运行 \(arguments["language"]?.stringValue ?? "代码")"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["ish-code:\(sessionID)"]
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["ish-sandbox:/workspace"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments) { _ in }
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try validate(arguments: arguments)
        let language = try arguments.requiredString("language", maximumUTF8Bytes: 32)
        let code = try arguments.requiredString("code", maximumUTF8Bytes: 64 * 1_024)
        let timeout: TimeInterval
        if case let .number(value)? = arguments["timeout_seconds"] {
            timeout = value
        } else {
            timeout = 300
        }
        let interpreter: String
        switch language {
        case "python": interpreter = "python3"
        case "javascript": interpreter = "node"
        default: interpreter = "/bin/sh"
        }
        let encoded = Data(code.utf8).base64EncodedString()
        // Base64 keeps arbitrary source bytes out of the shell parser while
        // preserving the code-runtime contract of stdin-fed execution.
        let command = "printf '%s' '\(encoded)' | base64 -d | \(interpreter)"
        let workspaceURL = try await store.rootURL()
        let mounts = try await store.activeMountBindings()
        await coordinator.setWorkspaceMounts(mounts)
        let result = try await coordinator.execute(
            sessionID: "\(sessionID).code",
            command: command,
            workspaceURL: workspaceURL,
            timeout: timeout,
            maximumOutputBytes: 112 * 1_024,
            policy: ISHSandboxExecutionPolicy(
                mode: .dangerFullAccess,
                workspaceRoot: workspaceURL
            ),
            onOutput: { chunk in
                let text = language == "javascript"
                    ? Self.removingKnownNodeRuntimeNoise(chunk.text)
                    : chunk.text
                guard !text.isEmpty else { return }
                await onOutput(
                    AgentToolOutputChunk(
                        channel: chunk.channel == .stderr ? .stderr : .stdout,
                        text: text
                    )
                )
            }
        )
        let stderr = language == "javascript"
            ? Self.removingKnownNodeRuntimeNoise(result.stderr)
            : result.stderr
        return JSONValue.object([
            "language": .string(language),
            "exit_code": .number(Double(result.exitCode)),
            "pid": .number(Double(result.pid)),
            "duration_ms": .number((result.duration * 1_000).rounded()),
            "stdout": .string(String(result.stdout.prefix(56 * 1_024))),
            "stderr": .string(String(stderr.prefix(56 * 1_024)))
        ]).displayText
    }

    private static func removingKnownNodeRuntimeNoise(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 != "Warning: disabling flag --expose_wasm due to conflicting flags" }
            .joined(separator: "\n")
    }
}
