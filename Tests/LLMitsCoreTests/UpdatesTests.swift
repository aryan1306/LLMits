import Foundation
import XCTest
@testable import LLMitsCore

final class UpdatesTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertTrue(AppVersion("1.10.0")! > AppVersion("1.9.9")!)
        XCTAssertEqual(AppVersion("v1.2.3"), AppVersion("1.2.3"))
        XCTAssertNil(AppVersion("1.2.3-beta"))
        XCTAssertNil(AppVersion("1.2"))
    }

    func testCheckerReturnsNewerReleaseWithExpectedAssets() async throws {
        let transport = UpdateStubTransport(status: 200, body: release(tag: "v1.2.0"))
        let update = try await GitHubUpdateChecker(transport: transport).availableUpdate(currentVersion: "1.1.9")

        XCTAssertEqual(update?.version, "v1.2.0")
        XCTAssertEqual(update?.diskImageURL.absoluteString, "https://github.com/aryan1306/LLMits/releases/download/v1.2.0/LLMits.dmg")
        XCTAssertEqual(update?.checksumURL.lastPathComponent, "LLMits.dmg.sha256")
        let request = await transport.request
        XCTAssertEqual(request?.url, GitHubUpdateChecker.latestReleaseURL)
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testCheckerIgnoresCurrentAndOlderReleases() async throws {
        let transport = UpdateStubTransport(status: 200, body: release(tag: "v1.2.0"))
        let checker = GitHubUpdateChecker(transport: transport)
        let current = try await checker.availableUpdate(currentVersion: "1.2.0")
        let older = try await checker.availableUpdate(currentVersion: "2.0.0")
        XCTAssertNil(current)
        XCTAssertNil(older)
    }

    func testCheckerRejectsMissingOrUnexpectedAssets() async {
        let body = Data(#"{"tag_name":"v2.0.0","assets":[{"name":"LLMits.dmg","browser_download_url":"https://example.com/LLMits.dmg"}]}"#.utf8)
        let checker = GitHubUpdateChecker(transport: UpdateStubTransport(status: 200, body: body))
        do {
            _ = try await checker.availableUpdate(currentVersion: "1.0.0")
            XCTFail("Expected invalid release")
        } catch {
            XCTAssertTrue(error is UpdateCheckError)
        }
    }

    func testCheckerReportsGitHubRateLimitReset() async {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = UpdateStubTransport(status: 403, body: Data(), headers: [
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": "1800000000",
        ])
        do {
            _ = try await GitHubUpdateChecker(transport: transport).availableUpdate(currentVersion: "1.0.0")
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .rateLimited(until: reset))
        }
    }

    func testCheckerPrefersRetryAfter() async {
        let now = Date(timeIntervalSince1970: 1_000)
        let transport = UpdateStubTransport(status: 429, body: Data(), headers: ["retry-after": "120"])
        do {
            _ = try await GitHubUpdateChecker(transport: transport, now: { now }).availableUpdate(currentVersion: "1.0.0")
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .rateLimited(until: now.addingTimeInterval(120)))
        }
    }

    func testCheckerTreatsPlainForbiddenAsInvalid() async {
        let transport = UpdateStubTransport(status: 403, body: Data())
        do {
            _ = try await GitHubUpdateChecker(transport: transport).availableUpdate(currentVersion: "1.0.0")
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .invalidResponse)
        }
    }

    func testThrottleSpacesChecksByMinimumInterval() {
        let start = Date(timeIntervalSince1970: 1_000)
        var throttle = UpdateCheckThrottle(minimumInterval: 60)
        XCTAssertNil(throttle.nextAllowedCheck(at: start))

        throttle.recordCheck(at: start)
        XCTAssertEqual(throttle.nextAllowedCheck(at: start.addingTimeInterval(30)), start.addingTimeInterval(60))
        XCTAssertNil(throttle.nextAllowedCheck(at: start.addingTimeInterval(60)))
    }

    func testThrottleHonorsRateLimitWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        var throttle = UpdateCheckThrottle(minimumInterval: 60)
        throttle.recordCheck(at: now)
        throttle.recordRateLimit(until: now.addingTimeInterval(600), now: now)
        XCTAssertEqual(throttle.nextAllowedCheck(at: now.addingTimeInterval(61)), now.addingTimeInterval(600))

        // An earlier reset never shortens an existing block.
        throttle.recordRateLimit(until: now.addingTimeInterval(10), now: now)
        XCTAssertEqual(throttle.blockedUntil, now.addingTimeInterval(600))

        var unknownReset = UpdateCheckThrottle()
        unknownReset.recordRateLimit(until: nil, now: now)
        XCTAssertEqual(unknownReset.blockedUntil, now.addingTimeInterval(15 * 60))
    }

    private func release(tag: String) -> Data {
        Data("""
        {"tag_name":"\(tag)","assets":[
          {"name":"LLMits.dmg","browser_download_url":"https://github.com/aryan1306/LLMits/releases/download/\(tag)/LLMits.dmg"},
          {"name":"LLMits.dmg.sha256","browser_download_url":"https://github.com/aryan1306/LLMits/releases/download/\(tag)/LLMits.dmg.sha256"}
        ]}
        """.utf8)
    }
}

private actor UpdateStubTransport: HTTPTransporting {
    let status: Int
    let body: Data
    let headers: [String: String]
    private(set) var request: URLRequest?
    private(set) var requestCount = 0

    init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    func send(_ request: URLRequest) -> HTTPResponse {
        self.request = request
        requestCount += 1
        return HTTPResponse(data: body, statusCode: status, headers: headers)
    }
}
