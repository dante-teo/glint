# Glint

A polished macOS terminal made for AI agents. SwiftUI + AppKit, with [Ghostty](https://ghostty.org) under the hood.

![Glint screenshot](docs/screenshot.png)

![Workspace state overview](docs/screenshot-sidebar.png)

## Install

### Homebrew (recommended)

```bash
brew tap dante-teo/tap
brew install --cask glint
```

### Manual Download

Grab the latest `Glint-x.y.z.dmg` from the [Releases](https://github.com/dante-teo/glint/releases) page, mount it, and drag `Glint.app` into `/Applications`.

If macOS refuses to open it with "developer cannot be verified", run once:

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
```

The Homebrew Cask does this automatically.

## Appearance

Glint supports Auto, Light, and Dark appearance modes. Auto follows macOS and keeps the app chrome and Ghostty terminal colors in sync. Liquid Glass chrome and terminal translucency are configurable from Settings.

Glint bundles Barlow for app UI and DepartureMono Nerd Font for new terminal defaults, so fresh installs do not depend on fonts installed in Font Book.

Developer notes and regression checks live in [docs/appearance.md](docs/appearance.md).

## App and Agent Icons

The app bundle icon is a conventional macOS `AppIcon.appiconset` under `Glint/Resources/Assets.xcassets`; selectable Dock icon presets are generated from the portrait sources in `AppIconSource/`. See [docs/appearance.md](docs/appearance.md#app-icon-packaging) before changing app icon resources.

Agent status icons are bundled in `Glint/Resources/Assets.xcassets`. Animated status assets are 128x128 transparent APNGs stored as `.png` files inside `.dataset` folders; compact marks are 24x24 and 48x48 rasters inside `.imageset` folders.

Managed ACP agent architecture notes live in [docs/agent-architecture.md](docs/agent-architecture.md). Read that before changing provider adapters, session state projection, permission handling, project file access, or conversation persistence.

Devin has two selectable icon families:

- `Devin*` / `DevinMark`: the default portrait family.
- `DevinPixel*` / `DevinPixelMark`: the optional pixel-monster family.

Regenerate the pixel-monster family with:

```bash
python3 scripts/generate_devin_pixel_monster_icons.py
```

The generator updates the asset catalog and writes a visual contact sheet to `design/devin-pixel-monster-icons/contact-sheet.png`. The pixel monster should remain a real character animation: body, face, limb, expression, or silhouette changes should carry each state, not decorative effects on a static logo.

## Upgrade & Uninstall

```bash
brew upgrade --cask glint
brew uninstall --cask glint
```

## License

MIT - see [LICENSE](LICENSE).
