import Foundation
import XCTest
@testable import LLMitsCore

final class ProviderEndpointTests: XCTestCase {
    func testClaudeUsageParserKeepsKnownAndDynamicWindows() throws {
        let data = Data(#"""
        {
          "plan":"max",
          "five_hour":{"utilization":42,"resets_at":"2026-09-22T01:00:00Z"},
          "seven_day":{"utilization":21,"resets_at":"2026-09-28T01:00:00Z"},
          "seven_day_fable":{"utilization":12,"resets_at":"2026-09-28T01:00:00Z"},
          "new_server_field":{"anything":true}
        }
        """#.utf8)

        let snapshot = try UsageResponseParser.parse(data, provider: .claude, fetchedAt: .distantPast)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.windows.map(\.id), ["five-hour", "weekly", "fable-weekly"])
        XCTAssertEqual(snapshot.windows.last?.label, "Fable weekly")
        XCTAssertEqual(snapshot.windows.first?.utilization, 0.42)
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-09-22T01:00:00Z"))
        XCTAssertEqual(snapshot.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-09-28T01:00:00Z"))
    }

    func testClaudeUsageParserReadsFractionalSecondResetTimes() throws {
        let data = Data(#"""
        {
          "five_hour":{"utilization":0,"resets_at":"2026-09-22T01:00:00.123Z"},
          "seven_day":{"utilization":78,"resets_at":"2026-09-28T01:00:00.456Z"}
        }
        """#.utf8)

        let snapshot = try UsageResponseParser.parse(data, provider: .claude, fetchedAt: .distantPast)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
        XCTAssertEqual(snapshot.windows[0].resetsAt, formatter.date(from: "2026-09-22T01:00:00.123Z"))
        XCTAssertEqual(snapshot.windows[1].resetsAt, formatter.date(from: "2026-09-28T01:00:00.456Z"))
    }

    func testClaudeProfileParserMapsSubscriptionAndRateLimitTier() throws {
        let maxData = Data(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#.utf8)
        let proData = Data(#"{"organization":{"organization_type":"claude_pro","rate_limit_tier":"default_claude_pro"}}"#.utf8)

        XCTAssertEqual(try UsageResponseParser.parseClaudePlan(maxData), "Max 20×")
        XCTAssertEqual(try UsageResponseParser.parseClaudePlan(proData), "Pro")
    }

    func testClaudeUsageProviderEnrichesSnapshotWithProfilePlan() async throws {
        let credentials = InMemoryCredentialStore()
        await credentials.save(OAuthCredential(accessToken: "access"), for: .claude)
        let transport = RecordingTransport(responses: [
            HTTPResponse(data: Data(#"{"five_hour":{"utilization":10}}"#.utf8), statusCode: 200),
            HTTPResponse(data: Data(#"{"organization":{"organization_type":"claude_max","rate_limit_tier":"default_claude_max_5x"}}"#.utf8), statusCode: 200),
        ])
        let provider = EndpointUsageProvider(id: .claude, credentials: credentials, transport: transport)

        let snapshot = try await provider.fetchUsage()

        XCTAssertEqual(snapshot.plan, "Max 5×")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.url), [ProviderEndpoints.Claude.usage, ProviderEndpoints.Claude.profile])
    }

    func testCodexUsageParserMapsPrimarySecondaryAndAdditionalLimits() throws {
        let data = Data(#"""
        {
          "plan_type":"plus",
          "rate_limit":{
            "primary_window":{"used_percent":67,"reset_at":2000000000},
            "secondary_window":{"used_percent":24,"reset_at":2000500000}
          },
          "additional_rate_limits":[{
            "limit_name":"codex_other",
            "metered_feature":"codex_other",
            "rate_limit":{"secondary_window":{"used_percent":11,"reset_at":2000600000}}
          }]
        }
        """#.utf8)

        let snapshot = try UsageResponseParser.parse(data, provider: .codex, fetchedAt: .distantPast)
        XCTAssertEqual(snapshot.plan, "Plus")
        XCTAssertEqual(snapshot.windows.map(\.id), ["five-hour", "weekly", "codex_other-weekly"])
        XCTAssertEqual(snapshot.windows[0].utilization, 0.67)
        XCTAssertEqual(snapshot.windows[2].utilization, 0.11)
    }

    func testTokenExchangeDecodesCredentialAndExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = HTTPResponse(
            data: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer","scope":"openid profile","id_token":"id"}"#.utf8),
            statusCode: 200
        )
        let client = OAuthTokenClient(transport: StubTransport(response: response))
        let credential = try await client.exchangeCode(
            endpoint: ProviderEndpoints.Codex.token,
            clientID: ProviderEndpoints.Codex.clientID,
            code: "code",
            verifier: "verifier",
            redirectURI: ProviderEndpoints.Codex.redirectURI,
            now: now
        )

        XCTAssertEqual(credential.accessToken, "access")
        XCTAssertEqual(credential.refreshToken, "refresh")
        XCTAssertEqual(credential.expiresAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(credential.scopes, ["openid", "profile"])
        XCTAssertEqual(credential.idToken, "id")
    }

    func testEndpointConstantsMatchCurrentProviderContracts() {
        XCTAssertEqual(ProviderEndpoints.Claude.token.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(ProviderEndpoints.Claude.usage.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(ProviderEndpoints.Claude.profile.absoluteString, "https://api.anthropic.com/api/oauth/profile")
        XCTAssertEqual(ProviderEndpoints.Codex.deviceCode.path, "/api/accounts/deviceauth/usercode")
        XCTAssertEqual(ProviderEndpoints.Codex.deviceToken.path, "/api/accounts/deviceauth/token")
        XCTAssertEqual(ProviderEndpoints.Codex.token.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(ProviderEndpoints.Codex.usage.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
    }

    func testCodexDeviceAuthorizationRequestsAndPollsJSONEndpoints() async throws {
        let transport = RecordingTransport(responses: [
            HTTPResponse(data: Data(#"{"device_auth_id":"device-1","user_code":"ABCD-EFGH","interval":"5"}"#.utf8), statusCode: 200),
            HTTPResponse(data: Data(#"{"authorization_code":"code-1","code_challenge":"unused","code_verifier":"verifier-1"}"#.utf8), statusCode: 200),
        ])
        let client = CodexDeviceAuthorizationClient(transport: transport)
        let authorization = try await client.requestCode(now: Date(timeIntervalSince1970: 100))
        let result = try await client.poll(authorization)

        XCTAssertEqual(authorization.deviceCode, "device-1")
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.pollingInterval, 5)
        XCTAssertEqual(result, .authorized(DeviceAuthorizationGrant(authorizationCode: "code-1", codeVerifier: "verifier-1")))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.url), [ProviderEndpoints.Codex.deviceCode, ProviderEndpoints.Codex.deviceToken])
        XCTAssertEqual(requests.map(\.valueForContentType), ["application/json", "application/json"])
        XCTAssertEqual(try jsonBody(requests[0])["client_id"] as? String, ProviderEndpoints.Codex.clientID)
        XCTAssertEqual(try jsonBody(requests[1])["device_auth_id"] as? String, "device-1")
    }

    func testRefreshingProviderPreservesRotatedFieldsThenFetchesUsage() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let credentials = InMemoryCredentialStore()
        await credentials.save(
            OAuthCredential(accessToken: "old", refreshToken: "keep-refresh", expiresAt: now, scopes: ["scope"], accountID: "account-1"),
            for: .codex
        )
        let transport = RecordingTransport(responses: [
            HTTPResponse(data: Data(#"{"access_token":"new","expires_in":3600}"#.utf8), statusCode: 200),
            HTTPResponse(data: Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":25}}}"#.utf8), statusCode: 200),
        ])
        let provider = RefreshingUsageProvider(id: .codex, credentials: credentials, transport: transport, now: { now })

        let snapshot = try await provider.fetchUsage()
        let saved = await credentials.credential(for: .codex)

        XCTAssertEqual(snapshot.windows.first?.utilization, 0.25)
        XCTAssertEqual(saved?.accessToken, "new")
        XCTAssertEqual(saved?.refreshToken, "keep-refresh")
        XCTAssertEqual(saved?.accountID, "account-1")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-1")
    }
}

private struct StubTransport: HTTPTransporting {
    let response: HTTPResponse
    func send(_ request: URLRequest) async throws -> HTTPResponse { response }
}

private actor RecordingTransport: HTTPTransporting {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) { self.responses = responses }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ProviderError.invalidResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private extension URLRequest {
    var valueForContentType: String? { value(forHTTPHeaderField: "Content-Type") }
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
}
