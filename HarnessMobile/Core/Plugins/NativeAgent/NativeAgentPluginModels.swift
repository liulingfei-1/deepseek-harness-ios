import Foundation

struct NativeAgentPluginSourceFile: Codable, Sendable, Equatable {
    let path: String
    let content: String
    let truncated: Bool
}

struct NativeAgentPluginSourceSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let failureReason: String
    let sourceDigest: String
    let source: ISHMarketplacePluginSource
    let packageName: String?
    let version: String?
    let description: String?
    let files: [NativeAgentPluginSourceFile]

    func validated() throws -> Self {
        guard schemaVersion == 1,
              Self.isDigest(sourceDigest),
              !failureReason.isEmpty,
              failureReason.utf8.count <= 128,
              !files.isEmpty,
              files.count <= 48 else {
            throw NativeAgentPluginError.invalidSourceSnapshot
        }
        var paths = Set<String>()
        var totalBytes = 0
        for file in files {
            guard Self.isSafeRelativePath(file.path),
                  paths.insert(file.path).inserted,
                  file.content.utf8.count <= 32 * 1_024 else {
                throw NativeAgentPluginError.invalidSourceSnapshot
            }
            totalBytes += file.content.utf8.count
        }
        guard totalBytes <= 180 * 1_024 else {
            throw NativeAgentPluginError.invalidSourceSnapshot
        }
        return self
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.split(separator: "/").contains("..") else { return false }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

/// The only production tools that a compiled native plugin may delegate to.
/// Keep this list separate from the full Agent catalog: recursive plugin
/// installation, arbitrary shell execution, and plan control must not become
/// ambient capabilities of every downloaded plugin.
enum NativeAgentPluginPolicy {
    static let approvedBaseToolNames: Set<String> = Set([
        "ask_user_question",
        "camera_ocr",
        "device_time",
        "diagnostics_read",
        "edit",
        "ios_native",
        "job_kill",
        "job_list",
        "job_output",
        "read",
        "skill",
        "web_fetch",
        "work_state_replace_plan",
        "work_state_replace_todos",
        "work_state_set_goal",
        "write",
        "workspace_list_files",
        "workspace_read_text",
        "workspace_write_text"
    ]).union(MobileNativeToolKit.approvedNames)
}

/// The declarative compilation result authored either by the main Agent or by
/// the optional marketplace UI compiler. Signed Swift code remains the only
/// authority that can materialize and validate it as an installed plugin.
struct NativeAgentPluginManifestDraft: Codable, Sendable, Equatable {
    struct PromptSection: Codable, Sendable, Equatable {
        let order: Int
        let text: String
        let complete: Bool?
    }

    struct Tool: Codable, Sendable, Equatable {
        let name: String
        let description: String
        let parameters: JSONValue
        let risk: ToolRisk
        let instructions: String
        let allowedTools: [String]

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case parameters
            case risk
            case instructions
            case allowedTools = "allowed_tools"
        }
    }

    struct PromptContext: Codable, Sendable, Equatable {
        let name: String
        let order: Int
        let source: NativeAgentPromptContextSource
        let path: String?
        let maximumCharacters: Int
        let prefix: String
        let suffix: String

        enum CodingKeys: String, CodingKey {
            case name
            case order
            case source
            case path
            case maximumCharacters = "maximum_characters"
            case prefix
            case suffix
        }
    }

    struct Settings: Codable, Sendable, Equatable {
        let schema: JSONValue
        let defaults: JSONValue
    }

    struct ToolGuard: Codable, Sendable, Equatable {
        let label: String
        let toolNames: [String]
        let risks: [ToolRisk]
        let decision: NativeAgentToolGuardDecision
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case label
            case toolNames = "tool_names"
            case risks
            case decision
            case reason
        }
    }

    let adaptable: Bool
    let reason: String?
    let name: String
    let description: String?
    let promptSections: [PromptSection]
    let promptContexts: [PromptContext]?
    let settings: Settings?
    let tools: [Tool]
    let toolGuards: [ToolGuard]?
    let compatibilityNotes: [String]

    enum CodingKeys: String, CodingKey {
        case adaptable
        case reason
        case name
        case description
        case promptSections = "prompt_sections"
        case promptContexts = "prompt_contexts"
        case settings
        case tools
        case toolGuards = "tool_guards"
        case compatibilityNotes = "compatibility_notes"
    }
}

