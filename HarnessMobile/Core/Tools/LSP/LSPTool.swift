import Foundation

enum LSPToolOperation: String, CaseIterable, Sendable {
    case goToDefinition
    case findReferences
    case goToImplementation
    case hover

    var wireMethod: String {
        switch self {
        case .goToDefinition: "textDocument/definition"
        case .findReferences: "textDocument/references"
        case .goToImplementation: "textDocument/implementation"
        case .hover: "textDocument/hover"
        }
    }
}

struct LSPOnDeviceProvider: Sendable, Equatable {
    let id: String
    let command: String
    let args: [String]
    let languageID: String
}

enum LSPOnDeviceProviderCatalog {
    static func provider(for path: String) -> LSPOnDeviceProvider? {
        switch finalExtension(path) {
        case ".py":
            LSPOnDeviceProvider(id: "pyright", command: "pyright-langserver", args: ["--stdio"], languageID: "python")
        case ".ts":
            LSPOnDeviceProvider(id: "typescript", command: "typescript-language-server", args: ["--stdio"], languageID: "typescript")
        case ".tsx":
            LSPOnDeviceProvider(id: "typescript", command: "typescript-language-server", args: ["--stdio"], languageID: "typescriptreact")
        case ".js":
            LSPOnDeviceProvider(id: "typescript", command: "typescript-language-server", args: ["--stdio"], languageID: "javascript")
        case ".jsx":
            LSPOnDeviceProvider(id: "typescript", command: "typescript-language-server", args: ["--stdio"], languageID: "javascriptreact")
        case ".c":
            LSPOnDeviceProvider(id: "clangd", command: "clangd", args: [], languageID: "c")
        case ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp":
            LSPOnDeviceProvider(id: "clangd", command: "clangd", args: [], languageID: "cpp")
        case ".rs":
            LSPOnDeviceProvider(id: "rust-analyzer", command: "rust-analyzer", args: [], languageID: "rust")
        case ".swift":
            LSPOnDeviceProvider(id: "sourcekit-lsp", command: "sourcekit-lsp", args: [], languageID: "swift")
        default:
            nil
        }
    }

    static func finalExtension(_ path: String) -> String {
        let name = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...]).lowercased()
    }
}

enum LSPToolError: LocalizedError, Sendable, Equatable {
    case unsupportedFile(String)
    case documentTooLarge(maximumBytes: Int)
    case serverUnavailable(String)
    case protocolFailure(String)
    case serverFailure(code: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFile(path):
            "LSP_UNAVAILABLE：没有本机语言服务器映射可处理 \(path)"
        case let .documentTooLarge(maximumBytes):
            "LSP_DOCUMENT_TOO_LARGE：源文件超过 \(maximumBytes) 字节。"
        case let .serverUnavailable(command):
            "LSP_UNAVAILABLE：iSH 中未安装 \(command)。可先用 shell_execute 在手机本机安装对应语言服务器。"
        case let .protocolFailure(message):
            "LSP_MALFORMED_RESPONSE：\(message)"
        case let .serverFailure(code, message):
            "LSP_SERVER_ERROR\(code.map { " \($0)" } ?? "")：\(message)"
        }
    }
}

struct OnDeviceLSPTool: LocalAgentTool {
    static let maximumDocumentBytes = 4 * 1_024 * 1_024
    static let maximumLocations = 100
    static let maximumResultCharacters = 16_000

    let store: WorkspaceStore
    let coordinator: ISHSandboxCoordinator
    let sessionID: String
    let risk: ToolRisk = .sensitiveRead

