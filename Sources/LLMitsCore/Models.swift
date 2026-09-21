import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

public enum CredentialSource: String, Codable, CaseIterable, Sendable {
    case llmits
    case cli

    public var displayName: String {
        switch self {
        case .llmits: "LLMits login"
        case .cli: "Existing CLI login"
        }
    }
}

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case used
    case remaining
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let utilization: Double
    public let resetsAt: Date?

    public init(id: String, label: String, utilization: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public func percentage(for mode: DisplayMode) -> Int {
        let used = min(max(utilization, 0), 1)
        let value = mode == .used ? used : 1 - used
        return Int((value * 100).rounded())
    }
}

public struct UsageSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: ProviderID { provider }
    public let provider: ProviderID
    public let plan: String
    public let windows: [QuotaWindow]
    public let fetchedAt: Date

    public init(provider: ProviderID, plan: String, windows: [QuotaWindow], fetchedAt: Date) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.fetchedAt = fetchedAt
    }

    public var statusWindow: QuotaWindow? {
        windows.first(where: { $0.id == "five-hour" })
            ?? windows.first(where: { $0.id == "weekly" })
    }

    public func isStale(at date: Date, interval: TimeInterval) -> Bool {
        date.timeIntervalSince(fetchedAt) > interval
    }
}

public struct ProviderConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: ProviderID { provider }
    public let provider: ProviderID
    public var source: CredentialSource
    public var isConnected: Bool

    public init(provider: ProviderID, source: CredentialSource = .llmits, isConnected: Bool = false) {
        self.provider = provider
        self.source = source
        self.isConnected = isConnected
    }
}

public struct AppPreferences: Codable, Equatable, Sendable {
    public var displayMode: DisplayMode
    public var pollingMinutes: Int
    public var showAccountIdentity: Bool

    public init(displayMode: DisplayMode = .used, pollingMinutes: Int = 5, showAccountIdentity: Bool = false) {
        self.displayMode = displayMode
        self.pollingMinutes = pollingMinutes
        self.showAccountIdentity = showAccountIdentity
    }
}
