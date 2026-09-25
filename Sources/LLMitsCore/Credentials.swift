import Foundation
import Security

public struct OAuthCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let tokenType: String
    public let scopes: [String]
    public let idToken: String?
    public let accountID: String?
    public let clientID: String?
    public let clientSecret: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        tokenType: String = "Bearer",
        scopes: [String] = [],
        idToken: String? = nil,
        accountID: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scopes = scopes
        self.idToken = idToken
        self.accountID = accountID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public protocol CredentialStoring: Sendable {
    func credential(for provider: ProviderID) async throws -> OAuthCredential?
    func save(_ credential: OAuthCredential, for provider: ProviderID) async throws
    func deleteCredential(for provider: ProviderID) async throws
}

public enum CredentialStoreError: LocalizedError, Sendable {
    case encodingFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "The credential could not be encoded."
        case let .keychain(status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }
}

/// Keeps every provider's credential in one Keychain item so macOS asks for access at most once.
/// Nothing is read until a provider first needs its credential; the result is cached for the session.
public actor KeychainCredentialStore: CredentialStoring {
    private static let bundleAccount = "credentials"
    private static let legacyProviders: [ProviderID] = [.claude, .codex]

    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [String: OAuthCredential]?

    public init(service: String = "com.llmits.credentials") {
        self.service = service
    }

    public func credential(for provider: ProviderID) throws -> OAuthCredential? {
        try loadCredentials()[provider.rawValue]
    }

    public func save(_ credential: OAuthCredential, for provider: ProviderID) throws {
        var credentials = try loadCredentials()
        credentials[provider.rawValue] = credential
        try write(credentials)
    }

    public func deleteCredential(for provider: ProviderID) throws {
        var credentials = try loadCredentials()
        if credentials.removeValue(forKey: provider.rawValue) != nil { try write(credentials) }
        try delete(account: provider.rawValue)
    }

    private func loadCredentials() throws -> [String: OAuthCredential] {
        if let cache { return cache }
        let credentials: [String: OAuthCredential]
        if let data = try read(account: Self.bundleAccount) {
            credentials = try decoder.decode([String: OAuthCredential].self, from: data)
        } else {
            // Earlier builds stored one item per provider. Old items stay until the provider is disconnected,
            // because deleting another build's item can trigger its own Keychain prompt.
            var migrated: [String: OAuthCredential] = [:]
            for provider in Self.legacyProviders {
                if let data = try read(account: provider.rawValue) {
                    migrated[provider.rawValue] = try decoder.decode(OAuthCredential.self, from: data)
                }
            }
            if !migrated.isEmpty { try write(migrated) }
            credentials = migrated
        }
        cache = credentials
        return credentials
    }

    private func write(_ credentials: [String: OAuthCredential]) throws {
        let data = try encoder.encode(credentials)
        let query = baseQuery(account: Self.bundleAccount)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw CredentialStoreError.keychain(updateStatus)
        }
        cache = credentials
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw CredentialStoreError.encodingFailed }
        return data
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public actor InMemoryCredentialStore: CredentialStoring {
    private var credentials: [ProviderID: OAuthCredential] = [:]

    public init() {}

    public func credential(for provider: ProviderID) -> OAuthCredential? {
        credentials[provider]
    }

    public func save(_ credential: OAuthCredential, for provider: ProviderID) {
        credentials[provider] = credential
    }

    public func deleteCredential(for provider: ProviderID) {
        credentials[provider] = nil
    }
}
