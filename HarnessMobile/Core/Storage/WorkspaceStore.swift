import Foundation

actor WorkspaceStore {
    struct FileEntry: Codable, Sendable, Equatable {
        let path: String
        let size: Int64
        let modifiedAt: Date?
    }

    enum MountAccess: String, Codable, Sendable, Equatable {
        case readOnly
        case readWrite

        var allowsWriting: Bool { self == .readWrite }
    }

    enum MountStatus: String, Sendable, Equatable {
        case active
        case staleBookmark
        case permissionDenied
        case unavailable
    }

    struct MountSnapshot: Identifiable, Sendable, Equatable {
        let id: UUID
        let name: String
        let sourceDisplayName: String
        let createdAt: Date
        let access: MountAccess
        let sourceWritable: Bool
        let status: MountStatus
        let failureMessage: String?

        var effectiveWritable: Bool {
            sourceWritable && access.allowsWriting && status == .active
        }

        var workspacePath: String {
            "mounts/\(name)"
        }

        var guestPath: String {
            "/workspace/\(workspacePath)"
        }
    }

    struct MountBinding: Sendable, Equatable {
        let id: UUID
        let name: String
        let hostURL: URL
        let readOnly: Bool

        var guestPath: String {
            "/workspace/mounts/\(name)"
        }
    }

    private struct MountRecord: Codable, Sendable, Equatable {
        let id: UUID
        var name: String
        let sourceDisplayName: String
        var bookmark: Data
        let createdAt: Date
        var sourceWritable: Bool
        var access: MountAccess
    }

    private struct MountActivation: Sendable, Equatable {
        let status: MountStatus
        let failureMessage: String?

        static let active = MountActivation(status: .active, failureMessage: nil)
    }

    /// A direct `SKILL.md` bundle or a flat Markdown skill found in one of the
    /// upstream-compatible workspace roots. Raw text stays local until the
    /// model explicitly invokes the `skill` tool.
    struct SkillDocument: Sendable, Equatable {
        let source: MobileSkillSource
        let path: String
        let directory: String
        let text: String
    }

    private let root: URL
    private let mountStoreURL: URL
    private let allowsUnscopedMounts: Bool
    private let fileManager = FileManager.default
    private let maximumReadableBytes = 1 * 1_024 * 1_024
    private let maximumWritableBytes = 256 * 1_024
    private let maximumImageBytes = 64 * 1_024 * 1_024
    private let maximumPluginArchiveBytes = 64 * 1_024 * 1_024
    private let maximumSkillBytes = 64 * 1_024
    private let maximumListedFiles = 200
    private var mountRecords: [MountRecord] = []
    private var activeMountURLs: [UUID: URL] = [:]
    private var activeMountScopes: Set<UUID> = []
    private var mountActivations: [UUID: MountActivation] = [:]
    private var didLoadMounts = false

    private static var protectedWritingOptions: Data.WritingOptions {
#if os(iOS)
        [.atomic, .completeFileProtection]
#else
        []
#endif
    }

    init(
        root: URL? = nil,
        mountStoreURL: URL? = nil,
        allowsUnscopedMounts: Bool = false
    ) {
        if let root {
            self.root = root.standardizedFileURL
            self.mountStoreURL = mountStoreURL
                ?? root
                    .appendingPathComponent(".harness-mobile", isDirectory: true)
                    .appendingPathComponent("workspace-mounts.json", isDirectory: false)
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
                .appendingPathComponent("HarnessMobile", isDirectory: true)
            self.root = base
                .appendingPathComponent("Workspace", isDirectory: true)
            self.mountStoreURL = mountStoreURL
                ?? base
                    .appendingPathComponent("Configuration", isDirectory: true)
                    .appendingPathComponent("workspace-mounts.json", isDirectory: false)
        }
        self.allowsUnscopedMounts = allowsUnscopedMounts
    }

    func activateMounts(forceRefresh: Bool = false) throws -> [MountSnapshot] {
        try ensureRoot()
        try loadMountsIfNeeded()
        for record in mountRecords {
            if forceRefresh {
                deactivateMount(id: record.id)
            }
            if activeMountURLs[record.id] == nil {
                activateMount(record)
            }
        }
        return mountSnapshots()
    }

    func mountedFolders() throws -> [MountSnapshot] {
        try activateMounts()
    }

    func activeMountBindings() throws -> [MountBinding] {
        _ = try activateMounts()
        return mountRecords.compactMap { record in
            guard let url = activeMountURLs[record.id],
                  mountActivations[record.id]?.status == .active else {
                return nil
            }
            return MountBinding(
                id: record.id,
                name: record.name,
                hostURL: url,
                readOnly: !(record.sourceWritable && record.access.allowsWriting)
            )
        }
    }

    @discardableResult
    func mountFolder(
        from pickedURL: URL,
        preferredName: String? = nil,
        access: MountAccess = .readWrite
    ) throws -> MountSnapshot {
        try ensureRoot()
        try loadMountsIfNeeded()
        guard mountRecords.count < Self.maximumMountCount else {
            throw WorkspaceError.mountLimitReached(Self.maximumMountCount)
        }

        let startedHere = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if startedHere {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try pickedURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkspaceError.notADirectory
        }

        let requestedName = preferredName ?? pickedURL.lastPathComponent
        let name = uniqueMountName(from: requestedName)
        let bookmark: Data
        do {
            bookmark = try pickedURL.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw WorkspaceError.bookmarkCreationFailed(error.localizedDescription)
        }

        let record = MountRecord(
            id: UUID(),
            name: name,
            sourceDisplayName: Self.humanReadableSourceName(for: pickedURL),
            bookmark: bookmark,
            createdAt: .now,
            sourceWritable: Self.probeWritable(at: pickedURL),
            access: access
        )
        mountRecords.append(record)
        try ensureMountPlaceholder(named: name)
        try saveMounts()
        activateMount(record)
        return snapshot(for: record)
    }

    @discardableResult
    func reauthorizeMount(id: UUID, with pickedURL: URL) throws -> MountSnapshot {
        try loadMountsIfNeeded()
        guard let index = mountRecords.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.mountNotFound
        }
        let startedHere = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if startedHere {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try pickedURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw WorkspaceError.notADirectory
        }
        do {
            mountRecords[index].bookmark = try pickedURL.bookmarkData(
                options: Self.bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw WorkspaceError.bookmarkCreationFailed(error.localizedDescription)
        }
        mountRecords[index].sourceWritable = Self.probeWritable(at: pickedURL)
        deactivateMount(id: id)
        try saveMounts()
        activateMount(mountRecords[index])
        return snapshot(for: mountRecords[index])
    }

    @discardableResult
    func setMountAccess(id: UUID, access: MountAccess) throws -> MountSnapshot {
        try loadMountsIfNeeded()
        guard let index = mountRecords.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.mountNotFound
        }
        mountRecords[index].access = access
        try saveMounts()
        return snapshot(for: mountRecords[index])
    }

    func removeMount(id: UUID) throws {
        try loadMountsIfNeeded()
        guard let index = mountRecords.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.mountNotFound
        }
        let record = mountRecords.remove(at: index)
        deactivateMount(id: id)
        mountActivations.removeValue(forKey: id)
        try saveMounts()
        let placeholder = root
            .appendingPathComponent("mounts", isDirectory: true)
            .appendingPathComponent(record.name, isDirectory: true)
        if (try? fileManager.contentsOfDirectory(atPath: placeholder.path).isEmpty) == true {
            try? fileManager.removeItem(at: placeholder)
        }
    }

    func listFiles() throws -> [FileEntry] {
        try ensureRoot()
        var result: [FileEntry] = []
        try appendFiles(
            at: root,
            pathPrefix: "",
            skippingTopLevel: ["Attachments", "mounts"],
            to: &result
        )
        if result.count < maximumListedFiles {
            _ = try activateMounts()
            for record in mountRecords {
                guard let mountURL = activeMountURLs[record.id],
                      mountActivations[record.id]?.status == .active else {
                    continue
                }
                try appendFiles(
                    at: mountURL,
                    pathPrefix: "mounts/\(record.name)",
                    skippingTopLevel: [],
                    to: &result
                )
                if result.count >= maximumListedFiles {
                    break
                }
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func skillDocuments() throws -> [SkillDocument] {
        try ensureRoot()
        let roots: [(path: String, source: MobileSkillSource)] = [
            (".dsh/skills", .projectDSH),
            (".agents/skills", .projectAgents),
            ("Skills", .custom)
        ]
        var result: [SkillDocument] = []

        for root in roots {
            let rootURL = try containedURL(for: root.path, write: false)
            guard fileManager.fileExists(atPath: rootURL.path) else { continue }
            let rootValues = try rootURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
                continue
            }

            let entries = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ],
                options: [.skipsPackageDescendants]
            )
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    let skillURL = entry.appendingPathComponent("SKILL.md", isDirectory: false)
                    if let document = try skillDocument(
                        at: skillURL,
                        rootURL: rootURL,
                        source: root.source
                    ) {
                        result.append(document)
                    }
                } else if values.isRegularFile == true,
                          entry.pathExtension.lowercased() == "md",
                          let document = try skillDocument(
                              at: entry,
                              rootURL: rootURL,
                              source: root.source
                          ) {
                    result.append(document)
                }
            }
        }
        return result
    }

    func readText(path: String) throws -> String {
        let resolvedPath = try resolvedWorkspacePath(for: path, write: false)
        let url = resolvedPath.url
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw WorkspaceError.notAFile
        }
        guard let size = values.fileSize, size <= maximumReadableBytes else {
            throw WorkspaceError.fileTooLarge(maximumReadableBytes)
        }
        let data: Data
        if resolvedPath.isExternalMount {
            data = try coordinatedRead(at: url)
        } else {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.notUTF8
        }
        return text
    }

    func writeText(path: String, text: String) throws {
        try ensureRoot()
        let data = Data(text.utf8)
        guard data.count <= maximumWritableBytes else {
            throw WorkspaceError.fileTooLarge(maximumWritableBytes)
        }
        let resolvedPath = try resolvedWorkspacePath(for: path, write: true)
        let url = resolvedPath.url
        guard Self.allowedTextExtensions.contains(url.pathExtension.lowercased()) else {
            throw WorkspaceError.unsupportedFileType
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let revalidatedPath = try resolvedWorkspacePath(for: path, write: true)
        if revalidatedPath.isExternalMount {
            try coordinatedWrite(data, to: revalidatedPath.url)
        } else {
            try data.write(to: revalidatedPath.url, options: Self.protectedWritingOptions)
        }
    }

    @discardableResult
    func importFile(from externalURL: URL) throws -> FileEntry {
        try ensureRoot()
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues = try externalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw WorkspaceError.notAFile
        }
        guard let size = sourceValues.fileSize, size <= maximumReadableBytes else {
            throw WorkspaceError.fileTooLarge(maximumReadableBytes)
        }

        let safeName = Self.sanitizedFilename(externalURL.lastPathComponent)
        let destination = try uniqueDestination(for: safeName)
        try fileManager.copyItem(at: externalURL, to: destination)
        let resolvedDestination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(resolvedDestination, in: root.resolvingSymlinksInPath()) else {
            try? fileManager.removeItem(at: destination)
            throw WorkspaceError.pathEscapesWorkspace
        }
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
#endif
        return FileEntry(
            path: destination.lastPathComponent,
            size: Int64(size),
            modifiedAt: .now
        )
    }

    func stagePluginArchive(from externalURL: URL) throws -> String {
        try ensureRoot()
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                externalURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceValues = try externalURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true else {
            throw WorkspaceError.notAFile
        }
        guard let size = sourceValues.fileSize,
              size > 0,
              size <= maximumPluginArchiveBytes else {
            throw WorkspaceError.fileTooLarge(maximumPluginArchiveBytes)
        }

        let file = try FileHandle(forReadingFrom: externalURL)
        defer { try? file.close() }
        let signature = try file.read(upToCount: 4) ?? Data()
        guard signature.starts(with: [0x50, 0x4B]) else {
            throw WorkspaceError.unsupportedFileType
        }

        let imports = root
            .appendingPathComponent(".harness-mobile", isDirectory: true)
            .appendingPathComponent("plugin-imports", isDirectory: true)
        try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString.lowercased()).zip"
        let destination = imports.appendingPathComponent(filename)
        try fileManager.copyItem(at: externalURL, to: destination)
