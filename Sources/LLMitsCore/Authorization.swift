import CryptoKit
import Foundation
import Security

public enum AuthorizationError: LocalizedError, Equatable, Sendable {
    case randomGenerationFailed
    case invalidAuthorizationURL
    case invalidCallback
    case stateMismatch
    case expiredDeviceCode
    case expiredBrowserSignIn
    case authorizationDenied

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed: "Secure authorization values could not be generated."
        case .invalidAuthorizationURL: "The provider authorization URL is invalid."
        case .invalidCallback: "The pasted authorization response is invalid."
        case .stateMismatch: "The authorization response did not match this connection attempt."
        case .expiredDeviceCode: "The device authorization code expired."
        case .expiredBrowserSignIn: "Google sign-in timed out. Try connecting again."
        case .authorizationDenied: "Authorization was denied."
        }
    }
}

public struct PKCETransaction: Equatable, Sendable {
    public let state: String
    public let verifier: String
    public let challenge: String

    public init(state: String, verifier: String, challenge: String) {
        self.state = state
        self.verifier = verifier
        self.challenge = challenge
    }

    public static func generate(byteCount: Int = 32) throws -> PKCETransaction {
        let state = try secureRandomURLSafeString(byteCount: byteCount)
        let verifier = try secureRandomURLSafeString(byteCount: byteCount)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCETransaction(state: state, verifier: verifier, challenge: Data(digest).base64URLString)
    }

    private static func secureRandomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthorizationError.randomGenerationFailed
        }
        return Data(bytes).base64URLString
    }
}

public struct OAuthAuthorizationConfiguration: Equatable, Sendable {
    public let authorizationEndpoint: URL
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]
    public let additionalParameters: [String: String]

    public init(
        authorizationEndpoint: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        additionalParameters: [String: String] = [:]
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.additionalParameters = additionalParameters
    }

    public func authorizationURL(for transaction: PKCETransaction) throws -> URL {
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw AuthorizationError.invalidAuthorizationURL
        }
        var parameters = additionalParameters
        parameters.merge([
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "response_type": "code",
            "scope": scopes.joined(separator: " "),
            "state": transaction.state,
            "code_challenge": transaction.challenge,
            "code_challenge_method": "S256",
        ]) { _, required in required }
        components.queryItems = parameters.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw AuthorizationError.invalidAuthorizationURL }
        return url
    }
}

public struct OAuthCallback: Equatable, Sendable {
    public let code: String
    public let state: String

    public init(code: String, state: String) {
        self.code = code
        self.state = state
    }

    public static func parse(_ pastedValue: String) throws -> OAuthCallback {
        let value = pastedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: value), components.scheme != nil {
            let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard let code = values["code"], let state = values["state"], !code.isEmpty, !state.isEmpty else {
                throw AuthorizationError.invalidCallback
            }
            return OAuthCallback(code: code, state: state)
        }

        let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw AuthorizationError.invalidCallback
        }
        return OAuthCallback(code: parts[0], state: parts[1])
    }

    public func validate(expectedState: String) throws {
        guard state == expectedState else { throw AuthorizationError.stateMismatch }
    }
}

public struct DeviceAuthorization: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let pollingInterval: TimeInterval

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresAt: Date, pollingInterval: TimeInterval) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.pollingInterval = pollingInterval
    }
}

public enum DeviceAuthorizationPollResult: Equatable, Sendable {
    case pending
    case slowDown
    case authorized(OAuthCredential)
    case denied
    case expired
}

public struct DeviceAuthorizationStateMachine: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case awaitingUser(DeviceAuthorization)
        case authorized(OAuthCredential)
        case failed(AuthorizationError)
    }

    public private(set) var state: State = .idle
    public private(set) var nextPollAt: Date?

    public init() {}

    public mutating func begin(_ authorization: DeviceAuthorization, now: Date) {
        state = .awaitingUser(authorization)
        nextPollAt = now.addingTimeInterval(authorization.pollingInterval)
    }

    public mutating func receive(_ result: DeviceAuthorizationPollResult, now: Date) {
        guard case let .awaitingUser(authorization) = state else { return }
        guard now < authorization.expiresAt else {
            state = .failed(.expiredDeviceCode)
            nextPollAt = nil
            return
        }

        switch result {
        case .pending:
            nextPollAt = now.addingTimeInterval(authorization.pollingInterval)
        case .slowDown:
            nextPollAt = now.addingTimeInterval(authorization.pollingInterval + 5)
        case let .authorized(credential):
            state = .authorized(credential)
            nextPollAt = nil
        case .denied:
            state = .failed(.authorizationDenied)
            nextPollAt = nil
        case .expired:
            state = .failed(.expiredDeviceCode)
            nextPollAt = nil
        }
    }
}

private extension Data {
    var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
