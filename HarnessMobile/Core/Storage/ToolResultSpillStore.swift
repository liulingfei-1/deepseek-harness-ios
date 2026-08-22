import Foundation

struct ToolResultSpillReference: Sendable, Equatable {
    let locator: String
    let bytes: Int
}

enum ToolResultSpillStoreError: LocalizedError, Sendable, Equatable {
    case contentTooLarge(actualBytes: Int, maximumBytes: Int)

    var errorDescription: String? {
        switch self {
        case let .contentTooLarge(actualBytes, maximumBytes):
            "工具完整结果为 \(actualBytes) 字节，超过本机可保存上限 \(maximumBytes) 字节。"
        }
    }
}

/// Durable storage shared by search-specific overflow and the generic tool
/// result output policy. Locators deliberately use the protected workspace
/// namespace so the model can inspect them with the ordinary `read` tool.
struct ToolResultSpillStore: Sendable {
    static let defaultMaximumBytes = 12 * 1_024 * 1_024

    let fileSystem: any HarnessFileSystem
    let maximumBytes: Int

    init(
        fileSystem: any HarnessFileSystem,
        maximumBytes: Int = Self.defaultMaximumBytes
    ) {
        precondition(maximumBytes > 0)
        self.fileSystem = fileSystem
        self.maximumBytes = maximumBytes
    }

    func save(
        _ content: String,
        suggestedName: String
    ) async throws -> ToolResultSpillReference {
        try Task.checkCancellation()
        let byteCount = content.utf8.count
        guard byteCount <= maximumBytes else {
            throw ToolResultSpillStoreError.contentTooLarge(
                actualBytes: byteCount,
                maximumBytes: maximumBytes
            )
        }
        let safeName = Self.safeFileName(suggestedName)
        let path = "/workspace/.harness-mobile/tool-results/\(UUID().uuidString.lowercased())-\(safeName)"
        let target = try await fileSystem.resolve(path, cwd: "/workspace")
        try Task.checkCancellation()
        _ = try await fileSystem.writeText(
            target,
            content: content,
            expected: .createIfAbsent
        )
        try Task.checkCancellation()
        return ToolResultSpillReference(locator: target.displayPath, bytes: byteCount)
    }

    private static func safeFileName(_ suggestedName: String) -> String {
        let safe = suggestedName
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        let bounded = String(safe.prefix(96))
        return bounded.isEmpty ? "tool-result.txt" : bounded
    }
}
