import CryptoKit
import Foundation

/// Small shared box used while the production registry is being assembled.
/// Code Mode child calls resolve against the exact same registry as native
/// calls; no second tool catalog or remote executor is introduced.
final class CodeModeToolResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var resolver: ((String) -> (any LocalAgentTool)?)?
    private var definitionsProvider: (() -> [ModelToolDefinition])?

    func install(_ resolver: @escaping (String) -> (any LocalAgentTool)?) {
        lock.lock(); defer { lock.unlock() }
        self.resolver = resolver
    }

    func installDefinitions(_ provider: @escaping () -> [ModelToolDefinition]) {
        lock.lock(); defer { lock.unlock() }
        definitionsProvider = provider
    }

    func tool(named name: String) -> (any LocalAgentTool)? {
        lock.lock(); defer { lock.unlock() }
        return resolver?(name)
    }

    func definitions() -> [ModelToolDefinition] {
        lock.lock(); defer { lock.unlock() }
        return definitionsProvider?() ?? []
    }
}

struct CodeModeChildDispatchRequest: Sendable, Equatable {
    let callID: String
    let name: String
    let arguments: [String: JSONValue]
}

struct CodeModeChildDispatchResult: Sendable, Equatable {
    let value: JSONValue?
    let error: String?
}

struct CodeModeExecutionContext: Sendable {
    let parentCallID: String
    let definitions: [ModelToolDefinition]
    let dispatch: @Sendable (CodeModeChildDispatchRequest) async -> CodeModeChildDispatchResult
}

enum CodeModeExecutionScope {
    @TaskLocal static var context: CodeModeExecutionContext?
}

enum CodeModePythonSDK {
    /// The generated block is intentionally plain Python and uses only the
    /// names provided by the mobile bridge. It mirrors dsh-tools' Python
    /// contract: `tools.<name>(dict)` returns a JSON value and raises
    /// `ToolCallError` for a failed child dispatch.
    static func render(definitions: [ModelToolDefinition]) -> String {
        var lines: [String] = [
            "from typing import Any, Protocol, TypedDict, NotRequired",
            "import asyncio, json, os, sys, uuid",
            "",
            "class ToolCallError(Exception):",
            "    def __init__(self, tool_name, message):",
            "        super().__init__(message)",
            "        self.tool_name = tool_name",
            "",
            "class _Tools:",
            "    def __getitem__(self, name):",
            "        return self.__getattr__(name)",
            "    def __getattr__(self, name):",
            "        async def call(args):",
            "            if not isinstance(args, dict):",
            "                raise ToolCallError(name, 'arguments must be a JSON object')",
            "            request_id = str(uuid.uuid4())",
            "            request = {'id': request_id, 'name': name, 'args': args}",
            "            print('__DSH_CODE_CALL__' + json.dumps(request, ensure_ascii=False, separators=(',', ':')), flush=True)",
            "            response_path = os.path.join(os.environ['DSH_CODE_DIR'], request_id + '.json')",
            "            for _ in range(6000):",
            "                try:",
            "                    with open(response_path, 'r', encoding='utf-8') as f:",
            "                        response = json.load(f)",
            "                    try: os.unlink(response_path)",
            "                    except OSError: pass",
            "                    if not response.get('ok', False):",
            "                        raise ToolCallError(name, str(response.get('error', 'child tool failed')))",
            "                    return response.get('value')",
            "                except FileNotFoundError:",
            "                    await asyncio.sleep(0.01)",
            "            raise ToolCallError(name, 'child dispatch timed out')",
            "        return call",
            "",
            "tools = _Tools()",
            "",
            "# Generated from the live tool registry. Arguments are ordinary dicts.",
            "class ToolsSDK(Protocol):"
        ]
        let callable = definitions.sorted { $0.name < $1.name }
        if callable.isEmpty {
            lines.append("    pass")
        }
        for definition in callable {
            let schema = definition.parameters.displayText
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\"")
            let description = definition.description
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"\"\"", with: "\\\"\\\"\\\"")
            if isBareIdentifier(definition.name) {
                lines.append("    async def \(definition.name)(self, args: dict[str, Any]) -> Any:")
                lines.append("        \"\"\"\(description) Parameters JSON Schema: \(schema)\"\"\"")
                lines.append("        ...")
            } else {
                lines.append("    # tools[\(String(reflecting: [definition.name]).dropFirst().dropLast())](args)")
                lines.append("    # \(description) Parameters JSON Schema: \(schema)")
            }
        }
        lines.append("")
        lines.append("TOOL_NAMES = " + String(reflecting: callable.map(\.name)))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func isBareIdentifier(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              (first == "_" || CharacterSet.letters.contains(first)) else { return false }
        guard value.unicodeScalars.dropFirst().allSatisfy({
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }) else { return false }
        return !["class", "def", "return", "await", "async", "lambda", "from", "import", "pass", "raise", "try", "except", "finally", "with", "yield", "for", "while", "if", "else", "elif", "in", "is", "and", "or", "not", "True", "False", "None"].contains(value)
    }
}

