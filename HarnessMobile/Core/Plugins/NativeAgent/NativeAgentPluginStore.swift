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
        return try document.plugins.map {
            try $0.validated(allowedBaseTools: allowedBaseTools)
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
