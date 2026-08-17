import Foundation

#if os(iOS)
import Contacts
#endif

struct DeviceContactRecord: Sendable, Equatable {
    let name: String
    let phoneNumbers: [String]
    let emailAddresses: [String]
}

protocol DeviceContactSearching: Sendable {
    func search(query: String, limit: Int) async throws -> [DeviceContactRecord]
}

struct ContactsSearchTool: LocalAgentTool {
    static let defaultLimit = 10
    static let maximumLimit = 20

    private static let maximumQueryBytes = 128
    private static let maximumNameBytes = 256
    private static let maximumPhoneBytes = 128
    private static let maximumEmailBytes = 320
    private static let maximumValuesPerKind = 3

    private let provider: any DeviceContactSearching

    let definition = ModelToolDefinition(
        name: "contacts_search",
        description: "Search the iPhone contact store by name. Returns only a bounded set of names, phone numbers, and email addresses; it never writes or deletes contacts.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "maxLength": .number(Double(maximumQueryBytes)),
                    "description": .string("Non-empty contact name search text.")
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "minimum": .number(1),
                    "maximum": .number(Double(maximumLimit)),
                    "description": .string("Maximum contacts to return. Defaults to 10.")
                ])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )
    let risk: ToolRisk = .sensitiveRead

    init(provider: any DeviceContactSearching) {
        self.provider = provider
    }

    func validate(arguments: [String: JSONValue]) throws {
        _ = try parsedArguments(arguments)
    }

    func summary(arguments: [String: JSONValue]) -> String {
        guard let parsed = try? parsedArguments(arguments) else {
            return "搜索本机联系人"
        }
        return "在本机联系人中搜索“\(parsed.query)”，最多返回 \(parsed.limit) 项；结果会发送给模型"
    }

    func approvalResources(arguments: [String: JSONValue]) throws -> Set<String> {
        try validate(arguments: arguments)
        return ["contacts:read"]
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        let parsed = try parsedArguments(arguments)
        try Task.checkCancellation()
        let records = try await provider.search(query: parsed.query, limit: parsed.limit)
        try Task.checkCancellation()

        let contacts = records.lazy
            .compactMap(Self.sanitizedRecord)
            .prefix(parsed.limit)
            .map { record in
                JSONValue.object([
                    "name": .string(record.name),
                    "phoneNumbers": .array(record.phoneNumbers.map(JSONValue.string)),
                    "emailAddresses": .array(record.emailAddresses.map(JSONValue.string))
                ])
            }

        return JSONValue.object([
            "query": .string(parsed.query),
            "count": .number(Double(contacts.count)),
            "contacts": .array(Array(contacts))
        ]).displayText
    }

    private func parsedArguments(
        _ arguments: [String: JSONValue]
    ) throws -> (query: String, limit: Int) {
        try arguments.requireOnlyKeys(["query", "limit"])
        guard let rawQuery = arguments["query"]?.stringValue else {
            throw LocalToolError.missingArgument("query")
        }
        let query = rawQuery.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              query.utf8.count <= Self.maximumQueryBytes,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LocalToolError.invalidArguments
        }

        let limit: Int
        if let rawLimit = arguments["limit"] {
            guard case let .number(value) = rawLimit,
                  value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= 1,
                  value <= Double(Self.maximumLimit) else {
                throw LocalToolError.invalidArguments
            }
            limit = Int(value)
        } else {
            limit = Self.defaultLimit
        }
        return (query, limit)
    }

    private static func sanitizedRecord(_ record: DeviceContactRecord) -> DeviceContactRecord? {
        guard let name = boundedText(record.name, maximumBytes: maximumNameBytes) else {
            return nil
        }
        return DeviceContactRecord(
            name: name,
            phoneNumbers: boundedValues(
                record.phoneNumbers,
                maximumBytes: maximumPhoneBytes
            ),
            emailAddresses: boundedValues(
                record.emailAddresses,
                maximumBytes: maximumEmailBytes
            )
        )
    }

    private static func boundedValues(
        _ values: [String],
        maximumBytes: Int
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let bounded = boundedText(value, maximumBytes: maximumBytes),
                  seen.insert(bounded).inserted else {
                continue
            }
            result.append(bounded)
            if result.count == maximumValuesPerKind { break }
        }
        return result
    }

    private static func boundedText(_ rawValue: String, maximumBytes: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in rawValue.precomposedStringWithCanonicalMapping.unicodeScalars
        where !CharacterSet.controlCharacters.contains(scalar) {
            scalars.append(scalar)
        }
        let value = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        for character in value {
            let candidateBytes = String(character).utf8.count
            guard result.utf8.count + candidateBytes <= maximumBytes else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }
}

#if os(iOS)
struct SystemDeviceContactSearcher: DeviceContactSearching {
    func search(query: String, limit: Int) async throws -> [DeviceContactRecord] {
        try await ensureAuthorization()
        try Task.checkCancellation()

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        do {
            let contacts = try store.unifiedContacts(
                matching: CNContact.predicateForContacts(matchingName: query),
                keysToFetch: keys
            )
            return contacts
                .sorted { lhs, rhs in
                    displayName(lhs).localizedStandardCompare(displayName(rhs)) == .orderedAscending
                }
                .prefix(limit)
                .map { contact in
                    DeviceContactRecord(
                        name: displayName(contact),
                        phoneNumbers: contact.phoneNumbers.map(\.value.stringValue),
                        emailAddresses: contact.emailAddresses.map { String($0.value) }
                    )
                }
        } catch {
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .denied:
                throw MobileNativeToolError.permissionDenied("联系人")
            case .restricted:
                throw MobileNativeToolError.restricted("联系人")
            default:
                throw MobileNativeToolError.operationFailed("联系人搜索")
            }
        }
    }

    private func ensureAuthorization() async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return
        case .denied:
            throw MobileNativeToolError.permissionDenied("联系人")
        case .restricted:
            throw MobileNativeToolError.restricted("联系人")
        case .notDetermined:
            do {
                _ = try await CNContactStore().requestAccess(for: .contacts)
            } catch {
                throw MobileNativeToolError.operationFailed("联系人授权")
            }
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized, .limited:
                return
            case .restricted:
                throw MobileNativeToolError.restricted("联系人")
            case .denied, .notDetermined:
                throw MobileNativeToolError.permissionDenied("联系人")
            @unknown default:
                throw MobileNativeToolError.operationFailed("联系人授权")
            }
        @unknown default:
            throw MobileNativeToolError.operationFailed("联系人授权")
        }
    }

    private func displayName(_ contact: CNContact) -> String {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName),
           !formatted.isEmpty {
            return formatted
        }
        return [contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif
