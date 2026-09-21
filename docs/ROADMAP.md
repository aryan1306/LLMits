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

## Next vertical slices

1. Wire Claude's PKCE primitives to verified client configuration, browser launch, token exchange, and the callback-code Settings flow.
2. Wire the Codex device authorization state machine to verified device/token endpoints and Settings polling UI.
3. Expand sanitized provider fixtures as schemas evolve; schema-tolerant parsers, token refresh requests, and revoked-session HTTP handling are implemented.
4. Apply server-directed/exponential backoff to live provider refresh failures (scheduler, wake handling, policy, and stale presentation are implemented).
5. CLI credential discovery and explicit source-switch flows.
6. Launch at Login, GitHub release checks, diagnostics UI, and update indicator.
7. Branded monochrome assets after trademark/brand review.
8. Universal app bundling, unsigned DMG production, and clean-machine CI verification.

Accessibility (VoiceOver labels, keyboard navigation, contrast, and reduced motion) is treated as a baseline requirement pending the product decision.
