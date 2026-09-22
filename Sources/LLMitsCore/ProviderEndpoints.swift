import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderEndpoints {
    public enum Claude {
        public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        public static let authorization = URL(string: "https://claude.ai/oauth/authorize")!
        public static let token = URL(string: "https://platform.claude.com/v1/oauth/token")!
        public static let usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        public static let profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        public static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    }

    public enum Codex {
        public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
        public static let deviceCode = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
        public static let deviceToken = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
        public static let verification = URL(string: "https://auth.openai.com/codex/device")!
        public static let token = URL(string: "https://auth.openai.com/oauth/token")!
        public static let usage = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        public static let redirectURI = "https://auth.openai.com/deviceauth/callback"
    }
}

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol HTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransporting {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        let headers: [String: String] = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
            guard let key = key as? String, let value = value as? String else { return nil }
            return (key.lowercased(), value)
        })
        return HTTPResponse(data: data, statusCode: http.statusCode, headers: headers)
    }
}

public struct OAuthTokenClient: Sendable {
    public enum Encoding: Sendable { case form, json }

    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) {
        self.transport = transport
    }

    public func exchangeCode(
        endpoint: URL,
        clientID: String,
        code: String,
        verifier: String,
        redirectURI: String,
        now: Date = Date(),
        encoding: Encoding = .form,
        additionalFields: [String: String] = [:]
    ) async throws -> OAuthCredential {
        var fields = [
            "grant_type": "authorization_code", "client_id": clientID, "code": code,
            "code_verifier": verifier, "redirect_uri": redirectURI,
        ]
        fields.merge(additionalFields) { _, new in new }
        return try await token(endpoint: endpoint, fields: fields, now: now, encoding: encoding)
    }

    public func refresh(
        endpoint: URL,
        clientID: String,
        refreshToken: String,
        scopes: [String] = [],
        now: Date = Date(),
        encoding: Encoding = .form
    ) async throws -> OAuthCredential {
        var fields = ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken]
        if !scopes.isEmpty { fields["scope"] = scopes.joined(separator: " ") }
        return try await token(endpoint: endpoint, fields: fields, now: now, encoding: encoding)
    }

    private func token(endpoint: URL, fields: [String: String], now: Date, encoding: Encoding) async throws -> OAuthCredential {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        switch encoding {
        case .form:
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = fields.formEncoded.data(using: .utf8)
        case .json:
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        }
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 400 { throw ProviderError.revokedSession }
            if response.statusCode == 429 { throw ProviderError.rateLimited(retryAfter: response.retryAfter) }
            throw ProviderError.invalidResponse
        }
        let payload = try JSONDecoder().decode(TokenPayload.self, from: response.data)
        let identityToken = payload.idToken ?? payload.accessToken
        return OAuthCredential(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: payload.expiresIn.map { now.addingTimeInterval($0) },
            tokenType: payload.tokenType ?? "Bearer",
            scopes: payload.scope?.split(separator: " ").map(String.init) ?? [],
            idToken: payload.idToken,
            accountID: Self.jwtClaim("chatgpt_account_id", token: identityToken)
        )
    }

    private static func jwtClaim(_ name: String, token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let value = object[name] as? String { return value }
        return (object["https://api.openai.com/auth"] as? [String: Any])?[name] as? String
    }
}

public struct DeviceAuthorizationGrant: Equatable, Sendable {
    public let authorizationCode: String
    public let codeVerifier: String
    public init(authorizationCode: String, codeVerifier: String) {
        self.authorizationCode = authorizationCode
        self.codeVerifier = codeVerifier
    }
}

public enum DeviceCodePollResponse: Equatable, Sendable {
    case pending
    case authorized(DeviceAuthorizationGrant)
}

public struct CodexDeviceAuthorizationClient: Sendable {
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) { self.transport = transport }

    public func requestCode(now: Date = Date()) async throws -> DeviceAuthorization {
        let response = try await post(ProviderEndpoints.Codex.deviceCode, body: ["client_id": ProviderEndpoints.Codex.clientID])
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(DeviceCodePayload.self, from: response.data) else {
            throw ProviderError.invalidResponse
        }
        return DeviceAuthorization(
            deviceCode: payload.deviceAuthID,
            userCode: payload.userCode,
            verificationURL: ProviderEndpoints.Codex.verification,
            expiresAt: now.addingTimeInterval(15 * 60),
            pollingInterval: max(1, TimeInterval(payload.interval) ?? 5)
        )
    }

    public func poll(_ authorization: DeviceAuthorization) async throws -> DeviceCodePollResponse {
        let response = try await post(ProviderEndpoints.Codex.deviceToken, body: [
            "device_auth_id": authorization.deviceCode, "user_code": authorization.userCode,
        ])
        if response.statusCode == 403 || response.statusCode == 404 { return .pending }
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(DeviceTokenPayload.self, from: response.data) else {
            throw ProviderError.invalidResponse
        }
        return .authorized(DeviceAuthorizationGrant(authorizationCode: payload.authorizationCode, codeVerifier: payload.codeVerifier))
    }

    private func post(_ url: URL, body: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await transport.send(request)
    }
}

