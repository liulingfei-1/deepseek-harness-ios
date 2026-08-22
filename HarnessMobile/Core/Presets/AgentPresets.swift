import Foundation

/// Matches the upstream preset-root trust vocabulary. Trust is assigned by
/// discovery and is never read from `preset.yml` display metadata.
enum AgentPresetTrust: String, Codable, Sendable, Equatable {
    case system
    case user
}

/// Display-only fields from the upstream `preset.yml` contract.
struct AgentPresetManifest: Codable, Sendable, Equatable {
    var name: String?
    var description: String?
    var order: Double?

    init(name: String? = nil, description: String? = nil, order: Double? = nil) {
        self.name = name
        self.description = description
        self.order = order
    }

    func validated() throws -> Self {
        guard order?.isFinite != false else {
            throw AgentPresetError.invalidOrder
        }
        return Self(
            name: Self.normalizedText(name),
            description: Self.normalizedText(description),
            order: order
        )
    }

    private static func normalizedText(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

enum AgentPresetPromptMode: String, Codable, Sendable, Equatable {
    case inherit
    case append
    case complete
}

struct AgentPresetPromptComposition: Codable, Sendable, Equatable {
    static let maximumUTF8Bytes = 64 * 1_024

    var mode: AgentPresetPromptMode
    var text: String?
    var includeRuntimeContext: Bool

    init(
        mode: AgentPresetPromptMode = .inherit,
        text: String? = nil,
        includeRuntimeContext: Bool = true
    ) {
        self.mode = mode
        self.text = text
        self.includeRuntimeContext = includeRuntimeContext
    }

    func validated() throws -> Self {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .inherit:
            guard normalized?.isEmpty != false else {
                throw AgentPresetError.inheritedPromptHasText
            }
            return Self(mode: .inherit, includeRuntimeContext: includeRuntimeContext)
        case .append, .complete:
            guard let normalized,
                  !normalized.isEmpty,
                  normalized.utf8.count <= Self.maximumUTF8Bytes else {
                throw AgentPresetError.invalidPrompt
            }
            return Self(
                mode: mode,
                text: normalized,
                includeRuntimeContext: includeRuntimeContext
            )
        }
    }
}

enum AgentPresetToolSelectionMode: String, Codable, Sendable, Equatable {
    case all
    case only
}

/// A native projection of the tool rows in `agent.cordis.yml`. This is an
/// internal compiled mapping, not a replacement file format for Cordis.
struct AgentPresetToolSelection: Codable, Sendable, Equatable {
    var mode: AgentPresetToolSelectionMode
    var names: Set<String>
    var excludedPrefixes: [String]

    init(
        mode: AgentPresetToolSelectionMode = .all,
        names: Set<String> = [],
        excludedPrefixes: [String] = []
    ) {
        self.mode = mode
        self.names = names
        self.excludedPrefixes = excludedPrefixes
    }

    func allows(_ name: String) -> Bool {
        if excludedPrefixes.contains(where: { name.hasPrefix($0) }) {
            return false
        }
        switch mode {
        case .all:
            return true
        case .only:
            return names.contains(name)
        }
    }

    func validated() throws -> Self {
        guard names.allSatisfy(Self.isValidContributionName),
              excludedPrefixes.allSatisfy({
                  !$0.isEmpty && $0.unicodeScalars.allSatisfy(Self.isValidContributionScalar)
              }) else {
            throw AgentPresetError.invalidToolSelection
        }
        if mode == .only, names.isEmpty {
            throw AgentPresetError.invalidToolSelection
        }
        return Self(
            mode: mode,
            names: names,
            excludedPrefixes: Array(Set(excludedPrefixes)).sorted()
        )
    }

    private static func isValidContributionName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= 128
            && name.unicodeScalars.allSatisfy(isValidContributionScalar)
    }

    private static func isValidContributionScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
            || scalar == "-"
            || scalar == "_"
            || scalar == "."
            || scalar == "/"
            || scalar == ":"
    }
}

struct AgentPresetNativeComposition: Codable, Sendable, Equatable {
    var prompt: AgentPresetPromptComposition
    var tools: AgentPresetToolSelection
    var defaultPermissionMode: ToolPermissionMode
    var maximumPermissionMode: ToolPermissionMode
    var excludedCommands: Set<String>

    init(
        prompt: AgentPresetPromptComposition = AgentPresetPromptComposition(),
        tools: AgentPresetToolSelection = AgentPresetToolSelection(),
        defaultPermissionMode: ToolPermissionMode = .workspaceWrite,
        maximumPermissionMode: ToolPermissionMode = .dangerFullAccess,
        excludedCommands: Set<String> = []
    ) {
        self.prompt = prompt
        self.tools = tools
        self.defaultPermissionMode = defaultPermissionMode
        self.maximumPermissionMode = maximumPermissionMode
        self.excludedCommands = excludedCommands
    }

