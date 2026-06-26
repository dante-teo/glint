# Repository Guidelines

## Project Structure & Module Organization

Glint is a macOS app built with SwiftUI, AppKit, and GhosttyKit. Application code lives under `Glint/`, grouped by feature: `App/` for app lifecycle and update wiring, `Chrome/` for shell UI, `Pane/` for terminal surfaces, `Agent/` for agent integration, `Workspace/` for persistence and workspace state, and `Ghostty/` for GhosttyKit management. Resources are in `Glint/Resources/`, including asset catalogs, entitlements, localization, themes, and `Info.plist`. Unit tests live in `GlintTests/`. Release and asset automation lives in `scripts/`; documentation and the static site live in `docs/`. `project.yml` is the XcodeGen source for the checked-in `Glint.xcodeproj`.

## Build, Test, and Development Commands

- `git submodule update --init --recursive`: fetch the `ghostty` submodule required by GhosttyKit setup.
- `scripts/setup-ghosttykit.sh`: download and verify the matching prebuilt `Vendor/GhosttyKit.xcframework`.
- `xcodegen generate`: regenerate `Glint.xcodeproj` after changing `project.yml` **or adding/removing source files**. XcodeGen resolves glob patterns at generation time, so new `.swift` files won't appear in the Xcode project until you regenerate.
- `xcodebuild test -project Glint.xcodeproj -scheme Glint -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO`: build and run the XCTest suite locally.
- `open Glint.xcodeproj`: open the app in Xcode for interactive development.

## Coding Style & Naming Conventions

Use Swift 5.10 conventions with 4-space indentation and clear feature-local organization. Prefer small pure helpers for domain logic, immutable values where practical, and SwiftUI views composed from focused private subviews. Name test files after the behavior under test, such as `AgentKindResolutionTests.swift`, and use direct test method names like `testUnknownReturnsNil`. Keep resources named by product or agent state, for example `CodexWorking.dataset`.

## Testing Guidelines

Tests use XCTest in the `GlintTests` target. Follow red, green, refactor: add or update a focused failing test before implementation changes. Keep tests independent and deterministic; use `@MainActor` for UI or workspace state code that requires it. Run the full `xcodebuild test` command before declaring a change complete.

To unit-test `WorkspaceStore` operations (tabs, splits, pane state), create a `WorkspaceStore()` and override `workspaces` and `selectedWorkspaceID` with test data. The init loads persisted state, but overwriting those two properties replaces it entirely. There are no live surface views in tests, so `focusedPaneLiveCwd()` falls back to the model — this is expected. See `CwdInheritanceTests.swift` for the canonical pattern.

Only apply `@MainActor` to test classes that actually require it (i.e. those calling `@MainActor`-isolated code like `WorkspaceStore` methods). Tests for non-isolated types such as `SleepAssertionManager` should remain unannotated. If a test file would need `@MainActor` for only some tests, split them into separate files — each named after the behavior it covers.

`DevinHookInstallerTests.testIsInstalledReturnsFalseByDefault` fails on machines that already have Devin hooks installed. This is a known environment-dependent failure — it does not indicate a regression.

### Reacting to agent state changes

`paneAgentState` on `WorkspaceStore` is a `@Published` dictionary mutated from ~18 sites (subscript writes, `removeValue`, bulk `filter` reassignment). All mutations trigger its `didSet` hook. To add a new side effect driven by agent state (as `updateSleepAssertion()` does), add a call in the `didSet` — do not scatter calls across individual mutation sites, which is fragile and easy to miss. IOKit is already linked in `project.yml`.

## Commit & Pull Request Guidelines

Commit history uses concise Conventional Commit-style prefixes, including `fix(agent): ...`, `feat(agent): ...`, `chore: ...`, `ci: ...`, and `release: ...`. Keep commits scoped to one change. Pull requests should include a short summary, tests run, linked issues when relevant, and screenshots or recordings for visible UI changes.

## Security & Configuration Tips

Do not commit signing secrets, Sparkle private keys, notarization credentials, or generated `.secrets/` material. Release setup is documented in `docs/releasing.md`; keep signing and appcast changes isolated from feature work.
