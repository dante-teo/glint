import SwiftUI
import AppKit

enum Theme {
    // Chrome neutrals come from the active theme. Theme changes bump
    // WorkspaceStore.themeRevision so SwiftUI recomputes these static values.
    static var current: GlintTheme { ThemeProvider.shared.current }

    // backgrounds
    static var bgWindow: Color { current.bgWindow }
    static var bgPane:   Color { current.bgPane }

    // vibrancy tint overlays — black-first with the faintest indigo cast
    static var sidebarTintTop:    Color { current.sidebarTintTop }
    static var sidebarTintBottom: Color { current.sidebarTintBottom }
    static var toolbarTint:       Color { current.toolbarTint }

    // Liquid Glass tint (macOS 26): the sidebar indigo, but thin enough that
    // the glass still refracts the terminal behind it instead of reading as
    // a painted slab.
    static var glassTint:         Color { current.glassTint }

    // text
    static var text1: Color { current.text1 }
    static var text2: Color { current.text2 }
    static var text3: Color { current.text3 }
    static var text4: Color { current.text4 }

    // accents
    static let accent       = Color(red: 0.369, green: 0.361, blue: 0.902) // #5E5CE6 systemIndigo
    static let accentBright = Color(red: 0.549, green: 0.549, blue: 1.000) // #8C8CFF
    static let green        = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let orange       = Color(red: 1.000, green: 0.624, blue: 0.039) // #FF9F0A
    static let pink         = Color(red: 1.000, green: 0.392, blue: 0.510) // #FF6482
    static let cyan         = Color(red: 0.392, green: 0.824, blue: 1.000) // #64D2FF

    // separators
    static var divider: Color { current.divider }
    static var border:  Color { current.border }

    /// Adaptive surface overlay. Dark themes lighten with white; light themes
    /// darken with black so the opacity meaning is consistent.
    static func overlay(_ o: Double) -> Color {
        current.isDark ? Color.white.opacity(o) : Color.black.opacity(o)
    }

    /// Canonical accent palette keyed by the `glint.accentName` token. Single
    /// source for the SwiftUI chrome accent (`WorkspaceStore.accent`), the
    /// Settings swatches, and the terminal cursor/selection color so the three
    /// never drift. "indigo" / unset map to `accentBright`.
    static func accent(named name: String?) -> Color {
        switch name {
        case "cyan":   return cyan
        case "pink":   return pink
        case "orange": return orange
        case "green":  return green
        default:       return accentBright
        }
    }
}

extension Color {
    /// "RRGGBB" in sRGB. Lets a chrome accent `Color` feed ghostty's text
    /// config (cursor/selection), which only accepts hex strings — so the
    /// terminal color is derived from the same `Theme` color the UI uses
    /// rather than a hand-kept parallel hex table.
    var rgbHex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

extension Font {
    static let glintUI       = AppFonts.ui(13, weight: .medium)
    static let glintUISmall  = AppFonts.ui(12, weight: .medium)
    static let glintCaption  = AppFonts.ui(10.5, weight: .semibold).leading(.tight)
    static let glintSection  = AppFonts.ui(10.5, weight: .semibold)
    static let glintMono     = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    static let glintMonoBig  = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let glintStatus   = Font.system(size: 11, weight: .medium, design: .monospaced)
}
