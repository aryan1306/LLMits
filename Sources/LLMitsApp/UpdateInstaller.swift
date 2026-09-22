import AppKit
import CryptoKit
import Foundation
import LLMitsCore

enum UpdateInstallError: LocalizedError {
    case requiresAppBundle
    case destinationNotWritable
    case invalidDownload
    case invalidChecksum
    case invalidApp
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresAppBundle: "Updates can only be installed from a packaged LLMits.app."
        case .destinationNotWritable: "LLMits cannot write to its current Applications folder. Reinstall the release manually."
        case .invalidDownload: "The update download failed. Please try again."
        case .invalidChecksum: "The update download did not match its published checksum."
        case .invalidApp: "The downloaded app could not be verified."
        case let .commandFailed(command): "The update could not complete: \(command)."
        }
    }
}

struct PreparedUpdate {
    let stagedApp: URL
    let targetApp: URL
    let helper: URL

    @MainActor
    func installAndRelaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, stagedApp.path, targetApp.path, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        NSApp.terminate(nil)
    }
}

enum UpdateInstaller {
    static func prepare(_ update: AvailableUpdate, currentApp: URL) async throws -> PreparedUpdate {
        guard currentApp.pathExtension == "app", currentApp.lastPathComponent == "LLMits.app" else {
            throw UpdateInstallError.requiresAppBundle
        }
        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateInstallError.destinationNotWritable
        }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("LLMits-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scratch.path)
        var keepScratch = false
        defer { if !keepScratch { try? FileManager.default.removeItem(at: scratch) } }

        let diskImage = scratch.appendingPathComponent("LLMits.dmg")
        let (download, downloadResponse) = try await URLSession.shared.download(from: update.diskImageURL)
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateInstallError.invalidDownload }
        try FileManager.default.moveItem(at: download, to: diskImage)
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: update.checksumURL)
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
              let checksumText = String(data: checksumData, encoding: .utf8),
              let expected = expectedChecksum(in: checksumText) else { throw UpdateInstallError.invalidChecksum }
        let actual = SHA256.hash(data: try Data(contentsOf: diskImage)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateInstallError.invalidChecksum }

        let mount = scratch.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        try await run("/usr/bin/hdiutil", ["attach", diskImage.path, "-nobrowse", "-readonly", "-mountpoint", mount.path, "-quiet"])
        let stagedApp = scratch.appendingPathComponent("LLMits.app", isDirectory: true)
        do {
            let mountedApp = mount.appendingPathComponent("LLMits.app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: mountedApp.path) else { throw UpdateInstallError.invalidApp }
            try await run("/usr/bin/ditto", [mountedApp.path, stagedApp.path])
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp.path])
            guard let bundle = Bundle(url: stagedApp),
                  bundle.bundleIdentifier == "com.llmits.app",
                  let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
                  AppVersion(version) == AppVersion(update.version),
                  FileManager.default.isExecutableFile(atPath: stagedApp.appendingPathComponent("Contents/MacOS/LLMits").path) else {
                throw UpdateInstallError.invalidApp
            }
        } catch {
            try? await run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            throw error
        }
        try await run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])

        guard let helperResource = Bundle.module.url(forResource: "update-helper", withExtension: "sh") else {
            throw UpdateInstallError.invalidApp
        }
        let helper = scratch.appendingPathComponent("update-helper.sh")
        try FileManager.default.copyItem(at: helperResource, to: helper)
        keepScratch = true
        return PreparedUpdate(stagedApp: stagedApp, targetApp: currentApp, helper: helper)
    }

    private static func expectedChecksum(in text: String) -> String? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[1] == "LLMits.dmg", fields[0].count == 64,
              fields[0].allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(fields[0]).lowercased()
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: UpdateInstallError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent)) }
            }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}