    func validated() throws -> Self {
        guard defaultPermissionMode.isAllowed(by: maximumPermissionMode) else {
            throw AgentPresetError.invalidPermissionComposition
        }
        guard excludedCommands.allSatisfy(AgentPresetIdentifier.isValidCommandName) else {
            throw AgentPresetError.invalidCommandSelection
        }
        return Self(
            prompt: try prompt.validated(),
            tools: try tools.validated(),
            defaultPermissionMode: defaultPermissionMode,
            maximumPermissionMode: maximumPermissionMode,
            excludedCommands: excludedCommands
        )
    }

    func effectivePermissionMode(_ requested: ToolPermissionMode) -> ToolPermissionMode {
        requested.constrained(to: maximumPermissionMode)
    }

    func allowsCommand(_ name: String) -> Bool {
        !excludedCommands.contains(name)
    }
}

/// One discovered preset row. `id` comes from its directory and `trust` comes
/// from the root, matching upstream; neither is writable through the manifest.
struct AgentPresetDefinition: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let trust: AgentPresetTrust
    var manifest: AgentPresetManifest
    var composition: AgentPresetNativeComposition
    var broken: String?

    var displayName: String { manifest.name ?? id }
    var description: String? { manifest.description }
    var isMountable: Bool { broken == nil }

    init(
        id: String,
        trust: AgentPresetTrust,
        manifest: AgentPresetManifest = AgentPresetManifest(),
        composition: AgentPresetNativeComposition = AgentPresetNativeComposition(),
        broken: String? = nil
    ) {
        self.id = id
        self.trust = trust
        self.manifest = manifest
        self.composition = composition
        self.broken = broken
    }

    func validated() throws -> Self {
        guard AgentPresetIdentifier.isValid(id) else {
            throw AgentPresetError.invalidID(id)
        }
        let normalizedBroken = broken?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(
            id: id,
            trust: trust,
            manifest: try manifest.validated(),
            composition: try composition.validated(),
            broken: normalizedBroken?.isEmpty == false ? normalizedBroken : nil
        )
    }

    var runtimeProjection: AgentPresetRuntimeProjection {
        AgentPresetRuntimeProjection(id: id, composition: composition)
    }
}

struct AgentPresetRuntimeProjection: Sendable, Equatable {
    let id: String
    let composition: AgentPresetNativeComposition

    var isCodeMode: Bool { id == "code" }

    func allowsTool(_ name: String) -> Bool {
        if isCodeMode { return name == "run_code" }
        if name == "run_code" { return false }
        return composition.tools.allows(name)
    }

    func filterTools(_ definitions: [ModelToolDefinition]) -> [ModelToolDefinition] {
        definitions.filter { definition in
            if isCodeMode { return definition.name == "run_code" }
            return definition.name != "run_code" && allowsTool(definition.name)
        }
    }

    func systemPrompt(
        assembledSystemPrompt: String,
        fallback: String
    ) -> String {
        let inherited = assembledSystemPrompt.isEmpty ? fallback : assembledSystemPrompt

        switch composition.prompt.mode {
        case .inherit:
            return inherited
        case .append:
            return [inherited, composition.prompt.text ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        case .complete:
            return composition.prompt.text ?? fallback
        }
    }

    func runtimeContext(_ context: String) -> String {
        composition.prompt.includeRuntimeContext ? context : ""
    }
}

enum AgentPresetRegistry {
    static let defaultID = "standard"

