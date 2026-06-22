import SwiftUI
import AppKit

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Auto"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct GlintTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool

    let background: Color
    let foreground: Color
    let cursor: Color
    let selectionBg: Color
    let selectionFg: Color
    let palette: [Color]

    var accentOverride: Color? = nil
    var chrome: ChromeOverrides? = nil
}

struct ChromeOverrides: Equatable {
    var accent: Color? = nil
    var bgWindow: Color? = nil
    var bgPane: Color? = nil
    var text1: Color? = nil
    var text2: Color? = nil
    var text3: Color? = nil
    var text4: Color? = nil
    var sidebarTintTop: Color? = nil
    var sidebarTintBottom: Color? = nil
    var toolbarTint: Color? = nil
    var glassTint: Color? = nil
    var divider: Color? = nil
    var border: Color? = nil
}

// MARK: - Derived chrome colors

extension GlintTheme {
    var accent: Color {
        accentOverride ?? chrome?.accent
            ?? (palette.indices.contains(4) ? palette[4] : foreground)
    }

    var bgWindow: Color { chrome?.bgWindow ?? (isDark ? background.darkened(0.30) : background.mixed(into: .black, 0.05)) }
    var bgPane:   Color { chrome?.bgPane   ?? background }

    var text1: Color { chrome?.text1 ?? foreground }
    var text2: Color { chrome?.text2 ?? foreground.mixed(into: background, 0.22) }
    var text3: Color { chrome?.text3 ?? foreground.mixed(into: background, 0.45) }
    var text4: Color { chrome?.text4 ?? foreground.mixed(into: background, 0.58) }

    var sidebarTintTop:    Color { chrome?.sidebarTintTop    ?? background.mixed(into: accent, 0.06).opacity(0.86) }
    var sidebarTintBottom: Color { chrome?.sidebarTintBottom ?? background.mixed(into: accent, 0.03).opacity(0.90) }
    var toolbarTint:       Color { chrome?.toolbarTint       ?? background.mixed(into: accent, 0.05).opacity(0.86) }
    var glassTint:         Color { chrome?.glassTint         ?? background.mixed(into: accent, 0.06).opacity(0.50) }

    var divider: Color { chrome?.divider ?? foreground.opacity(isDark ? 0.045 : 0.08) }
    var border:  Color { chrome?.border  ?? foreground.opacity(isDark ? 0.07  : 0.12) }
}

// MARK: - Built-in themes

