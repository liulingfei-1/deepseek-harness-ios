import Foundation

/// Provider-owned retry configuration compatible with the upstream
/// `dsh-llm` normal/always policy contract. Missing values retain the official
/// five-retry bounded defaults so older saved profiles migrate without a
/// behavior change.
struct ProviderRetryPolicyConfiguration: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mode
        case maxRetries
        case retryableCodes
        case backoff
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        case normal
        case always

        var id: String { rawValue }
        var title: String { self == .normal ? "有界重试" : "持续重试" }
    }

    var mode: Mode
    var maxRetries: Int?
    var retryableCodes: [String]?
    var backoff: Backoff?

    struct Backoff: Codable, Sendable, Equatable {
        private enum CodingKeys: String, CodingKey, CaseIterable {
            case initialDelayMs
            case maxDelayMs
            case jitterRatio
        }

        var initialDelayMs: Double?
        var maxDelayMs: Double?
        var jitterRatio: Double?

        init(
            initialDelayMs: Double? = nil,
            maxDelayMs: Double? = nil,
            jitterRatio: Double? = nil
        ) {
            self.initialDelayMs = initialDelayMs
            self.maxDelayMs = maxDelayMs
            self.jitterRatio = jitterRatio
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: AnyCodingKey.self)
            let allowed = Set(CodingKeys.allCases.map(\.rawValue))
            if let unknown = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath + [unknown],
                        debugDescription: "Unknown retry backoff field \(unknown.stringValue)"
                    )
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func value(_ key: CodingKeys) throws -> Double? {
                guard container.contains(key) else { return nil }
                guard try !container.decodeNil(forKey: key) else {
                    throw DecodingError.valueNotFound(
                        Double.self,
                        .init(
                            codingPath: decoder.codingPath + [key],
                            debugDescription: "Explicit null is not a retry override"
                        )
                    )
                }
                return try container.decode(Double.self, forKey: key)
            }
            initialDelayMs = try value(.initialDelayMs)
            maxDelayMs = try value(.maxDelayMs)
            jitterRatio = try value(.jitterRatio)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(initialDelayMs, forKey: .initialDelayMs)
            try container.encodeIfPresent(maxDelayMs, forKey: .maxDelayMs)
            try container.encodeIfPresent(jitterRatio, forKey: .jitterRatio)
        }
    }

    static let upstreamDefault = ProviderRetryPolicyConfiguration(mode: .normal)

    init(
        mode: Mode = .normal,
        maxRetries: Int? = nil,
        retryableCodes: [String]? = nil,
        backoff: Backoff? = nil
    ) {
        self.mode = mode
        self.maxRetries = maxRetries
        self.retryableCodes = retryableCodes
        self.backoff = backoff
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = raw.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath + [unknown],
                    debugDescription: "Unknown retry policy field \(unknown.stringValue)"
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(Mode.self, forKey: .mode)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            guard container.contains(key) else { return nil }
            guard try !container.decodeNil(forKey: key) else {
                throw DecodingError.valueNotFound(
                    T.self,
                    .init(
                        codingPath: decoder.codingPath + [key],
                        debugDescription: "Explicit null is not a retry override"
                    )
                )
            }
            return try container.decode(T.self, forKey: key)
        }
        maxRetries = try value(Int.self, .maxRetries)
        retryableCodes = try value([String].self, .retryableCodes)
        backoff = try value(Backoff.self, .backoff)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(maxRetries, forKey: .maxRetries)
        try container.encodeIfPresent(retryableCodes, forKey: .retryableCodes)
        try container.encodeIfPresent(backoff, forKey: .backoff)
    }
}

struct ResolvedProviderRetryPolicy: Sendable, Equatable {
    let mode: ProviderRetryPolicyConfiguration.Mode
    let maxRetries: Int
    let retryableCodes: [String]
    let initialDelayMilliseconds: Double
    let maxDelayMilliseconds: Double
    let jitterRatio: Double

    var policyKey: String {
        if mode == .always {
            return "[\"always\",\(Self.number(initialDelayMilliseconds)),\(Self.number(maxDelayMilliseconds)),\(Self.number(jitterRatio))]"
        }
        let codes = retryableCodes.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        return "[\"normal\",\(maxRetries),[\(codes)],\(Self.number(initialDelayMilliseconds)),\(Self.number(maxDelayMilliseconds)),\(Self.number(jitterRatio))]"
    }

    private static func number(_ value: Double) -> String {
        if value.rounded() == value, value <= Double(Int64.max) {
            return String(Int64(value))
        }
        return String(value)
    }
}

