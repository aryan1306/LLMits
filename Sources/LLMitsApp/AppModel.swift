import AppKit
import Combine
import Foundation
import LLMitsCore

enum AuthorizationPhase: Equatable {
    case starting
    case claudeCallback
    case codexCode(String)
    case antigravityBrowser
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
    private let antigravityCLIProvider: any UsageProviding
    private var lastManualRefresh: Date?
    private var cliRefreshError: String?
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
        providers = [
            .claude: RefreshingUsageProvider(id: .claude, credentials: credentials),
            .codex: RefreshingUsageProvider(id: .codex, credentials: credentials),
            .antigravity: AntigravityUsageProvider(credentials: credentials),
        ]
        antigravityCLIProvider = AntigravityCLIUsageProvider()
        preferences = Self.decode(AppPreferences.self, key: "preferences", defaults: defaults) ?? AppPreferences()
        let savedConnections = Self.decode([ProviderConnection].self, key: "connections", defaults: defaults) ?? []
        connections = ProviderID.allCases.map { provider in
            savedConnections.first(where: { $0.provider == provider }) ?? ProviderConnection(provider: provider)
        }
    }

    var statusTitle: String {
        let items = statusItems.map { "\($0.provider.displayName) \($0.percentage)%" }
        return items.isEmpty ? "LLMits" : items.joined(separator: "  ")
    }

    var statusItems: [(provider: ProviderID, percentage: Int)] {
        preferences.providerOrder.filter(preferences.menuBarProviders.contains).compactMap { provider in
            guard let snapshot = connectedSnapshots.first(where: { $0.provider == provider }),
                  let window = snapshot.statusWindow(antigravityPool: preferences.antigravityPool) else { return nil }
            return (snapshot.provider, window.percentage(for: preferences.displayMode))
        }
    }

    var statusAccessibilityLabel: String {
        let label = preferences.displayMode == .used ? "used" : "remaining"
        let items = statusItems.map { item in
            "\(item.provider.displayName) \(item.percentage) percent \(label)"
        }
        return items.isEmpty ? "no connected providers" : items.joined(separator: ", ")
    }

    var connectedSnapshots: [UsageSnapshot] {
        connectedProviders.compactMap { provider in snapshots.first { $0.provider == provider } }
    }

    func start() async {
        snapshots = (try? await snapshotStore.load()) ?? []
        for provider in ProviderID.allCases {
            let hasCredential = (try? await credentialStore.credential(for: provider)) != nil
            if provider == .antigravity, !hasCredential, preferences.allowAntigravityKeychainFallback,
               (try? AntigravityCredentialReader.credential()) != nil {
                updateConnection(provider, connected: true, source: .cli)
            } else {
                updateConnection(provider, connected: hasCredential, source: .llmits)
            }
        }
        ensureMenuBarSelection()
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
        cliRefreshError = nil
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        var updated = snapshots
        var failures: [String] = []
        for connection in connections where connection.isConnected {
            if connection.provider == .antigravity, connection.source == .cli,
               let cliRefreshError {
                failures.append("Antigravity: \(cliRefreshError)")
                continue
            }
            let provider: (any UsageProviding)? = connection.provider == .antigravity && connection.source == .cli
                ? antigravityCLIProvider : providers[connection.provider]
            guard let provider else { continue }
            do {
                let snapshot = try await provider.fetchUsage()
                updated.removeAll { $0.provider == snapshot.provider }
                updated.append(snapshot)
            } catch {
                if connection.provider == .antigravity, connection.source == .cli,
                   error is AntigravityCLIError {
                    cliRefreshError = error.localizedDescription
                }
                failures.append("\(connection.provider.displayName): \(error.localizedDescription)")
            }
        }
        do {
            snapshots = updated.sorted { $0.provider.rawValue < $1.provider.rawValue }
            try await snapshotStore.save(snapshots)
            onStatusChange?()
        } catch {
            failures.append(error.localizedDescription)
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func updateConnection(_ provider: ProviderID, connected: Bool, source: CredentialSource = .llmits) {
        guard let index = connections.firstIndex(where: { $0.provider == provider }) else { return }
        connections[index].isConnected = connected
        if connected { connections[index].source = source }
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
                case .antigravity: try await self.runAntigravityAuthorization()
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
                if provider == .antigravity, connections.first(where: { $0.provider == provider })?.source == .cli {
                    preferences.allowAntigravityKeychainFallback = false
                }
                try await credentialStore.deleteCredential(for: provider)
                updateConnection(provider, connected: false)
                if provider == .antigravity { cliRefreshError = nil }
                snapshots.removeAll { $0.provider == provider }
                ensureMenuBarSelection()
                onStatusChange?()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func connectUsingExistingAntigravityLogin() {
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard try AntigravityCredentialReader.credential() != nil else { throw ProviderError.notConnected }
                preferences.allowAntigravityKeychainFallback = true
                updateConnection(.antigravity, connected: true, source: .cli)
                cliRefreshError = nil
                authorization = nil
                ensureMenuBarSelection()
                await refresh()
            } catch {
                authorization = AuthorizationPresentation(provider: .antigravity, phase: .failed(error.localizedDescription))
            }
        }
    }

    /// Connected providers in the user's chosen display order.
    var connectedProviders: [ProviderID] {
        preferences.providerOrder.filter { provider in connections.contains { $0.provider == provider && $0.isConnected } }
    }

    func isShownInMenuBar(_ provider: ProviderID) -> Bool {
        connectedProviders.contains(provider) && preferences.menuBarProviders.contains(provider)
    }

    func canToggleMenuBar(_ provider: ProviderID) -> Bool {
        let shownCount = connectedProviders.filter(preferences.menuBarProviders.contains).count
        return isShownInMenuBar(provider) ? shownCount > 1 : connectedProviders.contains(provider) && shownCount < 3
    }

    func setMenuBarProvider(_ provider: ProviderID, enabled: Bool) {
        var selection = preferences.menuBarProviders
        if enabled {
            guard connectedProviders.contains(provider), !selection.contains(provider),
                  selection.filter({ connectedProviders.contains($0) }).count < 3 else { return }
            if selection.count == 3 { selection.removeAll { !connectedProviders.contains($0) } }
            selection.append(provider)
        } else {
            guard selection.contains(provider), selection.filter({ connectedProviders.contains($0) }).count > 1 else { return }
            selection.removeAll { $0 == provider }
        }
        preferences.menuBarProviders = selection
    }

    func moveProvider(_ provider: ProviderID, to index: Int) {
        var order = preferences.providerOrder
        guard let source = order.firstIndex(of: provider) else { return }
        let destination = min(max(index, 0), order.count - 1)
        guard source != destination else { return }
        order.remove(at: source)
        order.insert(provider, at: destination)
        preferences.providerOrder = order
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

    private func runAntigravityAuthorization() async throws {
        let config = try AntigravityOAuthConfig.discover()
        let transaction = try PKCETransaction.generate()
        let server = try LoopbackOAuthServer(state: transaction.state)
        defer { server.cancel() }
        let redirectURI = try await server.start()
        try Task.checkCancellation()
        let authorizationURL = try OAuthAuthorizationConfiguration(
            authorizationEndpoint: ProviderEndpoints.Antigravity.authorization,
            clientID: config.clientID,
            redirectURI: redirectURI,
            scopes: ProviderEndpoints.Antigravity.scopes,
            additionalParameters: ["access_type": "offline", "prompt": "consent select_account"]
        ).authorizationURL(for: transaction)
        authorization = AuthorizationPresentation(provider: .antigravity, phase: .antigravityBrowser)
        guard NSWorkspace.shared.open(authorizationURL) else { throw AuthorizationError.invalidAuthorizationURL }
        let callback = try await server.callback()
        try Task.checkCancellation()
        try callback.validate(expectedState: transaction.state)
        authorization = AuthorizationPresentation(provider: .antigravity, phase: .exchanging)
        let exchanged = try await OAuthTokenClient().exchangeCode(
            endpoint: ProviderEndpoints.Antigravity.token,
            clientID: config.clientID,
            code: callback.code,
            verifier: transaction.verifier,
            redirectURI: redirectURI,
            additionalFields: ["client_secret": config.clientSecret]
        )
        let credential = OAuthCredential(
            accessToken: exchanged.accessToken,
            refreshToken: exchanged.refreshToken,
            expiresAt: exchanged.expiresAt,
            tokenType: exchanged.tokenType,
            scopes: exchanged.scopes,
            idToken: exchanged.idToken,
            accountID: exchanged.accountID,
            clientID: config.clientID,
            clientSecret: config.clientSecret
        )
        try Task.checkCancellation()
        try await finishConnection(credential, provider: .antigravity)
    }

    private func finishConnection(_ credential: OAuthCredential, provider: ProviderID) async throws {
        try await credentialStore.save(credential, for: provider)
        updateConnection(provider, connected: true)
        ensureMenuBarSelection()
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

    private func ensureMenuBarSelection() {
        guard !connectedProviders.isEmpty else { return }
        if !preferences.menuBarProviders.contains(where: connectedProviders.contains) {
            var selection = preferences.menuBarProviders
            if selection.count == 3 { selection.removeFirst() }
            selection.append(connectedProviders[0])
            preferences.menuBarProviders = selection
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
