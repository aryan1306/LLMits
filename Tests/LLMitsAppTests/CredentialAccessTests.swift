import Foundation
import LLMitsCore
import Security
import XCTest
@testable import LLMitsApp

@MainActor
final class CredentialAccessTests: XCTestCase {
    func testLaunchReadsOnlyConnectedProviders() async {
        let store = RecordingCredentialStore()
        let defaults = makeDefaults(connected: [.claude])
        let model = makeModel(defaults, store: store)
        defer { model.stop() }

        await model.start()

        let reads = await store.reads
        XCTAssertEqual(reads, [.claude])
    }

    func testFreshInstallNeverTouchesKeychain() async {
        let store = RecordingCredentialStore()
        let defaults = makeDefaults(connected: [])
        let model = makeModel(defaults, store: store)
        defer { model.stop() }

        await model.start()

        let reads = await store.reads
        XCTAssertTrue(reads.isEmpty)
    }

    func testMissingCredentialDisconnectsProvider() async {
        let store = RecordingCredentialStore()
        let defaults = makeDefaults(connected: [.claude])
        let model = makeModel(defaults, store: store)

        await model.refresh()

        XCTAssertTrue(model.connectedProviders.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testDeniedKeychainAccessIsNotRetriedUntilManualRefresh() async {
        let store = RecordingCredentialStore(error: CredentialStoreError.keychain(errSecUserCanceled))
        let defaults = makeDefaults(connected: [.claude])
        let model = makeModel(defaults, store: store)

        await model.refresh()
        await model.refresh()
        var reads = await store.reads
        XCTAssertEqual(reads, [.claude])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.connectedProviders, [.claude])

        await model.manualRefresh()
        reads = await store.reads
        XCTAssertEqual(reads, [.claude, .claude])
    }

    func testAntigravityConnectsThroughCLIWithoutCredentialStore() async throws {
        let store = RecordingCredentialStore()
        let defaults = makeDefaults(connected: [])
        let model = makeModel(defaults, store: store)

        model.connect(.antigravity)
        try await waitUntil { model.authorization == nil }

        XCTAssertEqual(model.connectedProviders, [.antigravity])
        XCTAssertEqual(model.connections.first { $0.provider == .antigravity }?.source, .cli)
        XCTAssertEqual(model.connectedSnapshots.map(\.provider), [.antigravity])
        let reads = await store.reads
        XCTAssertTrue(reads.isEmpty)
    }

    func testAntigravityCLIFailureKeepsProviderDisconnected() async throws {
        let defaults = makeDefaults(connected: [])
        let model = makeModel(defaults, antigravity: StubUsageProvider(error: AntigravityCLIError.signInRequired))

        model.connect(.antigravity)
        try await waitUntil { model.authorization?.phase != .antigravityCLI && model.authorization?.phase != .starting }

        XCTAssertEqual(model.authorization?.phase, .failed(AntigravityCLIError.signInRequired.localizedDescription))
        XCTAssertTrue(model.connectedProviders.isEmpty)
    }

    func testSavedGoogleSignInCarriesOverToCLI() throws {
        let defaults = makeDefaults(connected: [.antigravity])
        let model = makeModel(defaults)

        let connection = try XCTUnwrap(model.connections.first { $0.provider == .antigravity })
        XCTAssertTrue(connection.isConnected)
        XCTAssertEqual(connection.source, .cli)
    }

    private func makeModel(
        _ defaults: TemporaryDefaults,
        store: RecordingCredentialStore = RecordingCredentialStore(),
        antigravity: StubUsageProvider = StubUsageProvider()
    ) -> AppModel {
        AppModel(defaults: defaults.value, snapshotStore: InMemorySnapshotStore(), credentialStore: store, antigravityProvider: antigravity)
    }

    private func makeDefaults(connected: [ProviderID]) -> TemporaryDefaults {
        let defaults = TemporaryDefaults()
        let connections = ProviderID.allCases.map {
            ProviderConnection(provider: $0, source: .llmits, isConnected: connected.contains($0))
        }
        defaults.value.set(try? JSONEncoder().encode(connections), forKey: "connections")
        addTeardownBlock { defaults.remove() }
        return defaults
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }
}

private final class TemporaryDefaults: @unchecked Sendable {
    let suite = "LLMitsCredentialAccessTests-\(UUID().uuidString)"
    let value: UserDefaults

    init() { value = UserDefaults(suiteName: suite)! }
    func remove() { value.removePersistentDomain(forName: suite) }
}

private actor RecordingCredentialStore: CredentialStoring {
    private(set) var reads: [ProviderID] = []
    private let error: Error?

    init(error: Error? = nil) { self.error = error }

    func credential(for provider: ProviderID) throws -> OAuthCredential? {
        reads.append(provider)
        if let error { throw error }
        return nil
    }

    func save(_ credential: OAuthCredential, for provider: ProviderID) {}
    func deleteCredential(for provider: ProviderID) {}
}

private struct StubUsageProvider: UsageProviding {
    let id: ProviderID = .antigravity
    var error: Error?

    func fetchUsage() async throws -> UsageSnapshot {
        if let error { throw error }
        return UsageSnapshot(
            provider: .antigravity,
            plan: "Pro",
            windows: [QuotaWindow(id: "gemini-five-hour", label: "Gemini five-hour quota", utilization: 0.2, resetsAt: nil)],
            fetchedAt: Date()
        )
    }
}