private extension String {
    init(reflecting values: [String]) {
        self = "[" + values.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }.joined(separator: ", ") + "]"
    }
}

private actor CodeModeMarkerParser {
    private var buffer = ""
    private(set) var completionValue: JSONValue?

    func append(_ text: String) -> [[String: JSONValue]] {
        buffer += text
        var records: [[String: JSONValue]] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.hasPrefix("__DSH_CODE_RESULT__") {
                let payload = String(line.dropFirst("__DSH_CODE_RESULT__".count))
                if let data = payload.data(using: .utf8) {
                    completionValue = try? JSONDecoder().decode(JSONValue.self, from: data)
                }
                continue
            }
            guard line.hasPrefix("__DSH_CODE_CALL__") else { continue }
            let payload = String(line.dropFirst("__DSH_CODE_CALL__".count))
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let values = object.objectValue else { continue }
            records.append(values)
        }
        return records
    }
}

/// Real Code Mode transport for iOS. The code itself runs in the embedded
/// iSH Python process; each `tools.*` call is dispatched back into the local
/// Swift registry through the marker/response file protocol.
struct ISHRunCodeTool: LocalAgentTool {
    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String
    let resolver: CodeModeToolResolver

    let definition: ModelToolDefinition
    let risk: ToolRisk = .sideEffect

