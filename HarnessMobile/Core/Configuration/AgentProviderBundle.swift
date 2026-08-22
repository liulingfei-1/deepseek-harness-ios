import Foundation

/// RC.8's installable coding-agent bundle projection. A bundle is metadata
/// plus an allowlisted executable contract; it never downloads or executes
/// machine code outside the on-device iSH guest.
enum AgentProviderBundleID: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case claudeCode = "claude-code"

    var id: String { rawValue }
}

/// Completion authority for a product Provider Bundle. The current mobile
/// adapter only consumes CLI stdout; it is intentionally marked degraded until
/// the upstream Codex app-server or Claude Agent SDK protocol is embedded.
enum AgentProviderBundleOutputAuthority: String, Codable, Sendable, Equatable {
    case mobileCLIStdoutDegraded = "mobile-cli-stdout-degraded"
}

enum AgentProviderBundlePermissionMode: String, Codable, CaseIterable, Sendable {
    case never
    case approveForMe = "approve-for-me"
    case dangerouslyBypassApprovalsAndSandbox = "dangerously-bypass-approvals-and-sandbox"
}

enum AgentProviderBundleProtocol: String, Codable, Sendable {
    case legacyCLI
    case structuredCLI
}

/// The install-time contract. It is intentionally data-only: an installed
/// bundle may point at a fixed executable inside iSH, but cannot provide an
/// arbitrary command or PATH fallback.
struct AgentProviderBundleInstallPayload: Codable, Sendable, Equatable {
    let bundleID: AgentProviderBundleID
    let packageName: String
    let version: String
    let executable: String
    let arguments: [String]
    let sourceURL: String
    let sha256: String
    let protocolKind: AgentProviderBundleProtocol

    func validate() throws {
        let validVersion = version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil
        let validHash = sha256.range(of: #"^[A-Fa-f0-9]{64}$"#, options: .regularExpression) != nil
            && Set(sha256.lowercased()) != ["0"]
        let validPackageName = packageName.range(
            of: #"^(@[a-z0-9._-]+/)?[a-z0-9._-]+$"#,
            options: .regularExpression
        ) != nil
        let validExecutable = executable.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
            options: .regularExpression
        ) != nil
        guard validVersion, validHash, validPackageName, validExecutable,
              arguments.count <= 16,
              arguments.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 256
                      && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0")
                      && !$0.contains("$(") && !$0.contains("`")
              }),
              let url = URL(string: sourceURL),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "registry.npmjs.org",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw AgentProviderBundleValidationError.invalidPayload
        }
    }
}

enum AgentProviderBundleValidationError: LocalizedError, Sendable, Equatable {
    case invalidPayload
    case unsupportedPermissionOverride
    case invalidInstanceName
    case duplicateInstance
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .invalidPayload: "Profile Bundle 清单无效或来源不受信任。"
        case .unsupportedPermissionOverride: "权限模式由 Profile Bundle 固定，不能由工具参数覆盖。"
        case .invalidInstanceName: "Profile Bundle 实例名无效。"
        case .duplicateInstance: "Profile Bundle 实例名已存在。"
        case .notInstalled: "请先在手机 iSH 中安装并验证 Profile Bundle，再启用它。"
        }
    }
}

/// Stable, bounded diagnostics for a failed Provider Bundle activation.
/// Raw stdout/stderr is deliberately omitted. A short, redacted first-line
/// detail is enough for the trajectory inspector without turning a provider
/// process dump into model input.
struct AgentProviderBundleFailureFacts: Codable, Sendable, Equatable {
    let provider: String
    let stage: String
    let exitCode: Int?
    let outputAuthority: AgentProviderBundleOutputAuthority
    let errorCategory: String
    let executablePath: String
    let detail: String?
    let retryable: Bool
    let instanceID: String?
    let truncated: Bool
    let credentialRedacted: Bool

    init(
        provider: String,
        stage: String,
        exitCode: Int?,
        outputAuthority: AgentProviderBundleOutputAuthority,
        errorCategory: String,
        executablePath: String,
        detail: String? = nil,
        retryable: Bool = false,
        instanceID: String? = nil,
        truncated: Bool = false,
        credentialRedacted: Bool = false
    ) {
        self.provider = HarnessTraceRedactor.string(provider, maximumUTF8Bytes: 128)
        self.stage = HarnessTraceRedactor.string(stage, maximumUTF8Bytes: 64)
        self.exitCode = exitCode
        self.outputAuthority = outputAuthority
        self.errorCategory = HarnessTraceRedactor.string(errorCategory, maximumUTF8Bytes: 64)
        self.executablePath = HarnessTraceRedactor.string(executablePath, maximumUTF8Bytes: 512)
        let bounded = Self.boundedDetail(detail)
        self.detail = bounded.value
        self.retryable = retryable
        self.instanceID = instanceID.map {
            HarnessTraceRedactor.string($0, maximumUTF8Bytes: 256)
        }
        self.truncated = truncated || bounded.wasTruncated
        self.credentialRedacted = credentialRedacted || bounded.wasRedacted
    }

