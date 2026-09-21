# LLMits

LLMits is an open-source macOS menu-bar utility for viewing quota utilization from Claude Code and Codex consumer subscriptions. It targets macOS 14+ and keeps credentials and usage data local.

> [!IMPORTANT]
> This repository is at the initial implementation milestone. The UI currently uses explicit preview connections. Real Claude/Codex authentication and quota adapters are not yet implemented because their client configuration and endpoints are unofficial and unstable.

## Run locally

Requirements: macOS 14+, Xcode 16+ with command-line tools.

```sh
swift test
swift run LLMits
```

The app runs as an accessory application (no Dock icon). Choose **Settings…** from its menu-bar popover and enable preview data for either provider.

## Current scope

- AppKit status item and popover hosting SwiftUI views
- Provider-neutral quota models with five-hour/weekly fallback
- Used/remaining display conversion and percentage clamping
- Local latest-snapshot cache (no history or identity)
- Explicit credential-source state
- Accessible status text and quota controls
- Test seams for provider adapters, persistence, and time

See [Architecture](docs/ARCHITECTURE.md) and [Roadmap](docs/ROADMAP.md).

## Privacy

LLMits has no backend, analytics, telemetry, or crash-reporting service. Production credentials will live in macOS Keychain or remain in their CLI-owned location. Cached quota snapshots contain neither credentials nor account identity.

## License

MIT
