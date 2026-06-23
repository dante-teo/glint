import XCTest
@testable import Glint

final class FontDefaultsTests: XCTestCase {

    func testTerminalDefaultFamilyIsDepartureMonoNerdFont() {
        XCTAssertEqual(AppFonts.defaultTerminalFamily, "DepartureMono Nerd Font")
        XCTAssertEqual(AppFonts.terminalFallbackFamily, "Menlo")
    }

    @MainActor
    func testWorkspaceStoreUsesDefaultTerminalFontWhenUnset() {
        let previous = UserDefaults.standard.object(forKey: "glint.terminalFontFamily")
        UserDefaults.standard.removeObject(forKey: "glint.terminalFontFamily")
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: "glint.terminalFontFamily")
            } else {
                UserDefaults.standard.removeObject(forKey: "glint.terminalFontFamily")
            }
        }

        let store = WorkspaceStore()

        XCTAssertEqual(store.terminalFontFamily, AppFonts.defaultTerminalFamily)
    }

    func testTerminalFontChoicesStartWithBundledDefault() {
        XCTAssertEqual(AppFonts.terminalFontFamilies.first, AppFonts.defaultTerminalFamily)
        XCTAssertTrue(AppFonts.terminalFontFamilies.contains("SF Mono"))
        XCTAssertTrue(AppFonts.terminalFontFamilies.contains(AppFonts.terminalFallbackFamily))
    }

    func testBundledFontManifestContainsRequiredFiles() {
        XCTAssertEqual(Set(BundledFontRegistrar.fontResourceNames), [
            "DepartureMonoNerdFont-Regular",
            "Barlow-Regular",
            "Barlow-Medium",
            "Barlow-SemiBold",
            "Barlow-Bold",
        ])
    }

    func testBundledFontsArePresentInBundle() {
        for name in BundledFontRegistrar.fontResourceNames {
            XCTAssertNotNil(BundledFontRegistrar.fontURL(forResource: name), name)
        }
    }

    func testBundledFontRegistrationIsIdempotent() {
        XCTAssertTrue(BundledFontRegistrar.registerBundledFonts())
        XCTAssertTrue(BundledFontRegistrar.registerBundledFonts())
    }
}
