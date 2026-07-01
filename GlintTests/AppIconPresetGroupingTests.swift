import XCTest
@testable import Glint

final class AppIconPresetGroupingTests: XCTestCase {

    // MARK: - Resolution (portrait + color → preset)

    func testOriginalSunriseResolvesToSunrise() {
        XCTAssertEqual(AppIconPreset.preset(portrait: .original, color: .sunrise), .sunrise)
    }

    func testOriginalClassicResolvesToClassic() {
        XCTAssertEqual(AppIconPreset.preset(portrait: .original, color: .classic), .classic)
    }

    func testBunSunriseResolvesToBun() {
        XCTAssertEqual(AppIconPreset.preset(portrait: .bun, color: .sunrise), .bun)
    }

    func testBunClassicResolvesToBunClassic() {
        XCTAssertEqual(AppIconPreset.preset(portrait: .bun, color: .classic), .bunClassic)
    }

    func testEveryPortraitColorPairResolvesToValidPreset() {
        for portrait in PortraitStyle.allCases {
            for color in IconColorTheme.allCases {
                let preset = AppIconPreset.preset(portrait: portrait, color: color)
                XCTAssertNotEqual(
                    preset, .default,
                    "(\(portrait), \(color)) should resolve to a non-default preset"
                )
            }
        }
    }

    func testAllResolvedPresetsAreUnique() {
        var seen = Set<AppIconPreset>()
        for portrait in PortraitStyle.allCases {
            for color in IconColorTheme.allCases {
                let preset = AppIconPreset.preset(portrait: portrait, color: color)
                XCTAssertTrue(
                    seen.insert(preset).inserted,
                    "(\(portrait), \(color)) resolved to \(preset) which was already produced by another pair"
                )
            }
        }
    }

    // MARK: - Decomposition (preset → portrait + color)

    func testDefaultPresetHasNilPortraitAndColor() {
        XCTAssertNil(AppIconPreset.default.portraitStyle)
        XCTAssertNil(AppIconPreset.default.colorTheme)
    }

    func testSunriseDecomposesToOriginalSunrise() {
        XCTAssertEqual(AppIconPreset.sunrise.portraitStyle, .original)
        XCTAssertEqual(AppIconPreset.sunrise.colorTheme, .sunrise)
    }

    func testBunDecomposesToBunSunrise() {
        XCTAssertEqual(AppIconPreset.bun.portraitStyle, .bun)
        XCTAssertEqual(AppIconPreset.bun.colorTheme, .sunrise)
    }

    func testBunClassicDecomposesToBunClassic() {
        XCTAssertEqual(AppIconPreset.bunClassic.portraitStyle, .bun)
        XCTAssertEqual(AppIconPreset.bunClassic.colorTheme, .classic)
    }

    func testAllNonDefaultPresetsHavePortraitAndColor() {
        for preset in AppIconPreset.allCases where preset != .default {
            XCTAssertNotNil(preset.portraitStyle, "\(preset) should have a portrait style")
            XCTAssertNotNil(preset.colorTheme, "\(preset) should have a color theme")
        }
    }

    // MARK: - Round-trip

    func testEveryNonDefaultPresetRoundTrips() {
        for preset in AppIconPreset.allCases where preset != .default {
            let portrait = preset.portraitStyle!
            let color = preset.colorTheme!
            let resolved = AppIconPreset.preset(portrait: portrait, color: color)
            XCTAssertEqual(resolved, preset, "\(preset) did not round-trip through decompose → resolve")
        }
    }

    func testEveryPortraitColorPairRoundTrips() {
        for portrait in PortraitStyle.allCases {
            for color in IconColorTheme.allCases {
                let preset = AppIconPreset.preset(portrait: portrait, color: color)
                XCTAssertEqual(preset.portraitStyle, portrait, "Portrait did not round-trip for (\(portrait), \(color))")
                XCTAssertEqual(preset.colorTheme, color, "Color did not round-trip for (\(portrait), \(color))")
            }
        }
    }

    // MARK: - Coverage / invariants

    func testPortraitStyleCountIsFive() {
        XCTAssertEqual(PortraitStyle.allCases.count, 5)
    }

    func testIconColorThemeCountIsNine() {
        XCTAssertEqual(IconColorTheme.allCases.count, 9)
    }

    func testTotalPresetsMatchExpectation() {
        // 1 default + 5 portraits × 9 colors = 46
        XCTAssertEqual(AppIconPreset.allCases.count, 46)
    }

    // MARK: - Display names

    func testPortraitDisplayNames() {
        let expected: [PortraitStyle: String] = [
            .original: "Original",
            .bun: "Bun",
            .longhair: "Long Hair",
            .pout: "Pout",
            .breeze: "Breeze",
        ]
        for (style, name) in expected {
            XCTAssertEqual(style.displayName, name)
        }
    }

    func testColorThemeDisplayNames() {
        let expected: [IconColorTheme: String] = [
            .sunrise: "Sunrise",
            .classic: "Classic",
            .aurora: "Aurora",
            .arctic: "Arctic",
            .steel: "Steel",
            .ultraviolet: "Ultraviolet",
            .jade: "Jade",
            .ember: "Ember",
            .graphite: "Graphite",
        ]
        for (theme, name) in expected {
            XCTAssertEqual(theme.displayName, name)
        }
    }
}
