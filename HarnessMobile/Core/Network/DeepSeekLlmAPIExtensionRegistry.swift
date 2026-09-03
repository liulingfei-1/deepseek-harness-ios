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

        /// Decoded body exposed to providers without giving them a mutable
        /// alias to the outgoing request.
        var body: [String: JSONValue] {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: baseBody) else {
                return [:]
            }
            return value.objectValue ?? [:]
        }
    }

    /// A provider returning top-level fields for one request, plus an
    /// optional post-2xx callback.
    struct Provider: Sendable {
        let prepare: @Sendable (RequestContext) async throws -> JSONValue?
        /// Runs at most once per captured request after a 2xx response.
        var onAccept: (@Sendable () async throws -> Void)?
    }

    /// Detached extension fields plus an idempotent post-2xx acceptance
    /// transaction. Repeated calls join the same callbacks.
    struct Prepared: Sendable {
        let fields: [String: JSONValue]
        private let acceptance: AcceptanceState

        fileprivate init(fields: [String: JSONValue], callbacks: [@Sendable () async throws -> Void]) {
            self.fields = fields
            acceptance = AcceptanceState(callbacks: callbacks)
        }

        func accept() async throws {
            try await acceptance.run()
        }
    }

    private actor AcceptanceState {
        let callbacks: [@Sendable () async throws -> Void]
        var settlement: Task<Void, Error>?

        init(callbacks: [@Sendable () async throws -> Void]) {
            self.callbacks = callbacks
        }

        func run() async throws {
            if let settlement {
                try await settlement.value
                return
            }
            let callbacks = callbacks
            let task = Task {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for callback in callbacks {
                        group.addTask { try await callback() }
                    }
                    try await group.waitForAll()
                }
            }
            settlement = task
            try await task.value
        }
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
        (try await prepareTransaction(context)).fields
    }

    /// Prepares fields and retains their post-2xx acceptance callbacks.
    func prepareTransaction(_ context: RequestContext) async throws -> Prepared {
        let snapshot: [(String, Provider)] = {
            lock.lock()
            defer { lock.unlock() }
            return claims.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        }()
        guard !snapshot.isEmpty else { return Prepared(fields: [:], callbacks: []) }

        try Task.checkCancellation()
        let prepared = try await withThrowingTaskGroup(of: (String, JSONValue?, (@Sendable () async throws -> Void)?).self) { group in
            for (field, provider) in snapshot {
                group.addTask {
                    try Task.checkCancellation()
                    let contribution = try await provider.prepare(context)
                    try Task.checkCancellation()
                    return (field, contribution, contribution == nil ? nil : provider.onAccept)
                }
            }
            var results: [(String, JSONValue?, (@Sendable () async throws -> Void)?)] = []
            for try await result in group { results.append(result) }
            return results
        }
        var fields: [String: JSONValue] = [:]
        var callbacks: [@Sendable () async throws -> Void] = []
        for (field, contribution, callback) in prepared {
            if let contribution {
                fields[field] = contribution
                if let callback { callbacks.append(callback) }
            }
        }
        return Prepared(fields: fields, callbacks: callbacks)
    }

    /// Runs every captured provider's post-2xx callback exactly once.
    /// Multiple failures merge into the reported error.
    func acceptAll(providers: [(String, Provider)]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (_, provider) in providers {
                if let callback = provider.onAccept {
                    group.addTask { try await callback() }
                }
            }
            try await group.waitForAll()
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
