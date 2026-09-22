import Foundation
import LLMitsCore
import XCTest
@testable import LLMitsApp

@MainActor
final class UpdateModelTests: XCTestCase {
    func testManualChecksAreRateLimited() async {
        let transport = CountingTransport(status: 200, body: Data(#"{"tag_name":"v1.0.0","assets":[]}"#.utf8))
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let model = UpdateModel(
            currentVersion: "1.0.0",
            checker: GitHubUpdateChecker(transport: transport),
            throttle: UpdateCheckThrottle(minimumInterval: 60),
            now: { clock.now }
        )

        await model.checkForUpdatesManually()
        XCTAssertEqual(model.lastChecked, clock.now)
        XCTAssertEqual(model.nextManualCheck, clock.now.addingTimeInterval(60))
        XCTAssertNil(model.checkErrorMessage)

        clock.now.addTimeInterval(30)
        await model.checkForUpdatesManually()
        let throttledCount = await transport.count
        XCTAssertEqual(throttledCount, 1)

        clock.now.addTimeInterval(30)
        await model.checkForUpdatesManually()
        let allowedCount = await transport.count
        XCTAssertEqual(allowedCount, 2)
        model.stop()
    }

    func testRateLimitedCheckReportsRetryAndBlocksBackgroundChecks() async {
        let transport = CountingTransport(status: 429, body: Data(), headers: ["retry-after": "600"])
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let model = UpdateModel(
            currentVersion: "1.0.0",
            checker: GitHubUpdateChecker(transport: transport, now: { clock.now }),
            now: { clock.now }
        )

        await model.checkForUpdatesManually()
        XCTAssertEqual(model.checkErrorMessage, "GitHub is limiting update checks. Try again in 10m.")
        XCTAssertEqual(model.nextManualCheck, clock.now.addingTimeInterval(600))

        await model.checkForUpdates()
        let count = await transport.count
        XCTAssertEqual(count, 1)
        model.stop()
    }

    func testDevelopmentBuildsCannotCheck() async {
        let transport = CountingTransport(status: 200, body: Data())
        let model = UpdateModel(currentVersion: nil, checker: GitHubUpdateChecker(transport: transport))
        XCTAssertFalse(model.canCheck)
        await model.checkForUpdatesManually()
        let count = await transport.count
        XCTAssertEqual(count, 0)
        model.stop()
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private actor CountingTransport: HTTPTransporting {
    let status: Int
    let body: Data
    let headers: [String: String]
    private(set) var count = 0

    init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }

    func send(_ request: URLRequest) -> HTTPResponse {
        count += 1
        return HTTPResponse(data: body, statusCode: status, headers: headers)
    }
}
