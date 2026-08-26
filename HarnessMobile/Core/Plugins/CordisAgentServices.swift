import Foundation

enum CordisAgentServiceKeys {
    static let tools = CordisServiceKey<CordisToolRuntime>("tools")
    static let systemPrompt = CordisServiceKey<CordisSystemPromptRuntime>("systemPrompt")
    static let fileSystem = CordisServiceKey<any HarnessFileSystem>("fs")
    static let jobs = CordisServiceKey<any HarnessJobManaging>("jobs")
}

/// Core agent services are ordinary Cordis services. The host keeps these actor
/// references for fast snapshots while plugins resolve the same instances by key.
struct CordisAgentServices: Sendable {
    let tools: CordisToolRuntime
    let systemPrompt: CordisSystemPromptRuntime

    init(
        tools: CordisToolRuntime = CordisToolRuntime(),
        systemPrompt: CordisSystemPromptRuntime = CordisSystemPromptRuntime()
    ) {
        self.tools = tools
        self.systemPrompt = systemPrompt
    }

    func pluginDefinition(
        id: CordisPluginID = "core.agent-services",
        version: String = "1",
        baseSystemPrompt: String? = nil
    ) -> CordisPluginDefinition {
        let tools = tools
        let systemPrompt = systemPrompt
        return CordisPluginDefinition(
            id: id,
            version: version,
            provides: [
                CordisAgentServiceKeys.tools.name,
                CordisAgentServiceKeys.systemPrompt.name
            ]
        ) { context in
            try await context.provide(CordisAgentServiceKeys.tools, value: tools)
            try await context.provide(CordisAgentServiceKeys.systemPrompt, value: systemPrompt)
            if let baseSystemPrompt {
                try await context.promptSection(
                    CordisPromptSection(
                        name: "harness:base",
                        order: -100,
                        complete: false,
                        text: baseSystemPrompt
                    ),
                    in: systemPrompt
                )
            }
        }
    }
}

enum CordisAgentServiceError: LocalizedError, Sendable, Equatable {
    case invalidContributionName(String)
    case duplicateTool(String)
    case duplicatePromptSection(String)
    case duplicatePromptContext(String)
    case duplicatePromptVariable(String)
    case invalidPromptVariableName(String)
    case multipleCompletePromptSections([String])
    case malformedPromptVariableReference(section: String, reference: String)
    case unknownPromptVariable(section: String, name: String)
    case undefinedPromptVariable(section: String, name: String)

    var errorDescription: String? {
        switch self {
        case let .invalidContributionName(name):
            return "Invalid Cordis contribution name: \(name)"
        case let .duplicateTool(name):
            return "Cordis tool \(name) is already registered."
        case let .duplicatePromptSection(name):
            return "Cordis prompt section \(name) is already registered."
        case let .duplicatePromptContext(name):
            return "Cordis prompt context \(name) is already registered."
        case let .duplicatePromptVariable(name):
            return "Cordis prompt variable \(name) is already registered."
        case let .invalidPromptVariableName(name):
            return "Invalid Cordis prompt variable name: \(name)"
        case let .multipleCompletePromptSections(names):
            return "Multiple complete Cordis prompt sections are active: \(names.joined(separator: ", "))."
        case let .malformedPromptVariableReference(section, reference):
            return "Malformed prompt variable \(reference) in section \(section)."
        case let .unknownPromptVariable(section, name):
            return "Unknown prompt variable {{\(name)}} in section \(section)."
        case let .undefinedPromptVariable(section, name):
            return "Prompt variable {{\(name)}} has no value in section \(section)."
        }
    }
}

struct CordisToolContributionSnapshot: Sendable, Equatable {
    let pluginID: CordisPluginID
    let definition: ModelToolDefinition
    let risk: ToolRisk
}

struct CordisToolGuardSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let pluginID: CordisPluginID
    let label: String
}

typealias CordisToolGuard = @Sendable (CordisToolExecution) async -> String?

