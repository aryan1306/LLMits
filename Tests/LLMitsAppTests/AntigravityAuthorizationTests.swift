import Foundation
import XCTest
@testable import LLMitsApp

final class AntigravityAuthorizationTests: XCTestCase {
    func testLoopbackReceivesMatchingGoogleCallback() async throws {
        let server = try LoopbackOAuthServer(state: "expected-state")
        defer { server.cancel() }
        let redirect = try await server.start()
        let timeout = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            server.cancel()
        }
        defer { timeout.cancel() }
        let callbackTask = Task { try await server.callback() }
        let url = try XCTUnwrap(URL(string: "\(redirect)?code=authorization-code&state=expected-state"))
        let (data, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Sign-in complete"))
        let callback = try await callbackTask.value
        XCTAssertEqual(callback.code, "authorization-code")
        XCTAssertEqual(callback.state, "expected-state")
    }
}
