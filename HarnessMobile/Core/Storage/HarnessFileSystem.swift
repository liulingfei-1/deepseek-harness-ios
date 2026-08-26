import Foundation

struct HarnessFsTarget: Sendable, Hashable {
    let targetKey: String
    let displayPath: String

    // Provider-owned coordinate. Consumers must use processPath/fileURL rather
    // than interpreting this value as a host path.
    let workspacePath: String
}

struct HarnessFsVersion: RawRepresentable, Codable, Sendable, Hashable {
    let rawValue: String
}

enum HarnessFsEntryType: String, Codable, Sendable, Equatable {
    case file
    case directory
    case other
}

enum HarnessFsPathEntryType: String, Codable, Sendable, Equatable {
    case file
    case directory
    case symlink
    case other
}

struct HarnessFsInfo: Codable, Sendable, Equatable {
    let version: HarnessFsVersion
    let type: HarnessFsEntryType
    let size: Int64?
}

struct HarnessFsPathInfo: Codable, Sendable, Equatable {
    let version: HarnessFsVersion
    let type: HarnessFsPathEntryType
    let size: Int64?
}

struct HarnessFsDirectoryEntry: Sendable, Equatable {
    let name: String
    let type: HarnessFsEntryType
    let target: HarnessFsTarget
    let version: HarnessFsVersion?
    let size: Int64?
    let modifiedAt: Date?
}

enum HarnessFsWriteIntent: Sendable, Equatable {
    case createIfAbsent
    case replaceIfVersion(HarnessFsVersion)
}

struct HarnessFsWriteOutcome: Sendable, Equatable {
    enum Operation: String, Sendable, Equatable {
        case create
        case update
    }

    let operation: Operation
    let version: HarnessFsVersion
    let before: String?
    let after: String
}

struct HarnessFsEditRequest: Sendable, Equatable {
    let oldString: String
    let newString: String
    let replaceAll: Bool
}

struct HarnessFsEditOutcome: Sendable, Equatable {
    let version: HarnessFsVersion
    let before: String
    let after: String
}

enum HarnessFsObservation: Sendable, Equatable {
    case present(HarnessFsVersion)
    case absent
}

enum HarnessFsErrorCode: String, Codable, Sendable, Equatable {
    case notFound = "FS_NOT_FOUND"
    case notDirectory = "FS_NOT_DIRECTORY"
    case notText = "FS_NOT_TEXT"
    case notRegularFile = "FS_NOT_REGULAR_FILE"
    case tooLarge = "FS_TOO_LARGE"
    case permissionDenied = "FS_PERMISSION_DENIED"
    case sandboxDenied = "FS_SANDBOX_DENIED"
    case ioError = "FS_IO_ERROR"
    case staleVersion = "FS_STALE_VERSION"
    case notObserved = "FS_NOT_OBSERVED"
    case ambiguousEdit = "FS_AMBIGUOUS_EDIT"
    case editNotFound = "FS_EDIT_NOT_FOUND"
    case aborted = "FS_ABORTED"
}

struct HarnessFsError: LocalizedError, Sendable, Equatable {
    let code: HarnessFsErrorCode
    let message: String

    var errorDescription: String? {
        "\(code.rawValue): \(message)"
    }
}

protocol HarnessFileSystem: Sendable {
    func resolve(
        _ path: String,
        cwd: String?
    ) async throws -> HarnessFsTarget

    func processPath(_ target: HarnessFsTarget) async -> String
    func fileURL(_ target: HarnessFsTarget) async -> String
    func contains(parent: HarnessFsTarget, child: HarnessFsTarget) async -> Bool
    func stat(_ target: HarnessFsTarget) async throws -> HarnessFsInfo?
    func lstat(path: String, cwd: String?) async throws -> HarnessFsPathInfo?
    func readText(_ target: HarnessFsTarget) async throws -> String
    func streamText(
        _ target: HarnessFsTarget
    ) async throws -> AsyncThrowingStream<String, Error>
    func readBytes(_ target: HarnessFsTarget, maximumBytes: Int) async throws -> Data
    func listDirectory(_ target: HarnessFsTarget) async throws -> [HarnessFsDirectoryEntry]
    func writeText(
        _ target: HarnessFsTarget,
        content: String,
        expected: HarnessFsWriteIntent?
    ) async throws -> HarnessFsWriteOutcome
    func editText(
        _ target: HarnessFsTarget,
        edit: HarnessFsEditRequest,
        expectedVersion: HarnessFsVersion?
    ) async throws -> HarnessFsEditOutcome
}