/// Dynamic tool and guard service. Registrations are owned by the activating
/// plugin through `CordisPluginContext`, so unload and rollback retract them.
actor CordisToolRuntime {
    private struct ToolEntry: Sendable {
        let registrationID: UUID
        let pluginID: CordisPluginID
        let mcpGenerationID: UUID?
        let tool: any LocalAgentTool
    }

    private struct GuardEntry: Sendable {
        let id: UUID
        let pluginID: CordisPluginID
        let label: String
        let guardBody: CordisToolGuard
    }

    private var toolEntries: [String: ToolEntry] = [:]
    private var guardEntries: [GuardEntry] = []

    fileprivate func register(
        _ tool: any LocalAgentTool,
        pluginID: CordisPluginID
    ) throws -> CordisDisposer {
        let name = tool.definition.name
        try Self.validateContributionName(name)
        guard toolEntries[name] == nil else {
            throw CordisAgentServiceError.duplicateTool(name)
        }
        let registrationID = UUID()
        toolEntries[name] = ToolEntry(
            registrationID: registrationID,
            pluginID: pluginID,
            mcpGenerationID: nil,
            tool: tool
        )
        return { [runtime = self] in
            await runtime.removeTool(name: name, registrationID: registrationID)
        }
    }

    /// Replaces every tool in one configured local-server generation within this actor turn.
    /// Callers either observe the prior full set or the replacement full set;
    /// conflicting third-party names fail before any entry is changed.
    func replaceMCPTools(
        pluginID: CordisPluginID,
        generationID: UUID,
        tools: [any LocalAgentTool]
    ) throws {
        var replacements: [String: ToolEntry] = [:]
        for tool in tools {
            let name = tool.definition.name
            try Self.validateContributionName(name)
            guard replacements[name] == nil else {
                throw CordisAgentServiceError.duplicateTool(name)
            }
            if let existing = toolEntries[name],
               existing.pluginID != pluginID,
               existing.mcpGenerationID != generationID {
                throw CordisAgentServiceError.duplicateTool(name)
            }
            replacements[name] = ToolEntry(
                registrationID: UUID(),
                pluginID: pluginID,
                mcpGenerationID: generationID,
                tool: tool
            )
        }
        toolEntries = toolEntries.filter { _, entry in
            entry.mcpGenerationID != generationID
        }
        for (name, entry) in replacements {
            toolEntries[name] = entry
        }
    }

    func removeMCPTools(generationID: UUID) {
        toolEntries = toolEntries.filter { _, entry in
            entry.mcpGenerationID != generationID
        }
    }

    fileprivate func registerGuard(
        pluginID: CordisPluginID,
        label: String,
        guardBody: @escaping CordisToolGuard
    ) throws -> CordisDisposer {
        try Self.validateContributionName(label)
        let id = UUID()
        guardEntries.append(
            GuardEntry(
                id: id,
                pluginID: pluginID,
                label: label,
                guardBody: guardBody
            )
        )
        return { [runtime = self] in
            await runtime.removeGuard(id: id)
        }
    }

    func snapshots() -> [CordisToolContributionSnapshot] {
        toolEntries.values
            .map {
                CordisToolContributionSnapshot(
                    pluginID: $0.pluginID,
                    definition: $0.tool.definition,
                    risk: $0.tool.risk
                )
            }
            .sorted { $0.definition.name < $1.definition.name }
    }

    func guardSnapshots() -> [CordisToolGuardSnapshot] {
        guardEntries.map {
            CordisToolGuardSnapshot(id: $0.id, pluginID: $0.pluginID, label: $0.label)
        }
    }

    func tools(allowedBy permissionMode: ToolPermissionMode) -> [any LocalAgentTool] {
        toolEntries.values
            .map(\.tool)
            .filter { permissionMode.decision(for: $0.risk) != .deny }
            .sorted { $0.definition.name < $1.definition.name }
    }

    func definitions(allowedBy permissionMode: ToolPermissionMode) -> [ModelToolDefinition] {
        tools(allowedBy: permissionMode).map(\.definition)
    }

    func tool(named name: String) -> (any LocalAgentTool)? {
        toolEntries[name]?.tool
    }

    /// Guards can only deny. They have no allow result, so ordering cannot
    /// reverse a platform or earlier plugin denial.
    func guardReason(for execution: CordisToolExecution) async -> String? {
        let guards = guardEntries
        for entry in guards {
            if let reason = await entry.guardBody(execution), !reason.isEmpty {
                return reason
            }
        }
        return nil
    }

    private func removeTool(name: String, registrationID: UUID) {
        guard toolEntries[name]?.registrationID == registrationID else { return }
        toolEntries.removeValue(forKey: name)
    }

    private func removeGuard(id: UUID) {
        guardEntries.removeAll { $0.id == id }
    }

    private static func validateContributionName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-"
                      || scalar == "_"
                      || scalar == "."
                      || scalar == "/"
                      || scalar == ":"
              }) else {
            throw CordisAgentServiceError.invalidContributionName(name)
        }
    }
}

