import Foundation
import Security

actor CredentialStore {
    private let service: String

    init(service: String = "com.llf.harnessmobile.credentials") {
        self.service = service
    }

    func saveAPIKey(_ key: String, for origin: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CredentialStoreError.emptyCredential
        }
        let account = try validatedAccount(origin)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(normalized.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = query
        item.merge(attributes) { _, new in new }
        item[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    func saveAPIKey(
        _ key: String,
        for reference: CredentialReference,
        origin: String
    ) throws {
        let normalized = try normalizedKey(key)
        let validatedReference = try reference.validated()
        let validatedOrigin = try validatedOrigin(origin)
        let record = ReferencedCredential(
            schemaVersion: ReferencedCredential.currentSchemaVersion,
            origin: validatedOrigin,
            secret: normalized
        )
        let data = try JSONEncoder().encode(record)
        try upsert(data: data, account: referencedAccount(validatedReference))
    }

    func readAPIKey(for origin: String) throws -> String? {
        let account = try validatedAccount(origin)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(status)
        }
        return key
    }

    func readAPIKey(
        for reference: CredentialReference,
        expectedOrigin: String
    ) throws -> String? {
        let validatedReference = try reference.validated()
        let expectedOrigin = try validatedOrigin(expectedOrigin)
        guard let data = try readData(account: referencedAccount(validatedReference)) else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(ReferencedCredential.self, from: data),
              record.schemaVersion == ReferencedCredential.currentSchemaVersion,
              !record.secret.isEmpty else {
            throw CredentialStoreError.keychain(errSecDecode)
        }
        guard record.origin == expectedOrigin else {
            throw CredentialStoreError.credentialOriginMismatch
        }
        return record.secret
    }

    /// Stores an opaque OAuth grant alongside the existing API-key schema. The
    /// grant is kept under a separate account namespace so older installs can
    /// continue to decode their API-key records without migration.
    func saveOAuthCredential(
        _ credential: ProviderOAuthCredential,
        for reference: CredentialReference,
        origin: String
    ) throws {
        let validatedReference = try reference.validated()
        let validatedOrigin = try validatedOrigin(origin)
        let record = OAuthCredentialRecord(
            schemaVersion: OAuthCredentialRecord.currentSchemaVersion,
            origin: validatedOrigin,
            credential: try credential.validated()
        )
        let data = try JSONEncoder().encode(record)
        try upsert(data: data, account: oauthAccount(validatedReference))
    }

    func readOAuthCredential(
        for reference: CredentialReference,
        expectedOrigin: String
    ) throws -> ProviderOAuthCredential? {
        let validatedReference = try reference.validated()
        let expectedOrigin = try validatedOrigin(expectedOrigin)
        guard let data = try readData(account: oauthAccount(validatedReference)) else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(OAuthCredentialRecord.self, from: data),
              record.schemaVersion == OAuthCredentialRecord.currentSchemaVersion else {
            throw CredentialStoreError.keychain(errSecDecode)
        }
        guard record.origin == expectedOrigin else {
            throw CredentialStoreError.credentialOriginMismatch
        }
        return try record.credential.validated()
    }

    func deleteOAuthCredential(for reference: CredentialReference) throws {
        let validatedReference = try reference.validated()
        try delete(account: oauthAccount(validatedReference))
    }

    func describeAPIKey(
        for reference: CredentialReference,
        expectedOrigin: String
    ) throws -> ProviderCredentialStatus {
        do {
            return try readAPIKey(for: reference, expectedOrigin: expectedOrigin) == nil
                ? .missing
                : .configured
        } catch CredentialStoreError.credentialOriginMismatch {
            return .originMismatch
        }
    }

    func deleteAPIKey(for reference: CredentialReference) throws {
        let validatedReference = try reference.validated()
        try delete(account: referencedAccount(validatedReference))
    }

    func deleteAPIKey(for origin: String) throws {
        try delete(account: validatedAccount(origin))
    }

    @discardableResult
    func migrateLegacyAPIKey(
        from origin: String,
        to reference: CredentialReference
    ) throws -> Bool {
        let expectedOrigin = try validatedOrigin(origin)
        if try readAPIKey(for: reference, expectedOrigin: expectedOrigin) != nil {
            try deleteAPIKey(for: expectedOrigin)
            return true
        }
        guard let legacyKey = try readAPIKey(for: expectedOrigin) else { return false }
        try saveAPIKey(legacyKey, for: reference, origin: expectedOrigin)
        try deleteAPIKey(for: expectedOrigin)
        return true
    }

    func replaceAllAPIKeys(with key: String, for origin: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CredentialStoreError.emptyCredential
        }
        _ = try validatedAccount(origin)

        // The app supports one active model connection. Clearing this
        // service first prevents stale credentials from older origins from
        // becoming unreachable orphaned Keychain items.
        try deleteAllAPIKeys()
        try saveAPIKey(normalized, for: origin)
    }

    func deleteAllAPIKeys() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let lookupStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if lookupStatus == errSecItemNotFound {
            return
        }
        guard lookupStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(lookupStatus)
        }

        let items: [[String: Any]]
        if let matchedItems = result as? [[String: Any]] {
            items = matchedItems
        } else if let matchedItem = result as? [String: Any] {
            items = [matchedItem]
        } else {
            throw CredentialStoreError.keychain(errSecDecode)
        }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else {
                throw CredentialStoreError.keychain(errSecDecode)
            }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw CredentialStoreError.keychain(deleteStatus)
            }
        }
    }

    private func validatedAccount(_ origin: String) throws -> String {
        "model-api-key|\(try validatedOrigin(origin))"
    }

    private func referencedAccount(_ reference: CredentialReference) -> String {
        "model-api-key-ref|\(reference.rawValue)"
    }

    private func oauthAccount(_ reference: CredentialReference) -> String {
        "model-oauth-ref|\(reference.rawValue)"
    }

    private func normalizedKey(_ key: String) throws -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CredentialStoreError.emptyCredential
        }
        return normalized
    }

    private func validatedOrigin(_ origin: String) throws -> String {
        guard origin.utf8.count <= 512,
              let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw CredentialStoreError.invalidOrigin
        }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        normalized.port = components.port ?? 443
        guard let value = normalized.string else {
            throw CredentialStoreError.invalidOrigin
        }
        return value
    }

    private func upsert(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychain(updateStatus)
        }

        var item = query
        item.merge(attributes) { _, new in new }
        item[kSecAttrSynchronizable as String] = false
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(addStatus)
        }
    }

    private func readData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialStoreError.keychain(status)
        }
        return data
    }

    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }
}

private struct ReferencedCredential: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let origin: String
    let secret: String
}

/// A versioned wrapper lets the OAuth payload evolve without changing the
/// legacy API-key record decoder.
private struct OAuthCredentialRecord: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let origin: String
    let credential: ProviderOAuthCredential
}

enum CredentialStoreError: LocalizedError, Sendable {
    case emptyCredential
    case invalidOrigin
    case keyRequiredForOriginChange
    case credentialOriginMismatch
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            return "API Key 不能为空。"
        case .invalidOrigin:
            return "模型 API origin 无效。"
        case .keyRequiredForOriginChange:
            return "模型 API 的域名或端口已改变，请为新地址重新输入 API Key。"
        case .credentialOriginMismatch:
            return "该凭据绑定的模型 API 域名或端口与当前 Provider Profile 不一致，请重新输入 API Key。"
        case let .keychain(status):
            return "Keychain 操作失败（\(status)）。"
        }
    }
}