    let definition = ModelToolDefinition(
        name: "lsp",
        description: "Query an on-device language server for precise code navigation. operation is goToDefinition, findReferences, goToImplementation, or hover. line and character are one-based UTF-16 cursor coordinates. findReferences includes the declaration.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "operation": .object([
                    "type": .string("string"),
                    "enum": .array(LSPToolOperation.allCases.map { .string($0.rawValue) })
                ]),
                "file_path": .object(["type": .string("string"), "maxLength": .number(4_096)]),
                "line": .object(["type": .string("integer"), "minimum": .number(1)]),
                "character": .object(["type": .string("integer"), "minimum": .number(1)])
            ]),
            "required": .array([.string("operation"), .string("file_path"), .string("line"), .string("character")]),
            "additionalProperties": .bool(false)
        ])
    )

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
        try arguments.requireOnlyKeys(["operation", "file_path", "line", "character"])
        _ = try parsedOperation(arguments)
        let path = try parsedPath(arguments)
        guard LSPOnDeviceProviderCatalog.provider(for: path) != nil else {
            throw LSPToolError.unsupportedFile(path)
        }
        _ = try positiveInteger(arguments["line"])
        _ = try positiveInteger(arguments["character"])
    }

    func summary(arguments: [String: JSONValue]) -> String {
        let operation = arguments["operation"]?.stringValue ?? "query"
        let path = arguments["file_path"]?.stringValue ?? "unknown"
        return "LSP \(operation)：\(path)"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["workspace:file:\(try parsedPath(arguments))"]
    }

    func concurrencyResources(arguments: [String: JSONValue]) throws -> Set<String> {
        ["lsp-provider:\(try provider(arguments).id)"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        try validate(arguments: arguments)
        let operation = try parsedOperation(arguments)
        let path = try parsedPath(arguments)
        let provider = try provider(arguments)
        let line = try positiveInteger(arguments["line"]) - 1
        let character = try positiveInteger(arguments["character"]) - 1
        let text = try await store.readText(path: path)
        guard text.utf8.count <= Self.maximumDocumentBytes else {
            throw LSPToolError.documentTooLarge(maximumBytes: Self.maximumDocumentBytes)
        }

        let workspaceURL = try await store.rootURL()
        let guestPath = Self.guestPath(path)
        let argv = [
            "python3", "-c", Self.pythonHost,
            provider.command,
            try Self.encodedJSON(provider.args),
            provider.languageID,
            operation.wireMethod,
            guestPath,
            String(line),
            String(character)
        ]
        let command = argv.map(Self.shellQuote).joined(separator: " ")
        let execution = try await coordinator.execute(
            sessionID: "\(sessionID).lsp.\(provider.id)",
            command: command,
            workspaceURL: workspaceURL,
            timeout: 60,
            maximumOutputBytes: 2 * 1_024 * 1_024,
            policy: ISHSandboxExecutionPolicy(mode: .dangerFullAccess, workspaceRoot: workspaceURL)
        )
        if execution.exitCode == 127 || execution.stderr.contains("No such file or directory") {
            throw LSPToolError.serverUnavailable(provider.command)
        }
        guard execution.exitCode == 0 else {
            let detail = execution.stderr.isEmpty ? execution.stdout : execution.stderr
            throw LSPToolError.protocolFailure(Self.bounded(detail, characters: 2_048))
        }
        return try Self.normalizeHostOutput(
            execution.stdout,
            operation: operation,
            workspaceURI: "file:///workspace"
        )
    }

    static func normalizeHostOutput(
        _ output: String,
        operation: LSPToolOperation,
        workspaceURI: String
    ) throws -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastLine = output.split(whereSeparator: \Character.isNewline).last.map(String.init) ?? ""
        let candidates = trimmed == lastLine ? [trimmed] : [trimmed, lastLine]
        let envelope = candidates.lazy.compactMap { candidate -> JSONValue? in
            guard let data = candidate.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }.first
        guard let object = envelope?.objectValue else {
            throw LSPToolError.protocolFailure("本机 LSP host 未返回有效 JSON。")
        }
        if object["ok"] != .bool(true) {
            let error = object["error"]?.objectValue
            let code = error?["code"].flatMap { value -> Int? in
                guard case let .number(number) = value else { return nil }
                return Int(number)
            }
            throw LSPToolError.serverFailure(
                code: code,
                message: error?["message"]?.stringValue ?? "unknown language server error"
            )
        }
        let result = object["result"] ?? .null
        switch operation {
        case .hover:
            var hover = try normalizeHover(result)
            var output = JSONValue.object([
                "kind": .string("hover"),
                "hover": hover
            ]).displayText
            if output.count > maximumResultCharacters,
               var hoverObject = hover.objectValue,
               let contents = hoverObject["contents"]?.stringValue {
                hoverObject["contents"] = .string(bounded(contents, characters: max(1, maximumResultCharacters / 2)))
                hover = .object(hoverObject)
                output = JSONValue.object(["kind": .string("hover"), "hover": hover]).displayText
            }
            return output
        case .goToDefinition, .findReferences, .goToImplementation:
            let locations = try normalizeLocations(result)
            var shown = Array(locations.prefix(maximumLocations))
            while true {
                var value: [String: JSONValue] = [
                    "kind": .string("locations"),
                    "locations": .array(shown),
                    "resolvedWorkspaceUri": .string(workspaceURI)
                ]
                if locations.count > shown.count {
                    value["omitted"] = .number(Double(locations.count - shown.count))
                }
                let output = JSONValue.object(value).displayText
                if output.count <= maximumResultCharacters || shown.isEmpty { return output }
                shown.removeLast()
            }
        }
    }

    private func parsedOperation(_ arguments: [String: JSONValue]) throws -> LSPToolOperation {
        guard let value = arguments["operation"]?.stringValue,
              let operation = LSPToolOperation(rawValue: value) else {
            throw LocalToolError.invalidArguments
        }
        return operation
    }

    private func parsedPath(_ arguments: [String: JSONValue]) throws -> String {
        let path = try arguments.requiredString("file_path", maximumUTF8Bytes: 4_096)
        if path == "/workspace" { throw LocalToolError.invalidArguments }
        let relativePath: String
        if path.hasPrefix("/workspace/") {
            relativePath = String(path.dropFirst("/workspace/".count))
        } else {
            guard !path.hasPrefix("/") else { throw LocalToolError.invalidArguments }
            relativePath = path
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !components.contains(where: { $0 == ".." || $0.isEmpty }) else {
            throw LocalToolError.invalidArguments
        }
        return relativePath
    }

    private func provider(_ arguments: [String: JSONValue]) throws -> LSPOnDeviceProvider {
        let path = try parsedPath(arguments)
        guard let provider = LSPOnDeviceProviderCatalog.provider(for: path) else {
            throw LSPToolError.unsupportedFile(path)
        }
        return provider
    }

    private func positiveInteger(_ value: JSONValue?) throws -> Int {
        guard case let .number(number)? = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= 1,
              number <= Double(Int.max) else {
            throw LocalToolError.invalidArguments
        }
        return Int(number)
    }

    private static func guestPath(_ path: String) -> String {
        "/workspace/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
    }

    private static func encodedJSON(_ strings: [String]) throws -> String {
        let data = try JSONEncoder().encode(strings)
        guard let text = String(data: data, encoding: .utf8) else { throw LocalToolError.invalidArguments }
        return text
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private static func bounded(_ text: String, characters: Int) -> String {
        guard text.count > characters else { return text }
        let notice = "\n… lsp result truncated (limit \(characters) characters)."
        return String(text.prefix(max(0, characters - notice.count))) + notice
    }

    private static func normalizeLocations(_ value: JSONValue) throws -> [JSONValue] {
        let values: [JSONValue]
        switch value {
        case .null: values = []
        case let .array(items): values = items
        case .object: values = [value]
        default: throw LSPToolError.protocolFailure("导航结果不是 Location、LocationLink、数组或 null。")
        }
        return try values.map { item in
            guard let object = item.objectValue else {
                throw LSPToolError.protocolFailure("导航结果包含非对象条目。")
            }
            if let uri = object["uri"]?.stringValue, let range = object["range"] {
                guard uri.utf8.count <= 4_096 else {
                    throw LSPToolError.protocolFailure("Location URI 超过 4096 字节。")
                }
                return .object(["uri": .string(uri), "range": try normalizedRange(range)])
            }
            if let uri = object["targetUri"]?.stringValue,
               let range = object["targetSelectionRange"] ?? object["targetRange"] {
                guard uri.utf8.count <= 4_096 else {
                    throw LSPToolError.protocolFailure("LocationLink URI 超过 4096 字节。")
                }
                return .object(["uri": .string(uri), "range": try normalizedRange(range)])
            }
            throw LSPToolError.protocolFailure("Location 缺少 uri/range。")
        }
    }

    private static func normalizeHover(_ value: JSONValue) throws -> JSONValue {
        if value == .null { return .null }
        guard let object = value.objectValue, let contents = object["contents"] else {
            throw LSPToolError.protocolFailure("Hover 缺少 contents。")
        }
        var hover: [String: JSONValue] = ["contents": .string(try hoverText(contents))]
        if let range = object["range"] { hover["range"] = try normalizedRange(range) }
        return .object(hover)
    }

    private static func hoverText(_ value: JSONValue) throws -> String {
        switch value {
        case let .string(text): return text
        case let .object(object):
            guard let text = object["value"]?.stringValue else {
                throw LSPToolError.protocolFailure("Hover MarkupContent 无有效 value。")
            }
            if let language = object["language"]?.stringValue, !language.isEmpty {
                return "```\(language)\n\(text)\n```"
            }
            return text
        case let .array(values): return try values.map(hoverText).joined(separator: "\n\n")
        default: throw LSPToolError.protocolFailure("Hover contents 类型无效。")
        }
    }

    private static func normalizedRange(_ value: JSONValue) throws -> JSONValue {
        guard let object = value.objectValue,
              let start = object["start"], let end = object["end"] else {
            throw LSPToolError.protocolFailure("Range 缺少 start/end。")
        }
        return .object(["start": try normalizedPosition(start), "end": try normalizedPosition(end)])
    }

    private static func normalizedPosition(_ value: JSONValue) throws -> JSONValue {
        guard let object = value.objectValue,
              case let .number(line)? = object["line"],
              case let .number(character)? = object["character"],
              line.isFinite, character.isFinite,
              line >= 0, character >= 0,
              line.rounded(.towardZero) == line,
              character.rounded(.towardZero) == character else {
            throw LSPToolError.protocolFailure("Position 不是非负整数。")
        }
        return .object(["line": .number(line), "character": .number(character)])
    }

    /// Small on-device protocol host adapted from upstream dsh-lsp-stdio. It
    /// exposes only the four read-only semantic operations and never offers a
    /// generic JSON-RPC escape hatch to the model.
    private static let pythonHost = #"""
import json, os, subprocess, sys

command, args_json, language, method, path, line, character = sys.argv[1:8]
args = json.loads(args_json)
proc = None

def send(message):
    data = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    proc.stdin.write(("Content-Length: %d\r\n\r\n" % len(data)).encode("ascii") + data)
    proc.stdin.flush()

def receive():
    headers = {}
    while True:
        line_bytes = proc.stdout.readline()
        if not line_bytes:
            raise RuntimeError("language server closed stdout")
        if line_bytes in (b"\r\n", b"\n"):
            break
        name, value = line_bytes.decode("ascii").split(":", 1)
        headers[name.strip().lower()] = value.strip()
    size = int(headers.get("content-length", "-1"))
    if size < 0 or size > 16000000:
        raise RuntimeError("invalid Content-Length")
    body = proc.stdout.read(size)
    if len(body) != size:
        raise RuntimeError("truncated language server frame")
    return json.loads(body.decode("utf-8"))

def request(request_id, method_name, params):
    send({"jsonrpc":"2.0", "id":request_id, "method":method_name, "params":params})
    while True:
        message = receive()
        if message.get("id") == request_id and ("result" in message or "error" in message):
            if "error" in message:
                error = message["error"]
                raise RuntimeError(json.dumps({"code":error.get("code"), "message":error.get("message", "server error")}, ensure_ascii=False))
            return message.get("result")
        if "id" in message and "method" in message:
            if message["method"] == "workspace/configuration":
                items = (message.get("params") or {}).get("items") or []
                send({"jsonrpc":"2.0", "id":message["id"], "result":[None for _ in items]})
            else:
                send({"jsonrpc":"2.0", "id":message["id"], "error":{"code":-32601,"message":"client request unsupported"}})

try:
    proc = subprocess.Popen([command] + args, cwd="/workspace", stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    uri = "file://" + path
    initialized = request(1, "initialize", {
        "processId": None,
        "rootUri": "file:///workspace",
        "workspaceFolders": [{"uri":"file:///workspace", "name":"workspace"}],
        "capabilities": {"general":{"positionEncodings":["utf-16"]}},
        "initializationOptions": None
    })
    encoding = ((initialized or {}).get("capabilities") or {}).get("positionEncoding", "utf-16")
    if encoding.lower() != "utf-16":
        raise RuntimeError("server negotiated unsupported position encoding " + encoding)
    send({"jsonrpc":"2.0", "method":"initialized", "params":{}})
    with open(path, "r", encoding="utf-8") as source_file:
        source = source_file.read()
    send({"jsonrpc":"2.0", "method":"textDocument/didOpen", "params":{"textDocument":{"uri":uri,"languageId":language,"version":1,"text":source}}})
    params = {"textDocument":{"uri":uri}, "position":{"line":int(line),"character":int(character)}}
    if method == "textDocument/references":
        params["context"] = {"includeDeclaration":True}
    result = request(2, method, params)
    send({"jsonrpc":"2.0", "method":"textDocument/didClose", "params":{"textDocument":{"uri":uri}}})
    try:
        request(3, "shutdown", None)
        send({"jsonrpc":"2.0", "method":"exit"})
    except Exception:
        pass
    print(json.dumps({"ok":True,"result":result}, ensure_ascii=False, separators=(",", ":")))
except FileNotFoundError:
    print(json.dumps({"ok":False,"error":{"code":-32001,"message":"command not found: " + command}}, ensure_ascii=False, separators=(",", ":")))
except Exception as error:
    try:
        parsed = json.loads(str(error))
        if not isinstance(parsed, dict): raise ValueError()
    except Exception:
        parsed = {"code":-32002,"message":str(error)}
    print(json.dumps({"ok":False,"error":parsed}, ensure_ascii=False, separators=(",", ":")))
finally:
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try: proc.wait(timeout=2)
        except Exception: proc.kill()
"""#
}
