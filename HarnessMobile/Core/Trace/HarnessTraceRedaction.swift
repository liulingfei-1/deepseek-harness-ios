import Foundation

enum HarnessTraceRedactor {
    private static let forbiddenKeyFragments = [
        "apikey",
        "authorization",
        "accesstoken",
        "refreshtoken",
        "secretkey",
        "clientsecret",
        "password"
    ]

    static func string(_ value: String, maximumUTF8Bytes: Int = 16 * 1_024) -> String {
        var redacted = value
        for pattern in [
            #"\bsk-[A-Za-z0-9_-]{12,}\b"#,
            #"\bBearer\s+[A-Za-z0-9._~-]{12,}\b"#
        ] {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: "<redacted>"
            )
        }
        return prefix(redacted, maximumUTF8Bytes: maximumUTF8Bytes)
    }

    static func json(
        _ value: JSONValue,
        depth: Int = 0,
        maximumDepth: Int = 6
    ) -> JSONValue {
        guard depth < maximumDepth else { return .string("<depth-limit>") }
        switch value {
        case let .string(text):
            return .string(string(text, maximumUTF8Bytes: 4 * 1_024))
        case let .array(values):
            var projected = values.prefix(32).map {
                json($0, depth: depth + 1, maximumDepth: maximumDepth)
            }
            if values.count > projected.count {
                projected.append(.string("<\(values.count - projected.count) more items>"))
            }
            return .array(projected)
        case let .object(object):
            var projected: [String: JSONValue] = [:]
            for key in object.keys.sorted().prefix(64) {
                if isCredentialKey(key) {
                    projected[key] = .string("<redacted>")
                } else if let child = object[key] {
                    projected[key] = json(
                        child,
                        depth: depth + 1,
                        maximumDepth: maximumDepth
                    )
                }
            }
            if object.count > projected.count {
                projected["<truncated>"] = .number(Double(object.count - projected.count))
            }
            return .object(projected)
        case .number, .bool, .null:
            return value
        }
    }

    private static func isCredentialKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter(\.isLetter)
        return forbiddenKeyFragments.contains { normalized.contains($0) }
    }

    private static func prefix(_ text: String, maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        var result = ""
        result.reserveCapacity(maximumUTF8Bytes)
        var usedBytes = 0
        for scalar in text.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard usedBytes + bytes <= maximumUTF8Bytes else { break }
            result.unicodeScalars.append(scalar)
            usedBytes += bytes
        }
        return result + "\n<truncated>"
    }
}
