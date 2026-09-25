import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case antigravity

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }
}

public enum AntigravityPool: String, Codable, CaseIterable, Sendable {
    case gemini
    case claudeGPT

    public var displayName: String {
        switch self {
        case .gemini: "Gemini"
        case .claudeGPT: "Claude & GPT"
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

    public func statusWindow(antigravityPool: AntigravityPool) -> QuotaWindow? {
        guard provider == .antigravity else { return statusWindow }
        let prefix = antigravityPool == .gemini ? "gemini" : "claude-gpt"
        return windows.first(where: { $0.id == "\(prefix)-five-hour" })
            ?? windows.first(where: { $0.id == "\(prefix)-weekly" })
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
    public var menuBarProviders: [ProviderID]
    /// Display order for the popover and the menu bar. Always contains every provider exactly once.
    public var providerOrder: [ProviderID] {
        didSet { providerOrder = Self.normalizedOrder(providerOrder) }
    }
    public var antigravityPool: AntigravityPool

    public init(
        displayMode: DisplayMode = .used,
        pollingMinutes: Int = 5,
        showAccountIdentity: Bool = false,
        menuBarProviders: [ProviderID] = [.claude, .codex],
        providerOrder: [ProviderID] = ProviderID.allCases,
        antigravityPool: AntigravityPool = .gemini
    ) {
        self.displayMode = displayMode
        self.pollingMinutes = pollingMinutes
        self.showAccountIdentity = showAccountIdentity
        self.menuBarProviders = Array(menuBarProviders.uniqued().prefix(3))
        self.providerOrder = Self.normalizedOrder(providerOrder)
        self.antigravityPool = antigravityPool
    }

    private enum CodingKeys: String, CodingKey {
        case displayMode, pollingMinutes, showAccountIdentity, menuBarProviders, providerOrder, antigravityPool
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = try values.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .used
        pollingMinutes = try values.decodeIfPresent(Int.self, forKey: .pollingMinutes) ?? 5
        showAccountIdentity = try values.decodeIfPresent(Bool.self, forKey: .showAccountIdentity) ?? false
        menuBarProviders = Array(
            (try values.decodeIfPresent([ProviderID].self, forKey: .menuBarProviders) ?? [.claude, .codex])
                .uniqued().prefix(3)
        )
        // Older builds ordered the menu bar through menuBarProviders; keep that order when migrating.
        providerOrder = Self.normalizedOrder(
            try values.decodeIfPresent([ProviderID].self, forKey: .providerOrder) ?? menuBarProviders
        )
        antigravityPool = try values.decodeIfPresent(AntigravityPool.self, forKey: .antigravityPool) ?? .gemini
    }

    private static func normalizedOrder(_ order: [ProviderID]) -> [ProviderID] {
        let known = order.uniqued()
        return known + ProviderID.allCases.filter { !known.contains($0) }
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