#if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: destination.path
        )
#endif
        return "/workspace/.harness-mobile/plugin-imports/\(filename)"
    }

    func removeStagedPluginArchive(guestPath: String) throws {
        let prefix = "/workspace/.harness-mobile/plugin-imports/"
        guard guestPath.hasPrefix(prefix) else {
            throw WorkspaceError.invalidPath
        }
        let filename = String(guestPath.dropFirst(prefix.count))
        guard !filename.isEmpty,
              !filename.contains("/"),
              filename.hasSuffix(".zip") else {
            throw WorkspaceError.invalidPath
        }
        let destination = root
            .appendingPathComponent(".harness-mobile", isDirectory: true)
            .appendingPathComponent("plugin-imports", isDirectory: true)
            .appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
    }

    func stageImage(_ data: Data) throws {
        try ensureRoot()
        guard data.count <= maximumImageBytes else {
            throw WorkspaceError.fileTooLarge(maximumImageBytes)
        }
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        try data.write(
            to: attachments.appendingPathComponent("latest-image.data"),
            options: Self.protectedWritingOptions
        )
    }

    func latestImageData() throws -> Data {
        let url = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("latest-image.data")
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceError.noStagedImage
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= maximumImageBytes else {
            throw WorkspaceError.fileTooLarge(maximumImageBytes)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func hasStagedImage() -> Bool {
        let url = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("latest-image.data")
        return fileManager.fileExists(atPath: url.path)
    }

    func rootURL() throws -> URL {
        try ensureRoot()
        return root
    }

    private struct ResolvedWorkspacePath {
        let url: URL
        let isExternalMount: Bool
    }

    private func mountSnapshots() -> [MountSnapshot] {
        mountRecords
            .map(snapshot(for:))
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func snapshot(for record: MountRecord) -> MountSnapshot {
        let activation = mountActivations[record.id]
            ?? MountActivation(status: .unavailable, failureMessage: "挂载尚未激活。")
        return MountSnapshot(
            id: record.id,
            name: record.name,
            sourceDisplayName: record.sourceDisplayName,
            createdAt: record.createdAt,
            access: record.access,
            sourceWritable: record.sourceWritable,
            status: activation.status,
            failureMessage: activation.failureMessage
        )
    }

    private func loadMountsIfNeeded() throws {
        guard !didLoadMounts else { return }
        didLoadMounts = true
        guard fileManager.fileExists(atPath: mountStoreURL.path) else { return }
        do {
            let data = try Data(contentsOf: mountStoreURL, options: [.mappedIfSafe])
            mountRecords = try JSONDecoder().decode([MountRecord].self, from: data)
            for record in mountRecords {
                try ensureMountPlaceholder(named: record.name)
            }
        } catch {
            didLoadMounts = false
            throw WorkspaceError.mountStoreCorrupted(error.localizedDescription)
        }
    }

    private func saveMounts() throws {
        try fileManager.createDirectory(
            at: mountStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(mountRecords)
        try data.write(to: mountStoreURL, options: Self.protectedWritingOptions)
    }

    private func activateMount(_ record: MountRecord) {
        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: record.bookmark,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            mountActivations[record.id] = MountActivation(
                status: .unavailable,
                failureMessage: error.localizedDescription
            )
            return
        }

        let startedScope = resolvedURL.startAccessingSecurityScopedResource()
        guard startedScope || allowsUnscopedMounts else {
            mountActivations[record.id] = MountActivation(
                status: .permissionDenied,
                failureMessage: "iOS 已撤销这个文件夹的访问权限，请重新授权。"
            )
            return
        }

        let values: URLResourceValues
        do {
            values = try resolvedURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            if startedScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
            mountActivations[record.id] = MountActivation(
                status: .unavailable,
                failureMessage: error.localizedDescription
            )
            return
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            if startedScope {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
            mountActivations[record.id] = MountActivation(
                status: .unavailable,
                failureMessage: "原位置不再是可访问的文件夹。"
            )
            return
        }

        activeMountURLs[record.id] = resolvedURL.standardizedFileURL
        if startedScope {
            activeMountScopes.insert(record.id)
        }
        mountActivations[record.id] = isStale
            ? MountActivation(status: .staleBookmark, failureMessage: "书签已过期，正在尝试刷新。")
            : .active

        if isStale {
            do {
                let refreshed = try resolvedURL.bookmarkData(
                    options: Self.bookmarkCreationOptions,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                if let index = mountRecords.firstIndex(where: { $0.id == record.id }) {
                    mountRecords[index].bookmark = refreshed
                    try saveMounts()
                    mountActivations[record.id] = .active
                }
            } catch {
                mountActivations[record.id] = MountActivation(
                    status: .staleBookmark,
                    failureMessage: "书签已过期，请重新选择这个文件夹。"
                )
            }
        }
    }

    private func deactivateMount(id: UUID) {
        if activeMountScopes.remove(id) != nil,
           let url = activeMountURLs[id] {
            url.stopAccessingSecurityScopedResource()
        }
        activeMountURLs.removeValue(forKey: id)
    }

    private func resolvedWorkspacePath(
        for relativePath: String,
        write: Bool
    ) throws -> ResolvedWorkspacePath {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !components.contains("..") else {
            throw WorkspaceError.invalidPath
        }

        if components.first == "mounts" {
            guard components.count >= 2 else {
                throw WorkspaceError.mountNotFound
            }
            _ = try activateMounts()
            let name = String(components[1])
            guard let record = mountRecords.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }), let mountRoot = activeMountURLs[record.id],
                  mountActivations[record.id]?.status == .active else {
                throw WorkspaceError.mountUnavailable(name)
            }
            if write, !(record.sourceWritable && record.access.allowsWriting) {
                throw WorkspaceError.mountReadOnly(name)
            }
            let descendant = components.dropFirst(2).map(String.init)
            var candidate = mountRoot
            for component in descendant {
                candidate.appendPathComponent(component)
            }
            candidate = candidate.standardizedFileURL
            guard Self.isContained(candidate, in: mountRoot) else {
                throw WorkspaceError.pathEscapesWorkspace
            }
            try rejectSymlinkComponents(in: candidate, rootedAt: mountRoot)
            try validateExistingBoundary(
                for: candidate,
                root: mountRoot,
                write: write
            )
            return ResolvedWorkspacePath(url: candidate, isExternalMount: true)
        }

        return ResolvedWorkspacePath(
            url: try containedURL(for: trimmed, write: write),
            isExternalMount: false
        )
    }

    private func appendFiles(
        at enumerationRoot: URL,
        pathPrefix: String,
        skippingTopLevel: Set<String>,
        to result: inout [FileEntry]
    ) throws {
        let rootURL = enumerationRoot.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            if result.count >= maximumListedFiles {
                break
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolved, in: rootURL) else {
                enumerator.skipDescendants()
                continue
            }
            let relative = String(resolved.path.dropFirst(rootURL.path.count + 1))
            let topLevel = relative.split(separator: "/", maxSplits: 1).first.map(String.init)
            if let topLevel, skippingTopLevel.contains(topLevel) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey
                ]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let presentedPath = pathPrefix.isEmpty
                ? relative
                : "\(pathPrefix)/\(relative)"
            result.append(
                FileEntry(
                    path: presentedPath,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            )
        }
    }

    private func coordinatedRead(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [.withoutChanges],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw WorkspaceError.notAFile
        }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try data.write(to: coordinatedURL, options: [.atomic])
            }
        }
        if let coordinationError {
            throw coordinationError
        }
        guard let result else {
            throw WorkspaceError.notAFile
        }
        try result.get()
    }

    private func containedURL(for relativePath: String, write: Bool) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains("..") else {
            throw WorkspaceError.invalidPath
        }

        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        guard Self.isContained(candidate, in: root) else {
            throw WorkspaceError.pathEscapesWorkspace
        }
        try rejectSymlinkComponents(in: candidate, rootedAt: root)
        try validateExistingBoundary(for: candidate, root: root, write: write)
        return candidate
    }

    private func skillDocument(
        at url: URL,
        rootURL: URL,
        source: MobileSkillSource
    ) throws -> SkillDocument? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(resolved, in: root.resolvingSymlinksInPath()) else {
            return nil
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= maximumSkillBytes else {
            return nil
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let workspaceRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let path = String(resolved.path.dropFirst(workspaceRoot.path.count + 1))
        let directoryURL = url.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let directory = String(directoryURL.path.dropFirst(workspaceRoot.path.count + 1))
        return SkillDocument(source: source, path: path, directory: directory, text: text)
    }

    private func rejectSymlinkComponents(in candidate: URL, rootedAt boundary: URL) throws {
        let rootPath = boundary.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw WorkspaceError.pathEscapesWorkspace
        }

        let relative = candidatePath.dropFirst(rootPath.count)
        var cursor = boundary
        for component in relative.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            guard fileManager.fileExists(atPath: cursor.path) else {
                break
            }
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw WorkspaceError.pathEscapesWorkspace
            }
        }
    }

    private func validateExistingBoundary(
        for candidate: URL,
        root boundary: URL,
        write: Bool
    ) throws {
        var existingBoundary = write ? candidate.deletingLastPathComponent() : candidate
        while !fileManager.fileExists(atPath: existingBoundary.path),
              existingBoundary.path != boundary.path {
            existingBoundary.deleteLastPathComponent()
        }
        let resolved = existingBoundary.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(resolved, in: boundary.resolvingSymlinksInPath()) else {
            throw WorkspaceError.pathEscapesWorkspace
        }
    }

    private func uniqueDestination(for filename: String) throws -> URL {
        let base = root.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: base.path) {
            return base
        }

        let extensionName = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        for index in 2...999 {
            let candidateName = extensionName.isEmpty
                ? "\(stem)-\(index)"
                : "\(stem)-\(index).\(extensionName)"
            let candidate = root.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw WorkspaceError.tooManyConflicts
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("mounts", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func ensureMountPlaceholder(named name: String) throws {
        try fileManager.createDirectory(
            at: root
                .appendingPathComponent("mounts", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    private static func sanitizedFilename(_ raw: String) -> String {
        let disallowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._- "))
            .inverted
        let cleaned = raw.components(separatedBy: disallowed).joined(separator: "_")
        return cleaned.isEmpty ? "Imported.txt" : String(cleaned.prefix(120))
    }

    private func uniqueMountName(from raw: String) -> String {
        let base = Self.sanitizedMountName(raw)
        let existing = Set(mountRecords.map { $0.name.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        for index in 2...999 {
            let suffix = "-\(index)"
            let prefixLimit = max(1, 64 - suffix.count)
            let candidate = String(base.prefix(prefixLimit)) + suffix
            if !existing.contains(candidate.lowercased()) {
                return candidate
            }
        }
        return "mount-\(UUID().uuidString.lowercased().prefix(8))"
    }

    private static func sanitizedMountName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let disallowed = CharacterSet(charactersIn: "/:\0")
            .union(.newlines)
        let cleaned = trimmed.components(separatedBy: disallowed).joined(separator: "-")
        let normalized = cleaned == "." || cleaned == ".." ? "mounted-folder" : cleaned
        return normalized.isEmpty ? "mounted-folder" : String(normalized.prefix(64))
    }

    private static func humanReadableSourceName(for url: URL) -> String {
        let components = url.pathComponents
        if let index = components.lastIndex(where: { $0.hasPrefix("iCloud~") }) {
            let container = components[index]
            let appName = container.split(separator: "~").last.map(String.init) ?? container
            let tail = components.dropFirst(index + 1).joined(separator: " › ")
            return tail.isEmpty ? appName : "\(appName) › \(tail)"
        }
        return url.lastPathComponent
    }

    private static func probeWritable(at url: URL) -> Bool {
        let probe = url.appendingPathComponent(".harness-mobile-probe-\(UUID().uuidString)")
        var coordinationError: NSError?
        var succeeded = false
        NSFileCoordinator().coordinate(
            writingItemAt: probe,
            options: [.forReplacing],
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try Data().write(to: coordinatedURL, options: [.atomic])
                succeeded = true
                try? FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                succeeded = false
            }
        }
        return coordinationError == nil && succeeded
    }

    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
#if os(macOS)
        [.withSecurityScope]
#else
        []
#endif
    }

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
#if os(macOS)
        [.withSecurityScope]
#else
        []
#endif
    }

    private static let maximumMountCount = 10

    private static let allowedTextExtensions: Set<String> = [
        "txt", "md", "json", "csv", "yaml", "yml", "xml", "log"
    ]
}

enum WorkspaceError: LocalizedError, Sendable {
    case invalidPath
    case pathEscapesWorkspace
    case notAFile
    case notADirectory
    case fileTooLarge(Int)
    case notUTF8
    case unsupportedFileType
    case noStagedImage
    case tooManyConflicts
    case mountLimitReached(Int)
    case mountNotFound
    case mountUnavailable(String)
    case mountReadOnly(String)
    case bookmarkCreationFailed(String)
    case mountStoreCorrupted(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "文件路径无效。"
        case .pathEscapesWorkspace:
            return "文件路径超出 App 本地工作区。"
        case .notAFile:
            return "目标不是普通文件。"
        case .notADirectory:
            return "目标不是可挂载的文件夹。"
        case let .fileTooLarge(limit):
            return "文件超过本地工具上限（\(limit) 字节）。"
        case .notUTF8:
            return "当前版本只读取 UTF-8 文本文件。"
        case .unsupportedFileType:
            return "当前版本只允许写入文本类文件。"
        case .noStagedImage:
            return "请先在对话页拍照或选择一张图片。"
        case .tooManyConflicts:
            return "同名导入文件过多。"
        case let .mountLimitReached(limit):
            return "最多可同时挂载 \(limit) 个外部文件夹。"
        case .mountNotFound:
            return "找不到这个工作区挂载。"
        case let .mountUnavailable(name):
            return "挂载“\(name)”当前不可用，请在文件页重新授权。"
        case let .mountReadOnly(name):
            return "挂载“\(name)”是只读的，不能修改其中的文件。"
        case let .bookmarkCreationFailed(message):
            return "无法保存文件夹授权：\(message)"
        case let .mountStoreCorrupted(message):
            return "工作区挂载记录损坏：\(message)"
        }
    }
}