struct NativeAgentPromptSection: Codable, Sendable, Equatable {
    let order: Int
    let text: String
    let complete: Bool?

    init(order: Int, text: String, complete: Bool? = nil) {
        self.order = order
        self.text = text
        self.complete = complete
    }
}

enum NativeAgentPromptContextSource: String, Codable, Sendable, Equatable {
    case file
    case conversation
    case settings
}

struct NativeAgentPromptContext: Codable, Sendable, Equatable {
    let name: String
    let order: Int
    let source: NativeAgentPromptContextSource
    let path: String?
    let maximumCharacters: Int
    let prefix: String
    let suffix: String
}

struct NativeAgentPluginSettings: Codable, Sendable, Equatable {
    let schema: JSONValue
    let defaults: JSONValue
    var values: JSONValue
}

enum NativeAgentToolGuardDecision: String, Codable, Sendable, Equatable {
    case allow
    case ask
    case deny
}

struct NativeAgentToolGuard: Codable, Sendable, Equatable {
    let label: String
    let toolNames: [String]
    let risks: [ToolRisk]
    let decision: NativeAgentToolGuardDecision
    let reason: String?
}

struct NativeAgentCompiledTool: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }

    let name: String
    let description: String
    let parameters: JSONValue
    let risk: ToolRisk
    let instructions: String
    let allowedTools: [String]
}

struct NativeAgentCompiledPlugin: Codable, Sendable, Equatable, Identifiable {
    static let schemaVersion = 1
    static let idPrefix = "native-agent."

    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let description: String?
    let source: ISHMarketplacePluginSource
    let sourceDigest: String
    let compiledAt: Date
    let compilerProviderID: String
    let compilerModel: String
    var enabled: Bool
    let promptSections: [NativeAgentPromptSection]
    let promptContexts: [NativeAgentPromptContext]
    var settings: NativeAgentPluginSettings?
    let tools: [NativeAgentCompiledTool]
    let toolGuards: [NativeAgentToolGuard]
    let compatibilityNotes: [String]