    init(
        store: WorkspaceStore,
        coordinator: ISHSandboxCoordinator = .shared,
        sessionID: String,
        resolver: CodeModeToolResolver
    ) {
        self.store = store
        self.coordinator = coordinator
        self.sessionID = sessionID
        self.resolver = resolver
        self.definition = ModelToolDefinition(
            name: "run_code",
            description: "Code Mode：在手机 iSH 中运行 Python 程序。程序通过生成的 tools SDK 调用已注册的本机工具；所有代码和子工具调用都在本机执行，不经过服务器。",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("异步 Python 函数体；支持顶层 await 和 return。只能通过 tools SDK 调用工具。")
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("程序要完成的简短说明。")
                    ])
                ]),
                "required": .array([.string("code"), .string("description")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    func validate(arguments: [String: JSONValue]) throws {
        try arguments.requireOnlyKeys(["code", "description"])
        _ = try arguments.requiredString("code", maximumUTF8Bytes: 96 * 1_024)
        _ = try arguments.requiredString("description", maximumUTF8Bytes: 4 * 1_024)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        "Code Mode：在手机运行 Python 并调用本机工具"
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["ish-code-mode:\(sessionID)"]
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
        let code = try arguments.requiredString("code", maximumUTF8Bytes: 96 * 1_024)
        let workspaceURL = try await store.rootURL()
        let mounts = try await store.activeMountBindings()
        await coordinator.setWorkspaceMounts(mounts)

        let parentCallID = CodeModeExecutionScope.context?.parentCallID
            ?? Self.stableID(sessionID + "\u{0}" + code)
        // Provider-owned tool call ids are opaque strings, not filesystem
        // components. Hash them before creating a workspace path.
        let runDirectoryID = Self.stableID(parentCallID)
        let runDirectory = workspaceURL
            .appendingPathComponent(".harness-mobile", isDirectory: true)
            .appendingPathComponent("code-runs", isDirectory: true)
            .appendingPathComponent(runDirectoryID, isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let definitions = CodeModeExecutionScope.context?.definitions ?? resolverDefinitions()
        let sdk = CodeModePythonSDK.render(definitions: definitions)
        let wrapped = Self.wrapPython(sdk: sdk, body: code)
        let encoded = Data(wrapped.utf8).base64EncodedString()
        let guestDirectory = "/workspace/.harness-mobile/code-runs/\(runDirectoryID)"
        let escapedDirectory = Self.shellEscaped(guestDirectory)
        let command = "mkdir -p '\(escapedDirectory)'; export DSH_CODE_DIR='\(escapedDirectory)'; printf '%s' '\(encoded)' | base64 -d | python3"
        let parser = CodeModeMarkerParser()
        let childCounter = ChildCallCounter()
        let result = try await coordinator.execute(
            sessionID: "\(sessionID).run-code",
            command: command,
            workspaceURL: workspaceURL,
            timeout: 600,
            maximumOutputBytes: 192 * 1_024,
            policy: ISHSandboxExecutionPolicy(mode: .dangerFullAccess, workspaceRoot: workspaceURL),
            onOutput: { chunk in
                let records = await parser.append(chunk.text)
                for record in records {
                    await self.dispatch(
                        record: record,
                        parentCallID: parentCallID,
                        counter: childCounter,
                        directory: runDirectory
                    )
                }
                let visible = chunk.text
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter {
                        !$0.hasPrefix("__DSH_CODE_CALL__")
                            && !$0.hasPrefix("__DSH_CODE_RESULT__")
                    }
                    .joined(separator: "\n")
                if !visible.isEmpty {
                    await onOutput(AgentToolOutputChunk(channel: chunk.channel == .stderr ? .stderr : .stdout, text: visible))
                }
            }
        )
        guard result.exitCode == 0 else {
            throw CodeModeToolError.programFailed(
                Self.cleanRuntimeOutput(result.stderr).isEmpty
                    ? "Python exited with code \(result.exitCode)"
                    : Self.cleanRuntimeOutput(result.stderr)
            )
        }
        var response: [String: JSONValue] = [
            "mode": .string("code"),
            "language": .string("python"),
            "exit_code": .number(Double(result.exitCode)),
            "stdout": .string(Self.bounded(Self.cleanRuntimeOutput(result.stdout), bytes: 112 * 1_024)),
            "stderr": .string(Self.bounded(Self.cleanRuntimeOutput(result.stderr), bytes: 112 * 1_024)),
            "child_calls": .number(Double(await childCounter.value))
        ]
        if let value = await parser.completionValue {
            response["value"] = value
        }
        return JSONValue.object(response).displayText
    }

    private func resolverDefinitions() -> [ModelToolDefinition] {
        // The runtime registry is authoritative. This list only informs the
        // generated SDK and is intentionally conservative when unavailable.
        resolver.definitions().filter { $0.name != "run_code" }
    }

    private func dispatch(
        record: [String: JSONValue],
        parentCallID: String,
        counter: ChildCallCounter,
        directory: URL
    ) async {
        guard let requestID = record["id"]?.stringValue,
              UUID(uuidString: requestID) != nil,
              let name = record["name"]?.stringValue,
              let args = record["args"]?.objectValue else {
            return
        }
        let ordinal = await counter.next()
        let childCallID = Self.deterministicChildCallID(
            parent: parentCallID,
            ordinal: ordinal,
            name: name
        )
        if let context = CodeModeExecutionScope.context {
            let result = await context.dispatch(CodeModeChildDispatchRequest(callID: childCallID, name: name, arguments: args))
            await writeResponse(id: requestID, value: result.value, error: result.error, directory: directory)
            return
        }
        guard let tool = resolver.tool(named: name) else {
            await writeResponse(id: requestID, value: nil, error: "未知或未启用的本机工具：\(name)", directory: directory)
            return
        }
        do {
            try tool.validate(arguments: args)
            let output = try await tool.execute(arguments: args)
            let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))) ?? .string(output)
            await writeResponse(id: requestID, value: value, error: nil, directory: directory)
        } catch {
            await writeResponse(id: requestID, value: nil, error: error.localizedDescription, directory: directory)
        }
    }

    private func writeResponse(id: String, value: JSONValue?, error: String?, directory: URL) async {
        var object: [String: JSONValue] = ["ok": .bool(error == nil)]
        if let value { object["value"] = value }
        if let error { object["error"] = .string(error) }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return }
        try? data.write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
    }

    private static func wrapPython(sdk: String, body: String) -> String {
        let indented = body.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
        return sdk + "\n\nasync def __dsh_main__():\n" + (indented.isEmpty ? "    pass" : indented) + "\n\n_result = asyncio.run(__dsh_main__())\nprint('__DSH_CODE_RESULT__' + json.dumps(_result, ensure_ascii=False, separators=(',', ':')), flush=True)\n"
    }

    private static func stableID(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private static func deterministicChildCallID(parent: String, ordinal: Int, name: String) -> String {
        "code-" + stableID("\(parent)\u{0}\(ordinal)\u{0}\(name)")
    }

    private static func shellEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func cleanRuntimeOutput(_ value: String) -> String {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                !$0.hasPrefix("__DSH_CODE_CALL__")
                    && !$0.hasPrefix("__DSH_CODE_RESULT__")
            }
            .joined(separator: "\n")
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        guard value.utf8.count > bytes else { return value }
        var result = ""
        result.reserveCapacity(bytes)
        var used = 0
        for scalar in value.unicodeScalars {
            let fragment = String(scalar)
            let count = fragment.utf8.count
            guard used + count <= bytes else { break }
            result.unicodeScalars.append(scalar)
            used += count
        }
        return result + "\n[output truncated]"
    }
}

private enum CodeModeToolError: LocalizedError {
    case programFailed(String)

    var errorDescription: String? {
        switch self {
        case let .programFailed(message):
            "run_code 程序失败：\(message)"
        }
    }
}

private actor ChildCallCounter {
    private var count = 0
    func next() -> Int { defer { count += 1 }; return count }
    var value: Int { count }
}
