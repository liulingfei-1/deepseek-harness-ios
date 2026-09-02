import Foundation

/// Mirrors upstream `deepseek-llm-api-extensions`: a provider-specific
/// registry letting plugins add top-level fields to DeepSeek official LLM API
/// requests after the base body is serialized.
///
/// `register(field:provider:)` claims one field for the calling plugin;
/// duplicate or malformed names fail synchronously. `prepare` snapshots the
/// registered providers, collects their contributions concurrently, and
/// returns the merged top-level fields — a throwing provider rejects the
/// request before HTTP dispatch. `acceptAll` runs each captured provider's
/// post-2xx callback exactly once, merging multiple failures into one error.
final class DeepSeekLlmAPIExtensionRegistry: @unchecked Sendable {
    /// Maximum fields one request may carry, mirroring upstream's bounded
    /// contribution surface.
    static let maximumFields = 32

    enum RegistryError: LocalizedError, Equatable {
        case malformedField(String)
        case duplicateField(String)
        case capacityReached

        var errorDescription: String? {
            switch self {
            case let .malformedField(name):
                "DeepSeek 请求扩展字段名不合法：\(name)。"
            case let .duplicateField(name):
                "DeepSeek 请求扩展字段已被认领：\(name)。"
            case .capacityReached:
                "DeepSeek 请求扩展字段数量已达上限。"
            }
        }
    }

    /// One provider's contribution for a single request.
    struct RequestContext: Sendable {
        /// The exact serialized base body (JSON), read-only.
        let baseBody: Data
        let sessionID: String?
        /// Why this auxiliary request exists (e.g. compaction summary, title).
        let purpose: String?
    }

    /// A provider returning top-level fields for one request, plus an
    /// optional post-2xx callback.
    struct Provider: Sendable {
        let prepare: @Sendable (RequestContext) async throws -> JSONValue?
        /// Runs at most once per captured request after a 2xx response.
        var onAccept: (@Sendable () async -> Void)?
    }

    private let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private var claims: [String: Provider] = [:]

    /// Claims one field name. Duplicate or malformed names fail synchronously.
    func register(field: String, provider: Provider) throws {
        guard Self.isValidFieldName(field) else {
            throw RegistryError.malformedField(field)
        }
        lock.lock()
        defer { lock.unlock() }
        if claims[field] != nil {
            throw RegistryError.duplicateField(field)
        }
        guard claims.count < Self.maximumFields else {
            throw RegistryError.capacityReached
        }
        claims[field] = provider
    }

    /// Releases a claim so a later provider can claim the same field.
    func unregister(field: String) {
        lock.lock()
        defer { lock.unlock() }
        claims.removeValue(forKey: field)
    }

    /// Collects all registered contributions concurrently. A throwing
    /// provider rejects the whole request (fail closed before dispatch).
    func prepare(_ context: RequestContext) async throws -> [String: JSONValue] {
        let snapshot: [(String, Provider)] = {
            lock.lock()
            defer { lock.unlock() }
            return claims.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }()
        guard !snapshot.isEmpty else { return [:] }

        var fields: [String: JSONValue] = [:]
        var failures: [Error] = []
        for (field, provider) in snapshot {
            do {
                if let contribution = try await provider.prepare(context) {
                    fields[field] = contribution
                }
            } catch {
                failures.append(error)
            }
        }
        if let first = failures.first {
            throw first
        }
        return fields
    }

    /// Runs every captured provider's post-2xx callback exactly once.
    /// Multiple failures merge into the reported error.
    func acceptAll(providers: [(String, Provider)]) async {
        for (_, provider) in providers {
            await provider.onAccept?()
        }
    }

    /// Field names must be ASCII identifiers starting with a letter,
    /// mirroring upstream's declared-merge discipline.
    static func isValidFieldName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard let first = name.first, first.isLetter else { return false }
        return true
    }
}
