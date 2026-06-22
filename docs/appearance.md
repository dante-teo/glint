# Appearance, Glass, and Contrast

Glint has three user-facing appearance modes:

- `Auto` follows the current macOS Light/Dark appearance.
- `Light` forces Glint chrome, AppKit window materials, and Ghostty colors to the paired light theme.
- `Dark` forces Glint chrome, AppKit window materials, and Ghostty colors to the paired dark theme.

The first-party paired themes are `glint-light` and `glint-dark`. Custom catalog themes, including `follow-ghostty`, remain available from the advanced theme browser and are preserved during migration.

## Runtime Behavior

Appearance changes resolve through `ThemeProvider.resolvedThemeID(themeID:mode:systemIsDark:)`. `WorkspaceStore` owns the persisted `glint.appearanceMode` and `glint.themeName` values, refreshes the active theme, and bumps `themeRevision` so SwiftUI chrome re-renders.

In Auto mode, a macOS appearance change should:

- recompute the active Glint theme,
- reload Ghostty configuration,
- refresh terminal backing views,
- update AppKit window appearance.

Glint's UI language is English-only. Unsupported stored language values are normalized to `system`, and Settings only offers `System` and `English`.

## Liquid Glass and Transparency

When glass is enabled, Glint uses floating glass islands for the top chrome and lets terminal content extend behind them. On macOS versions without native Liquid Glass, the fallback capsule must stay adaptive in both light and dark appearances.

Terminal translucency is controlled primarily by Ghostty's `background-opacity`. Host AppKit layers are only made transparent enough for Ghostty's opacity to reveal the desktop; they should not multiply the opacity aggressively. A slider move from `100%` to `99%` must remain visually subtle.

Chrome opacity and terminal opacity are separate settings. Full-screen macOS window behavior may reduce or disable desktop transparency, so verify windowed mode when testing glass refraction.

## Regression Checks

Run the XCTest suite with a fresh DerivedData path when touching appearance, theme, localization, or terminal backing behavior:

```bash
xcodebuild test -project Glint.xcodeproj -scheme Glint -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -derivedDataPath /private/tmp/glint-dd-appearance-check
```

Then run the static sweeps:

```bash
rg -n "[\\p{Han}]" Glint docs README.md README.en.md --glob '*.swift' --glob '*.xcstrings' --glob '*.md' --glob '*.html' --glob '!Resources/themes.json'
rg -n "previewTheme\\(id: store\\.themeName\\)|preferredColorScheme\\(\\.dark\\)|Theme\\.bgPane\\.opacity\\(0\\.6\\)|Semi-transparent theme-color scrim" Glint --glob '*.swift'
python3 -m json.tool Glint/Resources/Localizable.xcstrings >/tmp/glint-localizable-check.json
rg -n "darkAqua|Color\\.black|Color\\.white|NSColor\\(" Glint --glob '*.swift'
```

The first two `rg` commands should produce no matches. Inspect every hit from the final color sweep and keep only intentional adaptive/system appearance handling, shadows, dividers, or highlights.

Manual visual QA should cover Light, Dark, Auto-light, Auto-dark, glass on/off, terminal opacity at `1.0` and below `1.0`, Settings, command palette, theme browser, sidebar expanded/collapsed, and a split-pane terminal. Do not ship changes that introduce illegible text, stale dark materials in light mode, muddy glass, black-on-dark controls, white-on-light controls, or overlapping toolbar/sidebar content.
