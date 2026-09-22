# Repository Guidelines

## Project Structure & Module Organization

`Package.swift` defines a macOS 14+ Swift package with two targets. `Sources/LLMitsCore/` holds quota models, provider HTTP adapters, OAuth, Keychain storage, and refresh logic. `Sources/LLMitsApp/` contains the AppKit menu-bar lifecycle and SwiftUI popover/settings views; provider logos are in its `Resources/` directory. Core tests live in `Tests/LLMitsCoreTests/`. README artwork and screenshots are in `docs/assets/`; app icon and bundle metadata are in `packaging/`. Release scripts and GitHub Actions workflows are in `scripts/`, `install.sh`, and `.github/workflows/`.

## Build, Test, and Development Commands

- `swift build`: compile a development build.
- `swift test`: run the XCTest suite before submitting changes.
- `swift run LLMits`: launch the menu-bar app locally (it has no Dock icon).
- `./scripts/build-dmg.sh 1.0.1`: create a universal `.app`, DMG, and SHA-256 file under `dist/`.

Use Xcode 16+ and macOS 14+. Local `swift run` builds are ad-hoc signed, so macOS may ask for Keychain access after rebuilding.

## Coding Style & Naming Conventions

Use four-space indentation and follow the existing Swift style. Name types in `UpperCamelCase`, methods and properties in `lowerCamelCase`, and test methods `test<Behavior>`. Keep UI state in `AppModel`, views in `LLMitsApp`, and provider-specific parsing/network code in `LLMitsCore`. Prefer small, injectable protocols over direct network or Keychain calls in views. No dedicated formatter or linter is configured; keep diffs consistent with adjacent code and run `git diff --check`.

## Testing Guidelines

Use XCTest in `Tests/LLMitsCoreTests/`. Add focused tests for changed parsing, authorization, quota math, persistence, or refresh behavior; use stub transports and in-memory stores instead of live credentials or provider calls. Run `swift test` and, for packaging changes, build and verify the DMG locally.

## Commit & Pull Request Guidelines

Use conventional commits going forward. Keep commits scoped. PRs should describe user-visible behavior, list verification commands, link relevant issues, and include screenshots for UI changes. Do not commit secrets or real OAuth responses; provider endpoints are unofficial and may change.
