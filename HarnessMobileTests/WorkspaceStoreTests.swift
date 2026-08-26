@preconcurrency import ImageIO
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WorkspaceStoreTests: XCTestCase {
    func testReadWriteStaysInsideWorkspace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "notes/result.md", text: "local")
        let text = try await store.readText(path: "notes/result.md")
        XCTAssertEqual(text, "local")

        do {
            try await store.writeText(path: "../escape.md", text: "bad")
            XCTFail("Path traversal should be rejected")
        } catch {
            XCTAssertTrue(error is WorkspaceError)
        }
    }

    func testSymlinkEscapeIsRejected() async throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"),
            withDestinationURL: outside
        )

        let store = WorkspaceStore(root: root)
        do {
            _ = try await store.readText(path: "outside/secret.txt")
            XCTFail("Symlink escape should be rejected")
        } catch {
            XCTAssertTrue(error is WorkspaceError)
        }
    }

    func testWriteThroughSymlinkedAncestorIsRejected() async throws {
        let root = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside"),
            withDestinationURL: outside
        )

        let store = WorkspaceStore(root: root)
        do {
            try await store.writeText(path: "outside/new/result.md", text: "bad")
            XCTFail("Write through a symlinked ancestor should be rejected")
        } catch {
            XCTAssertTrue(error is WorkspaceError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("new/result.md").path
            )
        )
    }

    func testInternalOCRAttachmentIsNotExposedAsWorkspaceFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "visible.md", text: "visible")
        _ = try await store.stageImage(makeJPEG(width: 8, height: 8))

        let entries = try await store.listFiles()
        XCTAssertEqual(entries.map(\.path), ["visible.md"])
    }

    func testFileAttachmentIsPrivatelyCopiedValidatedAndExpires() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("brief.pdf")
        let pdf = Data("%PDF-1.7\nlocal-only".utf8)
        try pdf.write(to: source)

        let store = WorkspaceStore(root: root)
        let ref = try await store.stageFileAttachment(from: source)
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(ref.mimeType, "application/pdf")
        XCTAssertEqual(ref.displayName, "brief.pdf")
        let stagedData = try await store.readFileAttachment(ref)
        XCTAssertEqual(stagedData, pdf)
        let visibleFiles = try await store.listFiles()
        XCTAssertFalse(visibleFiles.contains { $0.path.contains("Attachments") })

        let expired = AgentFileAttachmentRef(
            id: ref.id,
            path: ref.path,
            mimeType: ref.mimeType,
            byteCount: ref.byteCount,
            displayName: ref.displayName,
            expiresAt: .distantPast
        )
        do {
            _ = try await store.readFileAttachment(expired)
            XCTFail("Expired attachment must not be readable")
        } catch {
            guard case WorkspaceError.attachmentExpired = error else {
                return XCTFail("Expected attachmentExpired, got \(error)")
            }
        }
    }

    func testFileAttachmentRejectsTypeSignatureMismatch() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("disguised.mp4")
        try Data("not a movie".utf8).write(to: source)
        let store = WorkspaceStore(root: root)

        do {
            _ = try await store.stageFileAttachment(from: source)
            XCTFail("A mismatched signature must be rejected")
        } catch {
            guard case WorkspaceError.unsupportedFileType = error else {
                return XCTFail("Expected unsupportedFileType, got \(error)")
            }
        }
    }

    func testStageImageNormalizesDimensionsAndUsesInterpolatedUUIDFilename() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        let admitted = try await store.stageImageWithMetadata(
            makeJPEG(width: 4_000, height: 1_000)
        )
        let second = try await store.stageImageWithMetadata(
            makeJPEG(width: 32, height: 16)
        )

        XCTAssertLessThanOrEqual(max(admitted.width, admitted.height), 2_048)
        XCTAssertEqual(admitted.width, 2_048)
        XCTAssertEqual(admitted.height, 512)
        XCTAssertEqual(admitted.originalWidth, 4_000)
        XCTAssertEqual(admitted.originalHeight, 1_000)
        XCTAssertEqual(admitted.reference.mimeType, "image/jpeg")
        XCTAssertLessThanOrEqual(admitted.reference.byteCount, 4 * 1_024 * 1_024)
        XCTAssertTrue(admitted.reference.path.hasPrefix("Attachments/"))
        XCTAssertTrue(admitted.reference.path.hasSuffix(".jpg"))
        XCTAssertFalse(admitted.reference.path.contains("id.uuidString"))
        XCTAssertTrue(admitted.reference.path.contains(admitted.reference.id.uuidString.lowercased()))
        XCTAssertNotEqual(admitted.reference.path, second.reference.path)

        let stored = try await store.readAttachment(admitted.reference)
        XCTAssertEqual(stored.count, admitted.reference.byteCount)
        let dimensions = try imageDimensions(stored)
        XCTAssertEqual(dimensions.width, admitted.width)
        XCTAssertEqual(dimensions.height, admitted.height)
        let latestReference = try await store.latestImageReference()
        let latestData = try await store.latestImageData()
        let secondData = try await store.readAttachment(second.reference)
        XCTAssertEqual(latestReference, second.reference)
        XCTAssertEqual(latestData, secondData)
    }

    func testStageImageRejectsMalformedAndOversizedInputBeforePersistence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)

        do {
            _ = try await store.stageImage(Data([0x01, 0x02, 0x03]))
            XCTFail("Malformed image should be rejected")
        } catch {
            XCTAssertEqual(error as? ImageAdmissionError, .invalidImage)
        }

        do {
            _ = try await store.stageImage(Data(count: 20 * 1_024 * 1_024 + 1))
            XCTFail("Oversized input should be rejected")
        } catch {
            XCTAssertEqual(
                error as? ImageAdmissionError,
                .inputTooLarge(20 * 1_024 * 1_024)
            )
        }
        let hasStagedImage = await store.hasStagedImage()
        XCTAssertFalse(hasStagedImage)
    }

    func testStageImageAppliesContainerOrientationBeforePersistence() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)

        let admitted = try await store.stageImageWithMetadata(
            makeJPEG(width: 40, height: 20, orientation: 6)
        )

        XCTAssertEqual(admitted.width, 20)
        XCTAssertEqual(admitted.height, 40)
        XCTAssertNil(admitted.originalWidth)
        XCTAssertNil(admitted.originalHeight)
    }

    func testModelRequestImageVariantIsBoundedAndReused() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        let admitted = try await store.stageImageWithMetadata(
            makeNoiseJPEG(width: 1_600, height: 1_600)
        )
        XCTAssertGreaterThan(
            admitted.reference.byteCount,
            WorkspaceStore.maximumModelRequestImageBytes
        )

        let first = try await store.readAttachmentForModelRequest(admitted.reference)
        let second = try await store.readAttachmentForModelRequest(admitted.reference)
        XCTAssertLessThanOrEqual(first.count, WorkspaceStore.maximumModelRequestImageBytes)
        XCTAssertEqual(first, second)
        XCTAssertLessThan(first.count, admitted.reference.byteCount)
        let dimensions = try imageDimensions(first)
        XCTAssertLessThanOrEqual(max(dimensions.width, dimensions.height), 2_048)
    }

    func testPluginArchiveIsStagedInPrivateImportDirectoryAndRemoved() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("plugin.zip")
        let archive = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02])
        try archive.write(to: source)

        let store = WorkspaceStore(root: root)
        let guestPath = try await store.stagePluginArchive(from: source)
        let filename = try XCTUnwrap(guestPath.split(separator: "/").last.map(String.init))
        let staged = root
            .appendingPathComponent(".harness-mobile/plugin-imports", isDirectory: true)
            .appendingPathComponent(filename)

        XCTAssertTrue(guestPath.hasPrefix("/workspace/.harness-mobile/plugin-imports/"))
        XCTAssertEqual(try Data(contentsOf: staged), archive)
        let visibleFiles = try await store.listFiles()
        XCTAssertFalse(visibleFiles.contains { $0.path.contains("plugin-imports") })

        try await store.removeStagedPluginArchive(guestPath: guestPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testPluginArchiveStagingRejectsNonZipAndUnsafeRemovalPath() async throws {
        let root = temporaryDirectory()
        let sourceRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = sourceRoot.appendingPathComponent("plugin.zip")
        try Data("not a zip".utf8).write(to: source)

        let store = WorkspaceStore(root: root)
        do {
            _ = try await store.stagePluginArchive(from: source)
            XCTFail("A non-ZIP payload should be rejected")
        } catch {
            guard case WorkspaceError.unsupportedFileType = error else {
                return XCTFail("Expected unsupportedFileType, got \(error)")
            }
        }

        do {
            try await store.removeStagedPluginArchive(
                guestPath: "/workspace/.harness-mobile/plugin-imports/../escape.zip"
            )
            XCTFail("An unsafe staged archive path should be rejected")
        } catch {
            guard case WorkspaceError.invalidPath = error else {
                return XCTFail("Expected invalidPath, got \(error)")
            }
        }
    }

    func testMountedFolderSharesOnePathWithNativeWorkspaceTools() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("external".utf8).write(to: external.appendingPathComponent("readme.md"))

        let store = WorkspaceStore(
            root: root,
            allowsUnscopedMounts: true
        )
        let mount = try await store.mountFolder(
            from: external,
            preferredName: "Project",
            access: .readWrite
        )

        XCTAssertEqual(mount.status, .active)
        XCTAssertEqual(mount.guestPath, "/workspace/mounts/Project")
        let mountedText = try await store.readText(path: "mounts/Project/readme.md")
        XCTAssertEqual(mountedText, "external")

        try await store.writeText(path: "mounts/Project/result.md", text: "written")
        XCTAssertEqual(
            try String(contentsOf: external.appendingPathComponent("result.md"), encoding: .utf8),
            "written"
        )
        let listedFiles = try await store.listFiles()
        XCTAssertTrue(listedFiles.contains { $0.path == "mounts/Project/result.md" })

        let bindings = try await store.activeMountBindings()
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].guestPath, "/workspace/mounts/Project")
        XCTAssertFalse(bindings[0].readOnly)
    }

    func testMountNameMayCollideWithExistingWorkspaceItem() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mounts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("existing".utf8).write(
            to: root
                .appendingPathComponent("mounts", isDirectory: true)
                .appendingPathComponent("File Provider Storage")
        )
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("mounted".utf8).write(to: external.appendingPathComponent("source.md"))

        let store = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        let mount = try await store.mountFolder(
            from: external,
            preferredName: "File Provider Storage"
        )

        XCTAssertEqual(mount.status, .active)
        let mountedText = try await store.readText(path: "mounts/File Provider Storage/source.md")
        XCTAssertEqual(mountedText, "mounted")
    }

    func testCorruptedMountRegistryIsQuarantinedAndDoesNotBlockWorkspace() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = root.appendingPathComponent(".harness-mobile", isDirectory: true)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        let registry = configuration.appendingPathComponent("workspace-mounts.json")
        try Data("not-json".utf8).write(to: registry)

        let store = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        let mounts = try await store.activateMounts()

        XCTAssertTrue(mounts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: configuration.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("workspace-mounts.corrupt-") })
    }

    func testReadOnlyMountRejectsWritesAndPersistsAcrossStoreReload() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: external.appendingPathComponent("source.md"))

        let firstStore = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        let mount = try await firstStore.mountFolder(
            from: external,
            preferredName: "Vault",
            access: .readOnly
        )
        do {
            try await firstStore.writeText(path: "mounts/Vault/new.md", text: "blocked")
            XCTFail("A read-only mount must reject writes")
        } catch {
            guard case WorkspaceError.mountReadOnly("Vault") = error else {
                return XCTFail("Expected mountReadOnly, got \(error)")
            }
        }

        let reloadedStore = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        let mounts = try await reloadedStore.activateMounts()
        XCTAssertEqual(mounts.map(\.id), [mount.id])
        XCTAssertEqual(mounts.first?.access, .readOnly)
        let reloadedText = try await reloadedStore.readText(path: "mounts/Vault/source.md")
        XCTAssertEqual(reloadedText, "source")
        let reloadedBindings = try await reloadedStore.activeMountBindings()
        XCTAssertEqual(reloadedBindings.first?.readOnly, true)
    }

    func testMountedFolderSymlinkEscapeIsRejected() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.md"))
        try FileManager.default.createSymbolicLink(
            at: external.appendingPathComponent("outside"),
            withDestinationURL: outside
        )

        let store = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        _ = try await store.mountFolder(from: external, preferredName: "Project")
        do {
            _ = try await store.readText(path: "mounts/Project/outside/secret.md")
            XCTFail("A mounted-folder symlink must not escape its root")
        } catch {
            guard case WorkspaceError.pathEscapesWorkspace = error else {
                return XCTFail("Expected pathEscapesWorkspace, got \(error)")
            }
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessMobileTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeJPEG(width: Int, height: Int, orientation: Int? = nil) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { preconditionFailure("Could not create test image context") }
        context.setFillColor(CGColor(red: 0.12, green: 0.42, blue: 0.78, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            preconditionFailure("Could not create test image")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { preconditionFailure("Could not create JPEG destination") }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.96
        ]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeNoiseJPEG(width: Int, height: Int) -> Data {
        var pixels = Data(count: width * height * 4)
        var image: CGImage? = nil
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                preconditionFailure("Could not allocate noise image")
            }
            var state: UInt64 = 0x9E37_79B9_7F4A_7C15
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes[offset] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 24)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 32)
                bytes[offset + 3] = 255
            }
            let context = CGContext(
                data: bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            image = context?.makeImage()
        }
        guard let image else { preconditionFailure("Could not create noise image") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { preconditionFailure("Could not create noise JPEG destination") }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary
        )
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func imageDimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber)
        return (width.intValue, height.intValue)
    }
}
