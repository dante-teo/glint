import AppKit
import SwiftUI
import XCTest
@testable import Glint

final class AppearanceThemeTests: XCTestCase {

    func testAppearanceModeRawValuesAreStable() {
        XCTAssertEqual(AppAppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppAppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppAppearanceMode.dark.rawValue, "dark")
    }

    func testPreferredColorSchemeResolution() {
        XCTAssertNil(AppAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(AppAppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(AppAppearanceMode.dark.preferredColorScheme, .dark)
    }

    func testThemeResolutionForFirstPartyAppearanceModes() {
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "glint-dark", mode: .dark, systemIsDark: false), "glint-dark")
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "glint-dark", mode: .light, systemIsDark: true), "glint-light")
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "glint-dark", mode: .system, systemIsDark: false), "glint-light")
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "glint-light", mode: .system, systemIsDark: true), "glint-dark")
    }

    func testAdvancedThemeResolutionPreservesCustomThemes() {
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "catppuccin-mocha", mode: .system, systemIsDark: false), "catppuccin-mocha")
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "follow-ghostty", mode: .light, systemIsDark: false), "follow-ghostty")
    }

    func testFirstPartyThemesExistAndHaveDifferentChromeBackgrounds() {
        let dark = ThemeRegistry.theme(id: "glint-dark")
        let light = ThemeRegistry.theme(id: "glint-light")

        XCTAssertTrue(dark.isDark)
        XCTAssertFalse(light.isDark)
        XCTAssertNotEqual(dark.bgPane.rgbHex, light.bgPane.rgbHex)
        XCTAssertNotEqual(dark.bgWindow.rgbHex, light.bgWindow.rgbHex)
    }

    func testEnglishOnlyLanguageOptions() {
        XCTAssertEqual(WorkspaceStore.languageOptions.map(\.value), ["system", "en"])
        XCTAssertEqual(WorkspaceStore.languageOptions.map(\.label), ["Follow system", "English"])
    }

    func testUnsupportedStoredLanguageNormalizesToSystem() {
        XCTAssertEqual(WorkspaceStore.normalizedPreferredLanguage("zh-Hans"), "system")
        XCTAssertEqual(WorkspaceStore.normalizedPreferredLanguage("fr"), "system")
        XCTAssertEqual(WorkspaceStore.normalizedPreferredLanguage(nil), "system")
        XCTAssertEqual(WorkspaceStore.normalizedPreferredLanguage("en"), "en")
    }

    func testThemeBrowserRestoreUsesResolvedAppearanceTheme() {
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "glint-dark", mode: .light, systemIsDark: true), "glint-light")
        XCTAssertEqual(ThemeProvider.resolvedThemeID(themeID: "glint-light", mode: .dark, systemIsDark: false), "glint-dark")
    }

    func testLiquidGlassDefaultsAreActuallyTranslucent() {
        XCTAssertLessThan(WorkspaceStore.defaultTerminalOpacity, 1.0)
        XCTAssertLessThan(WorkspaceStore.defaultChromeOpacity, 1.0)
        XCTAssertGreaterThan(WorkspaceStore.defaultBackgroundBlur, 0)
        XCTAssertGreaterThanOrEqual(WorkspaceStore.defaultTerminalOpacity, 0.85)
        XCTAssertGreaterThanOrEqual(WorkspaceStore.defaultChromeOpacity, 0.65)
    }

    func testTransparentTerminalBackingAppliesLayerAlpha() {
        let style = GhosttyManager.terminalBackingStyle(terminalOpacity: 0.72,
                                                        backgroundColor: .black)
        XCTAssertFalse(style.isOpaque)
        XCTAssertEqual(style.layerOpacity, 0.93, accuracy: 0.001)
        XCTAssertEqual(style.backgroundColor.alphaComponent, 0, accuracy: 0.001)
    }

    func testNearOpaqueTerminalBackingDoesNotOverFadeSurface() {
        let style = GhosttyManager.terminalBackingStyle(terminalOpacity: 0.99,
                                                        backgroundColor: .black)
        XCTAssertFalse(style.isOpaque)
        XCTAssertEqual(style.layerOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(style.backgroundColor.alphaComponent, 0, accuracy: 0.001)
    }

    func testTerminalBackingMutatesSurfaceButNotContainerOpacity() {
        let defaults = UserDefaults.standard
        let previousOpacity = defaults.object(forKey: "glint.terminalOpacity")
        let previousFramedSplitMode = defaults.object(forKey: GhosttyManager.activeFramedSplitModeKey)
        defaults.set(0.64, forKey: "glint.terminalOpacity")
        defaults.set(false, forKey: GhosttyManager.activeFramedSplitModeKey)
        defer {
            if let previousOpacity {
                defaults.set(previousOpacity, forKey: "glint.terminalOpacity")
            } else {
                defaults.removeObject(forKey: "glint.terminalOpacity")
            }
            if let previousFramedSplitMode {
                defaults.set(previousFramedSplitMode, forKey: GhosttyManager.activeFramedSplitModeKey)
            } else {
                defaults.removeObject(forKey: GhosttyManager.activeFramedSplitModeKey)
            }
        }

        let surfaceLayer = CALayer()
        GhosttyManager.shared.applyTerminalBacking(to: surfaceLayer)
        XCTAssertFalse(surfaceLayer.isOpaque)
        XCTAssertEqual(surfaceLayer.opacity, 0.91, accuracy: 0.001)
        XCTAssertEqual(Double(NSColor(cgColor: surfaceLayer.backgroundColor!)?.alphaComponent ?? 1),
                       0,
                       accuracy: 0.001)

        let containerLayer = CALayer()
        GhosttyManager.shared.applyTerminalBacking(to: containerLayer,
                                                   appliesContentOpacity: false)
        XCTAssertFalse(containerLayer.isOpaque)
        XCTAssertEqual(containerLayer.opacity, 1, accuracy: 0.001)
    }

    func testFirstPartyThemeTextContrastPassesAA() {
        for theme in [ThemeRegistry.theme(id: "glint-dark"), ThemeRegistry.theme(id: "glint-light")] {
            XCTAssertGreaterThanOrEqual(contrast(theme.text1, theme.bgPane), 4.5, theme.id)
            XCTAssertGreaterThanOrEqual(contrast(theme.text2, theme.bgPane), 4.5, theme.id)
            XCTAssertGreaterThanOrEqual(contrast(theme.text3, theme.bgPane), 4.5, theme.id)
            XCTAssertGreaterThanOrEqual(contrast(theme.text4, theme.bgPane), 4.5, theme.id)
        }
    }

    func testFirstPartySettingsSurfaceContrastPassesAA() {
        for theme in [ThemeRegistry.theme(id: "glint-dark"), ThemeRegistry.theme(id: "glint-light")] {
            let cardBackground = composite(ThemeOverlay.color(for: theme, opacity: 0.035), over: theme.bgPane)
            let hoverBackground = composite(ThemeOverlay.color(for: theme, opacity: 0.08), over: theme.bgPane)
            XCTAssertGreaterThanOrEqual(contrast(theme.text1, cardBackground), 4.5, "\(theme.id) card text1")
            XCTAssertGreaterThanOrEqual(contrast(theme.text4, cardBackground), 4.5, "\(theme.id) card text4")
            XCTAssertGreaterThanOrEqual(contrast(theme.text1, hoverBackground), 4.5, "\(theme.id) hover text1")
            XCTAssertGreaterThanOrEqual(contrast(theme.text2, hoverBackground), 4.5, "\(theme.id) hover text2")
        }
    }

    func testAccentSelectionContrastPassesAA() {
        for theme in [ThemeRegistry.theme(id: "glint-dark"), ThemeRegistry.theme(id: "glint-light")] {
            let selectedBackground = composite(Theme.accent(named: "indigo").opacity(0.12), over: theme.bgPane)
            XCTAssertGreaterThanOrEqual(contrast(theme.text1, selectedBackground), 4.5, "\(theme.id) selected text1")
            XCTAssertGreaterThanOrEqual(contrast(theme.text2, selectedBackground), 4.5, "\(theme.id) selected text2")
        }
    }

    private func contrast(_ foreground: Color, _ background: Color) -> Double {
        let f = components(foreground)
        let b = components(background)
        let lf = relativeLuminance(red: f.red, green: f.green, blue: f.blue)
        let lb = relativeLuminance(red: b.red, green: b.green, blue: b.blue)
        return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
    }

    private func components(_ color: Color) -> (red: Double, green: Double, blue: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private func composite(_ foreground: Color, over background: Color) -> Color {
        let f = NSColor(foreground).usingColorSpace(.sRGB) ?? NSColor(foreground)
        let b = NSColor(background).usingColorSpace(.sRGB) ?? NSColor(background)
        let alpha = Double(f.alphaComponent)
        return Color(.sRGB,
                     red: Double(f.redComponent) * alpha + Double(b.redComponent) * (1 - alpha),
                     green: Double(f.greenComponent) * alpha + Double(b.greenComponent) * (1 - alpha),
                     blue: Double(f.blueComponent) * alpha + Double(b.blueComponent) * (1 - alpha),
                     opacity: 1)
    }

    private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        let values = [red, green, blue].map { value in
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
    }
}

private enum ThemeOverlay {
    static func color(for theme: GlintTheme, opacity: Double) -> Color {
        theme.isDark ? Color.white.opacity(opacity) : Color.black.opacity(opacity)
    }
}
