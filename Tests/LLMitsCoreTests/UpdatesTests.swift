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
    private(set) var request: URLRequest?

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) -> HTTPResponse {
        self.request = request
        return HTTPResponse(data: body, statusCode: status)
    }
}
