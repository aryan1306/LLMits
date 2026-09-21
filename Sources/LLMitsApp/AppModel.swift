import AppKit
import Combine
import Foundation
import LLMitsCore

enum AuthorizationPhase: Equatable {
    case starting
    case claudeCallback
    case codexCode(String)
    case exchanging
    case failed(String)
}

struct AuthorizationPresentation: Equatable {
    let provider: ProviderID
    var phase: AuthorizationPhase
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var authorization: AuthorizationPresentation?
    @Published var preferences: AppPreferences {
        didSet {
            persistPreferences()
            onStatusChange?()
            if oldValue.pollingMinutes != preferences.pollingMinutes { schedulePolling() }
        }
    }
    @Published var connections: [ProviderConnection] {
        didSet { persistConnections() }
    }

    var onStatusChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let defaults: UserDefaults
    private let snapshotStore: any SnapshotPersisting
    private let credentialStore: any CredentialStoring
    private let providers: [ProviderID: any UsageProviding]
    private var lastManualRefresh: Date?
    private var pollingTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var claudeTransaction: PKCETransaction?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMits", isDirectory: true)
        snapshotStore = FileSnapshotStore(fileURL: support.appendingPathComponent("latest-usage.json"))
        let credentials = KeychainCredentialStore()
        credentialStore = credentials
        providers = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, RefreshingUsageProvider(id: $0, credentials: credentials) as any UsageProviding)
        })
        preferences = Self.decode(AppPreferences.self, key: "preferences", defaults: defaults) ?? AppPreferences()
        connections = Self.decode([ProviderConnection].self, key: "connections", defaults: defaults)
            ?? ProviderID.allCases.map { ProviderConnection(provider: $0) }
    }

    var statusTitle: String {
        let items = statusItems.map { "\($0.provider.displayName) \($0.percentage)%" }
        return items.isEmpty ? "LLMits" : items.joined(separator: "  ")
    }

    var statusItems: [(provider: ProviderID, percentage: Int)] {
        connectedSnapshots.compactMap { snapshot in
            guard let window = snapshot.statusWindow else { return nil }
            return (snapshot.provider, window.percentage(for: preferences.displayMode))
        }
    }

    var statusAccessibilityLabel: String {
        let label = preferences.displayMode == .used ? "used" : "remaining"
        let items = connectedSnapshots.compactMap { snapshot -> String? in
            guard let window = snapshot.statusWindow else { return nil }
            return "\(snapshot.provider.displayName) \(window.percentage(for: preferences.displayMode)) percent \(label)"
        }
        return items.isEmpty ? "no connected providers" : items.joined(separator: ", ")
    }

    var connectedSnapshots: [UsageSnapshot] {
        snapshots.filter { snapshot in
            connections.contains { $0.provider == snapshot.provider && $0.isConnected }
        }
    }

    func start() async {
        snapshots = (try? await snapshotStore.load()) ?? []
        for provider in ProviderID.allCases {
            let hasCredential = (try? await credentialStore.credential(for: provider)) != nil
            updateConnection(provider, connected: hasCredential)
        }
        onStatusChange?()
        if connections.contains(where: \.isConnected) { await refresh() }
        schedulePolling()
    }

    func refreshIfStale() async {
        guard snapshots.isEmpty || snapshots.contains(where: { $0.isStale(at: Date(), interval: 60) }) else { return }
        await refresh()
    }

    func manualRefresh() async {
        guard lastManualRefresh.map({ Date().timeIntervalSince($0) >= 2 }) ?? true else { return }
        lastManualRefresh = Date()
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        var updated = snapshots
        do {
            for connection in connections where connection.isConnected {
                guard let provider = providers[connection.provider] else { continue }
                let snapshot = try await provider.fetchUsage()
                updated.removeAll { $0.provider == snapshot.provider }
                updated.append(snapshot)
            }
            snapshots = updated.sorted { $0.provider.rawValue < $1.provider.rawValue }
            try await snapshotStore.save(snapshots)
            onStatusChange?()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateConnection(_ provider: ProviderID, connected: Bool) {
        guard let index = connections.firstIndex(where: { $0.provider == provider }) else { return }
        connections[index].isConnected = connected
        if connected { connections[index].source = .llmits }
    }

    func connect(_ provider: ProviderID) {
        authorizationTask?.cancel()
        authorization = AuthorizationPresentation(provider: provider, phase: .starting)
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch provider {
                case .claude: try self.beginClaudeAuthorization()
                case .codex: try await self.runCodexAuthorization()
                }
            } catch is CancellationError {
                self.authorization = nil
            } catch {
                self.authorization = AuthorizationPresentation(provider: provider, phase: .failed(error.localizedDescription))
            }
        }
    }

    func submitClaudeCallback(_ value: String) {
        guard let transaction = claudeTransaction else { return }
        authorizationTask?.cancel()
        authorization = AuthorizationPresentation(provider: .claude, phase: .exchanging)
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let callback = try OAuthCallback.parse(value)
                try callback.validate(expectedState: transaction.state)
                let credential = try await OAuthTokenClient().exchangeCode(
                    endpoint: ProviderEndpoints.Claude.token,
                    clientID: ProviderEndpoints.Claude.clientID,
                    code: callback.code,
                    verifier: transaction.verifier,
                    redirectURI: ProviderEndpoints.Claude.redirectURI,
                    encoding: .json,
                    additionalFields: ["state": callback.state]
                )
                try await self.finishConnection(credential, provider: .claude)
            } catch {
                self.authorization = AuthorizationPresentation(provider: .claude, phase: .failed(error.localizedDescription))
            }
        }
    }

    func cancelAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        claudeTransaction = nil
        authorization = nil
    }

    func disconnect(_ provider: ProviderID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await credentialStore.deleteCredential(for: provider)
                updateConnection(provider, connected: false)
                snapshots.removeAll { $0.provider == provider }
                onStatusChange?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openSettings() {
        onOpenSettings?()
    }

    func refreshAfterWake() {
        Task { await refresh() }
        schedulePolling()
    }

    func stop() {
        pollingTask?.cancel()
        authorizationTask?.cancel()
        pollingTask = nil
    }

    private func beginClaudeAuthorization() throws {
        let transaction = try PKCETransaction.generate()
        let configuration = OAuthAuthorizationConfiguration(
            authorizationEndpoint: ProviderEndpoints.Claude.authorization,
            clientID: ProviderEndpoints.Claude.clientID,
            redirectURI: ProviderEndpoints.Claude.redirectURI,
            scopes: ["org:create_api_key", "user:profile", "user:inference"],
            additionalParameters: ["code": "true"]
        )
        let url = try configuration.authorizationURL(for: transaction)
        guard NSWorkspace.shared.open(url) else { throw AuthorizationError.invalidAuthorizationURL }
        claudeTransaction = transaction
        authorization = AuthorizationPresentation(provider: .claude, phase: .claudeCallback)
    }

    private func runCodexAuthorization() async throws {
        let client = CodexDeviceAuthorizationClient()
        let device = try await client.requestCode()
        authorization = AuthorizationPresentation(provider: .codex, phase: .codexCode(device.userCode))
        _ = NSWorkspace.shared.open(device.verificationURL)

        while Date() < device.expiresAt {
            try await Task.sleep(nanoseconds: UInt64(device.pollingInterval * 1_000_000_000))
            switch try await client.poll(device) {
            case .pending: continue
            case let .authorized(grant):
                authorization = AuthorizationPresentation(provider: .codex, phase: .exchanging)
                let credential = try await OAuthTokenClient().exchangeCode(
                    endpoint: ProviderEndpoints.Codex.token,
                    clientID: ProviderEndpoints.Codex.clientID,
                    code: grant.authorizationCode,
                    verifier: grant.codeVerifier,
                    redirectURI: ProviderEndpoints.Codex.redirectURI
                )
                try await finishConnection(credential, provider: .codex)
                return
            }
        }
        throw AuthorizationError.expiredDeviceCode
    }

    private func finishConnection(_ credential: OAuthCredential, provider: ProviderID) async throws {
        try await credentialStore.save(credential, for: provider)
        updateConnection(provider, connected: true)
        authorization = nil
        claudeTransaction = nil
        await refresh()
    }

    private func schedulePolling() {
        pollingTask?.cancel()
        let interval = UInt64(max(1, preferences.pollingMinutes)) * 60 * 1_000_000_000
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func persistPreferences() { Self.encode(preferences, key: "preferences", defaults: defaults) }
    private func persistConnections() { Self.encode(connections, key: "connections", defaults: defaults) }

    private static func encode<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
