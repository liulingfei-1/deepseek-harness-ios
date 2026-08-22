import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WorkspaceSearchToolsTests: XCTestCase {
    func testGlobUsesRecursiveBasenameAndBraceSemanticsIncludesHiddenAndExcludesVCS() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "README.md", text: "root")
        try await writeRaw("swift", path: "Sources/App.swift", store: store)
        try await store.writeText(path: ".hidden/Note.md", text: "hidden")
        try await writeRaw("metadata", path: ".git/secret.swift", store: store)
        try await store.writeText(path: "Sources/ignored.txt", text: "other")
        let registry = registry(store: store)

        let output = try await tool("glob", in: registry).execute(arguments: [
            "pattern": .string("*.{swift,md}")
        ])

        XCTAssertTrue(output.contains("/workspace/README.md"))
        XCTAssertTrue(output.contains("/workspace/Sources/App.swift"))
        XCTAssertTrue(output.contains("/workspace/.hidden/Note.md"))
        XCTAssertFalse(output.contains(".git/secret.swift"))
        XCTAssertFalse(output.contains("ignored.txt"))
    }

    func testGlobDiscoversActiveMountButRejectsPathsOutsideWorkspace() async throws {
        let root = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("mounted".utf8).write(to: external.appendingPathComponent("external.txt"))
        let store = WorkspaceStore(root: root, allowsUnscopedMounts: true)
        _ = try await store.mountFolder(from: external, preferredName: "Project", access: .readOnly)
        let registry = registry(store: store)

        let output = try await tool("glob", in: registry).execute(arguments: [
            "pattern": .string("**/*.txt")
        ])
        XCTAssertTrue(output.contains("/workspace/mounts/Project/external.txt"))

        await assertFsError(.sandboxDenied) {
            _ = try await self.tool("glob", in: registry).execute(arguments: [
                "pattern": .string("*"),
                "path": .string("/tmp")
            ])
        }
    }

    func testGlobReturnsCompleteResultsInModificationTimeOrder() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "older.txt", text: "old")
        try await store.writeText(path: "newer.txt", text: "new")
        let rootURL = try await store.rootURL()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: rootURL.appendingPathComponent("older.txt").path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: rootURL.appendingPathComponent("newer.txt").path
        )

        let output = try await tool("glob", in: registry(store: store)).execute(arguments: [
            "pattern": .string("*.txt")
        ])

        let newer = try XCTUnwrap(output.range(of: "/workspace/newer.txt"))
        let older = try XCTUnwrap(output.range(of: "/workspace/older.txt"))
        XCTAssertLessThan(newer.lowerBound, older.lowerBound)
    }

    func testGrepUsesRegexLineNumbersAndGlobFilterAndSkipsBinaryAndHiddenFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await writeRaw("first\nNeedle   42\nlast", path: "Sources/One.swift", store: store)
        try await store.writeText(path: "Sources/Two.md", text: "Needle 99")
        try await writeRaw("Needle 100", path: ".hidden/Three.swift", store: store)
        let rootURL = try await store.rootURL()
        try Data("Needle 200\0binary".utf8).write(to: rootURL.appendingPathComponent("Sources/Binary.swift"))
        let registry = registry(store: store)

        let output = try await tool("grep", in: registry).execute(arguments: [
            "pattern": .string(#"Needle\s+\d+"#),
            "include": .string("*.swift")
        ])

        XCTAssertTrue(output.contains("/workspace/Sources/One.swift"))
        XCTAssertTrue(output.contains("Line 2: Needle   42"))
        XCTAssertFalse(output.contains("Two.md"))
        XCTAssertFalse(output.contains("Three.swift"))
        XCTAssertFalse(output.contains("Binary.swift"))

        let explicitHidden = try await tool("grep", in: registry).execute(arguments: [
            "pattern": .string("Needle"),
            "path": .string("/workspace/.hidden/Three.swift")
        ])
        XCTAssertTrue(explicitHidden.contains("Line 1: Needle 100"))
    }

    func testGrepRejectsInvalidRegexAndListValuedOrNegativeInclude() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = registry(store: WorkspaceStore(root: root))

        await assertSearchError(.invalidPattern) {
            _ = try await self.tool("grep", in: registry).execute(arguments: [
                "pattern": .string("[")
            ])
        }
        XCTAssertThrowsError(try tool("grep", in: registry).validate(arguments: [
            "pattern": .string("x"),
            "include": .string("*.swift,*.md")
        ]))
        XCTAssertThrowsError(try tool("grep", in: registry).validate(arguments: [
            "pattern": .string("x"),
            "include": .string("!*.swift")
        ]))
    }

    func testCappedGlobSpillsCompleteSortedResultAndKeepsModelOutputBounded() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        for index in 0..<8 {
            try await store.writeText(path: "Files/file-\(index).txt", text: "\(index)")
        }
        let configuration = WorkspaceSearchConfiguration(
            globMaximumResults: 2,
            maximumInlineBytes: 500
        )
        let registry = registry(store: store, configuration: configuration)

        let output = try await tool("glob", in: registry).execute(arguments: [
            "pattern": .string("*.txt")
        ])

        XCTAssertLessThanOrEqual(output.utf8.count, 500)
        XCTAssertTrue(output.contains("Showing 2 of 8 paths"))
        let locator = try XCTUnwrap(locator(in: output, marker: "Full sorted result stored at: "))
        XCTAssertTrue(locator.hasPrefix("/workspace/.harness-mobile/tool-results/"))
        let full = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string(locator)
        ])
        for index in 0..<8 {
            XCTAssertTrue(full.contains("/workspace/Files/file-\(index).txt"))
        }
    }

    func testCappedGrepSpillsEveryCompleteMatchedLineAndKeepsWholeInlineRows() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(
            path: "matches.txt",
            text: "needle-abcdefghijklmnopqrstuvwxyz\nneedle-second-complete-line"
        )
        let configuration = WorkspaceSearchConfiguration(
            grepMaximumMatches: 1,
            grepMaximumLineBytes: 18,
            maximumInlineBytes: 500
        )
        let registry = registry(store: store, configuration: configuration)

        let output = try await tool("grep", in: registry).execute(arguments: [
            "pattern": .string("needle")
        ])

        XCTAssertLessThanOrEqual(output.utf8.count, 500)
        XCTAssertTrue(output.contains("Found 1 of 2 matches"))
        XCTAssertTrue(output.contains("(line truncated)"))
        let locator = try XCTUnwrap(locator(in: output, marker: "Full grep result stored at: "))
        let full = try await tool("read", in: registry).execute(arguments: [
            "file_path": .string(locator)
        ])
        XCTAssertTrue(full.contains("Line 1: needle-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(full.contains("Line 2: needle-second-complete-line"))
    }

    func testSearchTimeoutCancellationAndAcquisitionLimitFailWithoutPartialResults() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root)
        try await store.writeText(path: "nested/value.txt", text: "needle")

        let timedRegistry = registry(
            store: store,
            configuration: WorkspaceSearchConfiguration(timeoutSeconds: 0.000_000_001)
        )
        await assertSearchError(.aborted) {
            _ = try await self.tool("glob", in: timedRegistry).execute(arguments: [
                "pattern": .string("*")
            ])
        }

        let limitedRegistry = registry(
            store: store,
            configuration: WorkspaceSearchConfiguration(maximumFilesVisited: 1)
        )
        await assertSearchError(.rawOutputOverflow) {
            _ = try await self.tool("glob", in: limitedRegistry).execute(arguments: [
                "pattern": .string("*")
            ])
        }

        let normalRegistry = registry(store: store)
        let gate = CancellationGate()
        let grepTool = try tool("grep", in: normalRegistry)
        let task = Task<String, Error> {
            await gate.wait()
            return try await grepTool.execute(arguments: [
                "pattern": .string("needle")
            ])
        }
        while !(await gate.hasWaiter()) { await Task.yield() }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled search should fail")
        } catch let error as HarnessSearchError {
            XCTAssertEqual(error.code, .aborted)
        } catch {
            XCTFail("Expected HarnessSearchError, got \(error)")
        }
    }

    private func registry(
        store: WorkspaceStore,
        configuration: WorkspaceSearchConfiguration = .standard
    ) -> LocalToolRegistry {
        let environment = FileSystemToolEnvironment.guarded(
            fileSystem: WorkspaceFileSystemProvider(store: store),
            sessionID: "workspace-search-tests",
            policy: HarnessFsObservationPolicy()
        )
        return LocalToolRegistry(tools: FileSystemToolSuite.makeTools(
            environment: environment,
            searchConfiguration: configuration
        ))
    }

    private func tool(_ name: String, in registry: LocalToolRegistry) throws -> any LocalAgentTool {
        try XCTUnwrap(registry.tool(named: name))
    }

    private func locator(in output: String, marker: String) -> String? {
        guard let markerRange = output.range(of: marker) else { return nil }
        let suffix = output[markerRange.upperBound...]
        return suffix.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    private func assertFsError(
        _ expected: HarnessFsErrorCode,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected.rawValue)")
        } catch let error as HarnessFsError {
            XCTAssertEqual(error.code, expected)
        } catch {
            XCTFail("Expected HarnessFsError, got \(error)")
        }
    }

    private func assertSearchError(
        _ expected: HarnessSearchErrorCode,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected.rawValue)")
        } catch let error as HarnessSearchError {
            XCTAssertEqual(error.code, expected)
        } catch {
            XCTFail("Expected HarnessSearchError, got \(error)")
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceSearchToolsTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeRaw(_ text: String, path: String, store: WorkspaceStore) async throws {
        let url = try await store.rootURL().appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }
}

private actor CancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasWaiter() -> Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
