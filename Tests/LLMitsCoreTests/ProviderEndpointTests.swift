import Foundation
import XCTest
@testable import LLMitsCore

final class ProviderEndpointTests: XCTestCase {
    func testClaudeUsageParserKeepsKnownAndDynamicWindows() throws {
        let data = Data(#"""
        {
          "plan":"max",
          "five_hour":{"utilization":0.42,"resets_at":"2026-09-22T01:00:00Z"},
          "seven_day":{"utilization":0.21,"resets_at":"2026-09-28T01:00:00Z"},
          "seven_day_fable":{"utilization":0.12,"resets_at":"2026-09-28T01:00:00Z"},
          "new_server_field":{"anything":true}
        }
        """#.utf8)

        let snapshot = try UsageResponseParser.parse(data, provider: .claude, fetchedAt: .distantPast)
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.windows.map(\.id), ["five-hour", "weekly", "fable-weekly"])
        XCTAssertEqual(snapshot.windows.last?.label, "Fable weekly")
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
        XCTAssertEqual(ProviderEndpoints.Codex.deviceCode.path, "/api/accounts/deviceauth/usercode")
        XCTAssertEqual(ProviderEndpoints.Codex.deviceToken.path, "/api/accounts/deviceauth/token")
        XCTAssertEqual(ProviderEndpoints.Codex.token.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(ProviderEndpoints.Codex.usage.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
    }
}

private struct StubTransport: HTTPTransporting {
    let response: HTTPResponse
    func send(_ request: URLRequest) async throws -> HTTPResponse { response }
}
