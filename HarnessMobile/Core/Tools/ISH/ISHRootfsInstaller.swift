import Compression
import Foundation

struct ISHRootfsInstallation: Sendable, Equatable {
    let rootURL: URL
    let installedNow: Bool
}

enum ISHRootfsError: LocalizedError, Sendable {
    case archiveMissing
    case invalidArchive
    case unsafeArchivePath(String)
    case unsupportedCompression(UInt16)
    case decompressionFailed(String)
    case invalidInstallation

    var errorDescription: String? {
        switch self {
        case .archiveMissing:
            return "App 中缺少 Alpine rootfs 镜像。"
        case .invalidArchive:
            return "Alpine rootfs 镜像格式无效。"
        case let .unsafeArchivePath(path):
            return "rootfs 镜像包含不安全路径：\(path)。"
        case let .unsupportedCompression(method):
            return "rootfs 镜像使用了不支持的 ZIP 压缩方式（\(method)）。"
        case let .decompressionFailed(path):
            return "无法解压 rootfs 文件：\(path)。"
        case .invalidInstallation:
            return "解压后的 rootfs 缺少 data 或 meta.db。"
        }
    }
}

actor ISHRootfsInstaller {
    static let shared = ISHRootfsInstaller()

    private static let installationVersion = "alpine-3.21.0-aarch64-1"
    private static let archivePrefix = "alpine-rootfs/"
    private static let maximumEntries = 10_000
    private static let maximumExpandedBytes = 256 * 1_024 * 1_024

    private let fileManager: FileManager
    private let bundle: Bundle
    private let containerURL: URL

    init(
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        containerURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.bundle = bundle
        if let containerURL {
            self.containerURL = containerURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.containerURL = applicationSupport
                .appendingPathComponent("HarnessMobile", isDirectory: true)
                .appendingPathComponent("iSH", isDirectory: true)
        }
    }

    func installIfNeeded() throws -> ISHRootfsInstallation {
        let installedRoot = containerURL.appendingPathComponent(
            "alpine-rootfs",
            isDirectory: true
        )
        if try isCurrentInstallation(at: installedRoot) {
            return ISHRootfsInstallation(rootURL: installedRoot, installedNow: false)
        }

        guard let archiveURL = bundle.url(
            forResource: "alpine-rootfs",
            withExtension: "zip"
        ) else {
            throw ISHRootfsError.archiveMissing
        }

        try fileManager.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )
        let stagingRoot = containerURL.appendingPathComponent(
            ".install-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        let archive = try ISHZipArchive(url: archiveURL)
        guard archive.entries.count <= Self.maximumEntries,
              archive.entries.reduce(0, { $0 + $1.uncompressedSize })
                <= Self.maximumExpandedBytes else {
            throw ISHRootfsError.invalidArchive
        }

        for entry in archive.entries {
            let relativePath = try safeRelativePath(for: entry.path)
            guard !relativePath.isEmpty else { continue }
            let destination = stagingRoot
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            guard Self.contains(destination, in: stagingRoot) else {
                throw ISHRootfsError.unsafeArchivePath(entry.path)
            }

            if entry.isDirectory {
                try fileManager.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try archive.extract(entry)
            try data.write(to: destination, options: .atomic)
        }

        guard try isStructurallyValid(at: stagingRoot) else {
            throw ISHRootfsError.invalidInstallation
        }
        try Self.installationVersion.write(
            to: versionMarker(in: stagingRoot),
            atomically: true,
            encoding: .utf8
        )
        try excludeFromBackup(stagingRoot)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: stagingRoot.path
        )

        if fileManager.fileExists(atPath: installedRoot.path) {
            _ = try fileManager.replaceItemAt(
                installedRoot,
                withItemAt: stagingRoot,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try fileManager.moveItem(at: stagingRoot, to: installedRoot)
        }

        guard try isCurrentInstallation(at: installedRoot) else {
            throw ISHRootfsError.invalidInstallation
        }
        return ISHRootfsInstallation(rootURL: installedRoot, installedNow: true)
    }

    private func safeRelativePath(for archivePath: String) throws -> String {
        guard archivePath.hasPrefix(Self.archivePrefix) else {
            throw ISHRootfsError.unsafeArchivePath(archivePath)
        }
        let relative = String(archivePath.dropFirst(Self.archivePrefix.count))
        guard !relative.hasPrefix("/"),
              !relative.split(separator: "/", omittingEmptySubsequences: false)
                .contains("..") else {
            throw ISHRootfsError.unsafeArchivePath(archivePath)
        }
        return relative
    }

    private func isCurrentInstallation(at url: URL) throws -> Bool {
        guard try isStructurallyValid(at: url),
              let version = try? String(contentsOf: versionMarker(in: url), encoding: .utf8)
        else {
            return false
        }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
            == Self.installationVersion
    }

    private func isStructurallyValid(at url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        let dataURL = url.appendingPathComponent("data", isDirectory: true)
        guard fileManager.fileExists(atPath: dataURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        let metadataURL = url.appendingPathComponent("meta.db")
        let values = try? metadataURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    }

    private func versionMarker(in root: URL) -> URL {
        root.appendingPathComponent(".harness-rootfs-version")
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
}

private final class ISHZipArchive {
    struct Entry {
        let path: String
        let isDirectory: Bool
        let compressedSize: Int
        let uncompressedSize: Int
        let compressionMethod: UInt16
        let localHeaderOffset: UInt64
    }

    private let handle: FileHandle
    let entries: [Entry]

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        entries = try Self.readEntries(from: handle)
    }

    deinit {
        try? handle.close()
    }

    func extract(_ entry: Entry) throws -> Data {
        handle.seek(toFileOffset: entry.localHeaderOffset)
        let localHeader = handle.readData(ofLength: 30)
        guard localHeader.count == 30,
              Self.readUInt32(localHeader, at: 0) == 0x04034B50 else {
            throw ISHRootfsError.invalidArchive
        }

        let filenameLength = Int(Self.readUInt16(localHeader, at: 26))
        let extraLength = Int(Self.readUInt16(localHeader, at: 28))
        handle.seek(
            toFileOffset: handle.offsetInFile + UInt64(filenameLength + extraLength)
        )
        let compressed = handle.readData(ofLength: entry.compressedSize)
        guard compressed.count == entry.compressedSize else {
            throw ISHRootfsError.invalidArchive
        }

        switch entry.compressionMethod {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw ISHRootfsError.invalidArchive
            }
            return compressed
        case 8:
            return try Self.inflate(
                compressed,
                expectedSize: entry.uncompressedSize,
                path: entry.path
            )
        default:
            throw ISHRootfsError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private static func readEntries(from handle: FileHandle) throws -> [Entry] {
        let fileSize = handle.seekToEndOfFile()
        guard fileSize >= 22 else { throw ISHRootfsError.invalidArchive }
        let searchSize = min(fileSize, 65_557)
        handle.seek(toFileOffset: fileSize - searchSize)
        let searchData = handle.readDataToEndOfFile()
        guard let endOffset = findEndOfCentralDirectory(in: searchData) else {
            throw ISHRootfsError.invalidArchive
        }

        let absoluteOffset = fileSize - searchSize + UInt64(endOffset)
        handle.seek(toFileOffset: absoluteOffset)
        let endRecord = handle.readData(ofLength: 22)
        guard endRecord.count == 22 else { throw ISHRootfsError.invalidArchive }
        let entryCount = Int(readUInt16(endRecord, at: 10))
        let centralDirectoryOffset = UInt64(readUInt32(endRecord, at: 16))
        handle.seek(toFileOffset: centralDirectoryOffset)

        var result: [Entry] = []
        result.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let header = handle.readData(ofLength: 46)
            guard header.count == 46,
                  readUInt32(header, at: 0) == 0x02014B50 else {
                throw ISHRootfsError.invalidArchive
            }
            let filenameLength = Int(readUInt16(header, at: 28))
            let extraLength = Int(readUInt16(header, at: 30))
            let commentLength = Int(readUInt16(header, at: 32))
            let filenameData = handle.readData(ofLength: filenameLength)
            guard filenameData.count == filenameLength,
                  let path = String(data: filenameData, encoding: .utf8) else {
                throw ISHRootfsError.invalidArchive
            }
            handle.seek(
                toFileOffset: handle.offsetInFile + UInt64(extraLength + commentLength)
            )
            result.append(
                Entry(
                    path: path,
                    isDirectory: path.hasSuffix("/"),
                    compressedSize: Int(readUInt32(header, at: 20)),
                    uncompressedSize: Int(readUInt32(header, at: 24)),
                    compressionMethod: readUInt16(header, at: 10),
                    localHeaderOffset: UInt64(readUInt32(header, at: 42))
                )
            )
        }
        return result
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            if data[offset] == 0x50,
               data[offset + 1] == 0x4B,
               data[offset + 2] == 0x05,
               data[offset + 3] == 0x06 {
                return offset
            }
        }
        return nil
    }

    private static func inflate(
        _ data: Data,
        expectedSize: Int,
        path: String
    ) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let decoded = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    expectedSize,
                    source.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expectedSize else {
            throw ISHRootfsError.decompressionFailed(path)
        }
        return output
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
