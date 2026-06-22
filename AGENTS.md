# Glint — Agent Guidelines

## Build & Test

Glint uses **XcodeGen** to generate the Xcode project from `project.yml`.

```bash
# Regenerate the Xcode project after editing project.yml
xcodegen generate

# Build the app
xcodebuild -project Glint.xcodeproj -scheme Glint -destination 'platform=macOS' build

# Build for testing (compiles app + test bundle)
xcodebuild -project Glint.xcodeproj -scheme Glint -destination 'platform=macOS' build-for-testing

# Run tests
xcodebuild -project Glint.xcodeproj -scheme Glint -destination 'platform=macOS' test-without-building
```

Do **not** edit `Glint.xcodeproj/project.pbxproj` by hand. Change
`project.yml` and run `xcodegen generate` instead.

## Project Layout

```
Glint/
  Agent/        — CLI-agent hook installers, IPC bridge, pane state
  App/          — App entry point, safety settings
  Chrome/       — SwiftUI views (settings, sidebar, tabs, themes)
  Ghostty/      — Ghostty terminal surface integration
  Pane/         — Terminal pane management
  Resources/    — Info.plist, entitlements, assets, localisation
  Workspace/    — WorkspaceStore (central state), workspace model
GlintTests/     — XCTest unit tests
docs/           — Release docs, screenshots
project.yml     — XcodeGen spec (source of truth for the Xcode project)
```

## Agent Hook System

Glint installs lightweight hook entries into each supported CLI agent's
config so the agent reports lifecycle events (thinking, tool use,
permission requests, completion) back to Glint via a Unix domain socket.
This powers the sidebar status icons and completion badges.

### Supported agents and config locations

| Agent      | Config file                         | Installer enum           |
|------------|-------------------------------------|--------------------------|
| Claude Code | `~/.claude/settings.json`          | `AgentHookInstaller`     |
| Codex      | `~/.codex/hooks.json`               | `CodexHookInstaller`     |
| OpenCode   | `~/.config/opencode/plugins/` (JS)  | `OpenCodeHookInstaller`  |
| Devin CLI  | `~/.config/devin/config.json`       | `DevinHookInstaller`     |

All hook-based installers (Claude, Codex, Devin) live in
`Glint/Agent/AgentHookInstaller.swift`. OpenCode uses a plugin file
instead of JSON hooks.

### Hook format

Claude, Codex, and Devin use a Claude Code-compatible JSON hook format:

```json
{
  "hooks": {
    "<EventName>": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.glint/hooks/glint-report.sh <Event> <agent>" }
        ]
      }
    ]
  }
}
```

The `matcher` field must be `""` (empty string) to match all events.
Do **not** use `"*"` — it is an invalid regex in strict parsers (Devin
CLI / Rust) and will silently break hooks.

### Hook events per agent

Each agent supports a different subset of lifecycle events:

| Event             | Claude | Codex | Devin |
|-------------------|:------:|:-----:|:-----:|
| SessionStart      |   x    |   x   |   x   |
| SessionEnd        |        |       |   x   |
| UserPromptSubmit  |   x    |   x   |   x   |
| PreToolUse        |   x    |   x   |   x   |
| PostToolUse       |   x    |   x   |   x   |
| Notification      |   x    |       |       |
| PermissionRequest |   x    |   x   |   x   |
| PreCompact        |   x    |   x   |       |
| PostCompaction    |        |       |   x   |
| Stop              |   x    |   x   |   x   |
| StopFailure       |   x    |   x   |       |

When adding or removing events for an agent, the stale-event cleanup
in the merge functions (via `hooksStrippingStaleEntries`) automatically
purges Glint-owned entries for events no longer in the `hookEvents`
list. This means event-list changes propagate on the next app launch
without requiring users to uninstall/reinstall hooks.

### Install flow

1. **First launch**: `autoInstallAgentHooksOnFirstLaunch` prompts the
   user once per detected agent. Accepted agents are installed and
   marked in `UserDefaults`.
2. **Subsequent launches**: Already-installed agents are refreshed
   silently (`installIfNeeded`) so script-body and event-list updates
   propagate automatically.
3. **Settings UI**: Users can manually Install / Uninstall per agent
   in Settings -> Agents.

### Key invariants

- **Idempotent merges**: Running install twice produces the same config.
- **Non-destructive**: Only Glint-owned entries (identified by
  `glint-report.sh` in the command) are touched. User-authored hooks
  are preserved.
- **Stale cleanup**: Events removed from `hookEvents` are automatically
  cleaned from the config on the next merge pass.
- **Atomic writes**: Config files are written with `.atomic` and POSIX
  permissions are preserved.
- **JSONC limitation**: Devin supports JSON with comments, but
  `JSONSerialization` does not. If a config has comments, Glint backs
  it up and skips rather than corrupting it.
