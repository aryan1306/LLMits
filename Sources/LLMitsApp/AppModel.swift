import AppKit
import Combine
import Foundation
import LLMitsCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshots: [UsageSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
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
    private let providers: [ProviderID: any UsageProviding]
    private var lastManualRefresh: Date?
    private var pollingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMits", isDirectory: true)
        snapshotStore = FileSnapshotStore(fileURL: support.appendingPathComponent("latest-usage.json"))
        providers = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, PreviewUsageProvider(id: $0)) })
        preferences = Self.decode(AppPreferences.self, key: "preferences", defaults: defaults) ?? AppPreferences()
        connections = Self.decode([ProviderConnection].self, key: "connections", defaults: defaults)
            ?? ProviderID.allCases.map { ProviderConnection(provider: $0) }
    }

    var statusTitle: String {
        let items = connectedSnapshots.compactMap { snapshot -> String? in
            guard let window = snapshot.statusWindow else { return nil }
            let mark = snapshot.provider == .claude ? "C" : "O"
            return "\(mark) \(window.percentage(for: preferences.displayMode))%"
        }
        return items.isEmpty ? "LLMits" : items.joined(separator: "  ")
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

    func setConnected(_ connected: Bool, provider: ProviderID) {
        guard let index = connections.firstIndex(where: { $0.provider == provider }) else { return }
        connections[index].isConnected = connected
        if connected { Task { await refresh() } }
        if !connected {
            snapshots.removeAll { $0.provider == provider }
            onStatusChange?()
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
        pollingTask = nil
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
