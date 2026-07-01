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

### Pane dim overlay and IOSurface compositing

The unfocused-pane dim wash (`Color.black` in `PaneView.paneBody`) must be **always present** in the ZStack with its opacity toggled (0 when focused, 0.18/0.28 when unfocused). Do NOT convert it to a conditional `if !isFocused { ... }` — that causes the SwiftUI layer to be inserted *after* the `GhosttySurfaceView`'s IOSurface-backed Metal layer is already composited, and the overlay ends up behind the surface (invisible). Keeping the overlay in the initial render guarantees correct Core Animation z-ordering. This applies to any SwiftUI overlay placed above an `NSViewRepresentable` with a GPU-backed layer in a ZStack.

### Split pane focus click propagation

`GhosttySurfaceView` (an NSView) handles `mouseDown` before SwiftUI's gesture system sees the event, so the `.onTapGesture { store.focus(paneID) }` on `PaneView`'s ZStack does NOT fire for clicks on the terminal surface. To propagate focus changes from clicks back to the store, `mouseDown` posts a `glintPaneFocusClicked` notification (same pattern as Esc/Return) with the pane key. The store observes this notification **synchronously** (`queue: nil` + `MainActor.assumeIsolated`) so that `focusedPane` updates before the next `updateNSView` pass can fight back and resign the first responder. Do NOT rely on `.onTapGesture` alone for focus — it only fires for clicks on SwiftUI-rendered areas, not on NSViewRepresentable content.

### Reacting to agent state changes

`paneAgentState` on `WorkspaceStore` is a `@Published` dictionary mutated from ~18 sites (subscript writes, `removeValue`, bulk `filter` reassignment). All mutations trigger its `didSet` hook. To add a new side effect driven by agent state (as `updateSleepAssertion()` does), add a call in the `didSet` — do not scatter calls across individual mutation sites, which is fragile and easy to miss. IOKit is already linked in `project.yml`.

### Agent workspace domain model

`WorkspaceKind` (`.terminal` | `.agent`) and `AgentProvider` (`.devin`) distinguish terminal from agent workspaces. Agent workspaces carry extra fields on `Workspace`: `kind`, `agentProvider`, `committed`, `agentProjectPath`, `agentSessionID`. All default to terminal-safe values (`.terminal`, `nil`, `true`, `nil`, `nil`) so old `state.json` files decode unchanged via `decodeIfPresent`. The encoder omits default values — terminal workspaces produce no extra JSON keys.

**Committed vs uncommitted:** Agent workspaces start `committed = false` (hidden from sidebar, stripped from `persist()`). Calling `commitAgentWorkspace(_:)` after the user sends their first message sets `committed = true`, making the workspace visible in `activeWorkspaces` and persistent across launches. Terminals are always committed.

**Auto-cleanup:** `selectWorkspace(_:)` silently removes the old workspace if it was uncommitted (user navigated away without sending a message). `addAgentWorkspace(provider:projectPath:)` also removes any prior uncommitted workspaces before creating a new one. Both paths currently do a bare array removal — side-state cleanup (surfaceViews, paneAgentState, etc.) will be added when the UI wiring lands in Phase 2+, since uncommitted workspaces cannot currently populate those dictionaries.

**Guards:** `splitFocused()` and `newTab()` beep and return for `.agent` workspaces (one session per workspace, v1). `liveIconKind(for:)` short-circuits to the provider's icon (`.devin`) for agent workspaces.

**Tests:** Store-dependent tests live in `WorkspaceKindTests.swift` (`@MainActor`). Pure Codable round-trip tests for the agent fields live in `WorkspaceAgentCodableTests.swift` (unannotated), following the `@MainActor` split convention documented above.

### App icon preset architecture

The Dock icon picker in Settings uses a two-level model: `PortraitStyle` (line art) x `IconColorTheme` (color palette) = `AppIconPreset` (the flat enum persisted to UserDefaults). The resolution helpers on `AppIconPreset` (`portraitStyle`, `colorTheme`, `preset(portrait:color:)`) map between the two representations.

**Naming asymmetry:** The original portrait uses bare color names as raw values (`sunrise`, `classic`, `aurora`, ...), while the other portraits use `<portrait>` for their sunrise/default variant and `<portrait>-<color>` for the rest (e.g. `bun`, `bun-classic`, `bun-aurora`). The `preset(portrait:color:)` resolver handles this branching. Do not assume a uniform `<portrait>-<color>` pattern for all presets.

**To add a new portrait style:** Add the base case and all color-variant cases to `AppIconPreset`, add a case to `PortraitStyle`, update the exhaustive switches in `portraitStyle` and `colorTheme`, add the corresponding `AppIconPreset-<name>` and `GlintLogo-<name>` image sets to `Assets.xcassets`, and run `xcodegen generate`. The compiler enforces exhaustive switches, so missing a case is a build error. The round-trip tests in `AppIconPresetGroupingTests` will catch any resolution/decomposition mismatch.

**To add a new color theme:** Add the themed cases for every portrait to `AppIconPreset`, add a case to `IconColorTheme` (including `swatchColor`), update the exhaustive switches, add image sets, and run `xcodegen generate`.

## Commit & Pull Request Guidelines

Commit history uses concise Conventional Commit-style prefixes, including `fix(agent): ...`, `feat(agent): ...`, `chore: ...`, `ci: ...`, and `release: ...`. Keep commits scoped to one change. Pull requests should include a short summary, tests run, linked issues when relevant, and screenshots or recordings for visible UI changes.

## Security & Configuration Tips

Do not commit signing secrets, Sparkle private keys, notarization credentials, or generated `.secrets/` material. Release setup is documented in `docs/releasing.md`; keep signing and appcast changes isolated from feature work.
