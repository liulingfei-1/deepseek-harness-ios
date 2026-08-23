@preconcurrency import ImageIO
import Foundation
import UniformTypeIdentifiers

struct WorkspaceAdmittedImage: Sendable, Equatable {
    let reference: AgentImageAttachmentRef
    let width: Int
    let height: Int
    let originalWidth: Int?
    let originalHeight: Int?
}

enum ImageAdmissionError: LocalizedError, Sendable, Equatable {
    case empty
    case inputTooLarge(Int)
    case tooManyPixels(Int)
    case dimensionTooLarge(Int)
    case invalidImage
    case unsupportedImageType
    case typeMismatch(expected: String, actual: String)
    case outputTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            "图片内容为空。"
        case let .inputTooLarge(limit):
            "原始图片超过本地准入上限（\(limit) 字节）。"
        case let .tooManyPixels(limit):
            "图片解码尺寸超过本地准入上限（\(limit) 像素）。"
        case let .dimensionTooLarge(limit):
            "图片单边尺寸超过本地准入上限（\(limit) 像素）。"
        case .invalidImage:
            "图片无法完整解码。"
        case .unsupportedImageType:
            "图片格式不受支持。"
        case let .typeMismatch(expected, actual):
            "图片扩展名声明为 \(expected)，但实际内容是 \(actual)。"
        case let .outputTooLarge(limit):
            "图片压缩后仍超过模型附件上限（\(limit) 字节）。"
        }
    }
}