    static let systemPresets: [AgentPresetDefinition] = [
        AgentPresetDefinition(
            id: "standard",
            trust: .system,
            manifest: AgentPresetManifest(
                name: "标准模式",
                description: "功能完整的编码 Agent，支持文件编辑、Shell、计划、目标和普通插件贡献工具。",
                order: 1
            ),
            composition: AgentPresetNativeComposition(
                tools: AgentPresetToolSelection(
                    mode: .all,
                    excludedPrefixes: ["cordis_"]
                )
            )
        ),
        AgentPresetDefinition(
            id: "code",
            trust: .system,
            manifest: AgentPresetManifest(
                name: "PTC 模式",
                description: "通过生成的 Python Code Mode SDK 在手机 iSH 中组合多步本机工具。",
                order: 2
            ),
            composition: AgentPresetNativeComposition(
                tools: AgentPresetToolSelection(
                    mode: .all,
                    excludedPrefixes: ["cordis_"]
                )
            )
        ),
        AgentPresetDefinition(
            id: "minimal",
            trust: .system,
            manifest: AgentPresetManifest(
                name: "极简模式",
                description: "仅保留本机 iSH Shell 与工作区文件工具的精简编码 Agent。",
                order: 3
            ),
            composition: AgentPresetNativeComposition(
                prompt: AgentPresetPromptComposition(
                    mode: .complete,
                    text: MobileHarnessPrompt.text,
                    includeRuntimeContext: false
                ),
                tools: AgentPresetToolSelection(
                    mode: .only,
                    names: [
                        "edit",
                        "job_kill",
                        "job_list",
                        "job_output",
                        "read",
                        "shell_execute",
                        "workspace_list_files",
                        "write"
                    ]
                ),
                defaultPermissionMode: .workspaceWrite,
                maximumPermissionMode: .workspaceWrite,
                excludedCommands: ["compact", "plan"]
            )
        ),
        AgentPresetDefinition(
            id: "cordis",
            trust: .system,
            manifest: AgentPresetManifest(
                name: "创造模式",
                description: "标准能力加上运行时检查、插件实验与可撤销的 Harness 自修改工具。",
                order: 4
            ),
            composition: AgentPresetNativeComposition(
                prompt: AgentPresetPromptComposition(
                    mode: .append,
                    text: "Treat Harness changes as reversible Cordis experiments. Inspect the active contract, change one generation at a time, verify it, and roll back only the failing plugin generation.",
                    includeRuntimeContext: true
                )
            )
        )
    ]

    /// Earlier roots win duplicate ids, matching upstream discovery.
    static func merge(roots: [[AgentPresetDefinition]]) throws -> [AgentPresetDefinition] {
        var seen = Set<String>()
        var result: [AgentPresetDefinition] = []
        for root in roots {
            let validated = try root.map { try $0.validated() }
                .sorted(by: rosterOrder)
            for preset in validated where seen.insert(preset.id).inserted {
                result.append(preset)
            }
        }
        return result
    }

    static func resolve(
        _ id: String,
        in presets: [AgentPresetDefinition]
    ) throws -> AgentPresetDefinition {
        guard let preset = presets.first(where: { $0.id == id }) else {
            throw AgentPresetError.unknownPreset(
                id,
                available: presets.map(\.id)
            )
        }
        guard let broken = preset.broken else { return preset }
        throw AgentPresetError.brokenPreset(id, reason: broken)
    }

    private static func rosterOrder(
        _ left: AgentPresetDefinition,
        _ right: AgentPresetDefinition
    ) -> Bool {
        let leftOrder = left.manifest.order ?? .infinity
        let rightOrder = right.manifest.order ?? .infinity
        if leftOrder != rightOrder { return leftOrder < rightOrder }
        return left.id.localizedStandardCompare(right.id) == .orderedAscending
    }
}

actor AgentPresetRegistryStore {
    private struct Snapshot: Codable {
        var version: Int
        var presets: [AgentPresetDefinition]
    }

    private static let currentVersion = 1

    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(root: URL? = nil) {
        if let root {
            directory = root
        } else {
            directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("AgentPresets", isDirectory: true)
        }
        fileURL = directory.appendingPathComponent("registry.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    func load() throws -> [AgentPresetDefinition] {
        try AgentPresetRegistry.merge(
            roots: [AgentPresetRegistry.systemPresets, readUserPresets()]
        )
    }

    func installUserPreset(_ preset: AgentPresetDefinition) throws {
        let validated = try preset.validated()
        guard validated.trust == .user else {
            throw AgentPresetError.userStoreRequiresUserTrust
        }
        guard !AgentPresetRegistry.systemPresets.contains(where: { $0.id == validated.id }) else {
            throw AgentPresetError.systemPresetIsReserved(validated.id)
        }
        var presets = try readUserPresets()
        guard !presets.contains(where: { $0.id == validated.id }) else {
            throw AgentPresetError.presetAlreadyExists(validated.id)
        }
        presets.append(validated)
        try writeUserPresets(presets)
    }

    func replaceUserPreset(_ preset: AgentPresetDefinition) throws {
        let validated = try preset.validated()
        guard validated.trust == .user else {
            throw AgentPresetError.userStoreRequiresUserTrust
        }
        var presets = try readUserPresets()
        guard let index = presets.firstIndex(where: { $0.id == validated.id }) else {
            throw AgentPresetError.unknownPreset(
                validated.id,
                available: presets.map(\.id)
            )
        }
        presets[index] = validated
        try writeUserPresets(presets)
    }

    @discardableResult
    func removeUserPreset(id: String) throws -> Bool {
        var presets = try readUserPresets()
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            return false
        }
        presets.remove(at: index)
        try writeUserPresets(presets)
        return true
    }

    func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func readUserPresets() throws -> [AgentPresetDefinition] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.version == Self.currentVersion else {
            throw AgentPresetError.unsupportedRegistryVersion(snapshot.version)
        }
        guard snapshot.presets.allSatisfy({ $0.trust == .user }),
              Set(snapshot.presets.map(\.id)).count == snapshot.presets.count else {
            throw AgentPresetError.corruptRegistry
        }
        return try snapshot.presets.map { try $0.validated() }
    }

