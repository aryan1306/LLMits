import XCTest
@testable import LLMitsCore

final class AuthorizationTests: XCTestCase {
    func testPKCEGeneratesURLSafeValuesAndMatchingChallenge() throws {
        let transaction = try PKCETransaction.generate()
        XCTAssertEqual(transaction.state.count, 43)
        XCTAssertEqual(transaction.verifier.count, 43)
        XCTAssertEqual(transaction.challenge.count, 43)
        XCTAssertFalse(transaction.state.contains("="))
        XCTAssertFalse(transaction.challenge.contains("+"))
        XCTAssertFalse(transaction.challenge.contains("/"))
    }

    func testAuthorizationURLContainsRequiredPKCEParameters() throws {
        let configuration = OAuthAuthorizationConfiguration(
            authorizationEndpoint: try XCTUnwrap(URL(string: "https://provider.example/authorize")),
            clientID: "client-id",
            redirectURI: "https://localhost/callback",
            scopes: ["profile", "usage"]
        )
        let transaction = PKCETransaction(state: "expected-state", verifier: "verifier", challenge: "challenge")
        let url = try configuration.authorizationURL(for: transaction)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(values["client_id"], "client-id")
        XCTAssertEqual(values["state"], "expected-state")
        XCTAssertEqual(values["code_challenge"], "challenge")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["scope"], "profile usage")
    }

    func testCallbackParsesURLAndValidatesState() throws {
        let callback = try OAuthCallback.parse("llmits://callback?code=secret-code&state=expected-state")
        XCTAssertEqual(callback.code, "secret-code")
        XCTAssertNoThrow(try callback.validate(expectedState: "expected-state"))
        XCTAssertThrowsError(try callback.validate(expectedState: "different-state")) { error in
            XCTAssertEqual(error as? AuthorizationError, .stateMismatch)
        }
    }

    func testCallbackParsesManualCodeFormat() throws {
        XCTAssertEqual(
            try OAuthCallback.parse(" secret-code#expected-state \n"),
            OAuthCallback(code: "secret-code", state: "expected-state")
        )
    }

    func testDeviceAuthorizationPendingSlowDownAndSuccess() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "ABCD-EFGH",
            verificationURL: try XCTUnwrap(URL(string: "https://provider.example/device")),
            expiresAt: now.addingTimeInterval(600),
            pollingInterval: 5
        )
        var machine = DeviceAuthorizationStateMachine()
        machine.begin(authorization, now: now)
        XCTAssertEqual(machine.nextPollAt, now.addingTimeInterval(5))
        machine.receive(.pending, now: now.addingTimeInterval(5))
        XCTAssertEqual(machine.nextPollAt, now.addingTimeInterval(10))
        machine.receive(.slowDown, now: now.addingTimeInterval(10))
        XCTAssertEqual(machine.nextPollAt, now.addingTimeInterval(20))

        let credential = OAuthCredential(accessToken: "access", refreshToken: "refresh")
        machine.receive(.authorized(credential), now: now.addingTimeInterval(20))
        XCTAssertEqual(machine.state, .authorized(credential))
        XCTAssertNil(machine.nextPollAt)
    }

    func testDeviceAuthorizationExpiresBeforePollResult() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let authorization = DeviceAuthorization(
            deviceCode: "device",
            userCode: "ABCD-EFGH",
            verificationURL: try XCTUnwrap(URL(string: "https://provider.example/device")),
            expiresAt: now.addingTimeInterval(5),
            pollingInterval: 5
        )
        var machine = DeviceAuthorizationStateMachine()
        machine.begin(authorization, now: now)
        machine.receive(.pending, now: now.addingTimeInterval(5))
        XCTAssertEqual(machine.state, .failed(.expiredDeviceCode))
        XCTAssertNil(machine.nextPollAt)
    }
}
