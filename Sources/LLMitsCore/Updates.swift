import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AppVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        let value = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

public struct AvailableUpdate: Sendable {
    public let version: String
    public let diskImageURL: URL
    public let checksumURL: URL

    public init(version: String, diskImageURL: URL, checksumURL: URL) {
        self.version = version
        self.diskImageURL = diskImageURL
        self.checksumURL = checksumURL
    }
}

public enum UpdateCheckError: LocalizedError {
    case invalidResponse

    public var errorDescription: String? {
        "Could not check the latest LLMits release."
    }
}

public struct GitHubUpdateChecker: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/aryan1306/LLMits/releases/latest")!
    private let transport: any HTTPTransporting

    public init(transport: any HTTPTransporting = URLSessionTransport()) {
        self.transport = transport
    }

    public func availableUpdate(currentVersion: String) async throws -> AvailableUpdate? {
        guard let current = AppVersion(currentVersion) else { return nil }
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LLMits", forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request)
        guard response.statusCode == 200,
              let release = try? JSONDecoder().decode(GitHubRelease.self, from: response.data),
              let latest = AppVersion(release.tagName) else { throw UpdateCheckError.invalidResponse }
        guard latest > current else { return nil }

        guard let diskImage = release.assets.first(where: { $0.name == "LLMits.dmg" })?.browserDownloadURL,
              let checksum = release.assets.first(where: { $0.name == "LLMits.dmg.sha256" })?.browserDownloadURL,
              isExpectedAssetURL(diskImage, tag: release.tagName, name: "LLMits.dmg"),
              isExpectedAssetURL(checksum, tag: release.tagName, name: "LLMits.dmg.sha256") else {
            throw UpdateCheckError.invalidResponse
        }
        return AvailableUpdate(version: release.tagName, diskImageURL: diskImage, checksumURL: checksum)
    }

    private func isExpectedAssetURL(_ url: URL, tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path == "/aryan1306/LLMits/releases/download/\(tag)/\(name)"
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
}