enum ProviderRetryPolicyError: LocalizedError, Sendable, Equatable {
    case invalidMaxRetries
    case invalidBackoff
    case invalidJitter
    case invalidRetryableCodes

    var errorDescription: String? {
        switch self {
        case .invalidMaxRetries:
            return "模型重试次数不能小于 0。"
        case .invalidBackoff:
            return "模型重试等待必须为正数，且初始等待不能大于最大等待。"
        case .invalidJitter:
            return "模型重试抖动比例必须在 0 到 1 之间。"
        case .invalidRetryableCodes:
            return "模型重试错误码不能为空、重复或包含空值。"
        }
    }
}

/// Provider-owned bounded request recovery. The policy mirrors the bundled
/// Harness `llm-retry` extension: five transient retries, bounded exponential
/// backoff, provider Retry-After when it fits, and cancellation at every wait.
enum ModelRetryPolicy {
    static let contextWindowExceededCode = "CONTEXT_WINDOW_EXCEEDED"
    static let maxRetries = 5
    static let initialDelayMilliseconds = 500
    static let maxDelayMilliseconds = 10_000
    static let jitterRatio = 0.1
    static let retryableCodes: Set<String> = [
        "EMPTY_RESPONSE", "RATE_LIMIT", "SERVER", "TIMEOUT", "TRANSPORT"
    ]
    static var policyKey: String {
        // The built-in default is statically known to be valid.
        try! resolved(nil).policyKey
    }

    static func resolved(
        _ configuration: ProviderRetryPolicyConfiguration?
    ) throws -> ResolvedProviderRetryPolicy {
        let configuration = configuration ?? .upstreamDefault
        let backoff = configuration.backoff
        let initialDelay = backoff?.initialDelayMs ?? 500
        let maxDelay = backoff?.maxDelayMs ?? 10_000
        let jitter = backoff?.jitterRatio ?? 0.1
        let timerMaximum = Double(Int32.max)
        guard initialDelay.isFinite, initialDelay > 0, initialDelay <= timerMaximum,
              maxDelay.isFinite, maxDelay > 0, maxDelay <= timerMaximum,
              initialDelay <= maxDelay else {
            throw ProviderRetryPolicyError.invalidBackoff
        }
        guard jitter.isFinite, (0...1).contains(jitter) else {
            throw ProviderRetryPolicyError.invalidJitter
        }
        let maxRetries = configuration.maxRetries ?? 5
        let retryableCodes = configuration.retryableCodes ?? Array(Self.retryableCodes).sorted()
        if configuration.mode == .normal {
            guard maxRetries >= 0 else {
                throw ProviderRetryPolicyError.invalidMaxRetries
            }
            guard !retryableCodes.isEmpty,
                  retryableCodes.allSatisfy({ !$0.isEmpty }),
                  Set(retryableCodes).count == retryableCodes.count else {
                throw ProviderRetryPolicyError.invalidRetryableCodes
            }
        }
        return ResolvedProviderRetryPolicy(
            mode: configuration.mode,
            maxRetries: maxRetries,
            retryableCodes: retryableCodes,
            initialDelayMilliseconds: initialDelay,
            maxDelayMilliseconds: maxDelay,
            jitterRatio: jitter
        )
    }

    struct Failure: Sendable, Equatable {
        let code: String
        let message: String
        let status: Int?
        let retryAfterMilliseconds: Int?

        var jsonValue: JSONValue {
            var value: [String: JSONValue] = [
                "message": .string(message),
                "code": .string(code)
            ]
            if let status { value["status"] = .number(Double(status)) }
            if let retryAfterMilliseconds {
                value["providerRetryAfterMs"] = .number(Double(retryAfterMilliseconds))
            }
            return .object(value)
        }
    }

