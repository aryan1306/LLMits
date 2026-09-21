# Architecture

The code is split into a provider-neutral `LLMitsCore` library and a macOS `LLMitsApp` executable. This keeps undocumented provider schemas and authentication flows out of views.

## Boundaries

- **Domain:** `UsageSnapshot`, `QuotaWindow`, connection, credential-source, and display preferences.
- **Provider adapters:** `UsageProviding` is the replaceable boundary for Claude and Codex quota fetching.
- **Persistence:** `SnapshotPersisting` stores only the latest non-sensitive snapshot. Credential persistence will use a separate Keychain protocol.
- **Presentation:** `AppModel` owns UI state; SwiftUI renders the popover and Settings; AppKit owns the status item and lifecycle.

One active connection per provider is enforced by the `ProviderConnection` collection in v1, while provider identity remains explicit for eventual multi-account support.

## Security invariants

- Never persist access tokens in `UserDefaults` or usage snapshots.
- Never log raw authenticated responses, authorization codes, identity, or account IDs.
- CLI credentials are read in place and never deleted by LLMits.
- App-owned credentials are isolated by provider and deleted on disconnect.
- Diagnostics are built from an explicit allowlist.
