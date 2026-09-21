import Foundation

public struct RefreshBackoff: Equatable, Sendable {
    public let baseDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(baseDelay: TimeInterval = 5, maximumDelay: TimeInterval = 900) {
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
    }

    public func delay(forAttempt attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter { return min(max(0, retryAfter), maximumDelay) }
        let exponent = min(max(0, attempt - 1), 20)
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }
}
