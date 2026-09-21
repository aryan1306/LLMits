import Foundation

public struct DiagnosticRecord: Sendable {
    public let appVersion: String
    public let macOSVersion: String
    public let provider: ProviderID
    public let credentialSource: CredentialSource
    public let failureCategory: String?
    public let lastSuccessfulRefresh: Date?

    public init(appVersion: String, macOSVersion: String, provider: ProviderID, credentialSource: CredentialSource, failureCategory: String?, lastSuccessfulRefresh: Date?) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.provider = provider
        self.credentialSource = credentialSource
        self.failureCategory = failureCategory
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
    }

    public var redactedText: String {
        [
            "LLMits: \(appVersion)",
            "macOS: \(macOSVersion)",
            "Provider: \(provider.displayName)",
            "Credential source: \(credentialSource.displayName)",
            "Failure: \(failureCategory ?? "none")",
            "Last successful refresh: \(lastSuccessfulRefresh.map { ISO8601DateFormatter().string(from: $0) } ?? "never")",
        ].joined(separator: "\n")
    }
}
