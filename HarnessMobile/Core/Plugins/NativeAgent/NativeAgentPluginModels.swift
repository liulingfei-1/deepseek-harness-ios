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

struct NativeAgentPromptSection: Codable, Sendable, Equatable {
    let order: Int
    let text: String
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
    let tools: [NativeAgentCompiledTool]
    let compatibilityNotes: [String]

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
              tools.count <= 16,
              !promptSections.isEmpty || !tools.isEmpty,
              compatibilityNotes.count <= 16 else {
            throw NativeAgentPluginError.invalidCompiledPlugin("插件元数据不合法。")
        }

        var totalTextBytes = 0
        for section in promptSections {
            guard (-10_000...10_000).contains(section.order),
                  !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  section.text.utf8.count <= 24 * 1_024 else {
                throw NativeAgentPluginError.invalidCompiledPlugin("系统提示贡献不合法。")
            }
            try ISHPluginHostCredentialFirewall.validate(.string(section.text))
            totalTextBytes += section.text.utf8.count
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
            totalTextBytes += tool.description.utf8.count + tool.instructions.utf8.count
        }
        guard totalTextBytes <= 128 * 1_024,
              compatibilityNotes.allSatisfy({ $0.utf8.count <= 1_024 }) else {
            throw NativeAgentPluginError.invalidCompiledPlugin("原生插件内容过大。")
        }
        return self
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
            entryCount: tools.count + promptSections.count,
            lastError: compatibilityNotes.isEmpty
                ? nil
                : compatibilityNotes.joined(separator: "\n")
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

extension NativeAgentPluginError {
    var shouldFallbackToISH: Bool {
        switch self {
        case .sourceNotAdaptable, .invalidCompiledPlugin:
            true
        case .invalidSourceSnapshot, .compilerDidNotReturnManifest,
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