extension GlintTheme {
    static let glintDark = GlintTheme(
        id: "glint-dark",
        name: "Glint Dark",
        isDark: true,
        background:  Color(red: 0.043, green: 0.039, blue: 0.078),   // #0B0A14(= applyGlintTheme background)
        foreground:  Color(red: 0.925, green: 0.929, blue: 0.949),   // #ECEDF2
        cursor:      Color(red: 0.549, green: 0.549, blue: 1.000),   // accentBright #8C8CFF
        selectionBg: Color(red: 0.549, green: 0.549, blue: 1.000),   // accentBright
        selectionFg: Color(red: 0.925, green: 0.929, blue: 0.949),   // #ECEDF2
        palette: GlintTheme.ghosttyDefaultPalette,
        accentOverride: Color(red: 0.549, green: 0.549, blue: 1.000),
        chrome: ChromeOverrides(
            bgWindow:          Color(red: 0.039, green: 0.043, blue: 0.063),            // #0A0B10
            bgPane:            Color(red: 0.043, green: 0.039, blue: 0.078),            // #0B0A14
            text1:             Color(red: 0.925, green: 0.929, blue: 0.949),            // #ECEDF2
            text2:             Color(red: 0.717, green: 0.725, blue: 0.784),            // #B7B9C8
            text3:             Color(red: 0.494, green: 0.510, blue: 0.565),            // #7E8290
            text4:             Color(red: 0.525, green: 0.545, blue: 0.635),
            sidebarTintTop:    Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.86),
            sidebarTintBottom: Color(red: 0.045, green: 0.038, blue: 0.085).opacity(0.90),
            toolbarTint:       Color(red: 0.060, green: 0.052, blue: 0.095).opacity(0.86),
            glassTint:         Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.50),
            divider:           Color.white.opacity(0.045),
            border:            Color.white.opacity(0.07)
        )
    )

    static let glintLight = GlintTheme(
        id: "glint-light",
        name: "Glint Light",
        isDark: false,
        background:  rgb(0xF7F8FB),
        foreground:  rgb(0x1E2330),
        cursor:      rgb(0x5E5CE6),
        selectionBg: rgb(0x5E5CE6),
        selectionFg: rgb(0xFFFFFF),
        palette: [
            rgb(0x1D2430), rgb(0xC73A45), rgb(0x248A3D), rgb(0xA66A00),
            rgb(0x246BCE), rgb(0x8B49C9), rgb(0x007A91), rgb(0xD5D9E2),
            rgb(0x697386), rgb(0xD94B55), rgb(0x2FA84F), rgb(0xB97900),
            rgb(0x3478F6), rgb(0x9B5DE5), rgb(0x009DB5), rgb(0xFFFFFF),
        ],
        accentOverride: rgb(0x5E5CE6),
        chrome: ChromeOverrides(
            bgWindow:          rgb(0xEEF1F7),
            bgPane:            rgb(0xF8F9FC),
            text1:             rgb(0x172033),
            text2:             rgb(0x344057),
            text3:             rgb(0x4B5870),
            text4:             rgb(0x5D687C),
            sidebarTintTop:    rgb(0xF8FAFF).opacity(0.88),
            sidebarTintBottom: rgb(0xEEF3FC).opacity(0.92),
            toolbarTint:       rgb(0xF4F7FE).opacity(0.88),
            glassTint:         rgb(0xF7FAFF).opacity(0.46),
            divider:           Color.black.opacity(0.08),
            border:            Color.black.opacity(0.12)
        )
    )

    static let followGhostty = GlintTheme(
        id: "follow-ghostty",
        name: "Follow Ghostty Config",
        isDark: true,
        background: glintDark.background,
        foreground: glintDark.foreground,
        cursor: glintDark.cursor,
        selectionBg: glintDark.selectionBg,
        selectionFg: glintDark.selectionFg,
        palette: glintDark.palette,
        accentOverride: glintDark.accentOverride,
        chrome: glintDark.chrome
    )

    static let catppuccinMocha = GlintTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        isDark: true,
        background:  rgb(0x1E1E2E),
        foreground:  rgb(0xCDD6F4),
        cursor:      rgb(0xF5E0DC),
        selectionBg: rgb(0x585B70),
        selectionFg: rgb(0xCDD6F4),
        palette: [
            rgb(0x45475A), rgb(0xF38BA8), rgb(0xA6E3A1), rgb(0xF9E2AF),
            rgb(0x89B4FA), rgb(0xF5C2E7), rgb(0x94E2D5), rgb(0xBAC2DE),
            rgb(0x585B70), rgb(0xF38BA8), rgb(0xA6E3A1), rgb(0xF9E2AF),
            rgb(0x89B4FA), rgb(0xF5C2E7), rgb(0x94E2D5), rgb(0xA6ADC8),
        ]
    )

    static let ghosttyDefaultPalette: [Color] = [
        rgb(0x1D1F21), rgb(0xCC6666), rgb(0xB5BD68), rgb(0xF0C674),
        rgb(0x81A2BE), rgb(0xB294BB), rgb(0x8ABEB7), rgb(0xC5C8C6),
        rgb(0x666666), rgb(0xD54E53), rgb(0xB9CA4A), rgb(0xE7C547),
        rgb(0x7AA6DA), rgb(0xC397D8), rgb(0x70C0B1), rgb(0xEAEAEA),
    ]
}

// MARK: - Provider + Registry

