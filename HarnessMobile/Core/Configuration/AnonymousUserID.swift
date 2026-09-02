import Foundation

/// Mirrors upstream `anonymous-user-id`: a per-harness-home anonymous id
/// shared by telemetry and feedback.
///
/// The id is a random UUID persisted as a bare line in `.anonymous-user-id`
/// inside the harness home, and is never derived from the hostname, network
/// address, git remote, or any other identifying source. It is scoped to the
/// home, not the machine: every run sharing one home reports the same id, and
/// deleting the file mints a fresh identity on the next launch. The result is
/// memoized per resolved file path for the process lifetime, so a file deleted
/// mid-run keeps this run's id until the next launch.
enum AnonymousUserID {
    static let fileName = ".anonymous-user-id"

    private static let lock = NSLock()
    // Guarded by `lock`; NSLock makes cross-isolation access safe.
    nonisolated(unsafe) private static var memo: [String: String] = [:]
    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    /// Reads a valid persisted id from the file, or nil when absent/corrupt.
    static func readPersistedID(at file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidUUID(trimmed) else { return nil }
        return trimmed
    }

    /// Mints and persists a fresh id as a bare UUID line.
    static func mintAndPersist(at file: URL) throws -> String {
        let id = UUID().uuidString
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    /// Returns the home's id, minting one when absent. Synchronous so
    /// boot-time consumers can share one API; memoized per file path.
    static func resolve(home: URL) -> String {
        let file = home.appendingPathComponent(fileName)
        let key = file.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let cached = memo[key] {
            return cached
        }
        let id = readPersistedID(at: file) ?? (try? mintAndPersist(at: file)) ?? UUID().uuidString
        memo[key] = id
        return id
    }

    static func isValidUUID(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return uuidPattern.firstMatch(in: text, range: range) != nil
    }

    /// Test hook: clears the process memo.
    static func resetMemoForTesting() {
        lock.lock()
        defer { lock.unlock() }
        memo.removeAll()
    }
}