actor WorkspaceStore {
    static let maximumModelRequestImageBytes = 1 * 1_024 * 1_024
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
    private let maximumImageBytes = ImageAttachmentAdmission.maximumInputBytes
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
        do {
            try saveMounts()
        } catch {
            mountRecords.removeAll { $0.id == record.id }
            throw error
        }
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
        _ = mountRecords.remove(at: index)
        deactivateMount(id: id)
        mountActivations.removeValue(forKey: id)
        try saveMounts()
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

    /// Reads one workspace file for native export/share. This supports both
    /// bounded UTF-8 text and binary files; Agent text tools keep using
    /// `readText` and preserve their UTF-8 contract.
    func readData(path: String) throws -> Data {
        let resolvedPath = try resolvedWorkspacePath(for: path, write: false)
        let url = resolvedPath.url
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw WorkspaceError.notAFile
        }
        guard let size = values.fileSize, size <= maximumReadableBytes else {
            throw WorkspaceError.fileTooLarge(maximumReadableBytes)
        }
        if resolvedPath.isExternalMount {
            return try coordinatedRead(at: url)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
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

    func stageImage(_ data: Data) throws -> AgentImageAttachmentRef {
        try stageImageWithMetadata(data).reference
    }

    /// Runs one shared image-admission path for camera/photo input and
    /// model-requested workspace images. The stored object is normalized,
    /// fully decoded, bounded, and therefore safe to resolve later through the
    /// existing `AgentImageAttachmentRef` request path.
    func stageImageWithMetadata(
        _ data: Data,
        declaredMimeType: String? = nil
    ) throws -> WorkspaceAdmittedImage {
        try ensureRoot()
        let admitted = try ImageAttachmentAdmission.admit(
            data,
            declaredMimeType: declaredMimeType
        )
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        let id = UUID()
        let filename = "\(id.uuidString.lowercased()).\(admitted.filenameExtension)"
        let destination = attachments.appendingPathComponent(filename)
        try admitted.data.write(
            to: destination,
            options: Self.protectedWritingOptions
        )
        // Keep the legacy latest-image path for existing OCR/UI callers while
        // durable messages point at immutable UUID-named files.
        try admitted.data.write(
            to: attachments.appendingPathComponent("latest-image.data"),
            options: Self.protectedWritingOptions
        )
        let ref = AgentImageAttachmentRef(
            id: id,
            path: "Attachments/\(filename)",
            mimeType: admitted.mimeType,
            byteCount: admitted.data.count
        )
        let metadata = try JSONEncoder().encode(ref)
        try metadata.write(
            to: attachments.appendingPathComponent("latest-image.ref"),
            options: Self.protectedWritingOptions
        )
        return WorkspaceAdmittedImage(
            reference: ref,
            width: admitted.width,
            height: admitted.height,
            originalWidth: admitted.originalWidth,
            originalHeight: admitted.originalHeight
        )
    }

    func latestImageReference() throws -> AgentImageAttachmentRef {
        let url = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("latest-image.ref")
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceError.noStagedImage
        }
        return try JSONDecoder().decode(
            AgentImageAttachmentRef.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe])
        )
    }

    func readAttachment(_ ref: AgentImageAttachmentRef) throws -> Data {
        try ensureRoot()
        guard ref.path.hasPrefix("Attachments/"),
              !ref.path.contains(".."),
              !ref.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkspaceError.invalidPath
        }
        let url = root.appendingPathComponent(ref.path)
        guard fileManager.fileExists(atPath: url.path) else {
            throw WorkspaceError.noStagedImage
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= maximumImageBytes else {
            throw WorkspaceError.fileTooLarge(maximumImageBytes)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Returns the deterministic provider-request variant for an immutable
    /// attachment. Durable history keeps the higher-quality admitted object;
    /// requests reuse this bounded derivative so an image that was valid to
    /// store cannot later exceed the provider body budget.
    func readAttachmentForModelRequest(_ ref: AgentImageAttachmentRef) throws -> Data {
        let original = try readAttachment(ref)
        guard original.count > Self.maximumModelRequestImageBytes else { return original }

        let requestVariants = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent("RequestVariants", isDirectory: true)
        try fileManager.createDirectory(
            at: requestVariants,
            withIntermediateDirectories: true
        )
        let filenameExtension = ref.mimeType == "image/png" ? "png" : "jpg"
        let variantURL = requestVariants.appendingPathComponent(
            "\(ref.id.uuidString.lowercased())-request-v1.\(filenameExtension)"
        )
        if fileManager.fileExists(atPath: variantURL.path) {
            let values = try variantURL.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize,
               size > 0,
               size <= Self.maximumModelRequestImageBytes {
                return try Data(contentsOf: variantURL, options: [.mappedIfSafe])
            }
        }

        let admitted = try ImageAttachmentAdmission.admit(
            original,
            declaredMimeType: ref.mimeType,
            maximumOutputBytes: Self.maximumModelRequestImageBytes
        )
        try admitted.data.write(to: variantURL, options: Self.protectedWritingOptions)
        return admitted.data
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

    func fileSystemResolve(path: String, cwd: String?) throws -> HarnessFsTarget {
        try ensureRoot()
        let normalized = try normalizedWorkspacePath(path, cwd: cwd)
        let canonical = try canonicalFileSystemPath(normalized)
        _ = try resolvedFileSystemPath(for: canonical, write: false)
        return HarnessFsTarget(
            targetKey: "workspace:\(canonical)",
            displayPath: canonical.isEmpty ? "/workspace" : "/workspace/\(canonical)",
            workspacePath: canonical
        )
    }

    func fileSystemStat(target: HarnessFsTarget) throws -> HarnessFsInfo? {
        try ensureRoot()
        let resolved = try resolvedFileSystemPath(for: target.workspacePath, write: false)
        return try Self.fileSystemInfo(at: resolved.url)
    }

    func fileSystemLStat(path: String, cwd: String?) throws -> HarnessFsPathInfo? {
        try ensureRoot()
        let normalized = try normalizedWorkspacePath(path, cwd: cwd)
        if normalized.isEmpty {
            guard let info = try Self.fileSystemInfo(at: root) else { return nil }
            return HarnessFsPathInfo(
                version: info.version,
                type: .directory,
                size: info.size
            )
        }

        let components = normalized.split(separator: "/").map(String.init)
        let parentPath = components.dropLast().joined(separator: "/")
        let parent = try resolvedFileSystemPath(for: parentPath, write: false)
        let candidate = parent.url
            .appendingPathComponent(components.last ?? "")
            .standardizedFileURL
        let parentBoundary = parent.url.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isContained(candidate, in: parent.url),
              Self.isContained(
                candidate.deletingLastPathComponent().resolvingSymlinksInPath(),
                in: parentBoundary
              ) else {
            throw WorkspaceError.pathEscapesWorkspace
        }
        guard fileManager.fileExists(atPath: candidate.path)
                || (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
            return nil
        }
        let values = try candidate.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        let type: HarnessFsPathEntryType
        if values.isSymbolicLink == true {
            type = .symlink
        } else if values.isRegularFile == true {
            type = .file
        } else if values.isDirectory == true {
            type = .directory
        } else {
            type = .other
        }
        return HarnessFsPathInfo(
            version: Self.fileSystemVersion(for: values, type: type.rawValue),
            type: type,
            size: values.fileSize.map(Int64.init)
        )
    }

    func fileSystemReadText(
        target: HarnessFsTarget,
        maximumBytes: Int
    ) throws -> String {
        let data = try fileSystemReadData(target: target, maximumBytes: maximumBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HarnessFsError(
                code: .notText,
                message: "cannot read \"\(target.displayPath)\": not UTF-8 text"
            )
        }
        guard !text.contains("\0") else {
            throw HarnessFsError(
                code: .notText,
                message: "cannot read \"\(target.displayPath)\": binary file"
            )
        }
        return Self.normalizedLineEndings(text)
    }

    func fileSystemStreamText(
        target: HarnessFsTarget
    ) throws -> AsyncThrowingStream<String, Error> {
        let resolved = try resolvedFileSystemPath(for: target.workspacePath, write: false)
        guard let info = try Self.fileSystemInfo(at: resolved.url) else {
            throw HarnessFsError(
                code: .notFound,
                message: "cannot read \"\(target.displayPath)\": not found"
            )
        }
        guard info.type == .file else {
            throw HarnessFsError(
                code: .notRegularFile,
                message: "cannot read \"\(target.displayPath)\": not a regular file"
            )
        }
        let url = resolved.url
        let displayPath = target.displayPath
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var carry = Data()
                    while true {
                        try Task.checkCancellation()
                        let next = try handle.read(upToCount: 32 * 1_024) ?? Data()
                        let isEOF = next.isEmpty
                        var buffer = carry
                        buffer.append(next)
                        if buffer.contains(0) {
                            throw HarnessFsError(
                                code: .notText,
                                message: "cannot read \"\(displayPath)\": binary file"
                            )
                        }

                        var decoded: String?
                        var retained = 0
                        let maximumRetained = isEOF ? 0 : min(3, buffer.count)
                        for suffixBytes in 0...maximumRetained {
                            let prefixCount = buffer.count - suffixBytes
                            if let text = String(
                                data: buffer.prefix(prefixCount),
                                encoding: .utf8
                            ) {
                                decoded = text
                                retained = suffixBytes
                                break
                            }
                        }
                        guard let decoded else {
                            throw HarnessFsError(
                                code: .notText,
                                message: "cannot read \"\(displayPath)\": not UTF-8 text"
                            )
                        }
                        if !decoded.isEmpty { continuation.yield(decoded) }
                        carry = retained == 0 ? Data() : Data(buffer.suffix(retained))
                        if isEOF {
                            guard carry.isEmpty else {
                                throw HarnessFsError(
                                    code: .notText,
                                    message: "cannot read \"\(displayPath)\": incomplete UTF-8 sequence"
                                )
                            }
                            continuation.finish()
                            return
                        }
                    }
                } catch is CancellationError {
                    continuation.finish(throwing: HarnessFsError(
                        code: .aborted,
                        message: "read was cancelled"
                    ))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func fileSystemReadData(
        target: HarnessFsTarget,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw HarnessFsError(code: .tooLarge, message: "read byte limit must be positive")
        }
        let resolved = try resolvedFileSystemPath(for: target.workspacePath, write: false)
        guard let info = try Self.fileSystemInfo(at: resolved.url) else {
            throw HarnessFsError(
                code: .notFound,
                message: "cannot read \"\(target.displayPath)\": not found"
            )
        }
        guard info.type == .file else {
            throw HarnessFsError(
                code: .notRegularFile,
                message: "cannot read \"\(target.displayPath)\": not a regular file"
            )
        }
        if let size = info.size, size > maximumBytes {
            throw HarnessFsError(
                code: .tooLarge,
                message: "cannot read \"\(target.displayPath)\": exceeds \(maximumBytes) bytes"
            )
        }
        let data = resolved.isExternalMount
            ? try coordinatedRead(at: resolved.url)
            : try Data(contentsOf: resolved.url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes else {
            throw HarnessFsError(
                code: .tooLarge,
                message: "cannot read \"\(target.displayPath)\": exceeds \(maximumBytes) bytes"
            )
        }
        return data
    }

    func fileSystemListDirectory(
        target: HarnessFsTarget
    ) throws -> [HarnessFsDirectoryEntry] {
        if target.workspacePath == "mounts" {
            _ = try activateMounts()
            return mountRecords.compactMap { record in
                guard mountActivations[record.id]?.status == .active else { return nil }
                let childPath = "mounts/\(record.name)"
                return HarnessFsDirectoryEntry(
                    name: record.name,
                    type: .directory,
                    target: HarnessFsTarget(
                        targetKey: "workspace:\(childPath)",
                        displayPath: "/workspace/\(childPath)",
                        workspacePath: childPath
                    ),
                    version: nil,
                    size: nil,
                    modifiedAt: record.createdAt
                )
            }.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        let resolved = try resolvedFileSystemPath(for: target.workspacePath, write: false)
        guard let info = try Self.fileSystemInfo(at: resolved.url) else {
            throw HarnessFsError(
                code: .notFound,
                message: "cannot list \"\(target.displayPath)\": not found"
            )
        }
        guard info.type == .directory else {
            throw HarnessFsError(
                code: .notDirectory,
                message: "cannot list \"\(target.displayPath)\": not a directory"
            )
        }

        let urls = try fileManager.contentsOfDirectory(
            at: resolved.url,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ],
            options: [.skipsPackageDescendants]
        )
        var entries: [HarnessFsDirectoryEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .fileResourceIdentifierKey
                ]
            )
            let entryType: HarnessFsEntryType
            if values.isSymbolicLink == true {
                entryType = .other
            } else if values.isRegularFile == true {
                entryType = .file
            } else if values.isDirectory == true {
                entryType = .directory
            } else {
                entryType = .other
            }
            let childPath = target.workspacePath.isEmpty
                ? url.lastPathComponent
                : "\(target.workspacePath)/\(url.lastPathComponent)"
            let child = HarnessFsTarget(
                targetKey: "workspace:\(childPath)",
                displayPath: "/workspace/\(childPath)",
                workspacePath: childPath
            )
            entries.append(
                HarnessFsDirectoryEntry(
                    name: url.lastPathComponent,
                    type: entryType,
                    target: child,
                    version: Self.fileSystemVersion(for: values, type: entryType.rawValue),
                    size: entryType == .file ? values.fileSize.map(Int64.init) : nil,
                    modifiedAt: values.contentModificationDate
                )
            )
        }
        return entries
    }

    func fileSystemWriteText(
        target: HarnessFsTarget,
        content: String,
        expected: HarnessFsWriteIntent?,
        maximumBytes: Int
    ) throws -> HarnessFsWriteOutcome {
        let normalized = Self.normalizedLineEndings(content)
        let data = Data(content.utf8)
        guard data.count <= maximumBytes else {
            throw HarnessFsError(
                code: .tooLarge,
                message: "cannot write \"\(target.displayPath)\": exceeds \(maximumBytes) bytes"
            )
        }
        let initial = try resolvedFileSystemPath(for: target.workspacePath, write: true)
        try fileManager.createDirectory(
            at: initial.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let resolved = try resolvedFileSystemPath(for: target.workspacePath, write: true)

        var outcome: Result<HarnessFsWriteOutcome, Error>?
        let mutation = { (url: URL) in
            outcome = Result {
                let current = try Self.fileSystemInfo(at: url)
                try Self.validateWriteIntent(
                    expected,
                    current: current,
                    displayPath: target.displayPath
                )
                let before = try Self.optionalText(at: url, maximumBytes: maximumBytes)
                try data.write(to: url, options: Self.protectedWritingOptions)
                guard let afterInfo = try Self.fileSystemInfo(at: url) else {
                    throw HarnessFsError(
                        code: .ioError,
                        message: "write completed but \"\(target.displayPath)\" could not be statted"
                    )
                }
                return HarnessFsWriteOutcome(
                    operation: current == nil ? .create : .update,
                    version: afterInfo.version,
                    before: before,
                    after: normalized
                )
            }
        }
        if resolved.isExternalMount {
            try coordinateMutation(at: resolved.url, mutation)
        } else {
            mutation(resolved.url)
        }
        guard let outcome else {
            throw HarnessFsError(code: .ioError, message: "write did not produce an outcome")
        }
        return try outcome.get()
    }

    func fileSystemEditText(
        target: HarnessFsTarget,
        edit: HarnessFsEditRequest,
        expectedVersion: HarnessFsVersion?,
        maximumBytes: Int
    ) throws -> HarnessFsEditOutcome {
        guard !edit.oldString.isEmpty, edit.oldString != edit.newString else {
            throw HarnessFsError(code: .editNotFound, message: "invalid literal edit request")
        }
        let resolved = try resolvedFileSystemPath(for: target.workspacePath, write: true)
        var outcome: Result<HarnessFsEditOutcome, Error>?
        let mutation = { (url: URL) in
            outcome = Result {
                guard let current = try Self.fileSystemInfo(at: url) else {
                    throw HarnessFsError(
                        code: .staleVersion,
                        message: "cannot edit \"\(target.displayPath)\": not found"
                    )
                }
                guard current.type == .file else {
                    throw HarnessFsError(
                        code: .notRegularFile,
                        message: "cannot edit \"\(target.displayPath)\": not a regular file"
                    )
                }
                if let size = current.size, size > maximumBytes {
                    throw HarnessFsError(
                        code: .tooLarge,
                        message: "cannot edit \"\(target.displayPath)\": exceeds \(maximumBytes) bytes"
                    )
                }
                if let expectedVersion, expectedVersion != current.version {
                    throw HarnessFsError(
                        code: .staleVersion,
                        message: "cannot edit \"\(target.displayPath)\": file changed after it was read"
                    )
                }
                guard let editable = try Self.editableText(at: url, maximumBytes: maximumBytes) else {
                    throw HarnessFsError(
                        code: .notText,
                        message: "cannot edit \"\(target.displayPath)\": not UTF-8 text"
                    )
                }
                let before = editable.content
                let oldString = Self.normalizedLineEndings(edit.oldString)
                let newString = Self.normalizedLineEndings(edit.newString)
                let matchCount = before.components(separatedBy: oldString).count - 1
                guard matchCount > 0 else {
                    throw HarnessFsError(
                        code: .editNotFound,
                        message: "cannot edit \"\(target.displayPath)\": old_string was not found"
                    )
                }
                guard edit.replaceAll || matchCount == 1 else {
                    throw HarnessFsError(
                        code: .ambiguousEdit,
                        message: "cannot edit \"\(target.displayPath)\": old_string matched \(matchCount) times"
                    )
                }
                let after: String
                if edit.replaceAll {
                    after = before.replacingOccurrences(of: oldString, with: newString)
                } else if let range = before.range(of: oldString) {
                    after = before.replacingCharacters(in: range, with: newString)
                } else {
                    throw HarnessFsError(
                        code: .editNotFound,
                        message: "cannot edit \"\(target.displayPath)\": old_string was not found"
                    )
                }
                let storedAfter = Self.restoredLineEndings(after, style: editable.lineEndings)
                let data = Data(storedAfter.utf8)
                guard data.count <= maximumBytes else {
                    throw HarnessFsError(
                        code: .tooLarge,
                        message: "cannot edit \"\(target.displayPath)\": result exceeds \(maximumBytes) bytes"
                    )
                }
                try data.write(to: url, options: Self.protectedWritingOptions)
                guard let afterInfo = try Self.fileSystemInfo(at: url) else {
                    throw HarnessFsError(
                        code: .ioError,
                        message: "edit completed but \"\(target.displayPath)\" could not be statted"
                    )
                }
                return HarnessFsEditOutcome(
                    version: afterInfo.version,
                    before: before,
                    after: after
                )
            }
        }
        if resolved.isExternalMount {
            try coordinateMutation(at: resolved.url, mutation)
        } else {
            mutation(resolved.url)
        }
        guard let outcome else {
            throw HarnessFsError(code: .ioError, message: "edit did not produce an outcome")
        }
        return try outcome.get()
    }

    private struct ResolvedWorkspacePath {
        let url: URL
        let isExternalMount: Bool
    }

    private func normalizedWorkspacePath(_ path: String, cwd: String?) throws -> String {
        func components(for rawPath: String, allowRelative: Bool) throws -> [String] {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "." {
                return []
            }
            var candidate = trimmed
            if candidate == "/workspace" {
                candidate = ""
            } else if candidate.hasPrefix("/workspace/") {
                candidate = String(candidate.dropFirst("/workspace/".count))
            } else if candidate.hasPrefix("/") {
                throw WorkspaceError.pathEscapesWorkspace
            } else if !allowRelative {
                throw WorkspaceError.invalidPath
            }
            return candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        }

        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAbsoluteWorkspacePath = raw == "/workspace" || raw.hasPrefix("/workspace/")
        var result = isAbsoluteWorkspacePath
            ? []
            : try components(for: cwd ?? "/workspace", allowRelative: true)
        for component in try components(for: raw, allowRelative: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !result.isEmpty else {
                    throw WorkspaceError.pathEscapesWorkspace
                }
                result.removeLast()
            default:
                guard !component.contains("\0") else { throw WorkspaceError.invalidPath }
                result.append(component)
            }
        }
        return result.joined(separator: "/")
    }

    private func canonicalFileSystemPath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.first == "mounts", components.count >= 2 else { return path }
        try loadMountsIfNeeded()
        let requested = String(components[1])
        guard let record = mountRecords.first(where: {
            $0.name.caseInsensitiveCompare(requested) == .orderedSame
        }) else {
            return path
        }
        return (["mounts", record.name] + components.dropFirst(2).map(String.init))
            .joined(separator: "/")
    }

    private func resolvedFileSystemPath(
        for workspacePath: String,
        write: Bool
    ) throws -> ResolvedWorkspacePath {
        if workspacePath.isEmpty {
            return ResolvedWorkspacePath(url: root, isExternalMount: false)
        }
        if workspacePath == "mounts" {
            return ResolvedWorkspacePath(
                url: root.appendingPathComponent("mounts", isDirectory: true),
                isExternalMount: false
            )
        }
        return try resolvedWorkspacePath(for: workspacePath, write: write)
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

        let data: Data
        do {
            data = try Data(contentsOf: mountStoreURL, options: [.mappedIfSafe])
        } catch {
            didLoadMounts = false
            throw WorkspaceError.mountStoreUnavailable(error.localizedDescription)
        }

        do {
            mountRecords = try JSONDecoder().decode([MountRecord].self, from: data)
        } catch {
            mountRecords = []
            activeMountURLs = [:]
            activeMountScopes = []
            mountActivations = [:]
            try quarantineCorruptedMountStore()
        }
    }

    private func quarantineCorruptedMountStore() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = mountStoreURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        do {
            try fileManager.moveItem(at: mountStoreURL, to: backupURL)
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

    private func coordinateMutation(
        at url: URL,
        _ mutation: @escaping (URL) -> Void
    ) throws {
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            writingItemAt: url,
            options: [.forReplacing],
            error: &coordinationError
        ) { coordinatedURL in
            mutation(coordinatedURL)
        }
        if let coordinationError {
            throw coordinationError
        }
    }

    private static func fileSystemInfo(at url: URL) throws -> HarnessFsInfo? {
        // Atomic writes replace the inode behind the path. A URL that was used
        // before the replacement can retain stale resource values on iOS, so
        // always stat through a fresh URL before publishing a write version.
        let freshURL = URL(fileURLWithPath: url.path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: freshURL.path) else { return nil }
        let values = try freshURL.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .fileResourceIdentifierKey
            ]
        )
        let type: HarnessFsEntryType
        if values.isSymbolicLink == true {
            type = .other
        } else if values.isRegularFile == true {
            type = .file
        } else if values.isDirectory == true {
            type = .directory
        } else {
            type = .other
        }
        return HarnessFsInfo(
            version: fileSystemVersion(for: values, type: type.rawValue),
            type: type,
            size: type == .file ? values.fileSize.map(Int64.init) : nil
        )
    }

    private static func fileSystemVersion(
        for values: URLResourceValues,
        type: String
    ) -> HarnessFsVersion {
        let identifier = values.fileResourceIdentifier.map(String.init(describing:)) ?? "-"
        let size = values.fileSize ?? -1
        let modifiedBits = (values.contentModificationDate?.timeIntervalSinceReferenceDate ?? -1)
            .bitPattern
        return HarnessFsVersion(
            rawValue: "\(type)|\(identifier)|\(size)|\(modifiedBits)"
        )
    }

    private static func validateWriteIntent(
        _ expected: HarnessFsWriteIntent?,
        current: HarnessFsInfo?,
        displayPath: String
    ) throws {
        switch expected {
        case .none:
            return
        case .createIfAbsent:
            guard current == nil else {
                throw HarnessFsError(
                    code: .notObserved,
                    message: "cannot create \"\(displayPath)\": target already exists; read it first"
                )
            }
        case let .replaceIfVersion(version):
            guard current?.version == version else {
                throw HarnessFsError(
                    code: .staleVersion,
                    message: "cannot replace \"\(displayPath)\": file changed after it was read"
                )
            }
        }
    }

    private static func optionalText(at url: URL, maximumBytes: Int) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes else {
            return nil
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedLineEndings(text)
    }

    private enum LineEndingStyle {
        case lf
        case crlf
    }

    private static func editableText(
        at url: URL,
        maximumBytes: Int
    ) throws -> (content: String, lineEndings: LineEndingStyle)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumBytes else {
            return nil
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumBytes,
              let raw = String(data: data, encoding: .utf8),
              !raw.contains("\0") else {
            return nil
        }
        let sample = String(raw.prefix(4_096))
        let crlfCount = sample.components(separatedBy: "\r\n").count - 1
        let allLFCount = sample.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        let bareLFCount = max(0, allLFCount - crlfCount)
        return (
            normalizedLineEndings(raw),
            crlfCount > bareLFCount ? .crlf : .lf
        )
    }

    private static func restoredLineEndings(
        _ text: String,
        style: LineEndingStyle
    ) -> String {
        switch style {
        case .lf:
            return text
        case .crlf:
            return normalizedLineEndings(text).replacingOccurrences(of: "\n", with: "\r\n")
        }
    }

    private static func normalizedLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
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

