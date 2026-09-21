import Foundation

public protocol UsageProviding: Sendable {
    var id: ProviderID { get }
    func fetchUsage() async throws -> UsageSnapshot
}

public enum ProviderError: LocalizedError, Sendable {
    case notConnected
    case rateLimited(retryAfter: TimeInterval?)
    case invalidResponse
    case revokedSession

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected"
        case .rateLimited: "Refresh was rate limited"
        case .invalidResponse: "The provider returned an unsupported response"
        case .revokedSession: "The session was revoked; reconnect to continue"
        }
    }
}

/// Development adapter. Real provider integrations conform to `UsageProviding`
/// without leaking response schemas into presentation code.
public struct PreviewUsageProvider: UsageProviding {
    public let id: ProviderID
    private let now: @Sendable () -> Date

    public init(id: ProviderID, now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        let date = now()
        let base = id == .claude ? 0.42 : 0.67
        return UsageSnapshot(
            provider: id,
            plan: id == .claude ? "Max" : "Plus",
            windows: [
                QuotaWindow(id: "five-hour", label: "Five-hour quota", utilization: base, resetsAt: date.addingTimeInterval(7_200)),
                QuotaWindow(id: "weekly", label: "Weekly quota", utilization: base / 2, resetsAt: date.addingTimeInterval(259_200)),
            ],
            fetchedAt: date
        )
    }
}
