import Foundation

public enum AntigravityCLIError: LocalizedError, Sendable, Equatable {
    case notInstalled
    case signInRequired
    case timedOut
    case invalidReport

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Antigravity CLI (agy) was not found. Install it or connect with Google in LLMits."
        case .signInRequired: "The Antigravity CLI needs sign-in. Run agy in Terminal, sign in, then refresh LLMits."
        case .timedOut: "Antigravity CLI quota check timed out. Try again after opening agy."
        case .invalidReport: "Antigravity CLI did not return quota data. Update agy and try again."
        }
    }
}

/// Uses agy's read-only quota command, which exposes the full Gemini and Claude/GPT pools.
public struct AntigravityCLIUsageProvider: UsageProviding {
    public let id: ProviderID = .antigravity
    private let executable: URL?
    private let now: @Sendable () -> Date

    public init(executable: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.executable = executable
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        guard let executable = executable ?? Self.findExecutable() else { throw AntigravityCLIError.notInstalled }
        let output = try await Task.detached(priority: .utility) { try Self.run(executable) }.value
        guard let snapshot = try? UsageResponseParser.parseAntigravity(output, fetchedAt: now()) else {
            throw AntigravityCLIError.invalidReport
        }
        return snapshot
    }

    private static func findExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            environment["ANTIGRAVITY_CLI_PATH"],
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ].compactMap { $0 }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private static func run(_ executable: URL) throws -> Data {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("llmits-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let collector = OutputCollector()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else if !collector.append(data) { process.terminate() }
        }
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        process.waitUntilExit()
        timeout.cancel()
        output.fileHandleForReading.readabilityHandler = nil
        _ = collector.append(output.fileHandleForReading.readDataToEndOfFile())
        if collector.overflowed { throw AntigravityCLIError.invalidReport }
        if process.terminationReason == .uncaughtSignal { throw AntigravityCLIError.timedOut }
        guard process.terminationStatus == 0 else { throw AntigravityCLIError.signInRequired }
        return collector.data
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var didOverflow = false

    var data: Data { lock.withLock { buffer } }
    var overflowed: Bool { lock.withLock { didOverflow } }

    @discardableResult
    func append(_ data: Data) -> Bool {
        lock.withLock {
            guard !didOverflow else { return false }
            guard buffer.count + data.count <= 1_048_576 else {
                didOverflow = true
                return false
            }
            buffer.append(data)
            return true
        }
    }
}
