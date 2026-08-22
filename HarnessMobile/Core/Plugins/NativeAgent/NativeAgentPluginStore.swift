import Foundation

actor NativeAgentPluginStore {
    private struct Document: Codable {
        let schemaVersion: Int
        var plugins: [NativeAgentCompiledPlugin]
    }

    private let fileURL: URL
    private let fileManager = FileManager.default

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.fileURL = base
                .appendingPathComponent("HarnessMobile", isDirectory: true)
                .appendingPathComponent("native-agent-plugins.json")
        }
    }

    func load(allowedBaseTools: Set<String>) throws -> [NativeAgentCompiledPlugin] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw NativeAgentPluginError.invalidCompiledPlugin("插件注册表过大。")
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1 else {
            throw NativeAgentPluginError.invalidCompiledPlugin("插件注册表版本不兼容。")
        }
        // A single stale compiled plugin must not hide every other plugin.
        // Keep valid entries and let the AppModel disable entries that fail
        // during runtime registration. Mutating operations will naturally
        // rewrite the registry with the surviving entries.
        return document.plugins.compactMap { plugin in
            try? plugin.validated(allowedBaseTools: allowedBaseTools)
        }
    }

    func upsert(
        _ plugin: NativeAgentCompiledPlugin,
        replace: Bool,
        allowedBaseTools: Set<String>
    ) throws -> [NativeAgentCompiledPlugin] {
        let plugin = try plugin.validated(allowedBaseTools: allowedBaseTools)
        var plugins = try load(allowedBaseTools: allowedBaseTools)
        if let index = plugins.firstIndex(where: { $0.id == plugin.id }) {
            guard replace else { throw NativeAgentPluginError.alreadyInstalled(plugin.id) }
            plugins[index] = plugin
        } else {
            plugins.append(plugin)
        }
        try save(plugins)
        return plugins.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setEnabled(
        id: String,
        enabled: Bool,
        allowedBaseTools: Set<String>
    ) throws -> [NativeAgentCompiledPlugin] {
        var plugins = try load(allowedBaseTools: allowedBaseTools)
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw NativeAgentPluginError.notFound(id)
        }
        plugins[index].enabled = enabled
        try save(plugins)
        return plugins
    }

    func setSettings(
        id: String,
        values: JSONValue,
        allowedBaseTools: Set<String>
    ) throws -> [NativeAgentCompiledPlugin] {
        var plugins = try load(allowedBaseTools: allowedBaseTools)
        guard let index = plugins.firstIndex(where: { $0.id == id }) else {
            throw NativeAgentPluginError.notFound(id)
        }
        guard var settings = plugins[index].settings else {
            throw NativeAgentPluginError.invalidCompiledPlugin("这个插件没有可编辑设置。")
        }
        try NativeAgentJSONSchemaValidator.validate(value: values, schema: settings.schema)
        try ISHPluginHostCredentialFirewall.validate(values)
        settings.values = values
        plugins[index].settings = settings
        plugins[index] = try plugins[index].validated(allowedBaseTools: allowedBaseTools)
        try save(plugins)
        return plugins
    }

    func remove(
        id: String,
        allowedBaseTools: Set<String>
    ) throws -> [NativeAgentCompiledPlugin] {
        var plugins = try load(allowedBaseTools: allowedBaseTools)
        guard plugins.contains(where: { $0.id == id }) else {
            throw NativeAgentPluginError.notFound(id)
        }
        plugins.removeAll { $0.id == id }
        try save(plugins)
        return plugins
    }

    func reset() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func save(_ plugins: [NativeAgentCompiledPlugin]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(Document(schemaVersion: 1, plugins: plugins))
        guard data.count <= 2 * 1_024 * 1_024 else {
            throw NativeAgentPluginError.invalidCompiledPlugin("插件注册表过大。")
        }
#if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: fileURL, options: [.atomic])
#endif
    }
}
