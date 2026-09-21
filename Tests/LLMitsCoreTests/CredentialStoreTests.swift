import XCTest
@testable import LLMitsCore

final class CredentialStoreTests: XCTestCase {
    func testInMemoryStoreKeepsProvidersIsolatedAndDeletesExplicitly() async throws {
        let store = InMemoryCredentialStore()
        let claude = OAuthCredential(accessToken: "claude-access", refreshToken: "claude-refresh")
        let codex = OAuthCredential(accessToken: "codex-access")
        await store.save(claude, for: .claude)
        await store.save(codex, for: .codex)
        let storedClaude = await store.credential(for: .claude)
        let storedCodex = await store.credential(for: .codex)
        XCTAssertEqual(storedClaude, claude)
        XCTAssertEqual(storedCodex, codex)

        await store.deleteCredential(for: .claude)
        let deletedClaude = await store.credential(for: .claude)
        let retainedCodex = await store.credential(for: .codex)
        XCTAssertNil(deletedClaude)
        XCTAssertEqual(retainedCodex, codex)
    }
}
