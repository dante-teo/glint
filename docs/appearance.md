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

## Typography

Glint bundles its app fonts in `Glint/Resources/Fonts/` and registers them process-locally during `GlintApp.init()`, before `WorkspaceStore` can build Ghostty configuration or SwiftUI renders app chrome.

- UI chrome uses Barlow through the helpers in `AppFonts.swift`.
- New terminal defaults use `DepartureMono Nerd Font`.
- Ghostty configuration keeps `Menlo` as the second `font-family` fallback, so missing or failed bundled font registration still leaves a usable terminal.
- Existing users keep their stored `glint.terminalFontFamily` value. Only missing-user-default and fresh-install states resolve to the bundled terminal default.
- Monospaced UI labels, shortcuts, counters, and terminal-like readouts intentionally keep system monospaced fonts. Ghostty terminal rendering is controlled only by Ghostty configuration.

When adding, removing, or renaming bundled fonts, update `AppFonts.swift`, `GlintTests/FontDefaultsTests.swift`, regenerate the Xcode project with `xcodegen generate`, and keep third-party attribution current in `Glint/Resources/Fonts/THIRD_PARTY_FONT_LICENSES.md`.

## Liquid Glass and Transparency

When glass is enabled, Glint uses floating glass islands for the top chrome and lets terminal content extend behind them. On macOS versions without native Liquid Glass, the fallback capsule must stay adaptive in both light and dark appearances.

Terminal translucency is controlled primarily by Ghostty's `background-opacity`. Host AppKit layers are only made transparent enough for Ghostty's opacity to reveal the desktop; they should not multiply the opacity aggressively. A slider move from `100%` to `99%` must remain visually subtle.

Chrome opacity and terminal opacity are separate settings. Full-screen macOS window behavior may reduce or disable desktop transparency, so verify windowed mode when testing glass refraction.

The optional `Liquid Glass split windows` setting is a visual treatment for split-pane tabs only. It is persisted as `glint.framedSplits`, but it is active only when global glass is enabled and the current tab has at least two panes. Single-pane tabs must remain full-bleed with the same terminal backing and no extra gutters, even if the preference is on.

When split windows are active, the outer pane area should keep the same background treatment as an unsplit terminal, while each split leaf becomes its own rounded glass shell. The Ghostty surface inside those shells is made clear through the derived runtime flag `glint.activeFramedSplitMode`, so the mini-window glass/fallback must sit behind the terminal surface. Keep that runtime key out of settings recovery or user-facing preference flows; it is derived from the current tab layout, not an independent setting.

The pane glass shell should use the shared `liquidGlass` helper so macOS 26 gets system Liquid Glass and older macOS versions keep the app's adaptive `VisualEffectBackground` fallback. Avoid adding opaque fills inside the pane frame; borders, highlights, shadows, and close controls should be the only chrome over the clear terminal surface.

## App Icon Packaging

The shipping bundle icon comes from `Glint/Resources/Assets.xcassets/AppIcon.appiconset`. Keep it as a complete conventional macOS app icon set with 16, 32, 128, 256, 512, and 1024 px representations so Launch Services, Spotlight, Launchpad, Finder, and release packaging can read `AppIcon.icns` without depending on runtime Dock overrides.

Private app-icon source photographs, model inputs, intermediate artwork, and Liquid Glass `.icon` packages are deliberately excluded from this repository. `AppIconSource/` is ignored by Git. Do not add private reference imagery to the project or to release artifacts.

`project.yml` must keep both `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` and `ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR: all`. After app icon resource changes, regenerate `Glint.xcodeproj` with `xcodegen generate` and run `GlintTests/AppIconAssetTests.swift`.

### Selectable Portrait App Icons

The approved distributable assets are the source of truth. The default bundle icon remains `AppIcon.appiconset`; the selectable presets live beside it as `AppIconPreset-<rawValue>.imageset/icon.png` at 1024 px and matching `GlintLogo-<rawValue>.imageset/icon.png` at 256 px for Settings and header previews.

Preset raw values are part of the `AppIconPreset` persistence and asset-naming contract. The Original portrait uses theme names directly (`sunrise`, `classic`, and `jade`); extra portraits use their bare name for Sunrise (`bun` or `pout`) and `<portrait>-<theme>` for every other palette (`longhair-ultraviolet` or `breeze-graphite`).

When replacing an approved portrait render, preserve its visual likeness and update every asset in the affected family:

1. Replace the 1024 px `AppIconPreset-<rawValue>.imageset/icon.png` for each color theme.
2. Generate the matching 256 px `GlintLogo-<rawValue>.imageset/icon.png` files.
3. For the default/Sunrise icon, regenerate every representation in `AppIcon.appiconset` from the same 1024 px source.
4. Keep the existing `Contents.json` metadata and raw-value naming contract intact.
5. Compile the asset catalog and run the XCTest suite before committing.

`scripts/generate_portrait_app_icons.py` is an internal design tool that expects private local source artwork in the ignored `AppIconSource/` directory. It is not runnable from a clean checkout, by design. Never commit its source photographs, model inputs, or intermediate design files.

## Regression Checks

Run the XCTest suite with a fresh DerivedData path when touching appearance, theme, typography, localization, or terminal backing behavior:

```bash
xcodebuild test -project Glint.xcodeproj -scheme Glint -configuration Debug -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -derivedDataPath /private/tmp/glint-dd-appearance-check
```

Then run the static sweeps:

```bash
rg -n "[\\p{Han}]" Glint docs README.md --glob '*.swift' --glob '*.xcstrings' --glob '*.md' --glob '*.html' --glob '!Resources/themes.json'
rg -n "previewTheme\\(id: store\\.themeName\\)|preferredColorScheme\\(\\.dark\\)|Theme\\.bgPane\\.opacity\\(0\\.6\\)|Semi-transparent theme-color scrim" Glint --glob '*.swift'
python3 -m json.tool Glint/Resources/Localizable.xcstrings >/tmp/glint-localizable-check.json
rg -n "darkAqua|Color\\.black|Color\\.white|NSColor\\(" Glint --glob '*.swift'
```

The first two `rg` commands should produce no matches. Inspect every hit from the final color sweep and keep only intentional adaptive/system appearance handling, shadows, dividers, or highlights.

Manual visual QA should cover Light, Dark, Auto-light, Auto-dark, glass on/off, terminal opacity at `1.0` and below `1.0`, Settings, command palette, theme browser, sidebar expanded/collapsed, and split-pane terminals. For `Liquid Glass split windows`, verify option off with splits, option on with a single pane, option on with horizontal/vertical/nested splits, split resizing, pane close buttons under the floating toolbar area, and switching between split and non-split tabs. Do not ship changes that introduce illegible text, stale dark materials in light mode, muddy glass, black-on-dark controls, white-on-light controls, or overlapping toolbar/sidebar content.
