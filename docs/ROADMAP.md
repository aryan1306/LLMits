# MVP roadmap

## Implemented foundation

- Menu-bar lifecycle and native popover/Settings shell
- Quota domain model, local cache, display conversion, and formatting
- Replaceable provider/persistence protocols
- Preview adapters and initial unit tests
- Device-local Keychain credential store behind a testable protocol
- OAuth PKCE generation, authorization URL construction, callback parsing, and state validation
- Codex-compatible device authorization state machine, including slow-down and expiry handling
- Automatic polling, refresh after wake, stale-card presentation, and reusable bounded backoff policy
- Concrete Claude/Codex token and quota endpoints, authenticated request adapters, and schema-tolerant quota parsers
- Settings-driven Claude PKCE and Codex device-code login, Keychain persistence, token refresh, disconnect, and live quota refresh

## Next vertical slices

1. Expand sanitized provider fixtures as schemas evolve; schema-tolerant parsers, token refresh requests, and revoked-session HTTP handling are implemented.
2. Apply server-directed/exponential backoff to live provider refresh failures (scheduler, wake handling, policy, and stale presentation are implemented).
3. CLI credential discovery and explicit source-switch flows.
4. Launch at Login, GitHub release checks, diagnostics UI, and update indicator.
5. Branded monochrome assets after trademark/brand review.
6. Universal app bundling, unsigned DMG production, and clean-machine CI verification.

Accessibility (VoiceOver labels, keyboard navigation, contrast, and reduced motion) is treated as a baseline requirement pending the product decision.
