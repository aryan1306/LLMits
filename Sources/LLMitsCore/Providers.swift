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
        let base: Double = switch id {
        case .claude: 0.42
        case .codex: 0.67
        case .antigravity: 0.31
        }
        let plan: String = switch id {
        case .claude: "Max"
        case .codex: "Plus"
        case .antigravity: "Pro"
        }
        let windows: [QuotaWindow] = if id == .antigravity {
            [
                QuotaWindow(id: "gemini-five-hour", label: "Gemini five-hour quota", utilization: base, resetsAt: date.addingTimeInterval(7_200)),
                QuotaWindow(id: "gemini-weekly", label: "Gemini weekly quota", utilization: base / 2, resetsAt: date.addingTimeInterval(259_200)),
                QuotaWindow(id: "claude-gpt-five-hour", label: "Claude & GPT five-hour quota", utilization: 0.18, resetsAt: date.addingTimeInterval(7_200)),
                QuotaWindow(id: "claude-gpt-weekly", label: "Claude & GPT weekly quota", utilization: 0.09, resetsAt: date.addingTimeInterval(259_200)),
            ]
        } else {
            [
                QuotaWindow(id: "five-hour", label: "Five-hour quota", utilization: base, resetsAt: date.addingTimeInterval(7_200)),
                QuotaWindow(id: "weekly", label: "Weekly quota", utilization: base / 2, resetsAt: date.addingTimeInterval(259_200)),
            ]
        }
        return UsageSnapshot(
            provider: id,
            plan: plan,
            windows: windows,
            fetchedAt: date
        )
    }
}