struct CordisPromptAssemblyInput: Sendable, Equatable {
    let agentID: UUID
    let runID: UUID
    let step: Int
    let configuration: AgentConfiguration
    let messages: [AgentMessage]

    init(
        runID: UUID,
        agentID: UUID? = nil,
        step: Int,
        configuration: AgentConfiguration,
        messages: [AgentMessage]
    ) {
        self.agentID = agentID ?? runID
        self.runID = runID
        self.step = step
        self.configuration = configuration
        self.messages = messages
    }
}

typealias CordisPromptTextProvider = @Sendable (CordisPromptAssemblyInput) async throws -> String
typealias CordisPromptVariableProvider = @Sendable (CordisPromptAssemblyInput) async throws -> String?

struct CordisPromptSection: Sendable {
    let name: String
    let order: Int
    let complete: Bool
    let interpolate: Bool
    let text: CordisPromptTextProvider

    init(
        name: String,
        order: Int,
        complete: Bool = false,
        interpolate: Bool = true,
        text: String
    ) {
        self.name = name
        self.order = order
        self.complete = complete
        self.interpolate = interpolate
        self.text = { _ in text }
    }

    init(
        name: String,
        order: Int,
        complete: Bool = false,
        interpolate: Bool = true,
        text: @escaping CordisPromptTextProvider
    ) {
        self.name = name
        self.order = order
        self.complete = complete
        self.interpolate = interpolate
        self.text = text
    }
}

struct CordisPromptContextContribution: Sendable {
    let name: String
    let order: Int
    let interpolate: Bool
    let text: CordisPromptTextProvider

    init(name: String, order: Int, interpolate: Bool = true, text: String) {
        self.name = name
        self.order = order
        self.interpolate = interpolate
        self.text = { _ in text }
    }

    init(
        name: String,
        order: Int,
        interpolate: Bool = true,
        text: @escaping CordisPromptTextProvider
    ) {
        self.name = name
        self.order = order
        self.interpolate = interpolate
        self.text = text
    }
}

struct CordisAssembledPromptContribution: Sendable, Equatable {
    let name: String
    let text: String
}

struct CordisPromptVariableValue: Sendable, Equatable {
    let name: String
    let value: String?
}

struct CordisPromptAssembly: Sendable, Equatable {
    let sections: [CordisAssembledPromptContribution]
    let contexts: [CordisAssembledPromptContribution]
    let variables: [CordisPromptVariableValue]

