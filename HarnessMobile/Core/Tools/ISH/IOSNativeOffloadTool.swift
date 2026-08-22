import Foundation

struct IOSNativeOffloadTool: LocalAgentTool {
    static let allowedCommands: Set<String> = [
        "apple-bluetooth",
        "apple-calendar",
        "apple-clipboard",
        "apple-device",
        "apple-healthkit",
        "apple-homekit",
        "apple-location",
        "apple-maps",
        "apple-media",
        "apple-nfc",
        "apple-nlp",
        "apple-notification",
        "apple-open",
        "apple-photos",
        "apple-reminders",
        "apple-speak",
        "apple-speech",
        "apple-vision",
    ]

    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String

    let definition = ModelToolDefinition(
        name: "ios_native",
        description: "Run one allowlisted OpenMinis iOS native capability on this iPhone through the embedded iSH bridge. HealthKit requires the signed entitlement and per-data-type authorization; its read, write, and delete operations receive separate approval scopes. Pass --help in arguments to inspect a command. No arbitrary shell or remote executor is available through this tool.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "enum": .array(
                        Self.allowedCommands.sorted().map(JSONValue.string)
                    ),
                ]),
                "arguments": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "maxLength": .number(2_048),
                    ]),
                    "maxItems": .number(64),
                    "description": .string("Command arguments as separate strings. Use [\"--help\"] to discover supported subcommands and flags."),
                ]),
                "timeout_seconds": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(600),
                    "description": .string("Defaults to 90 seconds."),
                ]),
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false),
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
        try arguments.requireOnlyKeys(["command", "arguments", "timeout_seconds"])
        _ = try command(from: arguments)
        _ = try commandArguments(from: arguments)
        _ = try timeout(from: arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let command = (try? command(from: arguments)) ?? "未知原生能力"
        let subcommand = (try? commandArguments(from: arguments).first)
            .flatMap { $0.hasPrefix("-") ? nil : $0 }
        if let subcommand {
            return "在本机调用 \(command) \(subcommand)"
        }
        return "在本机调用 \(command)"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        let command = try command(from: arguments)
        // The user explicitly chose durable approval for this personal-device
        // bridge. URL validation still runs on every call, but never filters
        // by scheme or destination application.
        let argv = try commandArguments(from: arguments)
        guard command == "apple-healthkit" else {
            return ["ios-native:\(command)"]
        }

        let action = argv.first(where: { !$0.hasPrefix("-") })?.lowercased()
        let scope: String
        switch action {
        case "log", "log-blood-pressure":
            scope = "write"
        case "delete":
            scope = "delete"
        default:
            scope = "read"
        }
        return ["ios-native:\(command):\(scope)"]
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try approvalResources(arguments: arguments)
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try await execute(arguments: arguments) { _ in }
    }

    func execute(
        arguments: [String: JSONValue],
        onOutput: @escaping @Sendable (AgentToolOutputChunk) async -> Void
    ) async throws -> String {
        try validate(arguments: arguments)
        let command = try command(from: arguments)
        let argv = try commandArguments(from: arguments)
        let timeout = try timeout(from: arguments)
        let script = (["/usr/local/bin/\(command)"] + argv)
            .map(Self.shellQuote)
            .joined(separator: " ")
        let workspaceURL = try await store.rootURL()
        let result = try await coordinator.execute(
            sessionID: "\(sessionID).ios-native",
            command: script,
            workspaceURL: workspaceURL,
            timeout: timeout,
            maximumOutputBytes: 128 * 1_024,
            policy: ISHSandboxExecutionPolicy(
                mode: .dangerFullAccess,
                workspaceRoot: workspaceURL
            ),
            onOutput: { chunk in
                await onOutput(AgentToolOutputChunk(
                    channel: chunk.channel == .stderr ? .stderr : .stdout,
                    text: chunk.text
                ))
            }
        )
        return JSONValue.object([
            "command": .string(command),
            "exit_code": .number(Double(result.exitCode)),
            "duration_ms": .number((result.duration * 1_000).rounded()),
            "stdout": .string(Self.bounded(result.stdout, maximumBytes: 64 * 1_024)),
            "stderr": .string(Self.bounded(result.stderr, maximumBytes: 48 * 1_024)),
        ]).displayText
    }

    private func command(from arguments: [String: JSONValue]) throws -> String {
        let command = try arguments.requiredString("command", maximumUTF8Bytes: 64)
        guard Self.allowedCommands.contains(command) else {
            throw LocalToolError.invalidArguments
        }
        return command
    }

    private func commandArguments(from arguments: [String: JSONValue]) throws -> [String] {
        guard let value = arguments["arguments"] else { return [] }
        guard case let .array(values) = value, values.count <= 64 else {
            throw LocalToolError.invalidArguments
        }
        var totalBytes = 0
        let parsedArguments = try values.map { value in
            guard case let .string(argument) = value,
                  argument.utf8.count <= 2_048,
                  !argument.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw LocalToolError.invalidArguments
            }
            totalBytes += argument.utf8.count
            guard totalBytes <= 32 * 1_024 else {
                throw LocalToolError.invalidArguments
            }
            return argument
        }
        if (try? command(from: arguments)) == "apple-open" {
            try Self.validateOpenTarget(parsedArguments.first)
        }
        return parsedArguments
    }

    private func timeout(from arguments: [String: JSONValue]) throws -> TimeInterval {
        guard let raw = arguments["timeout_seconds"] else { return 90 }
        guard case let .number(value) = raw,
              value.isFinite,
              value.rounded(.towardZero) == value,
              (1...600).contains(value) else {
            throw LocalToolError.invalidArguments
        }
        return value
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func validateOpenTarget(_ target: String?) throws {
        guard let target else { throw LocalToolError.missingArgument("arguments") }
        let normalized = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 2_048 else {
            throw LocalToolError.invalidArguments
        }
        guard !normalized.unicodeScalars.contains(where: {
            $0 == "\0" || CharacterSet.controlCharacters.contains($0)
        }) else {
            throw LocalToolError.invalidArguments
        }
        // UIApplication owns the final decision for every URL scheme. Keep
        // this boundary scheme-agnostic: tel:, sms:, mailto:, file:, data:,
        // javascript:, and third-party app schemes all pass through equally.
        // The native OpenMinis handler performs the same NSURL parse before
        // handing the value to UIApplication.
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