private enum ImageAttachmentAdmission {
    // Match the RC.8 local attachment defaults while using ImageIO rather
    // than Sharp: source admission is independent from the normalized object
    // that will ride later model requests.
    static let maximumInputBytes = 20 * 1_024 * 1_024
    static let maximumOutputBytes = 4 * 1_024 * 1_024
    static let maximumPixelSize = 2_048
    static let maximumSourcePixels = 64_000_000
    static let maximumSourceDimension = 8_192

    struct Admitted: Sendable, Equatable {
        let data: Data
        let mimeType: String
        let filenameExtension: String
        let width: Int
        let height: Int
        let originalWidth: Int?
        let originalHeight: Int?
    }

    static func admit(
        _ data: Data,
        declaredMimeType: String?,
        maximumOutputBytes: Int = ImageAttachmentAdmission.maximumOutputBytes,
        maximumPixelSize: Int = ImageAttachmentAdmission.maximumPixelSize
    ) throws -> Admitted {
        guard !data.isEmpty else { throw ImageAdmissionError.empty }
        guard data.count <= maximumInputBytes else {
            throw ImageAdmissionError.inputTooLarge(maximumInputBytes)
        }
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw ImageAdmissionError.invalidImage
        }
        guard let sourceType = CGImageSourceGetType(source) as String?,
              let sourceMimeType = mimeType(forTypeIdentifier: sourceType) else {
            throw ImageAdmissionError.unsupportedImageType
        }
        if let declaredMimeType {
            let expected = normalizedMimeType(declaredMimeType)
            guard expected == sourceMimeType else {
                throw ImageAdmissionError.typeMismatch(
                    expected: expected,
                    actual: sourceMimeType
                )
            }
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) as? [CFString: Any]
        guard let sourceWidth = positiveInteger(properties?[kCGImagePropertyPixelWidth]),
              let sourceHeight = positiveInteger(properties?[kCGImagePropertyPixelHeight]) else {
            throw ImageAdmissionError.invalidImage
        }
        let orientation = positiveInteger(properties?[kCGImagePropertyOrientation]) ?? 1
        let swapsAxes = [5, 6, 7, 8].contains(orientation)
        let orientedSourceWidth = swapsAxes ? sourceHeight : sourceWidth
        let orientedSourceHeight = swapsAxes ? sourceWidth : sourceHeight
        let (sourcePixels, overflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        guard !overflow, sourcePixels <= maximumSourcePixels else {
            throw ImageAdmissionError.tooManyPixels(maximumSourcePixels)
        }
        guard max(sourceWidth, sourceHeight) <= maximumSourceDimension else {
            throw ImageAdmissionError.dimensionTooLarge(maximumSourceDimension)
        }

        // Normalizing every admitted image removes container-specific metadata,
        // applies EXIF orientation, and bounds future provider request memory.
        // If an alpha-preserving PNG remains too large, reduce dimensions rather
        // than silently discarding transparency.
        let pixelSizes = [maximumPixelSize, 1_600, 1_280, 1_024, 768, 640, 512]
            .filter { $0 <= maximumPixelSize }
            .reduce(into: [Int]()) { values, value in
                if values.last != value { values.append(value) }
            }
        for pixelSize in pixelSizes {
            guard let thumbnail = thumbnail(source: source, maximumPixelSize: pixelSize),
                  let image = normalizedSRGB(thumbnail) else {
                throw ImageAdmissionError.invalidImage
            }
            let preservesAlpha = hasAlpha(image)
            if preservesAlpha {
                if let encoded = encode(image, type: UTType.png.identifier, quality: nil),
                   encoded.count <= maximumOutputBytes {
                    return try verified(
                        encoded,
                        mimeType: "image/png",
                        filenameExtension: "png",
                        sourceWidth: orientedSourceWidth,
                        sourceHeight: orientedSourceHeight
                    )
                }
            } else {
                for quality in [0.85, 0.80, 0.75] {
                    if let encoded = encode(
                        image,
                        type: UTType.jpeg.identifier,
                        quality: quality
                    ), encoded.count <= maximumOutputBytes {
                        return try verified(
                            encoded,
                            mimeType: "image/jpeg",
                            filenameExtension: "jpg",
                            sourceWidth: orientedSourceWidth,
                            sourceHeight: orientedSourceHeight
                        )
                    }
                }
            }
        }
        throw ImageAdmissionError.outputTooLarge(maximumOutputBytes)
    }

