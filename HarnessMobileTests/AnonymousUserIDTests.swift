import Foundation
import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

/// Pins the anonymous id contract: random UUID v4 persisted as a bare line,
/// memoized for the process lifetime, and a corrupt file is treated like an
/// absent one (fresh identity, never derived from other sources).
final class AnonymousUserIDTests: XCTestCase {
    private func makeHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anon-id-\(UUID().uuidString)", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        AnonymousUserID.resetMemoForTesting()
    }

    func testResolveMintsAndPersistsBareUUIDLine() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let id = AnonymousUserID.resolve(home: home)
        XCTAssertTrue(AnonymousUserID.isValidUUID(id))
        let persisted = try String(
            contentsOf: home.appendingPathComponent(AnonymousUserID.fileName),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(persisted, id)
    }

    func testResolveReusesPersistedIDAndMemoizes() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = AnonymousUserID.resolve(home: home)
        let second = AnonymousUserID.resolve(home: home)
        XCTAssertEqual(first, second)
        // Deleting the file mid-run keeps this run's id (memo contract).
        try FileManager.default.removeItem(at: home.appendingPathComponent(AnonymousUserID.fileName))
        XCTAssertEqual(AnonymousUserID.resolve(home: home), first)
    }

    func testCorruptFileIsReplacedWithFreshIdentity() throws {
        let home = makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "not a uuid".write(
            to: home.appendingPathComponent(AnonymousUserID.fileName),
            atomically: true,
            encoding: .utf8
        )
        let id = AnonymousUserID.resolve(home: home)
        XCTAssertTrue(AnonymousUserID.isValidUUID(id))
    }

    func testDistinctHomesMintDistinctIDs() {
        let homeA = makeHome()
        let homeB = makeHome()
        defer {
            try? FileManager.default.removeItem(at: homeA)
            try? FileManager.default.removeItem(at: homeB)
        }
        XCTAssertNotEqual(AnonymousUserID.resolve(home: homeA), AnonymousUserID.resolve(home: homeB))
    }
}