private struct DeviceCodePayload: Decodable {
    let deviceAuthID: String
    let userCode: String
    let interval: String
    enum CodingKeys: String, CodingKey { case deviceAuthID = "device_auth_id", userCode = "user_code", interval }
}

private struct DeviceTokenPayload: Decodable {
    let authorizationCode: String
    let codeVerifier: String
    enum CodingKeys: String, CodingKey { case authorizationCode = "authorization_code", codeVerifier = "code_verifier" }
}

public struct EndpointUsageProvider: UsageProviding {
    public let id: ProviderID
    private let credentials: any CredentialStoring
    private let transport: any HTTPTransporting
    private let now: @Sendable () -> Date

    public init(id: ProviderID, credentials: any CredentialStoring, transport: any HTTPTransporting = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.credentials = credentials
        self.transport = transport
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let credential = try await credentials.credential(for: id) else { throw ProviderError.notConnected }
        var request = URLRequest(url: id == .claude ? ProviderEndpoints.Claude.usage : ProviderEndpoints.Codex.usage)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if id == .claude {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            request.setValue("LLMits/1", forHTTPHeaderField: "User-Agent")
            if let accountID = credential.accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
            }
        }
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw ProviderError.revokedSession }
            if response.statusCode == 429 { throw ProviderError.rateLimited(retryAfter: response.retryAfter) }
            throw ProviderError.invalidResponse
        }
        let snapshot = try UsageResponseParser.parse(response.data, provider: id, fetchedAt: now())
        guard id == .claude else { return snapshot }

        var profileRequest = URLRequest(url: ProviderEndpoints.Claude.profile)
        profileRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        profileRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let profileResponse = try? await transport.send(profileRequest),
              (200..<300).contains(profileResponse.statusCode),
              let plan = try? UsageResponseParser.parseClaudePlan(profileResponse.data) else {
            return snapshot
        }
        return UsageSnapshot(
            provider: snapshot.provider,
            plan: plan,
            windows: snapshot.windows,
            fetchedAt: snapshot.fetchedAt
        )
    }
}

/// Refreshes an expiring app-owned token before delegating to the quota endpoint.
public struct RefreshingUsageProvider: UsageProviding {
    public let id: ProviderID
    private let credentials: any CredentialStoring
    private let tokenClient: OAuthTokenClient
    private let usageProvider: EndpointUsageProvider
    private let now: @Sendable () -> Date

    public init(
        id: ProviderID,
        credentials: any CredentialStoring,
        transport: any HTTPTransporting = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.id = id
        self.credentials = credentials
        self.tokenClient = OAuthTokenClient(transport: transport)
        self.usageProvider = EndpointUsageProvider(id: id, credentials: credentials, transport: transport, now: now)
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let existing = try await credentials.credential(for: id) else { throw ProviderError.notConnected }
        if let expiry = existing.expiresAt, expiry <= now().addingTimeInterval(60) {
            guard let refreshToken = existing.refreshToken else { throw ProviderError.revokedSession }
            let refreshed = try await tokenClient.refresh(
                endpoint: id == .claude ? ProviderEndpoints.Claude.token : ProviderEndpoints.Codex.token,
                clientID: id == .claude ? ProviderEndpoints.Claude.clientID : ProviderEndpoints.Codex.clientID,
                refreshToken: refreshToken,
                scopes: existing.scopes,
                now: now(),
                encoding: id == .claude ? .json : .form
            )
            let merged = OAuthCredential(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken ?? existing.refreshToken,
                expiresAt: refreshed.expiresAt,
                tokenType: refreshed.tokenType,
                scopes: refreshed.scopes.isEmpty ? existing.scopes : refreshed.scopes,
                idToken: refreshed.idToken ?? existing.idToken,
                accountID: refreshed.accountID ?? existing.accountID
            )
            try await credentials.save(merged, for: id)
        }
        return try await usageProvider.fetchUsage()
    }
}

public enum UsageResponseParser {
    public static func parse(_ data: Data, provider: ProviderID, fetchedAt: Date) throws -> UsageSnapshot {
        switch provider {
        case .claude: try parseClaude(data, fetchedAt: fetchedAt)
        case .codex: try parseCodex(data, fetchedAt: fetchedAt)
        }
    }

