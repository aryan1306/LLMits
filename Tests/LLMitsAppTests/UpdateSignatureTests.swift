import Foundation
import XCTest
@testable import LLMitsApp

final class UpdateSignatureTests: XCTestCase {
    private let releaseRequirement = #"identifier "com.llmits.app" and certificate root = H"ad1c6cab05feb10232c97e561047c7fd13d0f924""#

    func testCertificateRequirementIsPinned() {
        XCTAssertEqual(UpdateInstaller.pinnedRequirement(forDesignated: releaseRequirement), releaseRequirement)
    }

    func testAdHocRequirementIsNotPinned() {
        XCTAssertNil(UpdateInstaller.pinnedRequirement(forDesignated: #"cdhash H"0123456789abcdef0123456789abcdef01234567""#))
    }

    func testAdHocSignedBinarySatisfiesOnlyItsOwnRequirement() throws {
        let binary = try adHocSignedBinary()
        defer { try? FileManager.default.removeItem(at: binary.deletingLastPathComponent()) }

        let own = try XCTUnwrap(UpdateInstaller.designatedRequirement(of: binary))
        XCTAssertNil(UpdateInstaller.pinnedRequirement(forDesignated: own))
        XCTAssertTrue(UpdateInstaller.satisfies(binary, requirement: own))
        XCTAssertFalse(UpdateInstaller.satisfies(binary, requirement: releaseRequirement))
    }

    private func adHocSignedBinary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LLMitsSignature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let binary = directory.appendingPathComponent("fixture")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", "com.llmits.fixture", binary.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return binary
    }
}