    /// Compatibility constructor for the earlier bundle adapter. It keeps
    /// call sites source-compatible while projecting only stable facts.
    static func make(
        bundleID: AgentProviderBundleID,
        instanceID: String,
        phase: String,
        exitCode: Int?,
        errorCode: String,
        stdout: String,
        stderr: String,
        retryable: Bool = true
    ) -> Self {
        let raw = stdout + stderr
        let redactedRaw = redactCredentials(raw)
        let diagnostic = stderr.isEmpty ? stdout : stderr
        return Self(
            provider: bundleID.rawValue,
            stage: phase,
            exitCode: exitCode,
            outputAuthority: .mobileCLIStdoutDegraded,
            errorCategory: errorCode,
            executablePath: AgentProviderBundle.catalog
                .first(where: { $0.id == bundleID })?.resolvedExecutablePath
                ?? "/usr/local/lib/harness-mobile/provider-bundles/" + bundleID.rawValue + "/bin/" + bundleID.rawValue,
            detail: diagnostic,
            retryable: retryable,
            instanceID: instanceID,
            truncated: raw.utf8.count > 512,
            credentialRedacted: redactedRaw != raw
        )
    }

    /// Legacy aliases retained for existing diagnostics consumers. They never
    /// expose separate stdout/stderr payloads anymore.
    var bundleID: AgentProviderBundleID? { AgentProviderBundleID(rawValue: provider) }
    var phase: String { stage }
    var errorCode: String { errorCategory }
    var stderrPreview: String { detail ?? "" }
    var stdoutPreview: String { "" }

    var jsonValue: JSONValue {
        .object([
            "provider": .string(provider),
            "stage": .string(stage),
            "exitCode": exitCode.map { .number(Double($0)) } ?? .null,
            "outputAuthority": .string(outputAuthority.rawValue),
            "errorCategory": .string(errorCategory),
            "executablePath": .string(executablePath),
            "detail": detail.map(JSONValue.string) ?? .null,
            "retryable": .bool(retryable),
            "instanceID": instanceID.map(JSONValue.string) ?? .null,
            "truncated": .bool(truncated),
            "credentialRedacted": .bool(credentialRedacted)
        ])
    }

    var userMessage: String {
        var message = provider + " Profile Bundle 在 " + stage + " 阶段失败（" + errorCategory
        if let exitCode { message += ", exit " + String(exitCode) }
        message += "）。"
        if let detail, !detail.isEmpty { message += " " + detail }
        return message
    }

