import Foundation
import LLMitsCore
import XCTest
@testable import LLMitsApp

@MainActor
final class MenuBarSelectionTests: XCTestCase {
    func testSelectionIsConnectedOnlyAndBounded() {
        let suite = "LLMitsMenuSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.preferences.menuBarProviders, [.claude, .codex])

        model.connections = ProviderID.allCases.map { ProviderConnection(provider: $0, isConnected: true) }
        model.setMenuBarProvider(.antigravity, enabled: true)
        XCTAssertEqual(model.preferences.menuBarProviders, [.claude, .codex, .antigravity])

        model.setMenuBarProvider(.claude, enabled: false)
        model.setMenuBarProvider(.codex, enabled: false)
        model.setMenuBarProvider(.antigravity, enabled: false)
        XCTAssertEqual(model.preferences.menuBarProviders, [.antigravity])
        XCTAssertFalse(model.canToggleMenuBar(.antigravity))
    }

    func testProviderOrderDrivesPopoverAndMenuBar() {
        let suite = "LLMitsMenuSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.connections = ProviderID.allCases.map { ProviderConnection(provider: $0, isConnected: true) }
        model.preferences.menuBarProviders = [.claude, .codex, .antigravity]
        XCTAssertEqual(model.connectedProviders, [.claude, .codex, .antigravity])

        model.moveProvider(.antigravity, to: 0)
        XCTAssertEqual(model.preferences.providerOrder, [.antigravity, .claude, .codex])
        XCTAssertEqual(model.connectedProviders, [.antigravity, .claude, .codex])

        model.moveProvider(.antigravity, to: 99)
        XCTAssertEqual(model.preferences.providerOrder, [.claude, .codex, .antigravity])

        model.connections[0].isConnected = false
        XCTAssertEqual(model.connectedProviders, [.codex, .antigravity])
        XCTAssertFalse(model.isShownInMenuBar(.claude))
    }

    func testDisconnectedDefaultDoesNotConsumeThirdSlot() {
        let suite = "LLMitsMenuSelectionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.connections = [.claude, .codex, .antigravity].map {
            ProviderConnection(provider: $0, isConnected: $0 == .antigravity)
        }
        model.setMenuBarProvider(.antigravity, enabled: true)
        XCTAssertTrue(model.preferences.menuBarProviders.contains(.antigravity))
        XCTAssertLessThanOrEqual(model.preferences.menuBarProviders.count, 3)
    }
}
