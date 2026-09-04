import Foundation

/// Host-compatible named Workspace registry. Files remain owned by
/// `WorkspaceStore`; this actor only persists directory identities, titles and
/// session grouping order used by the Desktop workspace controller.
struct LocalWorkspaceView: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let path: String
    var title: String
    var sessionIDs: [UUID]
    let createdAt: Date
    var updatedAt: Date
}

struct LocalWorkspaceRegistrySnapshot: Codable, Sendable, Equatable {
    let workspaces: [LocalWorkspaceView]
    let archivedSessionIDs: [UUID]
}

enum LocalWorkspaceRegistryError: LocalizedError, Sendable, Equatable {
    case invalidPath
    case notFound(UUID)
    case duplicateTitle
    case invalidTitle
    case invalidSession(UUID)

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "Workspace path must be an existing absolute directory."
        case let .notFound(id): return "Workspace not found: \(id.uuidString)"
        case .duplicateTitle: return "A Workspace already uses this title."
        case .invalidTitle: return "Workspace title must not be blank."
        case let .invalidSession(id): return "Session is not registered in this Workspace: \(id.uuidString)"
        }
    }
}

actor LocalWorkspaceRegistry {
    private let storageURL: URL
    private var workspaces: [LocalWorkspaceView] = []
    private var archivedSessionIDs: Set<UUID> = []
    private var didLoad = false

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("HarnessMobile", isDirectory: true)
            .appendingPathComponent("workspace-registry.json", isDirectory: false)
    }

    func snapshot() throws -> LocalWorkspaceRegistrySnapshot {
        try loadIfNeeded()
        return LocalWorkspaceRegistrySnapshot(
            workspaces: workspaces,
            archivedSessionIDs: archivedSessionIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    @discardableResult
    func ensureDefault(path: URL, title: String = "Workspace") throws -> LocalWorkspaceView {
        try loadIfNeeded()
        let normalized = try normalizedDirectory(path)
        if let existing = workspaces.first(where: { $0.path == normalized.path }) {
            return existing
        }
        return try create(path: normalized.path, title: title)
    }

    @discardableResult
    func create(path: String, title: String? = nil) throws -> LocalWorkspaceView {
        try loadIfNeeded()
        let url = try normalizedDirectory(URL(fileURLWithPath: path))
        // Desktop create is idempotent: resolving an already registered path
        // returns the existing Workspace without mutating its title/order.
        if let existing = workspaces.first(where: { $0.path == url.path }) {
            return existing
        }
        let normalizedTitle = try normalizedTitle(title ?? url.lastPathComponent)
        guard !workspaces.contains(where: { $0.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame }) else {
            throw LocalWorkspaceRegistryError.duplicateTitle
        }
        let now = Date.now
        let workspace = LocalWorkspaceView(
            id: UUID(),
            path: url.path,
            title: normalizedTitle,
            sessionIDs: [],
            createdAt: now,
            updatedAt: now
        )
        workspaces.append(workspace)
        try persist()
        return workspace
    }

    @discardableResult
    func rename(id: UUID, title: String) throws -> LocalWorkspaceView {
        try loadIfNeeded()
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw LocalWorkspaceRegistryError.notFound(id)
        }
        let normalized = try normalizedTitle(title)
        guard !workspaces.contains(where: {
            $0.id != id && $0.title.caseInsensitiveCompare(normalized) == .orderedSame
        }) else { throw LocalWorkspaceRegistryError.duplicateTitle }
        workspaces[index].title = normalized
        workspaces[index].updatedAt = .now
        try persist()
        return workspaces[index]
    }

    func delete(id: UUID) throws {
        try loadIfNeeded()
        guard workspaces.contains(where: { $0.id == id }) else {
            throw LocalWorkspaceRegistryError.notFound(id)
        }
        workspaces.removeAll { $0.id == id }
        try persist()
    }

    func insertBefore(id: UUID, beforeID: UUID? = nil) throws -> LocalWorkspaceRegistrySnapshot {
        try loadIfNeeded()
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
            throw LocalWorkspaceRegistryError.notFound(id)
        }
        let item = workspaces.remove(at: index)
        if let beforeID,
           let destination = workspaces.firstIndex(where: { $0.id == beforeID }) {
            workspaces.insert(item, at: destination)
        } else {
            workspaces.append(item)
        }
        try persist()
        return try snapshot()
    }

    func insertSessionBefore(
        workspaceID: UUID,
        sessionID: UUID,
        beforeSessionID: UUID? = nil
    ) throws -> LocalWorkspaceView {
        try loadIfNeeded()
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw LocalWorkspaceRegistryError.notFound(workspaceID)
        }
        var sessions = workspaces[index].sessionIDs.filter { $0 != sessionID }
        let knownSessionIDs = Set(workspaces.flatMap(\.sessionIDs))
        guard knownSessionIDs.isEmpty || knownSessionIDs.contains(sessionID) else {
            throw LocalWorkspaceRegistryError.invalidSession(sessionID)
        }
        if let beforeSessionID {
            guard let destination = sessions.firstIndex(of: beforeSessionID) else {
                throw LocalWorkspaceRegistryError.invalidSession(beforeSessionID)
            }
            sessions.insert(sessionID, at: destination)
        } else {
            sessions.append(sessionID)
        }
        workspaces[index].sessionIDs = sessions
        workspaces[index].updatedAt = .now
        try persist()
        return workspaces[index]
    }

    func archiveSession(_ sessionID: UUID) throws -> LocalWorkspaceRegistrySnapshot {
        try loadIfNeeded()
        let knownSessionIDs = Set(workspaces.flatMap(\.sessionIDs))
        guard knownSessionIDs.contains(sessionID) || archivedSessionIDs.contains(sessionID) else {
            throw LocalWorkspaceRegistryError.invalidSession(sessionID)
        }
        archivedSessionIDs.insert(sessionID)
        try persist()
        return try snapshot()
    }

    private func loadIfNeeded() throws {
        guard !didLoad else { return }
        didLoad = true
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL, options: [.mappedIfSafe])
            let snapshot = try JSONDecoder().decode(LocalWorkspaceRegistrySnapshot.self, from: data)
            workspaces = snapshot.workspaces
            archivedSessionIDs = Set(snapshot.archivedSessionIDs)
        } catch {
            workspaces = []
            archivedSessionIDs = []
            throw error
        }
    }

    private func persist() throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(LocalWorkspaceRegistrySnapshot(
            workspaces: workspaces,
            archivedSessionIDs: archivedSessionIDs.sorted { $0.uuidString < $1.uuidString }
        ))
        try data.write(to: storageURL, options: [.atomic])
    }

    private func normalizedDirectory(_ url: URL) throws -> URL {
        let normalized = url.standardizedFileURL
        guard normalized.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: normalized.path),
              (try? normalized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw LocalWorkspaceRegistryError.invalidPath
        }
        return normalized
    }

    private func normalizedTitle(_ title: String) throws -> String {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 256 else {
            throw LocalWorkspaceRegistryError.invalidTitle
        }
        return normalized
    }
}
