import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WorkspaceRegistryTests: XCTestCase {
    func testCreateRenameOrderArchiveAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstPath = directory.appendingPathComponent("first", isDirectory: true)
        let secondPath = directory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        let storage = directory.appendingPathComponent("registry.json")
        let registry = LocalWorkspaceRegistry(storageURL: storage)
        let first = try await registry.create(path: firstPath.path, title: "First")
        let second = try await registry.create(path: secondPath.path, title: "Second")
        let sessionID = UUID()
        _ = try await registry.insertSessionBefore(
            workspaceID: first.id,
            sessionID: sessionID
        )
        _ = try await registry.archiveSession(sessionID)
        _ = try await registry.rename(id: second.id, title: "Renamed")
        _ = try await registry.insertBefore(id: second.id, beforeID: first.id)

        let snapshot = try await registry.snapshot()
        XCTAssertEqual(snapshot.workspaces.map(\.id), [second.id, first.id])
        XCTAssertEqual(snapshot.workspaces[1].sessionIDs, [sessionID])
        XCTAssertEqual(snapshot.archivedSessionIDs, [sessionID])

        let reloaded = LocalWorkspaceRegistry(storageURL: storage)
        let reloadedSnapshot = try await reloaded.snapshot()
        XCTAssertEqual(reloadedSnapshot, snapshot)
    }

    func testCreateIsIdempotentAndRejectsInvalidTitlesAndPaths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = LocalWorkspaceRegistry(
            storageURL: directory.appendingPathComponent("registry.json")
        )
        let first = try await registry.create(path: directory.path, title: "Only")
        let resolved = try await registry.create(path: directory.path, title: "Other")
        XCTAssertEqual(resolved, first)
        await XCTAssertThrowsErrorAsync(
            try await registry.rename(id: UUID(), title: "")
        )
        await XCTAssertThrowsErrorAsync(
            try await registry.create(path: directory.appendingPathComponent("missing").path)
        )
    }
}
