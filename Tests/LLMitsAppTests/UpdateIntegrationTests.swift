import AppKit
import Foundation
import LLMitsCore
import XCTest
@testable import LLMitsApp

final class UpdateIntegrationTests: XCTestCase {
    func testLiveReleaseDownloadsInstallsRelaunchesAndRollsBack() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["LLMITS_UPDATE_TEST_CURRENT_APP"] else {
            throw XCTSkip("Set LLMITS_UPDATE_TEST_CURRENT_APP to a disposable packaged LLMits.app to run the live update test.")
        }
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LLMits-update-integration-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("LLMits.app", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: fixture, to: target)
        defer {
            terminateTestApp(at: target)
            try? FileManager.default.removeItem(at: root)
        }

        let currentVersion = try version(at: target)
        let detectedUpdate = try await GitHubUpdateChecker().availableUpdate(currentVersion: currentVersion)
        let update = try XCTUnwrap(detectedUpdate)
        let expectedVersion = update.version.hasPrefix("v") ? String(update.version.dropFirst()) : update.version
        let prepared = try await UpdateInstaller.prepare(update, currentApp: target)
        XCTAssertEqual(prepared.targetApp, target)
        XCTAssertEqual(try version(at: prepared.stagedApp), expectedVersion)
        let retainedHelper = root.appendingPathComponent("update-helper.sh")
        try FileManager.default.copyItem(at: prepared.helper, to: retainedHelper)

        try launchTestApp(at: target)
        let oldApp = try XCTUnwrap(waitForRunningTestApp(at: target))
        let helper = try startHelper(prepared.helper, stagedApp: prepared.stagedApp, target: target,
                                     parentPID: oldApp.processIdentifier)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(helper.isRunning, "The helper should wait while the old app is running.")
        XCTAssertEqual(try version(at: target), currentVersion,
                       "The installed app should not change until its process exits.")
        oldApp.terminate()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0, "The replacement helper failed.")
        XCTAssertEqual(try version(at: target), expectedVersion)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("Contents/MacOS/LLMits").path))
        XCTAssertNotNil(waitForRunningTestApp(at: target), "The replacement app was not observed running after relaunch.")

        terminateTestApp(at: target)
        let missingStage = root.appendingPathComponent("missing/LLMits.app", isDirectory: true)
        XCTAssertNotEqual(try runHelper(retainedHelper, stagedApp: missingStage, target: target), 0,
                          "A missing staged app should fail the update.")
        XCTAssertEqual(try version(at: target), expectedVersion,
                       "The original app should be restored after replacement fails.")
        XCTAssertNotNil(waitForRunningTestApp(at: target), "The restored app was not observed running.")
    }

    private func waitForRunningTestApp(at target: URL) -> NSRunningApplication? {
        for _ in 0..<40 {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.llmits.app")
                .first(where: { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }) {
                return app
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private func version(at app: URL) throws -> String {
        let info = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: info)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
    }

    private func runHelper(_ helperURL: URL, stagedApp: URL, target: URL) throws -> Int32 {
        let process = try startHelper(helperURL, stagedApp: stagedApp, target: target, parentPID: 999999999)
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func startHelper(_ helperURL: URL, stagedApp: URL, target: URL, parentPID: pid_t) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helperURL.path, stagedApp.path, target.path, String(parentPID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func launchTestApp(at target: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The old test app did not launch.")
    }

    private func terminateTestApp(at target: URL) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.llmits.app")
        where app.bundleURL?.standardizedFileURL == target.standardizedFileURL {
            app.terminate()
        }
    }
}
