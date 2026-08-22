import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class StrReplaceEditorToolTests: XCTestCase {
    func testSchemaMatchesOfficialFourCommandSurface() throws {
        let tool = makeTool(store: WorkspaceStore(), sessionID: "schema")
        let properties = try XCTUnwrap(tool.definition.parameters.objectValue?["properties"]?.objectValue)
        XCTAssertEqual(
            properties["command"]?.objectValue?["enum"],
            .array(["view", "create", "str_replace", "insert"].map(JSONValue.string))
        )
        XCTAssertThrowsError(try tool.validate(arguments: [
            "command": .string("view"),
            "path": .string("relative.txt")
        ]))
    }

    func testViewUsesLineNumbersAndRange() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "sample.txt", text: "one\ntwo\nthree")
        let output = try await makeTool(store: store, sessionID: "view").execute(arguments: [
            "command": .string("view"),
            "path": .string("/workspace/sample.txt"),
            "view_range": .array([.number(2), .number(3)])
        ])
        XCTAssertTrue(output.contains("view_range=[2, 3]"))
        XCTAssertTrue(output.contains("     2  two"))
        XCTAssertTrue(output.contains("     3  three"))
        XCTAssertFalse(output.contains("     1  one"))
    }

    func testDirectoryViewIsTwoLevelsAndFiltersGeneratedDirectories() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        let paths = [
            "Project/visible.txt",
            "Project/Sources/App.swift",
            "Project/Sources/Nested/deep.txt",
            "Project/node_modules/pkg.js",
            "Project/.secret",
            "Project/__pycache__/cache.pyc"
        ]
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: file)
        }
        let hidden = root.appendingPathComponent("Project/.secret")
        let cache = root.appendingPathComponent("Project/__pycache__/cache.pyc")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        let output = try await makeTool(store: store, sessionID: "directory").execute(arguments: [
            "command": .string("view"),
            "path": .string("/workspace/Project")
        ])
        XCTAssertTrue(output.contains("visible.txt"))
        XCTAssertTrue(output.contains("Sources/App.swift"))
        XCTAssertTrue(output.contains("Sources/Nested"))
        XCTAssertFalse(output.contains("deep.txt"))
        XCTAssertFalse(output.contains(".secret"))
        XCTAssertFalse(output.contains("/workspace/Project/node_modules"))
        XCTAssertFalse(output.contains("/workspace/Project/__pycache__"))
    }

    func testCreateNeverOverwritesAndAllowsEmptyContent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        let tool = makeTool(store: store, sessionID: "create")
        _ = try await tool.execute(arguments: [
            "command": .string("create"),
            "path": .string("/workspace/empty.txt"),
            "file_text": .string("")
        ])
        let created = try await store.readText(path: "empty.txt")
        XCTAssertEqual(created, "")

        do {
            _ = try await tool.execute(arguments: [
                "command": .string("create"),
                "path": .string("/workspace/empty.txt"),
                "file_text": .string("overwrite")
            ])
            XCTFail("create must not overwrite")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
    }

    func testStrReplaceRequiresUniqueMatchAndReportsLines() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "repeat.txt", text: "same\nkeep\nsame")
        let tool = makeTool(store: store, sessionID: "replace")

        do {
            _ = try await tool.execute(arguments: [
                "command": .string("str_replace"),
                "path": .string("/workspace/repeat.txt"),
                "old_str": .string("same"),
                "new_str": .string("new")
            ])
            XCTFail("ambiguous replacement must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("lines [1, 3]"))
            XCTAssertFalse(error.localizedDescription.contains("old_string"))
        }

        _ = try await tool.execute(arguments: [
            "command": .string("str_replace"),
            "path": .string("/workspace/repeat.txt"),
            "old_str": .string("same\nkeep"),
            "new_str": .string("")
        ])
        let edited = try await store.readText(path: "repeat.txt")
        XCTAssertEqual(edited, "\nsame")
    }

    func testInsertUsesZeroBasedBoundaryWithoutImplicitTrailingNewline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "insert.txt", text: "one\ntwo")
        let tool = makeTool(store: store, sessionID: "insert")
        _ = try await tool.execute(arguments: [
            "command": .string("insert"),
            "path": .string("/workspace/insert.txt"),
            "insert_line": .number(1),
            "new_str": .string("middle")
        ])
        let edited = try await store.readText(path: "insert.txt")
        XCTAssertEqual(edited, "one\nmiddle\ntwo")
        XCTAssertFalse(edited.hasSuffix("\n"))
    }

    private func makeTool(store: WorkspaceStore, sessionID: String) -> StrReplaceEditorTool {
        StrReplaceEditorTool(environment: .guarded(
            fileSystem: WorkspaceFileSystemProvider(store: store),
            sessionID: sessionID,
            policy: HarnessFsObservationPolicy()
        ))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("str-editor-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
