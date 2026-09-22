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

public enum AntigravityCredentialReader {
    /// Reads Antigravity/agy's Go-keyring entry without modifying it.
    public static func credential() throws -> OAuthCredential? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeAll()
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              var value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.keychain(status)
        }
        let prefix = "go-keyring-base64:"
        if value.hasPrefix(prefix),
           let decoded = Data(base64Encoded: String(value.dropFirst(prefix.count))),
           let text = String(data: decoded, encoding: .utf8) {
            value = text
        }
        guard let payload = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let token = (object["token"] as? [String: Any]) ?? object
        guard let access = token["access_token"] as? String else { return nil }
        let expiry: Date? = (token["expiry"] as? String).flatMap { value in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.remove(.withFractionalSeconds)
            return formatter.date(from: value)
        }
        return OAuthCredential(
            accessToken: access,
            refreshToken: token["refresh_token"] as? String,
            expiresAt: expiry,
            scopes: ["https://www.googleapis.com/auth/cloud-platform"]
        )
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

public actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.llmits.credentials") {
        self.service = service
    }

    public func credential(for provider: ProviderID) throws -> OAuthCredential? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw CredentialStoreError.encodingFailed }
        return try decoder.decode(OAuthCredential.self, from: data)
    }

    public func save(_ credential: OAuthCredential, for provider: ProviderID) throws {
        let data = try encoder.encode(credential)
        let query = baseQuery(for: provider)
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
    }

    public func deleteCredential(for provider: ProviderID) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for provider: ProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
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
