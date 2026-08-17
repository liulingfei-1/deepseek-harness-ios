import Foundation
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
        try await store.stageImage(Data([0x01, 0x02, 0x03]))

        let entries = try await store.listFiles()
        XCTAssertEqual(entries.map(\.path), ["visible.md"])
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
}
