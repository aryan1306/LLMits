import AppKit
import Combine
import Foundation
import LLMitsCore

@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isInstalling = false
    @Published private(set) var errorMessage: String?

    private let checker = GitHubUpdateChecker()
    private var pollingTask: Task<Void, Never>?

    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                try? await Task.sleep(nanoseconds: 6 * 60 * 60 * 1_000_000_000)
            }
        }
    }

    func checkForUpdates() async {
        guard !isInstalling,
              let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        do {
            availableUpdate = try await checker.availableUpdate(currentVersion: version)
        } catch {
            // A temporary network or GitHub failure should not interrupt quota usage.
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
    }
}
