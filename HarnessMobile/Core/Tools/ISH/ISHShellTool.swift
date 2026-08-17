import Foundation

struct ISHShellExecuteTool: LocalAgentTool {
    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "shell_execute",
        description: "Execute a shell command inside the on-device iSH ARM64 Alpine sandbox. The command never runs on a remote server. The working directory is /workspace; user-mounted folders are available at /workspace/mounts/<name> with their configured read-only or read-write policy.",
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
                ])
            ]),
            "required": .array([.string("command")]),
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
        try arguments.requireOnlyKeys(["command", "timeout_seconds"])
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
        let result = try await coordinator.execute(
            sessionID: sessionID,
            command: command,
            workspaceURL: workspaceURL,
            timeout: timeout,
            maximumOutputBytes: 112 * 1_024,
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
}