    private static func parseClaude(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let object = root as? [String: Any] else { throw ProviderError.invalidResponse }
        var windows: [QuotaWindow] = []
        let known = [("five_hour", "five-hour", "Five-hour quota"), ("seven_day", "weekly", "Weekly quota")]
        for (key, id, label) in known {
            if let value = object[key] as? [String: Any], let utilization = number(value["utilization"]) {
                windows.append(QuotaWindow(id: id, label: label, utilization: utilization / 100, resetsAt: date(value["resets_at"])))
            }
        }
        for (key, value) in object where key.hasPrefix("seven_day_") {
            guard let value = value as? [String: Any], let utilization = number(value["utilization"]) else { continue }
            let model = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
            windows.append(QuotaWindow(id: key.replacingOccurrences(of: "seven_day_", with: "") + "-weekly", label: "\(model) weekly", utilization: utilization / 100, resetsAt: date(value["resets_at"])))
        }
        guard !windows.isEmpty else { throw ProviderError.invalidResponse }
        let plan = (object["plan"] as? String) ?? "Claude"
        return UsageSnapshot(provider: .claude, plan: plan, windows: windows, fetchedAt: fetchedAt)
    }

    public static func parseClaudePlan(_ data: Data) throws -> String {
        let profile = try JSONDecoder().decode(ClaudeProfilePayload.self, from: data)
        let organizationType = profile.organization?.organizationType
        switch organizationType {
        case "claude_max":
            guard let tier = profile.organization?.rateLimitTier,
                  let multiplier = tier.range(of: #"max_(\d+)x"#, options: .regularExpression)
                    .map({ String(tier[$0]).dropFirst(4).dropLast() }) else { return "Max" }
            return "Max \(multiplier)×"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default:
            if profile.account?.hasClaudeMax == true { return "Max" }
            if profile.account?.hasClaudePro == true { return "Pro" }
            return "Claude"
        }
    }

    private static func parseCodex(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: data)
        var windows = payload.rateLimit?.windows(prefix: nil) ?? []
        for additional in payload.additionalRateLimits ?? [] {
            windows.append(contentsOf: additional.rateLimit?.windows(prefix: additional.limitName) ?? [])
        }
        guard !windows.isEmpty else { throw ProviderError.invalidResponse }
        return UsageSnapshot(provider: .codex, plan: payload.planType?.capitalized ?? "Codex", windows: windows, fetchedAt: fetchedAt)
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

private struct ClaudeProfilePayload: Decodable {
    let account: ClaudeProfileAccount?
    let organization: ClaudeProfileOrganization?
}

private struct ClaudeProfileAccount: Decodable {
    let hasClaudeMax: Bool?
    let hasClaudePro: Bool?

    enum CodingKeys: String, CodingKey {
        case hasClaudeMax = "has_claude_max"
        case hasClaudePro = "has_claude_pro"
    }
}

private struct ClaudeProfileOrganization: Decodable {
    let organizationType: String?
    let rateLimitTier: String?

    enum CodingKeys: String, CodingKey {
        case organizationType = "organization_type"
        case rateLimitTier = "rate_limit_tier"
    }
}

private struct TokenPayload: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let tokenType: String?
    let scope: String?
    let idToken: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        case tokenType = "token_type", scope, idToken = "id_token"
    }
}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let additionalRateLimits: [CodexAdditionalLimit]?
    enum CodingKeys: String, CodingKey {
        case planType = "plan_type", rateLimit = "rate_limit", additionalRateLimits = "additional_rate_limits"
    }
}

private struct CodexAdditionalLimit: Decodable {
    let limitName: String
    let rateLimit: CodexRateLimit?
    enum CodingKeys: String, CodingKey { case limitName = "limit_name", rateLimit = "rate_limit" }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
    enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window", secondaryWindow = "secondary_window" }

    func windows(prefix: String?) -> [QuotaWindow] {
        [(primaryWindow, prefix == nil ? "five-hour" : "\(prefix!)-primary", prefix == nil ? "Five-hour quota" : "\(prefix!) short window"),
         (secondaryWindow, prefix == nil ? "weekly" : "\(prefix!)-weekly", prefix == nil ? "Weekly quota" : "\(prefix!) weekly")]
            .compactMap { value, id, label in value.map { $0.window(id: id, label: label) } }
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double
    let resetAt: TimeInterval?
    enum CodingKeys: String, CodingKey { case usedPercent = "used_percent", resetAt = "reset_at" }
    func window(id: String, label: String) -> QuotaWindow {
        QuotaWindow(id: id, label: label, utilization: usedPercent / 100, resetsAt: resetAt.map(Date.init(timeIntervalSince1970:)))
    }
}

private extension Dictionary where Key == String, Value == String {
    var formEncoded: String {
        map { key, value in "\(key.formComponent)=\(value.formComponent)" }.sorted().joined(separator: "&")
    }
}

private extension String {
    var formComponent: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}

private extension HTTPResponse {
    var retryAfter: TimeInterval? { headers["retry-after"].flatMap(TimeInterval.init) }
}