    init(
        schemaVersion: Int,
        id: String,
        name: String,
        version: String,
        description: String?,
        source: ISHMarketplacePluginSource,
        sourceDigest: String,
        compiledAt: Date,
        compilerProviderID: String,
        compilerModel: String,
        enabled: Bool,
        promptSections: [NativeAgentPromptSection],
        promptContexts: [NativeAgentPromptContext] = [],
        settings: NativeAgentPluginSettings? = nil,
        tools: [NativeAgentCompiledTool],
        toolGuards: [NativeAgentToolGuard] = [],
        compatibilityNotes: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.source = source
        self.sourceDigest = sourceDigest
        self.compiledAt = compiledAt
        self.compilerProviderID = compilerProviderID
        self.compilerModel = compilerModel
        self.enabled = enabled
        self.promptSections = promptSections
        self.promptContexts = promptContexts
        self.settings = settings
        self.tools = tools
        self.toolGuards = toolGuards
        self.compatibilityNotes = compatibilityNotes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case version
        case description
        case source
        case sourceDigest
        case compiledAt
        case compilerProviderID
        case compilerModel
        case enabled
        case promptSections
        case promptContexts
        case settings
        case tools
        case toolGuards
        case compatibilityNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            version: try container.decode(String.self, forKey: .version),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            source: try container.decode(ISHMarketplacePluginSource.self, forKey: .source),
            sourceDigest: try container.decode(String.self, forKey: .sourceDigest),
            compiledAt: try container.decode(Date.self, forKey: .compiledAt),
            compilerProviderID: try container.decode(String.self, forKey: .compilerProviderID),
            compilerModel: try container.decode(String.self, forKey: .compilerModel),
            enabled: try container.decode(Bool.self, forKey: .enabled),
            promptSections: try container.decode(
                [NativeAgentPromptSection].self,
                forKey: .promptSections
            ),
            promptContexts: try container.decodeIfPresent(
                [NativeAgentPromptContext].self,
                forKey: .promptContexts
            ) ?? [],
            settings: try container.decodeIfPresent(
                NativeAgentPluginSettings.self,
                forKey: .settings
            ),
            tools: try container.decode([NativeAgentCompiledTool].self, forKey: .tools),
            toolGuards: try container.decodeIfPresent(
                [NativeAgentToolGuard].self,
                forKey: .toolGuards
            ) ?? [],
            compatibilityNotes: try container.decode(
                [String].self,
                forKey: .compatibilityNotes
            )
        )
    }

    func validated(allowedBaseTools: Set<String>) throws -> Self {
        guard schemaVersion == Self.schemaVersion,
              id.hasPrefix(Self.idPrefix),
              Self.isIdentifier(id, maximumBytes: 120),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 214,
              version.utf8.count <= 80,
              sourceDigest.utf8.count == 64,
              sourceDigest.allSatisfy(\.isHexDigit),
              compilerProviderID.utf8.count <= 128,
              compilerModel.utf8.count <= 256,
              promptSections.count <= 8,
              promptContexts.count <= 12,
              tools.count <= 16,
              toolGuards.count <= 16,
              !promptSections.isEmpty || !promptContexts.isEmpty || !tools.isEmpty
                || !toolGuards.isEmpty,
              compatibilityNotes.count <= 16 else {
            throw NativeAgentPluginError.invalidCompiledPlugin("插件元数据不合法。")
        }

        var totalTextBytes = 0
        guard promptSections.count(where: { $0.complete == true }) <= 1 else {
            throw NativeAgentPluginError.invalidCompiledPlugin(
                "同一个插件只能声明一个完整系统提示替换段。"
            )
        }
        for section in promptSections {
            guard (-10_000...10_000).contains(section.order),
                  !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.text.utf8.count <= 24 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin("系统提示贡献不合法。")
            }
            try ISHPluginHostCredentialFirewall.validate(.string(section.text))
            totalTextBytes += section.text.utf8.count
        }

        var contextNames = Set<String>()
        for context in promptContexts {
            guard contextNames.insert(context.name).inserted,
                  Self.isContributionName(context.name),
                  (-10_000...10_000).contains(context.order),
                  (1...32_768).contains(context.maximumCharacters),
                  context.prefix.utf8.count <= 8 * 1_024,
                  context.suffix.utf8.count <= 8 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin("动态上下文贡献不合法。")
            }
            switch context.source {
            case .file:
                guard let path = context.path,
                      Self.isPrivateContextPath(path) else {
                    throw NativeAgentPluginError.invalidCompiledPlugin(
                        "文件上下文必须使用插件私有目录中的精确路径。"
                    )
                }
            case .conversation, .settings:
                guard context.path == nil else {
                    throw NativeAgentPluginError.invalidCompiledPlugin(
                        "非文件上下文不能声明 path。"
                    )
                }
            }
            try ISHPluginHostCredentialFirewall.validate(.string(context.prefix))
            try ISHPluginHostCredentialFirewall.validate(.string(context.suffix))
            totalTextBytes += context.prefix.utf8.count + context.suffix.utf8.count
        }

        if let settings {
            guard case let .object(schema) = settings.schema,
                  schema["type"] == .string("object"),
                  case .object = settings.defaults,
                  case .object = settings.values,
                  try JSONEncoder().encode(settings.schema).count <= 32 * 1_024,
                  try JSONEncoder().encode(settings.defaults).count <= 32 * 1_024,
                  try JSONEncoder().encode(settings.values).count <= 32 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin("插件设置不合法。")
            }
            try NativeAgentJSONSchemaValidator.validate(
                value: settings.defaults,
                schema: settings.schema
            )
            try NativeAgentJSONSchemaValidator.validate(
                value: settings.values,
                schema: settings.schema
            )
            try ISHPluginHostCredentialFirewall.validate(settings.defaults)
            try ISHPluginHostCredentialFirewall.validate(settings.values)
        }

        var names = Set<String>()
        for tool in tools {
            guard names.insert(tool.name).inserted,
                  Self.isToolName(tool.name),
                  !allowedBaseTools.contains(tool.name),
                  !tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tool.description.utf8.count <= 1_024,
                  tool.instructions.utf8.count <= 24 * 1_024,
                  !tool.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(tool.allowedTools).count == tool.allowedTools.count,
                  tool.allowedTools.count <= 24,
                  Set(tool.allowedTools).isSubset(of: allowedBaseTools) else {
                throw NativeAgentPluginError.invalidCompiledPlugin("工具贡献不合法。")
            }
            guard case let .object(schema) = tool.parameters,
                  schema["type"] == .string("object") else {
                throw NativeAgentPluginError.invalidCompiledPlugin("工具参数必须是 JSON object schema。")
            }
            let schemaBytes = try JSONEncoder().encode(tool.parameters).count
            guard schemaBytes <= 32 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin("工具参数 schema 过大。")
            }
            try ISHPluginHostCredentialFirewall.validate(tool.parameters)
            try ISHPluginHostCredentialFirewall.validate(.string(tool.instructions))
            try Self.validatePrivateStorageInstructions(tool)
            totalTextBytes += tool.description.utf8.count + tool.instructions.utf8.count
        }

        var guardLabels = Set<String>()
        for guardRule in toolGuards {
            guard guardLabels.insert(guardRule.label).inserted,
                  Self.isContributionName(guardRule.label),
                  guardRule.toolNames.count <= 32,
                  Set(guardRule.toolNames).count == guardRule.toolNames.count,
                  guardRule.risks.count <= 5,
                  Set(guardRule.risks).count == guardRule.risks.count,
                  !guardRule.toolNames.isEmpty || !guardRule.risks.isEmpty,
                  guardRule.toolNames.allSatisfy({ $0 == "*" || Self.isToolName($0) }),
                  (guardRule.reason?.utf8.count ?? 0) <= 2_048 else {
                throw NativeAgentPluginError.invalidCompiledPlugin("工具策略守卫不合法。")
            }
            if guardRule.decision == .deny {
                guard let reason = guardRule.reason?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !reason.isEmpty else {
                    throw NativeAgentPluginError.invalidCompiledPlugin(
                        "deny 工具策略必须提供原因。"
                    )
                }
                try ISHPluginHostCredentialFirewall.validate(.string(reason))
            }
        }
        guard totalTextBytes <= 128 * 1_024,
              compatibilityNotes.allSatisfy({ $0.utf8.count <= 1_024 }) else {
            throw NativeAgentPluginError.invalidCompiledPlugin("原生插件内容过大。")
        }
        return self
    }

    private static func validatePrivateStorageInstructions(
        _ tool: NativeAgentCompiledTool
    ) throws {
        let allowed = Set(tool.allowedTools)
        guard allowed.contains("workspace_list_files"),
              !allowed.isDisjoint(with: ["workspace_read_text", "read"]) else { return }

        let text = tool.instructions.lowercased()
        let mentionsPrivatePath = [
            ".harness-mobile", "native-agent-plugins", "<plugin-id>"
        ].contains { text.contains($0) }
        let mentionsListing = [
            "workspace_list_files", "list files", "file listing", "enumerate",
            "列出", "枚举", "文件列表"
        ].contains { text.contains($0) }
        let mentionsMembershipGate = [
            "contains", "if present", "if found", "exists", "existence",
            "列表中", "存在后", "找到后", "发现后"
        ].contains { text.contains($0) }
        let explicitlyForbidsGate = [
            "never use", "do not use", "must not", "禁止", "不要使用", "不得"
        ].contains { text.contains($0) }

        guard mentionsPrivatePath,
              mentionsListing,
              mentionsMembershipGate,
              !explicitlyForbidsGate else { return }
        throw NativeAgentPluginError.invalidCompiledPlugin(
            "工具 \(tool.name) 把隐藏插件状态的读取门控在文件列表/contains/exists 之后；workspace_list_files 不返回点开头路径。请直接读取 `.harness-mobile/native-agent-plugins/<plugin-id>/<filename>`，把 not-found 当作初始空状态，并从 allowed_tools 移除不需要的 workspace_list_files。"
        )
    }

    var marketplaceProjection: ISHMarketplacePlugin {
        let timestamp = compiledAt.formatted(.iso8601)
        return ISHMarketplacePlugin(
            id: id,
            name: name,
            version: version,
            description: description,
            license: nil,
            source: source,
            enabled: enabled,
            state: enabled ? .enabled : .disabled,
            installedAt: timestamp,
            updatedAt: timestamp,
            entryCount: tools.count + promptSections.count + promptContexts.count
                + toolGuards.count + (settings == nil ? 0 : 1),
            lastError: nil
        )
    }

    static func makeID(packageName: String?, sourceDigest: String) -> String {
        let source = packageName ?? "plugin-\(sourceDigest.prefix(12))"
        var normalized = source
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .unicodeScalars
            .map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-" || scalar == "_" || scalar == "." {
                    return Character(scalar)
                }
                return "-"
            }
        while normalized.first == "-" { normalized.removeFirst() }
        while normalized.last == "-" { normalized.removeLast() }
        let suffix = String(normalized.prefix(88))
        return Self.idPrefix + (suffix.isEmpty ? String(sourceDigest.prefix(12)) : suffix)
    }

    private static func isIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= maximumBytes,
              isASCIIAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
        }
    }

    private static func isToolName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              value.utf8.count <= 64,
              (0x61...0x7A).contains(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            (0x61...0x7A).contains($0)
                || (0x30...0x39).contains($0)
                || $0 == 0x2D
                || $0 == 0x5F
        }
    }

    private static func isContributionName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 96 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == ":"
        }
    }

    private static func isPrivateContextPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.split(separator: "/").contains(".."),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        return value.hasPrefix("<plugin-storage>/")
            || value.hasPrefix("<session-storage>/")
            || value.hasPrefix(".harness-mobile/native-agent-plugins/<plugin-id>/")
    }

    private static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5A).contains(value)
            || (0x61...0x7A).contains(value)
    }
}

