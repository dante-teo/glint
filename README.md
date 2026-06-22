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

Developer notes and regression checks live in [docs/appearance.md](docs/appearance.md).

## Upgrade & Uninstall

```bash
brew upgrade --cask glint
brew uninstall --cask glint
```

## License

MIT - see [LICENSE](LICENSE).