    var systemPrompt: String {
        sections.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    var runtimeContext: String {
        let body = contexts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !body.isEmpty else { return "" }
        return "Current runtime context. This snapshot supersedes earlier runtime-context snapshots.\n\n\(body)"
    }
}

enum CordisPromptContributionKind: String, Sendable, Equatable {
    case section
    case context
    case variable
}

struct CordisPromptContributionSnapshot: Sendable, Equatable {
    let pluginID: CordisPluginID
    let kind: CordisPromptContributionKind
    let name: String
    let order: Int?
    let complete: Bool
}

/// Ordered prompt registry aligned with the upstream system-prompt service:
/// sections, dynamic context, variables, strict interpolation, and complete
/// prompt replacement are all reversible plugin contributions.
actor CordisSystemPromptRuntime {
    private struct SectionEntry: Sendable {
        let registrationID: UUID
        let pluginID: CordisPluginID
        let contribution: CordisPromptSection
    }

    private struct ContextEntry: Sendable {
        let registrationID: UUID
        let pluginID: CordisPluginID
        let contribution: CordisPromptContextContribution
    }

    private struct VariableEntry: Sendable {
        let registrationID: UUID
        let pluginID: CordisPluginID
        let name: String
        let provider: CordisPromptVariableProvider
    }

    private var sections: [String: SectionEntry] = [:]
    private var contexts: [String: ContextEntry] = [:]
    private var variables: [String: VariableEntry] = [:]

    fileprivate func register(
        _ section: CordisPromptSection,
        pluginID: CordisPluginID
    ) throws -> CordisDisposer {
        try Self.validateContributionName(section.name)
        guard sections[section.name] == nil else {
            throw CordisAgentServiceError.duplicatePromptSection(section.name)
        }
        let registrationID = UUID()
        sections[section.name] = SectionEntry(
            registrationID: registrationID,
            pluginID: pluginID,
            contribution: section
        )
        return { [runtime = self] in
            await runtime.removeSection(name: section.name, registrationID: registrationID)
        }
    }

    fileprivate func register(
        _ context: CordisPromptContextContribution,
        pluginID: CordisPluginID
    ) throws -> CordisDisposer {
        try Self.validateContributionName(context.name)
        guard contexts[context.name] == nil else {
            throw CordisAgentServiceError.duplicatePromptContext(context.name)
        }
        let registrationID = UUID()
        contexts[context.name] = ContextEntry(
            registrationID: registrationID,
            pluginID: pluginID,
            contribution: context
        )
        return { [runtime = self] in
            await runtime.removeContext(name: context.name, registrationID: registrationID)
        }
    }

    fileprivate func registerVariable(
        name: String,
        pluginID: CordisPluginID,
        provider: @escaping CordisPromptVariableProvider
    ) throws -> CordisDisposer {
        guard Self.isVariableName(name) else {
            throw CordisAgentServiceError.invalidPromptVariableName(name)
        }
        guard variables[name] == nil else {
            throw CordisAgentServiceError.duplicatePromptVariable(name)
        }
        let registrationID = UUID()
        variables[name] = VariableEntry(
            registrationID: registrationID,
            pluginID: pluginID,
            name: name,
            provider: provider
        )
        return { [runtime = self] in
            await runtime.removeVariable(name: name, registrationID: registrationID)
        }
    }

    func snapshots() -> [CordisPromptContributionSnapshot] {
        let sectionSnapshots = sections.values.map {
            CordisPromptContributionSnapshot(
                pluginID: $0.pluginID,
                kind: .section,
                name: $0.contribution.name,
                order: $0.contribution.order,
                complete: $0.contribution.complete
            )
        }
        let contextSnapshots = contexts.values.map {
            CordisPromptContributionSnapshot(
                pluginID: $0.pluginID,
                kind: .context,
                name: $0.contribution.name,
                order: $0.contribution.order,
                complete: false
            )
        }
        let variableSnapshots = variables.values.map {
            CordisPromptContributionSnapshot(
                pluginID: $0.pluginID,
                kind: .variable,
                name: $0.name,
                order: nil,
                complete: false
            )
        }
        return (sectionSnapshots + contextSnapshots + variableSnapshots).sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.name < $1.name
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    func assemble(_ input: CordisPromptAssemblyInput) async throws -> CordisPromptAssembly {
        let variableEntries = variables.values.sorted { $0.name < $1.name }
        var resolvedVariables: [CordisPromptVariableValue] = []
        resolvedVariables.reserveCapacity(variableEntries.count)
        for entry in variableEntries {
            resolvedVariables.append(
                CordisPromptVariableValue(
                    name: entry.name,
                    value: try await entry.provider(input)
                )
            )
        }
        let variableMap = Dictionary(
            uniqueKeysWithValues: resolvedVariables.map { ($0.name, $0.value) }
        )

        let sectionEntries = sections.values.sorted {
            if $0.contribution.order == $1.contribution.order {
                return $0.contribution.name < $1.contribution.name
            }
            return $0.contribution.order < $1.contribution.order
        }
        let completeNames = sectionEntries
            .filter(\.contribution.complete)
            .map(\.contribution.name)
        guard completeNames.count <= 1 else {
            throw CordisAgentServiceError.multipleCompletePromptSections(completeNames)
        }

        var assembledSections: [CordisAssembledPromptContribution] = []
        assembledSections.reserveCapacity(sectionEntries.count)
        for entry in sectionEntries {
            let raw = try await entry.contribution.text(input)
            assembledSections.append(
                CordisAssembledPromptContribution(
                    name: entry.contribution.name,
                    text: entry.contribution.interpolate
                        ? try Self.interpolate(
                            raw,
                            contributionName: entry.contribution.name,
                            variables: variableMap
                        )
                        : raw
                )
            )
        }
        if let completeName = completeNames.first {
            assembledSections = assembledSections.filter { $0.name == completeName }
        }

        let contextEntries = contexts.values.sorted {
            if $0.contribution.order == $1.contribution.order {
                return $0.contribution.name < $1.contribution.name
            }
            return $0.contribution.order < $1.contribution.order
        }
        var assembledContexts: [CordisAssembledPromptContribution] = []
        assembledContexts.reserveCapacity(contextEntries.count)
        for entry in contextEntries {
            let raw = try await entry.contribution.text(input)
            assembledContexts.append(
                CordisAssembledPromptContribution(
                    name: entry.contribution.name,
                    text: entry.contribution.interpolate
                        ? try Self.interpolate(
                            raw,
                            contributionName: entry.contribution.name,
                            variables: variableMap
                        )
                        : raw
                )
            )
        }

        return CordisPromptAssembly(
            sections: assembledSections,
            contexts: assembledContexts,
            variables: resolvedVariables
        )
    }

    private func removeSection(name: String, registrationID: UUID) {
        guard sections[name]?.registrationID == registrationID else { return }
        sections.removeValue(forKey: name)
    }

    private func removeContext(name: String, registrationID: UUID) {
        guard contexts[name]?.registrationID == registrationID else { return }
        contexts.removeValue(forKey: name)
    }

    private func removeVariable(name: String, registrationID: UUID) {
        guard variables[name]?.registrationID == registrationID else { return }
        variables.removeValue(forKey: name)
    }

    private nonisolated static func validateContributionName(_ name: String) throws {
        guard !name.isEmpty,
              name.utf8.count <= 128,
              name.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-"
                      || scalar == "_"
                      || scalar == "."
                      || scalar == "/"
                      || scalar == ":"
              }) else {
            throw CordisAgentServiceError.invalidContributionName(name)
        }
    }

