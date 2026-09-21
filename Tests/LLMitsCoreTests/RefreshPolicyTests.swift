import XCTest
@testable import LLMitsCore

final class RefreshPolicyTests: XCTestCase {
    func testBackoffGrowsExponentiallyAndCaps() {
        let policy = RefreshBackoff(baseDelay: 5, maximumDelay: 60)
        XCTAssertEqual(policy.delay(forAttempt: 1), 5)
        XCTAssertEqual(policy.delay(forAttempt: 2), 10)
        XCTAssertEqual(policy.delay(forAttempt: 4), 40)
        XCTAssertEqual(policy.delay(forAttempt: 8), 60)
    }

    func testServerRetryDelayTakesPrecedenceAndCaps() {
        let policy = RefreshBackoff(baseDelay: 5, maximumDelay: 60)
        XCTAssertEqual(policy.delay(forAttempt: 4, retryAfter: 27), 27)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: 120), 60)
    }
}
