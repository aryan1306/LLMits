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

public enum UpdateCheckError: LocalizedError, Equatable {
    case invalidResponse
    case rateLimited(until: Date?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Could not check the latest LLMits release."
        case .rateLimited: "GitHub is limiting update checks. Try again later."
        }
    }
}

/// Spaces out manual update checks and honors GitHub's own rate-limit window.
public struct UpdateCheckThrottle: Equatable, Sendable {
    public let minimumInterval: TimeInterval
    public private(set) var lastCheck: Date?
    public private(set) var blockedUntil: Date?

    public init(minimumInterval: TimeInterval = 60) {
        self.minimumInterval = minimumInterval
    }

    /// When the next check may run, or nil if one may run now.
    public func nextAllowedCheck(at now: Date) -> Date? {
        let candidates = [lastCheck?.addingTimeInterval(minimumInterval), blockedUntil]
        guard let next = candidates.compactMap({ $0 }).max(), next > now else { return nil }
        return next
    }

    public mutating func recordCheck(at date: Date) {
        lastCheck = date
    }

    public mutating func recordRateLimit(until date: Date?, now: Date) {
        // Without a reset time from GitHub, wait out a conservative window.
        let until = date ?? now.addingTimeInterval(15 * 60)
        blockedUntil = max(blockedUntil ?? until, until)
    }
}

public struct GitHubUpdateChecker: Sendable {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/aryan1306/LLMits/releases/latest")!
    private let transport: any HTTPTransporting
    private let now: @Sendable () -> Date

    public init(transport: any HTTPTransporting = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func availableUpdate(currentVersion: String) async throws -> AvailableUpdate? {
        guard let current = AppVersion(currentVersion) else { return nil }
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("LLMits", forHTTPHeaderField: "User-Agent")
        let response = try await transport.send(request)
        try throwIfRateLimited(response)
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

    /// GitHub signals exhausted limits with 403 or 429 plus Retry-After or X-RateLimit-* headers.
    private func throwIfRateLimited(_ response: HTTPResponse) throws {
        guard response.statusCode == 403 || response.statusCode == 429 else { return }
        if let retryAfter = response.headers["retry-after"].flatMap(TimeInterval.init) {
            throw UpdateCheckError.rateLimited(until: now().addingTimeInterval(retryAfter))
        }
        if response.headers["x-ratelimit-remaining"] == "0" {
            let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init)
            throw UpdateCheckError.rateLimited(until: reset.map(Date.init(timeIntervalSince1970:)))
        }
        if response.statusCode == 429 { throw UpdateCheckError.rateLimited(until: nil) }
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
