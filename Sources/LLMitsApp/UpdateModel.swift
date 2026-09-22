import AppKit
import Combine
import Foundation
import LLMitsCore

@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isInstalling = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checkErrorMessage: String?
    /// Set while manual checks are cooling down; cleared once another check is allowed.
    @Published private(set) var nextManualCheck: Date?

    /// Nil outside a packaged LLMits.app, where there is nothing to update.
    let currentVersion: String?
    private let checker: GitHubUpdateChecker
    private let now: () -> Date
    private var throttle: UpdateCheckThrottle
    private var pollingTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?

    init(
        currentVersion: String? = UpdateModel.packagedVersion,
        checker: GitHubUpdateChecker = GitHubUpdateChecker(),
        throttle: UpdateCheckThrottle = UpdateCheckThrottle(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.currentVersion = currentVersion
        self.checker = checker
        self.throttle = throttle
        self.now = now
    }

    var canCheck: Bool { currentVersion != nil }

    func start() {
        guard canCheck else { return }
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
            }
        }
    }

    /// Background check: stays quiet on failure so a network or GitHub hiccup never interrupts quota usage.
    func checkForUpdates() async {
        if let blockedUntil = throttle.blockedUntil, blockedUntil > now() { return }
        await performCheck(reportingErrors: false)
    }

    /// User-initiated check from Settings, limited to one per `throttle.minimumInterval`.
    func checkForUpdatesManually() async {
        let start = now()
        guard throttle.nextAllowedCheck(at: start) == nil else {
            // A background check may have hit GitHub's limit; explain why nothing happens.
            if let blockedUntil = throttle.blockedUntil, blockedUntil > start {
                checkErrorMessage = rateLimitMessage(until: blockedUntil)
            }
            scheduleCooldown()
            return
        }
        throttle.recordCheck(at: start)
        await performCheck(reportingErrors: true)
        scheduleCooldown()
    }

    private func performCheck(reportingErrors: Bool) async {
        guard !isInstalling, !isChecking, let currentVersion else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            availableUpdate = try await checker.availableUpdate(currentVersion: currentVersion)
            lastChecked = now()
            checkErrorMessage = nil
        } catch let UpdateCheckError.rateLimited(until) {
            throttle.recordRateLimit(until: until, now: now())
            if reportingErrors, let blockedUntil = throttle.blockedUntil {
                checkErrorMessage = rateLimitMessage(until: blockedUntil)
            }
        } catch {
            if reportingErrors { checkErrorMessage = error.localizedDescription }
        }
    }

    private func rateLimitMessage(until date: Date) -> String {
        "GitHub is limiting update checks. Try again in \(QuotaFormatting.countdown(until: date, now: now()))."
    }

    private func scheduleCooldown() {
        cooldownTask?.cancel()
        nextManualCheck = throttle.nextAllowedCheck(at: now())
        guard let nextManualCheck else { return }
        let delay = nextManualCheck.timeIntervalSince(now())
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.nextManualCheck = nil
        }
    }

    func installAvailableUpdate() {
        guard let availableUpdate, !isInstalling else { return }
        isInstalling = true
        errorMessage = nil
        Task {
            do {
                let prepared = try await UpdateInstaller.prepare(availableUpdate, currentApp: Bundle.main.bundleURL)
                try prepared.installAndRelaunch()
            } catch {
                errorMessage = error.localizedDescription
                isInstalling = false
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        cooldownTask?.cancel()
        cooldownTask = nil
    }

    nonisolated private static var packagedVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
