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

final class FileSystemToolsTests: XCTestCase {
    func testWriteCanCreateAndClearAnEmptyFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        let registry = fileToolRegistry(store: store, sessionID: "empty-write")
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("empty.txt"),
            "content": .string("")
        ])
        let created = try await store.readText(path: "empty.txt")
        XCTAssertEqual(created, "")

        try await store.writeText(path: "clear.txt", text: "remove me")
        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("clear.txt")
        ])
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("clear.txt"),
            "content": .string("")
        ])
        let cleared = try await store.readText(path: "clear.txt")
        XCTAssertEqual(cleared, "")
    }

    func testEditCanDeleteTheMatchedText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "delete.txt", text: "keep remove keep")
        let registry = fileToolRegistry(store: store, sessionID: "edit-delete")
        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("delete.txt")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("delete.txt"),
            "old_string": .string(" remove"),
            "new_string": .string("")
        ])
        let edited = try await store.readText(path: "delete.txt")
        XCTAssertEqual(edited, "keep keep")
    }

    func testWriteCreatesNewFileWithoutPriorRead() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        let registry = fileToolRegistry(store: store, sessionID: "create")
        let output = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("notes/new.md"),
            "content": .string("created")
        ])

        XCTAssertTrue(output.contains("Created file"))
        let storedText = try await store.readText(path: "notes/new.md")
        XCTAssertEqual(storedText, "created")
    }

    func testOverwriteRequiresReadAndThenUsesObservedVersion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "notes.md", text: "before")
        let registry = fileToolRegistry(store: store, sessionID: "overwrite")

        await assertFsError(.notObserved) {
            _ = try await self.tool("write", in: registry).execute(arguments: [
                "file_path": .string("notes.md"),
                "content": .string("after")
            ])
        }

        let readOutput = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("notes.md")
        ])
        XCTAssertTrue(readOutput.contains("1: before"))

        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("notes.md"),
            "content": .string("after")
        ])
        let storedText = try await store.readText(path: "notes.md")
        XCTAssertEqual(storedText, "after")
    }

    func testExternalMutationInvalidatesObservedVersion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "shared.md", text: "version one")
        let registry = fileToolRegistry(store: store, sessionID: "stale")
        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("shared.md")
        ])

        try await store.writeText(path: "shared.md", text: "version two from iSH")

        await assertFsError(.staleVersion) {
            _ = try await self.tool("edit", in: registry).execute(arguments: [
                "file_path": .string("shared.md"),
                "old_string": .string("version one"),
                "new_string": .string("version three")
            ])
        }
    }

    func testSuccessfulEditRefreshesVersionForNextEdit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "sequence.txt", text: "one two")
        let registry = fileToolRegistry(store: store, sessionID: "edit-sequence")

        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "old_string": .string("one"),
            "new_string": .string("first")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "old_string": .string("two"),
            "new_string": .string("second")
        ])

        let finalText = try await store.readText(path: "sequence.txt")
        XCTAssertEqual(finalText, "first second")
    }

    func testSuccessfulWriteRefreshesVersionForNextEdit() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "sequence.txt", text: "before")
        let registry = fileToolRegistry(store: store, sessionID: "write-sequence")

        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt")
        ])
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "content": .string("middle")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "old_string": .string("middle"),
            "new_string": .string("after")
        ])

        let finalText = try await store.readText(path: "sequence.txt")
        XCTAssertEqual(finalText, "after")
    }

    func testSuccessfulEditRefreshesVersionForNextWrite() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "sequence.txt", text: "before")
        let registry = fileToolRegistry(store: store, sessionID: "edit-write-sequence")

        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "old_string": .string("before"),
            "new_string": .string("middle")
        ])
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "content": .string("after")
        ])

        let finalText = try await store.readText(path: "sequence.txt")
        XCTAssertEqual(finalText, "after")
    }

    func testTwoSuccessfulWritesUseTheLatestFreshnessBaseline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "sequence.txt", text: "before")
        let registry = fileToolRegistry(store: store, sessionID: "write-write-sequence")

        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt")
        ])
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "content": .string("middle")
        ])
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("sequence.txt"),
            "content": .string("after")
        ])

        let finalText = try await store.readText(path: "sequence.txt")
        XCTAssertEqual(finalText, "after")
    }

    func testEditRequiresReadAndRejectsAmbiguousReplacement() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "repeat.txt", text: "same same")
        let registry = fileToolRegistry(store: store, sessionID: "edit")

        await assertFsError(.notObserved) {
            _ = try await self.tool("edit", in: registry).execute(arguments: [
                "file_path": .string("repeat.txt"),
                "old_string": .string("same"),
                "new_string": .string("new")
            ])
        }

        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("repeat.txt")
        ])
        await assertFsError(.ambiguousEdit) {
            _ = try await self.tool("edit", in: registry).execute(arguments: [
                "file_path": .string("repeat.txt"),
                "old_string": .string("same"),
                "new_string": .string("new")
            ])
        }

        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("repeat.txt"),
            "old_string": .string("same"),
            "new_string": .string("new"),
            "replace_all": .bool(true)
        ])
        let storedText = try await store.readText(path: "repeat.txt")
        XCTAssertEqual(storedText, "new new")
    }

    func testCanonicalToolsUseMountedFolderPath() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("mounted".utf8).write(to: external.appendingPathComponent("source.md"))

        let store = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        _ = try await store.mountFolder(
            from: external,
            preferredName: "Project",
            access: .readWrite
        )
        let registry = fileToolRegistry(store: store, sessionID: "mount")

        let output = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("/workspace/mounts/Project/source.md")
        ])
        XCTAssertTrue(output.contains("1: mounted"))

        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("/workspace/mounts/Project/result.md"),
            "content": .string("native")
        ])
        XCTAssertEqual(
            try String(contentsOf: external.appendingPathComponent("result.md"), encoding: .utf8),
            "native"
        )
    }

    func testReadDoesNotReportPhantomLineAfterTrailingNewline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "lines.txt", text: "first\n\nthird\n")
        let registry = fileToolRegistry(store: store, sessionID: "trailing-newline")

        let output = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("lines.txt")
        ])

        XCTAssertTrue(output.contains("1: first"))
        XCTAssertTrue(output.contains("2: \n"))
        XCTAssertTrue(output.contains("3: third"))
        XCTAssertTrue(output.contains("total 3 lines"))
        XCTAssertFalse(output.contains("4: "))
    }

    func testReadReportsAnEmptyFileAsZeroLines() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "empty.txt", text: "")
        let output = try await tool(
            "read",
            in: fileToolRegistry(store: store, sessionID: "empty-read")
        ).execute(arguments: ["file_path": .string("empty.txt")])

        XCTAssertTrue(output.contains("End of file - total 0 lines"))
        XCTAssertFalse(output.contains("1: "))
    }

    func testWorkspaceAliasesShareCanonicalFreshnessBaseline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "alias.txt", text: "one")
        let registry = fileToolRegistry(store: store, sessionID: "aliases")

        _ = try await tool("workspace_read_text", in: registry).execute(arguments: [
            "path": .string("alias.txt")
        ])
        _ = try await tool("write", in: registry).execute(arguments: [
            "file_path": .string("alias.txt"),
            "content": .string("two")
        ])
        _ = try await tool("workspace_write_text", in: registry).execute(arguments: [
            "path": .string("alias.txt"),
            "text": .string("three")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("alias.txt"),
            "old_string": .string("three"),
            "new_string": .string("four")
        ])

        let finalText = try await store.readText(path: "alias.txt")
        XCTAssertEqual(finalText, "four")
    }

    func testEditPreservesCRLFWhileUsingLFMatchText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("windows.txt")
        try Data("one\r\ntwo\r\n".utf8).write(to: file)

        let store = WorkspaceStore(root: root)
        let registry = fileToolRegistry(store: store, sessionID: "crlf")
        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("windows.txt")
        ])
        _ = try await tool("edit", in: registry).execute(arguments: [
            "file_path": .string("windows.txt"),
            "old_string": .string("one\ntwo"),
            "new_string": .string("first\nsecond")
        ])

        XCTAssertEqual(String(decoding: try Data(contentsOf: file), as: UTF8.self), "first\r\nsecond\r\n")
    }

    func testReadRejectsNULContainingUTF8AsBinary() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x61, 0x00, 0x62]).write(to: root.appendingPathComponent("binary.dat"))
        let registry = fileToolRegistry(store: WorkspaceStore(root: root), sessionID: "nul")

        await assertFsError(.notText) {
            _ = try await self.tool("read", in: registry).execute(arguments: [
                "file_path": .string("binary.dat")
            ])
        }
    }

    func testStreamingReadPreservesUTF8SplitAcrossChunkBoundary() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expected = String(repeating: "a", count: 32 * 1_024 - 1) + "你\nsecond"
        try Data(expected.utf8).write(to: root.appendingPathComponent("chunked.txt"))

        let provider = WorkspaceFileSystemProvider(store: WorkspaceStore(root: root))
        let target = try await provider.resolve("chunked.txt", cwd: "/workspace")
        let stream = try await provider.streamText(target)
        var actual = ""
        for try await chunk in stream { actual += chunk }

        XCTAssertEqual(actual, expected)
    }

    func testFileValidationErrorsIdentifyTheInvalidField() throws {
        let registry = fileToolRegistry(store: WorkspaceStore(), sessionID: "validation")
        XCTAssertThrowsError(try tool("read", in: registry).validate(arguments: [
            "file_path": .string("file.txt"),
            "offset": .number(0)
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("offset"))
            XCTAssertFalse(error.localizedDescription.contains("JSON 对象"))
        }
        XCTAssertThrowsError(try tool("edit", in: registry).validate(arguments: [
            "file_path": .string("file.txt"),
            "old_string": .string("same"),
            "new_string": .string("same")
        ])) { error in
            XCTAssertTrue(error.localizedDescription.contains("new_string"))
        }
    }

    func testWorkspaceSearchFindsHiddenTextSkipsBinaryAndHonorsOptions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: ".harness-mobile/state.log", text: "Needle\nsecond")
        try await store.writeText(path: "visible.txt", text: "needle\nNEEDLE")
        let rootURL = try await store.rootURL()
        try Data([0xff, 0xfe, 0xfd]).write(
            to: rootURL.appendingPathComponent(".harness-mobile/blob.dat")
        )
        let registry = fileToolRegistry(store: store, sessionID: "search")

        let hidden = try await tool("workspace_search", in: registry).execute(arguments: [
            "query": .string("needle"),
            "case_sensitive": .bool(false),
            "include_hidden": .bool(true),
            "max_results": .number(3)
        ])
        XCTAssertTrue(hidden.contains(".harness-mobile/state.log"))
        XCTAssertTrue(hidden.contains("visible.txt"))
        XCTAssertFalse(hidden.contains("blob.dat"))
        XCTAssertTrue(hidden.contains("\"truncated\""))

        let visibleOnly = try await tool("workspace_search", in: registry).execute(arguments: [
            "query": .string("NEEDLE"),
            "case_sensitive": .bool(true),
            "include_hidden": .bool(false)
        ])
        XCTAssertFalse(visibleOnly.contains(".harness-mobile/state.log"))
        XCTAssertTrue(visibleOnly.contains("visible.txt"))
        XCTAssertTrue(visibleOnly.contains("\"line\""))
    }

    func testReadImageAdmitsWorkspaceFileAndReturnsDurableAttachmentContract() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = makeJPEG(width: 3_000, height: 1_500)
        try source.write(to: root.appendingPathComponent("diagram.jpg"))
        let registry = fileToolRegistry(store: store, sessionID: "read-image")

        // `glob` and `workspace_search` expose canonical guest paths. Keep
        // this regression on that boundary instead of only testing a cwd-
        // relative path, so a model can pass the returned path directly to
        // read_image.
        let output = try await tool("read_image", in: registry).execute(arguments: [
            "file_path": .string("/workspace/diagram.jpg")
        ])
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        let rootValue = try XCTUnwrap(value.objectValue)
        let image = try XCTUnwrap(rootValue["image"]?.objectValue)
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(image["attachmentId"]?.stringValue)))
        let path = try XCTUnwrap(image["attachmentPath"]?.stringValue)
        let mimeType = try XCTUnwrap(image["mediaType"]?.stringValue)
        guard case let .number(byteCountValue)? = image["bytes"],
              case let .number(widthValue)? = image["width"],
              case let .number(heightValue)? = image["height"] else {
            return XCTFail("read_image metadata must contain numeric bytes and dimensions")
        }
        let attachment = AgentImageAttachmentRef(
            id: id,
            path: path,
            mimeType: mimeType,
            byteCount: Int(byteCountValue)
        )
        let stored = try await store.readAttachment(attachment)

        XCTAssertEqual(rootValue["path"]?.stringValue, "/workspace/diagram.jpg")
        XCTAssertEqual(mimeType, "image/jpeg")
        XCTAssertEqual(stored.count, attachment.byteCount)
        XCTAssertLessThanOrEqual(max(Int(widthValue), Int(heightValue)), 2_048)
        XCTAssertLessThanOrEqual(stored.count, 4 * 1_024 * 1_024)
        let original = try XCTUnwrap(image["originalDimensions"]?.objectValue)
        XCTAssertEqual(original["width"], .number(3_000))
        XCTAssertEqual(original["height"], .number(1_500))
        let latestReference = try await store.latestImageReference()
        XCTAssertEqual(latestReference, attachment)
    }

    func testReadImageRejectsExtensionContentMismatchWithoutStagingAttachment() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeJPEG(width: 32, height: 16).write(to: root.appendingPathComponent("wrong.png"))
        let registry = fileToolRegistry(store: store, sessionID: "read-image-mismatch")

        do {
            _ = try await tool("read_image", in: registry).execute(arguments: [
                "file_path": .string("wrong.png")
            ])
            XCTFail("Mismatched extension and bytes should be rejected")
        } catch {
            XCTAssertEqual(
                error as? ImageAdmissionError,
                .typeMismatch(expected: "image/png", actual: "image/jpeg")
            )
        }
        let hasStagedImage = await store.hasStagedImage()
        XCTAssertFalse(hasStagedImage)
    }

    private func tool(
        _ name: String,
        in registry: LocalToolRegistry
    ) throws -> any LocalAgentTool {
        try XCTUnwrap(registry.tool(named: name))
    }

    private func fileToolRegistry(
        store: WorkspaceStore,
        sessionID: String
    ) -> LocalToolRegistry {
        let environment = FileSystemToolEnvironment.guarded(
            fileSystem: WorkspaceFileSystemProvider(store: store),
            sessionID: sessionID,
            policy: HarnessFsObservationPolicy()
        )
        return LocalToolRegistry(
            tools: [
                WorkspaceReadTextTool(environment: environment),
                WorkspaceWriteTextTool(environment: environment)
            ] + FileSystemToolSuite.makeTools(
                environment: environment,
                imageStore: store
            ) + DeliverableToolSuite.makeTools(environment: environment)
        )
    }

    func testWorkspaceDiffReturnsStructuredUnifiedDiffWithoutWriting() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "report.md", text: "one\ntwo\n")
        let registry = fileToolRegistry(store: store, sessionID: "diff")
        let output = try await tool("workspace_diff", in: registry).execute(arguments: [
            "file_path": .string("report.md"),
            "proposed_content": .string("one\nthree\n")
        ])
        let value = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)).objectValue)
        XCTAssertEqual(value["kind"], .string("diff"))
        XCTAssertEqual(value["changed"], .bool(true))
        XCTAssertTrue(value["diff"]?.stringValue?.contains("-two") == true)
        XCTAssertTrue(value["diff"]?.stringValue?.contains("+three") == true)
        let unchanged = try await store.readText(path: "report.md")
        XCTAssertEqual(unchanged, "one\ntwo\n")
    }

    func testDeliverableWriteUsesFreshnessAndReturnsPreviewMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "deliverables/old.md", text: "old")
        let registry = fileToolRegistry(store: store, sessionID: "deliverable")
        await assertFsError(.notObserved) {
            _ = try await self.tool("deliverable_write", in: registry).execute(arguments: [
                "file_path": .string("deliverables/old.md"),
                "content": .string("new")
            ])
        }
        _ = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string("deliverables/old.md")
        ])
        let output = try await tool("deliverable_write", in: registry).execute(arguments: [
            "file_path": .string("deliverables/old.md"),
            "content": .string("new\ncontent"),
            "title": .string("Final report")
        ])
        let value = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)).objectValue)
        XCTAssertEqual(value["kind"], .string("deliverable"))
        XCTAssertEqual(value["title"], .string("Final report"))
        XCTAssertEqual(value["shareable"], .bool(true))
        let stored = try await store.readText(path: "deliverables/old.md")
        XCTAssertEqual(stored, "new\ncontent")
    }

    func testDeliverablePreviewIsBoundedByUTF8Bytes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkspaceStore(root: root)
        let registry = fileToolRegistry(store: store, sessionID: "deliverable-unicode")
        let content = String(repeating: "界", count: 3_000)
        let output = try await tool("deliverable_write", in: registry).execute(arguments: [
            "file_path": .string("deliverables/unicode.md"),
            "content": .string(content)
        ])
        let value = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)).objectValue)
        let preview = try XCTUnwrap(value["preview"]?.stringValue)
        XCTAssertLessThanOrEqual(preview.utf8.count, 4 * 1_024)
        XCTAssertEqual(value["preview_truncated"], .bool(true))
        XCTAssertEqual(value["bytes"], .number(Double(content.utf8.count)))
    }

    private func assertFsError(
        _ expectedCode: HarnessFsErrorCode,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expectedCode.rawValue)")
        } catch let error as HarnessFsError {
            XCTAssertEqual(error.code, expectedCode)
        } catch {
            XCTFail("Expected HarnessFsError, got \(error)")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("HarnessFileSystemTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeJPEG(width: Int, height: Int) -> Data {
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
        context.setFillColor(CGColor(red: 0.72, green: 0.18, blue: 0.28, alpha: 1))
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
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary
        )
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
