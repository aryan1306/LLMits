import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum AntigravityConfigurationError: LocalizedError {
    case clientUnavailable

    public var errorDescription: String? {
        "Google sign-in in LLMits requires Antigravity.app; the agy CLI alone cannot supply its browser callback. Install the desktop app, or sign in by running agy in Terminal and use its CLI login."
    }
}

public struct AntigravityOAuthConfig: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static func discover(fileManager: FileManager = .default) throws -> AntigravityOAuthConfig {
        let environment = ProcessInfo.processInfo.environment
        if let id = environment["ANTIGRAVITY_OAUTH_CLIENT_ID"],
           let secret = environment["ANTIGRAVITY_OAUTH_CLIENT_SECRET"],
           !id.isEmpty, !secret.isEmpty {
            return AntigravityOAuthConfig(clientID: id, clientSecret: secret)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [URL(fileURLWithPath: "/Applications/Antigravity.app"), home.appendingPathComponent("Applications/Antigravity.app")]
        let relativePaths = [
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
            "Contents/Resources/app/extensions/antigravity/bin/language_server_macos",
            "Contents/Resources/bin/language_server",
            "Contents/Resources/bin/language_server_macos",
            "Contents/MacOS/Antigravity",
        ]
        let idPattern = #"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#
        let secretPattern = #"GOCSPX-[A-Za-z0-9_-]{20,}"#
        for root in roots where fileManager.fileExists(atPath: root.path) {
            for relativePath in relativePaths {
                let url = root.appendingPathComponent(relativePath)
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let text = String(data: data, encoding: .isoLatin1),
                      let clientID = text.firstMatch(pattern: idPattern),
                      let clientSecret = text.firstMatch(pattern: secretPattern) else { continue }
                return AntigravityOAuthConfig(clientID: clientID, clientSecret: clientSecret)
            }
        }
        throw AntigravityConfigurationError.clientUnavailable
    }
}

public struct AntigravityUsageProvider: UsageProviding {
    public let id: ProviderID = .antigravity
    private let credentials: any CredentialStoring
    private let transport: any HTTPTransporting
    private let now: @Sendable () -> Date

    public init(credentials: any CredentialStoring, transport: any HTTPTransporting = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let owned = try await credentials.credential(for: .antigravity)
        let fallback = owned == nil ? try AntigravityCredentialReader.credential() : nil
        guard var credential = owned ?? fallback else { throw ProviderError.notConnected }
        if let expiry = credential.expiresAt, expiry <= now().addingTimeInterval(60) {
            guard let refreshToken = credential.refreshToken else { throw ProviderError.revokedSession }
            let config = try credential.clientID.flatMap { id in credential.clientSecret.map { AntigravityOAuthConfig(clientID: id, clientSecret: $0) } }
                ?? AntigravityOAuthConfig.discover()
            let refreshed = try await OAuthTokenClient(transport: transport).refresh(
                endpoint: ProviderEndpoints.Antigravity.token,
                clientID: config.clientID,
                refreshToken: refreshToken,
                scopes: credential.scopes,
                now: now(),
                additionalFields: ["client_secret": config.clientSecret]
            )
            credential = OAuthCredential(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? refreshToken,
                expiresAt: refreshed.expiresAt,
                tokenType: refreshed.tokenType,
                scopes: refreshed.scopes.isEmpty ? credential.scopes : refreshed.scopes,
                idToken: refreshed.idToken ?? credential.idToken,
                accountID: credential.accountID,
                clientID: config.clientID,
                clientSecret: config.clientSecret
            )
            if owned != nil { try await credentials.save(credential, for: .antigravity) }
        }

        let metadata: [String: Any] = ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en", "ideVersion": "unknown"]
        let assist = try? await post(ProviderEndpoints.Antigravity.loadCodeAssist, credential: credential, body: ["metadata": metadata])
        let assistObject = assist.flatMap { try? JSONSerialization.jsonObject(with: $0.data) as? [String: Any] }
        let projectValue = assistObject?["cloudaicompanionProject"]
        let project = (projectValue as? String) ?? ((projectValue as? [String: Any])?["id"] as? String)
        let plan = ((assistObject?["currentTier"] as? [String: Any])?["name"] as? String)
            ?? ((assistObject?["planInfo"] as? [String: Any])?["planType"] as? String)
            ?? "Antigravity"
        var body: [String: Any] = ["metadata": metadata]
        if let project, !project.isEmpty { body["project"] = project }
        if let response = try? await post(ProviderEndpoints.Antigravity.quotaSummary, credential: credential, body: body),
           (200..<300).contains(response.statusCode),
           let parsed = try? UsageResponseParser.parseAntigravity(response.data, fetchedAt: now(), plan: plan) {
            return parsed
        }
        var modelBody: [String: Any] = [:]
        if let project, !project.isEmpty { modelBody["project"] = project }
        let modelResponse = try await post(ProviderEndpoints.Antigravity.availableModels, credential: credential, body: modelBody)
        let snapshot = try UsageResponseParser.parseAntigravity(modelResponse.data, fetchedAt: now(), plan: plan)
        if snapshot.windows.allSatisfy({ $0.utilization <= 0 }) {
            let verification = try await post(ProviderEndpoints.Antigravity.retrieveQuota, credential: credential, body: modelBody)
            guard let object = try? JSONSerialization.jsonObject(with: verification.data),
                  Self.containsRemainingFraction(object) else { throw ProviderError.invalidResponse }
        }
        return snapshot
    }

    private func post(_ url: URL, credential: OAuthCredential, body: [String: Any]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity/1.0 darwin/arm64", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await transport.send(request)
        try validate(response)
        return response
    }

    private func validate(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw ProviderError.revokedSession }
            if response.statusCode == 429 { throw ProviderError.rateLimited(retryAfter: nil) }
            throw ProviderError.invalidResponse
        }
    }

    private static func containsRemainingFraction(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object["remainingFraction"] is NSNumber { return true }
            return object.values.contains(where: containsRemainingFraction)
        }
        if let array = value as? [Any] { return array.contains(where: containsRemainingFraction) }
        return false
    }
}

private extension String {
    func firstMatch(pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let range = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self))?.range,
              let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
