<p align="center">
  <img src="docs/assets/llmits-terminal-graffiti.png" alt="LLMits" width="900">
</p>

LLMits is an open-source macOS menu-bar utility for viewing quota utilization from Claude and ChatGPT subscriptions. It targets macOS 14+ and keeps credentials and usage data local.

> [!IMPORTANT]
> LLMits uses provider OAuth and quota endpoints that are not public, supported APIs. Provider-side changes may temporarily break authentication or usage reporting.

## Features

- Live five-hour and weekly quota usage for Claude and ChatGPT
- Claude subscription plan detection, including Pro and Max tiers
- Native menu-bar percentages with Claude and ChatGPT icons
- Used or remaining percentage display modes
- Secure Claude PKCE and ChatGPT device-code sign-in flows
- Credentials stored in macOS Keychain
- Automatic token refresh, configurable polling, and refresh after wake
- Relative freshness labels, reset times, stale-data indicators, and manual refresh
- Local snapshot cache so the latest usage remains visible between launches
- No backend, analytics, telemetry, or account-identity data in cached snapshots

## Run locally

Requirements:

- macOS 14 or newer
- Xcode 16 or newer, including the command-line tools

Clone and run the project:

```sh
git clone https://github.com/aryan1306/LLMits.git
cd LLMits
swift test
swift run LLMits
```

LLMits runs as a menu-bar accessory without a Dock icon. Click its menu-bar item, open **Settings…**, then choose **Connect** beside Claude or ChatGPT:

- **Claude:** complete authorization in the browser, then paste the authorization code or full callback URL into LLMits.
- **ChatGPT:** enter the one-time code on the page opened by LLMits and wait for approval.

After connecting, the menu bar shows the configured used or remaining percentage. Open the popover for quota windows, reset times, plan details, and refresh status.

> [!NOTE]
> Running with `swift run` produces an ad-hoc-signed development executable. macOS may ask for Keychain access again after a rebuild because the executable identity changes. Choose **Always Allow** for the current build, or use a consistently signed app bundle for stable Keychain trust.

## How it works

- AppKit owns the status item and transient popover; SwiftUI renders the popover and settings UI.
- `LLMitsCore` contains provider-neutral quota models, OAuth flows, endpoint adapters, persistence, formatting, and refresh policy.
- Claude usage comes from the OAuth usage endpoint and is enriched with profile data for the plan label.
- ChatGPT usage comes from the Codex usage endpoint associated with the authorized account.
- Quota values are clamped and normalized before display, with a five-hour window preferred in the menu bar and weekly usage used as a fallback.

See [Architecture](docs/ARCHITECTURE.md) and [Roadmap](docs/ROADMAP.md).

## Development

Run the complete test suite:

```sh
swift test
```

Build without launching the app:

```sh
swift build
```

The test suite covers authorization primitives, credential storage, provider response parsing, quota calculations, persistence, diagnostics, and refresh policy.

## Privacy

LLMits has no backend, analytics, telemetry, or crash-reporting service. OAuth credentials are stored in macOS Keychain. Cached quota snapshots are written locally and contain neither credentials nor account identity.

## License

MIT
