import XCTest
@testable import LLMitsCore

final class PersistenceTests: XCTestCase {
    func testFileStoreRoundTripsLatestSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
        let expected = [UsageSnapshot(
            provider: .codex,
            plan: "Plus",
            windows: [QuotaWindow(id: "weekly", label: "Weekly", utilization: 0.5, resetsAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]

        try await store.save(expected)
        let actual = try await store.load()
        XCTAssertEqual(actual, expected)
    }
}
