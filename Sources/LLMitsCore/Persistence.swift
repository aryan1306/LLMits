import Foundation

public protocol SnapshotPersisting: Sendable {
    func load() async throws -> [UsageSnapshot]
    func save(_ snapshots: [UsageSnapshot]) async throws
}

public actor FileSnapshotStore: SnapshotPersisting {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> [UsageSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([UsageSnapshot].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ snapshots: [UsageSnapshot]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshots).write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

public struct InMemorySnapshotStore: SnapshotPersisting {
    private let loadHandler: @Sendable () -> [UsageSnapshot]
    private let saveHandler: @Sendable ([UsageSnapshot]) -> Void

    public init(
        load: @escaping @Sendable () -> [UsageSnapshot] = { [] },
        save: @escaping @Sendable ([UsageSnapshot]) -> Void = { _ in }
    ) {
        loadHandler = load
        saveHandler = save
    }

    public func load() async throws -> [UsageSnapshot] { loadHandler() }
    public func save(_ snapshots: [UsageSnapshot]) async throws { saveHandler(snapshots) }
}