    private nonisolated static func isVariableName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              (Character("a").asciiValue!...Character("z").asciiValue!).contains(first) else {
            return false
        }
        return name.utf8.dropFirst().allSatisfy { byte in
            (Character("a").asciiValue!...Character("z").asciiValue!).contains(byte)
                || (Character("0").asciiValue!...Character("9").asciiValue!).contains(byte)
                || byte == Character("_").asciiValue!
        }
    }

    private nonisolated static func interpolate(
        _ text: String,
        contributionName: String,
        variables: [String: String?]
    ) throws -> String {
        var result = ""
        var cursor = text.startIndex
        while let open = text.range(of: "{{", range: cursor..<text.endIndex) {
            result += text[cursor..<open.lowerBound]
            guard let close = text.range(of: "}}", range: open.upperBound..<text.endIndex) else {
                result += text[open.lowerBound..<text.endIndex]
                return result
            }
            let name = String(text[open.upperBound..<close.lowerBound])
            guard isVariableName(name) else {
                throw CordisAgentServiceError.malformedPromptVariableReference(
                    section: contributionName,
                    reference: "{{\(name)}}"
                )
            }
            switch variables[name] {
            case .none:
                throw CordisAgentServiceError.unknownPromptVariable(
                    section: contributionName,
                    name: name
                )
            case .some(.none):
                throw CordisAgentServiceError.undefinedPromptVariable(
                    section: contributionName,
                    name: name
                )
            case let .some(.some(value)):
                result += value
            }
            cursor = close.upperBound
        }
        result += text[cursor..<text.endIndex]
        return result
    }
}