final class ThemeProvider {
    static let shared = ThemeProvider()
    var current: GlintTheme

    private init() {
        let mode = AppAppearanceMode(rawValue: UserDefaults.standard.string(forKey: "glint.appearanceMode") ?? "") ?? .system
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        current = ThemeRegistry.theme(id: Self.resolvedThemeID(
            themeID: UserDefaults.standard.string(forKey: "glint.themeName"),
            mode: mode,
            systemIsDark: systemIsDark
        ))
    }

    func update(themeID: String?, mode: AppAppearanceMode, systemIsDark: Bool) {
        current = ThemeRegistry.theme(id: Self.resolvedThemeID(themeID: themeID, mode: mode, systemIsDark: systemIsDark))
    }

    static func resolvedThemeID(themeID: String?, mode: AppAppearanceMode, systemIsDark: Bool) -> String {
        if let themeID, themeID == GlintTheme.followGhostty.id {
            return GlintTheme.followGhostty.id
        }
        if let themeID,
           themeID != GlintTheme.glintDark.id,
           themeID != GlintTheme.glintLight.id,
           ThemeRegistry.theme(id: themeID).id == themeID {
            return themeID
        }
        switch mode {
        case .system:
            return systemIsDark ? GlintTheme.glintDark.id : GlintTheme.glintLight.id
        case .light:
            return GlintTheme.glintLight.id
        case .dark:
            return GlintTheme.glintDark.id
        }
    }
}

enum ThemeRegistry {
    static let featured: [GlintTheme] = [.glintDark, .glintLight, .catppuccinMocha]
    static let followGhostty: GlintTheme = .followGhostty

    static let catalog: [GlintTheme] = {
        let featuredIDs = Set(featured.map(\.id))
        return ThemeCatalog.all.filter { !featuredIDs.contains($0.id) }
    }()

    static var all: [GlintTheme] { featured + catalog + [followGhostty] }

    static func theme(id: String?) -> GlintTheme {
        featured.first { $0.id == id }
            ?? catalog.first { $0.id == id }
            ?? (id == followGhostty.id ? followGhostty : .glintDark)
    }
}

// MARK: - Theme catalog

enum ThemeCatalog {
    private struct Entry: Decodable {
        let id: String
        let name: String
        let dark: Bool
        let bg, fg, cur, sb, sf: String
        let pal: [String]
    }

    static let all: [GlintTheme] = load()

    private static func load() -> [GlintTheme] {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            assertionFailure("themes.json is missing or could not be decoded; the theme catalog will be empty")
            return []
        }
        return entries.map { e in
            GlintTheme(
                id: e.id, name: e.name, isDark: e.dark,
                background:  rgb(hex: e.bg),
                foreground:  rgb(hex: e.fg),
                cursor:      rgb(hex: e.cur),
                selectionBg: rgb(hex: e.sb),
                selectionFg: rgb(hex: e.sf),
                palette:     e.pal.map { rgb(hex: $0) }
            )
        }
    }
}

// MARK: - Helpers

private func rgb(_ hex: UInt32) -> Color {
    Color(.sRGB,
          red:   Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue:  Double(hex & 0xFF) / 255,
          opacity: 1)
}

private func rgb(hex s: String) -> Color {
    let v = UInt32(s, radix: 16) ?? 0
    return rgb(v)
}

// MARK: - Color helpers

extension Color {
    func darkened(_ amount: Double) -> Color { mixed(into: .black, amount) }

    func mixed(into other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let b = NSColor(other).usingColorSpace(.sRGB) ?? NSColor(other)
        let t = CGFloat(max(0, min(1, amount)))
        return Color(.sRGB,
                     red:     Double(a.redComponent   + (b.redComponent   - a.redComponent)   * t),
                     green:   Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue:    Double(a.blueComponent  + (b.blueComponent  - a.blueComponent)  * t),
                     opacity: Double(a.alphaComponent))
    }
}

// MARK: - Collection helper

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