    private func writeUserPresets(_ presets: [AgentPresetDefinition]) throws {
        guard presets.allSatisfy({ $0.trust == .user }),
              Set(presets.map(\.id)).count == presets.count else {
            throw AgentPresetError.corruptRegistry
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(
            Snapshot(
                version: Self.currentVersion,
                presets: try presets.map { try $0.validated() }
            )
        )
        try data.write(to: fileURL, options: Self.protectedWritingOptions)
    }

    private static var protectedWritingOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        [.atomic]
#endif
    }
}

enum AgentPresetIdentifier {
    static func isValid(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              isLowercaseASCII(first) || isDigitASCII(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            isLowercaseASCII($0) || isDigitASCII($0) || $0 == "-"
        }
    }

    static func isValidCommandName(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              isLowercaseASCII(first) else {
            return false
        }
        return value.unicodeScalars.dropFirst().allSatisfy {
            isLowercaseASCII($0) || isDigitASCII($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func isLowercaseASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 97 && scalar.value <= 122
    }

    private static func isDigitASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }
}

extension ToolPermissionMode {
    func isAllowed(by maximum: ToolPermissionMode) -> Bool {
        agentPresetRank <= maximum.agentPresetRank
    }

    func constrained(to maximum: ToolPermissionMode) -> ToolPermissionMode {
        isAllowed(by: maximum) ? self : maximum
    }

    private var agentPresetRank: Int {
        switch self {
        case .readOnly: 0
        case .workspaceWrite: 1
        case .dangerFullAccess: 2
        }
    }
}

enum AgentPresetError: LocalizedError, Sendable, Equatable {
    case invalidID(String)
    case invalidOrder
    case invalidPrompt
    case inheritedPromptHasText
    case invalidToolSelection
    case invalidPermissionComposition
    case invalidCommandSelection
    case unknownPreset(String, available: [String])
    case brokenPreset(String, reason: String)
    case presetLocked
    case presetAlreadyExists(String)
    case systemPresetIsReserved(String)
    case userStoreRequiresUserTrust
    case unsupportedRegistryVersion(Int)
    case corruptRegistry

    var errorDescription: String? {
        switch self {
        case let .invalidID(id):
            return "Agent preset ID \(id.debugDescription) 必须匹配 [a-z0-9][a-z0-9-]*。"
        case .invalidOrder:
            return "Agent preset 的 order 必须是有限数值。"
        case .invalidPrompt:
            return "Agent preset Prompt 不能为空或超过 64 KiB。"
        case .inheritedPromptHasText:
            return "继承 Prompt 的 preset 不能同时携带替换文本。"
        case .invalidToolSelection:
            return "Agent preset 的工具组合无效。"
        case .invalidPermissionComposition:
            return "Agent preset 的默认权限高于它允许的最高权限。"
        case .invalidCommandSelection:
            return "Agent preset 的命令组合无效。"
        case let .unknownPreset(id, available):
            let choices = available.isEmpty ? "无" : available.joined(separator: "、")
            return "找不到 Agent preset \(id.debugDescription)；可用：\(choices)。"
        case let .brokenPreset(id, reason):
            return "Agent preset \(id.debugDescription) 无法挂载：\(reason)"
        case .presetLocked:
            return "Agent preset 当前正在运行中，停止任务后才能切换。"
        case let .presetAlreadyExists(id):
            return "Agent preset \(id.debugDescription) 已存在，安装不会覆盖。"
        case let .systemPresetIsReserved(id):
            return "Agent preset \(id.debugDescription) 由 App 提供，用户 registry 不能遮蔽它。"
        case .userStoreRequiresUserTrust:
            return "用户 registry 只接受 trust=user 的 Agent preset。"
        case let .unsupportedRegistryVersion(version):
            return "不支持的 Agent preset registry 版本：\(version)。"
        case .corruptRegistry:
            return "Agent preset registry 已损坏。"
        }
    }
}