struct WorkspaceFileSystemProvider: HarnessFileSystem {
    static let maximumTextBytes = 16 * 1_024 * 1_024

    let store: WorkspaceStore

    func resolve(_ path: String, cwd: String?) async throws -> HarnessFsTarget {
        do {
            return try await store.fileSystemResolve(path: path, cwd: cwd)
        } catch {
            throw Self.map(error, operation: "resolve \(path)")
        }
    }

    func processPath(_ target: HarnessFsTarget) async -> String {
        target.workspacePath.isEmpty
            ? "/workspace"
            : "/workspace/\(target.workspacePath)"
    }

    func fileURL(_ target: HarnessFsTarget) async -> String {
        let path = await processPath(target)
        return URL(fileURLWithPath: path).absoluteString
    }

    func contains(parent: HarnessFsTarget, child: HarnessFsTarget) async -> Bool {
        let parentPath = parent.workspacePath
        let childPath = child.workspacePath
        return parentPath.isEmpty
            || childPath == parentPath
            || childPath.hasPrefix(parentPath + "/")
    }

    func stat(_ target: HarnessFsTarget) async throws -> HarnessFsInfo? {
        do {
            return try await store.fileSystemStat(target: target)
        } catch {
            throw Self.map(error, operation: "stat \(target.displayPath)")
        }
    }

    func lstat(path: String, cwd: String?) async throws -> HarnessFsPathInfo? {
        do {
            return try await store.fileSystemLStat(path: path, cwd: cwd)
        } catch {
            throw Self.map(error, operation: "lstat \(path)")
        }
    }

    func readText(_ target: HarnessFsTarget) async throws -> String {
        do {
            return try await store.fileSystemReadText(
                target: target,
                maximumBytes: Self.maximumTextBytes
            )
        } catch {
            throw Self.map(error, operation: "read \(target.displayPath)")
        }
    }

    func streamText(
        _ target: HarnessFsTarget
    ) async throws -> AsyncThrowingStream<String, Error> {
        do {
            return try await store.fileSystemStreamText(target: target)
        } catch {
            throw Self.map(error, operation: "stream \(target.displayPath)")
        }
    }

    func readBytes(_ target: HarnessFsTarget, maximumBytes: Int) async throws -> Data {
        do {
            return try await store.fileSystemReadData(
                target: target,
                maximumBytes: maximumBytes
            )
        } catch {
            throw Self.map(error, operation: "read bytes \(target.displayPath)")
        }
    }

    func listDirectory(_ target: HarnessFsTarget) async throws -> [HarnessFsDirectoryEntry] {
        do {
            return try await store.fileSystemListDirectory(target: target)
        } catch {
            throw Self.map(error, operation: "list \(target.displayPath)")
        }
    }

    func writeText(
        _ target: HarnessFsTarget,
        content: String,
        expected: HarnessFsWriteIntent?
    ) async throws -> HarnessFsWriteOutcome {
        do {
            return try await store.fileSystemWriteText(
                target: target,
                content: content,
                expected: expected,
                maximumBytes: Self.maximumTextBytes
            )
        } catch {
            throw Self.map(error, operation: "write \(target.displayPath)")
        }
    }

    func editText(
        _ target: HarnessFsTarget,
        edit: HarnessFsEditRequest,
        expectedVersion: HarnessFsVersion?
    ) async throws -> HarnessFsEditOutcome {
        do {
            return try await store.fileSystemEditText(
                target: target,
                edit: edit,
                expectedVersion: expectedVersion,
                maximumBytes: Self.maximumTextBytes
            )
        } catch {
            throw Self.map(error, operation: "edit \(target.displayPath)")
        }
    }