    var serialized: String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else {
            return userMessage
        }
        return value
    }

    private static func boundedDetail(_ value: String?) -> (value: String?, wasTruncated: Bool, wasRedacted: Bool) {
        guard let value else { return (nil, false, false) }
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard !firstLine.isEmpty else { return (nil, false, false) }
        let credentialScrubbed = redactCredentials(firstLine)
        let redacted = HarnessTraceRedactor.string(credentialScrubbed, maximumUTF8Bytes: 480)
        let bounded = prefixUTF8(redacted, maximumUTF8Bytes: 512)
        return (
            bounded,
            firstLine.utf8.count > 512 || bounded.utf8.count < redacted.utf8.count,
            credentialScrubbed != firstLine
        )
    }

    private static func redactCredentials(_ value: String) -> String {
        var result = value
        let patterns: [(String, String)] = [
            (#"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)(bearer\s+)[^\s,;]+"#, "$1<redacted>"),
            (#"(?i)(api[_-]?key|token|secret|password|cookie)\s*[:=]\s*[^\s,;]+"#, "$1=<redacted>"),
            (#"(?i)sk-[A-Za-z0-9_-]+"#, "<redacted>")
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    private static func prefixUTF8(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result
    }
}

struct AgentProviderBundleInstance: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let bundleID: AgentProviderBundleID
    let name: String
    let createdAt: Date

    init(bundleID: AgentProviderBundleID, name: String, createdAt: Date = .now) throws {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count >= 1, normalized.count <= 64,
              normalized.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw AgentProviderBundleValidationError.invalidInstanceName
        }
        self.bundleID = bundleID
        self.name = normalized
        self.id = "\(bundleID.rawValue):\(normalized)"
        self.createdAt = createdAt
    }
}

actor AgentProviderBundleInstanceRegistry {
    private var instances: [String: AgentProviderBundleInstance] = [:]

    func register(_ instance: AgentProviderBundleInstance) throws {
        guard instances[instance.id] == nil else { throw AgentProviderBundleValidationError.duplicateInstance }
        instances[instance.id] = instance
    }

    func remove(id: String) { instances.removeValue(forKey: id) }
    func contains(id: String) -> Bool { instances[id] != nil }
    func snapshot() -> [AgentProviderBundleInstance] { Array(instances.values).sorted { $0.id < $1.id } }
}

enum AgentProviderBundleCompletionParser {
    static func parse(_ output: String) -> (text: String, structured: Bool)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            if let text = extract(json), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (text, true) }
        }
        var candidates: [String] = []
        for line in trimmed.split(whereSeparator: { $0.isNewline }) {
            guard let data = line.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data), let text = extract(json) else { continue }
            candidates.append(text)
        }
        if let last = candidates.last { return (last, true) }
        return (trimmed, false)
    }

    private static func extract(_ value: Any) -> String? {
        if let object = value as? [String: Any] {
            for key in ["final_answer", "finalAnswer", "result", "text", "content", "message"] {
                if let string = object[key] as? String { return string }
            }
            if let content = object["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}

/// A start-time capability exposed by a product Provider Bundle. These are
/// deliberately separate from the app's native Harness capabilities: a
/// child running in another process cannot inherit parent-enforced state just
/// because the caller supplied it in a request.
enum AgentProviderBundleCapability: String, Codable, CaseIterable, Sendable {
    case parentContext = "parent-context"
    case outputSchema = "output-schema"
    case depthLimit = "depth-limit"
    case toolFilter = "tool-filter"
    case persona
    case modelOverride = "model-override"
    case continuations

    var displayName: String {
        switch self {
        case .parentContext: "父会话上下文"
        case .outputSchema: "结构化输出 schema"
        case .depthLimit: "Harness 深度限制"
        case .toolFilter: "工具过滤器"
        case .persona: "子 Agent persona"
        case .modelOverride: "模型覆盖"
        case .continuations: "持久会话续接"
        }
    }
}

/// The immutable capability advertisement of one product Provider Bundle.
/// Codex and Claude Code currently use the same out-of-process contract.
struct AgentProviderBundleCapabilities: Codable, Sendable, Equatable {
    let inheritsParentContext: Bool
    let outputSchema: Bool
    let depthLimit: Bool
    let toolFilter: Bool
    let persona: Bool
    let modelOverride: Bool
    let structuredCompletion: Bool
    let supportsContinuations: Bool

    static let outOfProcess = Self(
        inheritsParentContext: false,
        outputSchema: false,
        depthLimit: false,
        toolFilter: false,
        persona: false,
        modelOverride: false,
        structuredCompletion: false,
        supportsContinuations: false
    )

    func supports(_ capability: AgentProviderBundleCapability) -> Bool {
        switch capability {
        case .parentContext: inheritsParentContext
        case .outputSchema: outputSchema
        case .depthLimit: depthLimit
        case .toolFilter: toolFilter
        case .persona: persona
        case .modelOverride: modelOverride
        case .continuations: supportsContinuations
        }
    }
}

/// The request-side projection used before a Provider Bundle is started.
/// Keeping this value type independent from `LocalSubagentRequest` makes the
/// capability contract easy to test without constructing an AppModel.
struct AgentProviderBundleRequestFeatures: Sendable, Equatable {
    let usesParentContext: Bool
    let hasOutputSchema: Bool
    let hasDepthLimitOverride: Bool
    let hasToolFilter: Bool
    let hasPersona: Bool
    let hasModelOverride: Bool
    let isContinuation: Bool

    var requestedCapabilities: [AgentProviderBundleCapability] {
        var result: [AgentProviderBundleCapability] = []
        if usesParentContext { result.append(.parentContext) }
        if hasOutputSchema { result.append(.outputSchema) }
        if hasDepthLimitOverride { result.append(.depthLimit) }
        if hasToolFilter { result.append(.toolFilter) }
        if hasPersona { result.append(.persona) }
        if hasModelOverride { result.append(.modelOverride) }
        if isContinuation { result.append(.continuations) }
        return result
    }
}

struct AgentProviderBundle: Codable, Sendable, Equatable, Identifiable {
    let id: AgentProviderBundleID
    let displayName: String
    let executable: String
    let nonInteractiveArguments: [String]
    let supportsNamedInstances: Bool
    let requiresLocalCredential: Bool
    let capabilities: AgentProviderBundleCapabilities
    let permissionMode: AgentProviderBundlePermissionMode
    let installPayload: AgentProviderBundleInstallPayload
    var enabled: Bool

    var installHint: String {
        switch id {
        case .codex: "在 iSH 中把 Codex CLI 安装到 " + resolvedExecutablePath + " 后即可作为子 Agent 调用。"
        case .claudeCode: "在 iSH 中把 Claude CLI 安装到 " + resolvedExecutablePath + " 后即可作为子 Agent 调用。"
        }
    }

    /// Deterministic iSH target. The provider never probes or falls back to a
    /// host executable found on PATH.
    var resolvedExecutablePath: String {
        "/usr/local/lib/harness-mobile/provider-bundles/\(id.rawValue)/bin/\(installPayload.executable)"
    }

    var outputAuthority: AgentProviderBundleOutputAuthority {
        .mobileCLIStdoutDegraded
    }

    /// Return the requested features this bundle cannot honor. The caller
    /// must reject a non-empty result before starting the child process.
    func unsupportedCapabilities(
        for request: AgentProviderBundleRequestFeatures
    ) -> [AgentProviderBundleCapability] {
        request.requestedCapabilities.filter { !capabilities.supports($0) }
    }

    func capabilityFailureMessage(
        for request: AgentProviderBundleRequestFeatures
    ) -> String? {
        let unsupported = unsupportedCapabilities(for: request)
        guard !unsupported.isEmpty else { return nil }
        let names = unsupported.map(\.displayName).joined(separator: "、")
        return "Profile Bundle \(displayName) 不支持：\(names)。该请求未启动。"
    }

    static let catalog: [AgentProviderBundle] = [
        AgentProviderBundle(
            id: .codex,
            displayName: "Codex",
            executable: "codex",
            nonInteractiveArguments: ["exec", "--full-auto"],
            supportsNamedInstances: true,
            requiresLocalCredential: true,
            capabilities: .outOfProcess,
            permissionMode: .dangerouslyBypassApprovalsAndSandbox,
            installPayload: AgentProviderBundleInstallPayload(
                bundleID: .codex,
                packageName: "@openai/codex",
                version: "0.147.0",
                executable: "codex",
                arguments: ["exec", "--full-auto"],
                sourceURL: "https://registry.npmjs.org/@openai/codex/-/codex-0.147.0.tgz",
                sha256: "d28b4fd4bd9f07ea71083d0cc40c579595cebbd4c10bc8ca98a6d385432e7255",
                protocolKind: .structuredCLI
            ),
            enabled: false
        ),
        AgentProviderBundle(
            id: .claudeCode,
            displayName: "Claude Code",
            executable: "claude",
            nonInteractiveArguments: ["-p", "--permission-mode", "bypassPermissions"],
            supportsNamedInstances: true,
            requiresLocalCredential: true,
            capabilities: .outOfProcess,
            permissionMode: .dangerouslyBypassApprovalsAndSandbox,
            installPayload: AgentProviderBundleInstallPayload(
                bundleID: .claudeCode,
                packageName: "@anthropic-ai/claude-agent-sdk",
                version: "0.3.220",
                executable: "claude",
                arguments: ["-p", "--permission-mode", "bypassPermissions"],
                sourceURL: "https://registry.npmjs.org/@anthropic-ai/claude-agent-sdk/-/claude-agent-sdk-0.3.220.tgz",
                sha256: "6e631effbd48827bb09d8e07a7c715fd8059bccdaaa553635794be1c663bc7a9",
                protocolKind: .structuredCLI
            ),
            enabled: false
        )
    ]
}

struct AgentProviderBundleStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "agent.provider-bundles.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [AgentProviderBundle] {
        let enabled: Set<AgentProviderBundleID>
        if let data = defaults.data(forKey: key), let ids = try? JSONDecoder().decode([AgentProviderBundleID].self, from: data) {
            enabled = Set(ids)
        } else { enabled = [] }
        return AgentProviderBundle.catalog.map { bundle in
            var value = bundle
            value.enabled = enabled.contains(bundle.id)
            return value
        }
    }

    func save(_ bundles: [AgentProviderBundle]) throws {
        defaults.set(try JSONEncoder().encode(bundles.filter(\.enabled).map(\.id)), forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}
