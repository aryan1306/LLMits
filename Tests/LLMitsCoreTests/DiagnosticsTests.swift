import XCTest
@testable import LLMitsCore

final class DiagnosticsTests: XCTestCase {
    func testDiagnosticsContainOnlyAllowlistedFields() {
        let record = DiagnosticRecord(
            appVersion: "0.1.0",
            macOSVersion: "14.0",
            provider: .claude,
            credentialSource: .cli,
            failureCategory: "HTTP 401",
            lastSuccessfulRefresh: Date(timeIntervalSince1970: 0)
        )

        let text = record.redactedText
        XCTAssertTrue(text.contains("Provider: Claude"))
        XCTAssertTrue(text.contains("HTTP 401"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("account"))
    }
}