    private static func map(_ error: Error, operation: String) -> Error {
        if let fsError = error as? HarnessFsError {
            return fsError
        }
        if let workspaceError = error as? WorkspaceError {
            switch workspaceError {
            case .notAFile:
                return HarnessFsError(code: .notRegularFile, message: workspaceError.localizedDescription)
            case .notADirectory:
                return HarnessFsError(code: .notDirectory, message: workspaceError.localizedDescription)
            case .fileTooLarge:
                return HarnessFsError(code: .tooLarge, message: workspaceError.localizedDescription)
            case .notUTF8:
                return HarnessFsError(code: .notText, message: workspaceError.localizedDescription)
            case .mountReadOnly, .pathEscapesWorkspace, .invalidPath:
                return HarnessFsError(code: .sandboxDenied, message: workspaceError.localizedDescription)
            case .mountUnavailable, .mountNotFound:
                return HarnessFsError(code: .notFound, message: workspaceError.localizedDescription)
            case .bookmarkCreationFailed, .mountStoreCorrupted, .mountStoreUnavailable:
                return HarnessFsError(code: .ioError, message: workspaceError.localizedDescription)
            case .unsupportedFileType, .noStagedImage, .attachmentExpired, .tooManyConflicts, .mountLimitReached:
                return HarnessFsError(code: .ioError, message: workspaceError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError:
                return HarnessFsError(code: .notFound, message: "\(operation): not found")
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return HarnessFsError(code: .permissionDenied, message: "\(operation): permission denied")
            default:
                break
            }
        }
        return HarnessFsError(code: .ioError, message: "\(operation): \(error.localizedDescription)")
    }
}

struct CordisFsActor: Sendable, Equatable {
    let sessionID: String
}

struct CordisFsIntentInput: Sendable, Equatable {
    let target: HarnessFsTarget
    let actor: CordisFsActor
}

struct CordisFsObservedInput: Sendable, Equatable {
    let target: HarnessFsTarget
    let observation: HarnessFsObservation
    let actor: CordisFsActor
}

enum CordisFileSystemEvents {
    static let writeIntent = CordisCheckpointKey<CordisFsIntentInput, HarnessFsWriteIntent?>(
        "fs/write-intent"
    )
    static let editIntent = CordisCheckpointKey<CordisFsIntentInput, HarnessFsVersion?>(
        "fs/edit-intent"
    )
    static let observed = CordisEventKey<CordisFsObservedInput>("fs/observed")
}

actor HarnessFsObservationPolicy {
    private var observations: [String: [String: HarnessFsObservation]] = [:]

    func record(_ input: CordisFsObservedInput) {
        observations[input.actor.sessionID, default: [:]][input.target.targetKey] = input.observation
    }

    func writeIntent(for input: CordisFsIntentInput) -> HarnessFsWriteIntent {
        switch observations[input.actor.sessionID]?[input.target.targetKey] {
        case let .present(version):
            return .replaceIfVersion(version)
        case .absent, .none:
            return .createIfAbsent
        }
    }

    func editVersion(for input: CordisFsIntentInput) throws -> HarnessFsVersion {
        switch observations[input.actor.sessionID]?[input.target.targetKey] {
        case let .present(version):
            return version
        case .absent:
            throw HarnessFsError(
                code: .notFound,
                message: "cannot edit \"\(input.target.displayPath)\": not found"
            )
        case .none:
            throw HarnessFsError(
                code: .notObserved,
                message: "cannot edit \"\(input.target.displayPath)\": read the file first"
            )
        }
    }

    func clear(sessionID: String) {
        observations.removeValue(forKey: sessionID)
    }

    func clearAll() {
        observations.removeAll()
    }

    func pluginDefinition(
        id: CordisPluginID = "core.fs-observation-policy",
        version: String = "1"
    ) -> CordisPluginDefinition {
        let policy = self
        return CordisPluginDefinition(id: id, version: version) { context in
            try await context.intercept(CordisFileSystemEvents.writeIntent) { input, _ in
                await policy.writeIntent(for: input)
            }
            try await context.intercept(CordisFileSystemEvents.editIntent) { input, _ in
                try await policy.editVersion(for: input)
            }
            try await context.on(CordisFileSystemEvents.observed) { input in
                await policy.record(input)
            }
            try await context.onDispose("fs-observation-policy.clear") {
                await policy.clearAll()
            }
        }
    }
}

enum WorkspaceFileSystemCordisPlugin {
    static func definition(
        store: WorkspaceStore,
        id: CordisPluginID = "core.workspace-fs",
        version: String = "1"
    ) -> CordisPluginDefinition {
        let provider: any HarnessFileSystem = WorkspaceFileSystemProvider(store: store)
        return CordisPluginDefinition(
            id: id,
            version: version,
            provides: [CordisAgentServiceKeys.fileSystem.name]
        ) { context in
            try await context.provide(CordisAgentServiceKeys.fileSystem, value: provider)
        }
    }
}
