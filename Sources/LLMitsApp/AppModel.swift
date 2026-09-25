import AppKit
import Combine
import Foundation
import LLMitsCore

enum AuthorizationPhase: Equatable {
    case starting
    case claudeCallback
    case codexCode(String)
    case antigravityCLI
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
    /// Failures that need the user (agy sign-in, a denied Keychain prompt). Polling skips these providers
    /// so it doesn't re-run agy or re-prompt; a manual refresh or reconnect retries them.
    private var blockedRefreshErrors: [ProviderID: String] = [:]
    private var pollingTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var claudeTransaction: PKCETransaction?

    init(
        defaults: UserDefaults = .standard,
        snapshotStore: (any SnapshotPersisting)? = nil,
        credentialStore: (any CredentialStoring)? = nil,
        antigravityProvider: (any UsageProviding)? = nil
    ) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMits", isDirectory: true)
        self.snapshotStore = snapshotStore ?? FileSnapshotStore(fileURL: support.appendingPathComponent("latest-usage.json"))
        let credentials = credentialStore ?? KeychainCredentialStore()
        self.credentialStore = credentials
        providers = [
            .claude: RefreshingUsageProvider(id: .claude, credentials: credentials),
            .codex: RefreshingUsageProvider(id: .codex, credentials: credentials),
            .antigravity: antigravityProvider ?? AntigravityCLIUsageProvider(),
        ]
        preferences = Self.decode(AppPreferences.self, key: "preferences", defaults: defaults) ?? AppPreferences()
        let savedConnections = Self.decode([ProviderConnection].self, key: "connections", defaults: defaults) ?? []
        connections = ProviderID.allCases.map { provider in
            var connection = savedConnections.first(where: { $0.provider == provider }) ?? ProviderConnection(provider: provider)
            // Antigravity is read only through the agy CLI; earlier Google sign-ins carry over to it.
            if provider == .antigravity { connection.source = .cli }
            return connection
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

    /// Launch trusts the saved connection list instead of probing the Keychain, so a new user sees no
    /// access prompts until they connect a provider.
    func start() async {
        snapshots = (try? await snapshotStore.load()) ?? []
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
        blockedRefreshErrors.removeAll()
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
            if let blocked = blockedRefreshErrors[connection.provider] {
                failures.append("\(connection.provider.displayName): \(blocked)")
                continue
            }
            guard let provider = providers[connection.provider] else { continue }
            do {
                let snapshot = try await provider.fetchUsage()
                updated.removeAll { $0.provider == snapshot.provider }
                updated.append(snapshot)
            } catch ProviderError.notConnected {
                // The saved connection outlived its credential, e.g. the Keychain item was removed.
                updateConnection(connection.provider, connected: false)
                updated.removeAll { $0.provider == connection.provider }
            } catch {
                if error is AntigravityCLIError || error is CredentialStoreError {
                    blockedRefreshErrors[connection.provider] = error.localizedDescription
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
                case .antigravity: try await self.connectAntigravityCLI()
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
                if provider != .antigravity { try await credentialStore.deleteCredential(for: provider) }
                updateConnection(provider, connected: false)
                blockedRefreshErrors[provider] = nil
                snapshots.removeAll { $0.provider == provider }
                ensureMenuBarSelection()
                onStatusChange?()
            } catch {
                errorMessage = error.localizedDescription
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

    /// Verifies the agy login by running its quota report; LLMits never reads agy's credentials itself.
    private func connectAntigravityCLI() async throws {
        authorization = AuthorizationPresentation(provider: .antigravity, phase: .antigravityCLI)
        guard let provider = providers[.antigravity] else { return }
        let snapshot = try await provider.fetchUsage()
        try Task.checkCancellation()
        blockedRefreshErrors[.antigravity] = nil
        snapshots.removeAll { $0.provider == .antigravity }
        snapshots.append(snapshot)
        snapshots.sort { $0.provider.rawValue < $1.provider.rawValue }
        try? await snapshotStore.save(snapshots)
        updateConnection(.antigravity, connected: true, source: .cli)
        ensureMenuBarSelection()
        authorization = nil
        onStatusChange?()
    }

    private func finishConnection(_ credential: OAuthCredential, provider: ProviderID) async throws {
        try await credentialStore.save(credential, for: provider)
        blockedRefreshErrors[provider] = nil
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