    static func failure(
        for error: Error,
        includeNonTransientModelFailures: Bool = false
    ) -> Failure? {
        if let modelError = error as? ModelClientError {
            let metadata = modelError.providerHTTPFailure
            let message: String
            if case let .httpFailure(_, rawMessage) = modelError {
                message = rawMessage
            } else {
                message = modelError.localizedDescription
            }
            let code: String
            switch modelError {
            case .emptyResponse: code = "EMPTY_RESPONSE"
            case .httpFailure:
                let normalizedCode = metadata?.code?.uppercased()
                if let status = metadata?.status {
                    if status == 408 { code = "TIMEOUT" }
                    else if status == 429 { code = "RATE_LIMIT" }
                    else if status >= 500 { code = "SERVER" }
                    else if metadata?.isRetryable == true { code = "SERVER" }
                    else if Self.isContextWindowFailure(code: normalizedCode, message: message) {
                        code = contextWindowExceededCode
                    } else { code = normalizedCode ?? "HTTP" }
                } else if Self.isContextWindowFailure(code: normalizedCode, message: message) {
                    code = contextWindowExceededCode
                } else { code = normalizedCode ?? "HTTP" }
            case .incompleteStream: code = "TRANSPORT"
            case .streamError: code = "TRANSPORT"
            case let .providerStreamFailure(providerCode, _):
                code = normalizedProviderStreamCode(providerCode)
            case .invalidResponse where includeNonTransientModelFailures:
                code = "INVALID_RESPONSE"
            case .requestTooLarge where includeNonTransientModelFailures:
                code = "REQUEST_TOO_LARGE"
            case .eventTooLarge where includeNonTransientModelFailures:
                code = "EVENT_TOO_LARGE"
            case .unexpectedContentType where includeNonTransientModelFailures:
                code = "UNEXPECTED_CONTENT_TYPE"
            case .unexpectedChoice where includeNonTransientModelFailures:
                code = "UNEXPECTED_CHOICE"
            case .malformedEvent where includeNonTransientModelFailures:
                code = "MALFORMED_EVENT"
            case .invalidUsage where includeNonTransientModelFailures:
                code = "INVALID_USAGE"
            default: return nil
            }
            return Failure(
                code: code,
                message: message,
                status: metadata?.status,
                retryAfterMilliseconds: metadata?.retryAfterMilliseconds
            )
        }
        if let urlError = error as? URLError {
            let code: String
            switch urlError.code {
            case .timedOut:
                code = "TIMEOUT"
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .secureConnectionFailed, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed:
                code = "TRANSPORT"
            default:
                return nil
            }
            return Failure(code: code, message: urlError.localizedDescription,
                           status: nil, retryAfterMilliseconds: nil)
        }
        if includeNonTransientModelFailures {
            return Failure(
                code: "UNKNOWN",
                message: error.localizedDescription,
                status: nil,
                retryAfterMilliseconds: nil
            )
        }
        return nil
    }

    private static func isContextWindowFailure(code: String?, message: String) -> Bool {
        let haystack = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")
        return haystack.contains("context_length_exceeded")
            || haystack.contains("context window")
            || haystack.contains("maximum context")
            || haystack.contains("too many tokens")
            || haystack.contains("request too large for model context")
    }

    private static func normalizedProviderStreamCode(_ rawValue: String?) -> String {
        switch rawValue?.lowercased() {
        case "overloaded_error", "api_error": return "SERVER"
        case "rate_limit_error": return "RATE_LIMIT"
        case "authentication_error", "permission_error": return "AUTH"
        case "invalid_request_error", "request_too_large": return "INVALID_REQUEST"
        case let value?: return value.uppercased()
        case nil: return "TRANSPORT"
        }
    }

    static func delayMilliseconds(
        retry: Int,
        failure: Failure,
        policy: ResolvedProviderRetryPolicy = try! ModelRetryPolicy.resolved(nil),
        random: Double = Double.random(in: 0...1)
    ) -> Double {
        if let providerDelay = failure.retryAfterMilliseconds,
           providerDelay > 0,
           Double(providerDelay) <= policy.maxDelayMilliseconds {
            return Double(providerDelay)
        }
        let exponent = min(max(retry - 1, 0), 1024)
        let exponential = min(
            policy.initialDelayMilliseconds * pow(2, Double(exponent)),
            policy.maxDelayMilliseconds
        )
        let boundedRandom = min(max(random, 0), 1)
        let multiplier = 1 - policy.jitterRatio + 2 * policy.jitterRatio * boundedRandom
        return min(
            max(0, exponential * multiplier),
            policy.maxDelayMilliseconds
        )
    }

    /// The provider owns Retry-After. A normal bounded policy fails through
    /// when that value exceeds its local safety cap; it must not silently turn
    /// an explicit long server pause into another request.
    static func accepts(
        _ failure: Failure,
        policy: ResolvedProviderRetryPolicy = try! ModelRetryPolicy.resolved(nil)
    ) -> Bool {
        guard let providerDelay = failure.retryAfterMilliseconds else { return true }
        return providerDelay > 0 && Double(providerDelay) <= policy.maxDelayMilliseconds
    }

    static func permits(
        _ failure: Failure,
        retry: Int,
        policy: ResolvedProviderRetryPolicy
    ) -> Bool {
        switch policy.mode {
        case .always:
            return true
        case .normal:
            return accepts(failure, policy: policy)
                && retry < policy.maxRetries
                && Set(policy.retryableCodes).contains(failure.code)
        }
    }

    static func wait(milliseconds: Double) async throws {
        let nanoseconds = UInt64(max(0, milliseconds) * 1_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}