    private static func thumbnail(
        source: CGImageSource,
        maximumPixelSize: Int
    ) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// ImageIO applies container orientation while CoreGraphics redraws into
    /// an 8-bit sRGB/sRGBA buffer, matching the upstream normalized-object
    /// contract without shipping a second image runtime on device.
    private static func normalizedSRGB(_ image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let alphaInfo: CGImageAlphaInfo = hasAlpha(image) ? .premultipliedLast : .noneSkipLast
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func encode(
        _ image: CGImage,
        type: String,
        quality: Double?
    ) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            type as CFString,
            1,
            nil
        ) else { return nil }
        let properties: CFDictionary?
        if let quality {
            properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        } else {
            properties = nil
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func verified(
        _ data: Data,
        mimeType: String,
        filenameExtension: String,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> Admitted {
        guard data.count <= maximumOutputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              decoded.width > 0,
              decoded.height > 0,
              max(decoded.width, decoded.height) <= maximumPixelSize else {
            throw ImageAdmissionError.invalidImage
        }
        return Admitted(
            data: data,
            mimeType: mimeType,
            filenameExtension: filenameExtension,
            width: decoded.width,
            height: decoded.height,
            originalWidth: decoded.width == sourceWidth && decoded.height == sourceHeight
                ? nil
                : sourceWidth,
            originalHeight: decoded.width == sourceWidth && decoded.height == sourceHeight
                ? nil
                : sourceHeight
        )
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            true
        case .none, .noneSkipFirst, .noneSkipLast:
            false
        @unknown default:
            true
        }
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        if let value = value as? NSNumber, value.intValue > 0 { return value.intValue }
        if let value = value as? Int, value > 0 { return value }
        return nil
    }

    private static func normalizedMimeType(_ value: String) -> String {
        switch value.lowercased() {
        case "image/jpg": "image/jpeg"
        default: value.lowercased()
        }
    }

    private static func mimeType(forTypeIdentifier identifier: String) -> String? {
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.identifier == "org.webmproject.webp" { return "image/webp" }
        // Composer input may arrive as HEIC. It is accepted here because the
        // admitted durable object is always normalized to JPEG or PNG.
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return "image/heic" }
        return nil
    }
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
    case mountStoreUnavailable(String)

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
        case let .mountStoreUnavailable(message):
            return "无法读取工作区挂载记录：\(message)"
        }
    }
}