extension CordisPluginContext {
    @discardableResult
    func registerTool(
        _ tool: any LocalAgentTool,
        in runtime: CordisToolRuntime
    ) async throws -> CordisEffectHandle {
        let pluginID = pluginID
        let toolName = tool.definition.name
        let context = self
        let acquire: @Sendable () async throws -> CordisDisposer? = {
            let disposer: CordisDisposer = try await runtime.register(
                tool,
                pluginID: pluginID
            )
            await context.emit(
                CordisAgentLoopEvents.toolsChange,
                input: .value,
                target: .unfiltered
            )
            let cleanup: CordisDisposer = {
                try await disposer()
                await context.emit(
                    CordisAgentLoopEvents.toolsChange,
                    input: .value,
                    target: .unfiltered
                )
            }
            return cleanup
        }
        return try await effect("tools.register(\(toolName))", acquire: acquire)
    }

    @discardableResult
    func registerTool(_ tool: any LocalAgentTool) async throws -> CordisEffectHandle {
        let runtime = try await service(CordisAgentServiceKeys.tools)
        return try await registerTool(tool, in: runtime)
    }

    @discardableResult
    func guardTool(
        label: String,
        in runtime: CordisToolRuntime,
        _ guardBody: @escaping CordisToolGuard
    ) async throws -> CordisEffectHandle {
        let pluginID = pluginID
        return try await effect("tools.guard(\(label))") {
            let disposer = try await runtime.registerGuard(
                pluginID: pluginID,
                label: label,
                guardBody: guardBody
            )
            return Optional(disposer)
        }
    }

    @discardableResult
    func guardTool(
        label: String,
        _ guardBody: @escaping CordisToolGuard
    ) async throws -> CordisEffectHandle {
        let runtime = try await service(CordisAgentServiceKeys.tools)
        return try await guardTool(label: label, in: runtime, guardBody)
    }

    @discardableResult
    func promptSection(
        _ section: CordisPromptSection,
        in runtime: CordisSystemPromptRuntime
    ) async throws -> CordisEffectHandle {
        let pluginID = pluginID
        return try await effect("systemPrompt.section(\(section.name))") {
            let disposer = try await runtime.register(section, pluginID: pluginID)
            return Optional(disposer)
        }
    }

    @discardableResult
    func promptSection(_ section: CordisPromptSection) async throws -> CordisEffectHandle {
        let runtime = try await service(CordisAgentServiceKeys.systemPrompt)
        return try await promptSection(section, in: runtime)
    }

    @discardableResult
    func promptContext(
        _ contribution: CordisPromptContextContribution,
        in runtime: CordisSystemPromptRuntime
    ) async throws -> CordisEffectHandle {
        let pluginID = pluginID
        return try await effect("systemPrompt.context(\(contribution.name))") {
            let disposer = try await runtime.register(contribution, pluginID: pluginID)
            return Optional(disposer)
        }
    }

    @discardableResult
    func promptContext(
        _ contribution: CordisPromptContextContribution
    ) async throws -> CordisEffectHandle {
        let runtime = try await service(CordisAgentServiceKeys.systemPrompt)
        return try await promptContext(contribution, in: runtime)
    }

    @discardableResult
    func promptVariable(
        _ name: String,
        in runtime: CordisSystemPromptRuntime,
        provider: @escaping CordisPromptVariableProvider
    ) async throws -> CordisEffectHandle {
        let pluginID = pluginID
        return try await effect("systemPrompt.variable(\(name))") {
            let disposer = try await runtime.registerVariable(
                name: name,
                pluginID: pluginID,
                provider: provider
            )
            return Optional(disposer)
        }
    }

    @discardableResult
    func promptVariable(
        _ name: String,
        provider: @escaping CordisPromptVariableProvider
    ) async throws -> CordisEffectHandle {
        let runtime = try await service(CordisAgentServiceKeys.systemPrompt)
        return try await promptVariable(name, in: runtime, provider: provider)
    }
}