enum NativeAgentPluginError: LocalizedError, Sendable, Equatable {
    case invalidSourceSnapshot
    case sourceNotAdaptable(String)
    case compilerDidNotReturnManifest
    case invalidCompiledPlugin(String)
    case alreadyInstalled(String)
    case notFound(String)
    case noExecutionResult

    var errorDescription: String? {
        switch self {
        case .invalidSourceSnapshot:
            "插件源码快照不完整，无法交给手机 Agent 编译。"
        case let .sourceNotAdaptable(reason):
            "手机 Agent 无法把这个插件转换为原生工具：\(reason)"
        case .compilerDidNotReturnManifest:
            "手机 Agent 没有返回有效的原生插件清单。"
        case let .invalidCompiledPlugin(reason):
            "手机 Agent 生成的原生插件未通过校验：\(reason)"
        case let .alreadyInstalled(id):
            "原生插件 \(id) 已安装；更新时需要 replace=true。"
        case let .notFound(id):
            "未找到原生插件 \(id)。"
        case .noExecutionResult:
            "原生插件子 Agent 没有返回执行结果。"
        }
    }
}

/// Small machine-readable facts that the parent Agent can use to repair and
/// retry a native manifest. The full compilation trace stays in diagnostics.
struct NativeAgentCompilationDiagnostic: Codable, Sendable, Equatable {
    let code: String
    let stage: String
    let message: String
    let retryable: Bool
    let preparedToken: String?
    let suggestedAction: String

    init(
        code: String,
        stage: String,
        message: String,
        retryable: Bool,
        preparedToken: String? = nil,
        suggestedAction: String
    ) {
        self.code = code
        self.stage = stage
        self.message = message
        self.retryable = retryable
        self.preparedToken = preparedToken
        self.suggestedAction = suggestedAction
    }
}

extension NativeAgentPluginError {
    var shouldFallbackToISH: Bool {
        switch self {
        case .sourceNotAdaptable:
            true
        case .invalidSourceSnapshot, .compilerDidNotReturnManifest, .invalidCompiledPlugin,
             .alreadyInstalled, .notFound, .noExecutionResult:
            false
        }
    }
}

extension ISHPluginHostError {
    var nativeAgentCompilationCandidate: NativeAgentPluginSourceSnapshot? {
        guard case let .remote(code, _, data) = self,
              code == -32_010,
              let candidate = data?.objectValue?["nativeCandidate"] else { return nil }
        do {
            let encoded = try JSONEncoder().encode(candidate)
            return try JSONDecoder()
                .decode(NativeAgentPluginSourceSnapshot.self, from: encoded)
                .validated()
        } catch {
            return nil
        }
    }
}
