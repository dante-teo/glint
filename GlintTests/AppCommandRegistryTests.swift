import XCTest
@testable import Glint

final class AppCommandRegistryTests: XCTestCase {
    func testRegistryHasUniqueStableIdentifiers() {
        let commands = AppCommandRegistry.commands
        XCTAssertEqual(Set(commands.map(\.id)).count, commands.count)
    }

    func testRegistryRetainsExistingPaletteShortcuts() {
        let shortcuts = Dictionary(
            uniqueKeysWithValues: AppCommandRegistry.commands.map { ($0.id, $0.shortcut) }
        )
        XCTAssertEqual(shortcuts[.newTab], "⌘T")
        XCTAssertEqual(shortcuts[.splitRight], "⌘D")
        XCTAssertEqual(shortcuts[.splitDown], "⌘⇧D")
        XCTAssertEqual(shortcuts[.closePane], "⌘W")
        XCTAssertEqual(shortcuts[.toggleSidebar], "⌘/")
        XCTAssertEqual(shortcuts[.settings], "⌘,")
    }

    func testAliasesParticipateInDeterministicRanking() {
        let first = AppCommandRegistry.ranked(query: "preferences").map(\.id)
        let second = AppCommandRegistry.ranked(query: "preferences").map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first, .settings)
    }

    func testTitleMatchRanksAboveAliasMatch() {
        XCTAssertEqual(
            AppCommandRegistry.ranked(query: "new tab").first?.id,
            .newTab
        )
    }

    func testFuzzyMatcherPreservesPrefixBoundaryAndSubsequenceOrdering() {
        let prefix = FuzzyMatcher.score(needle: "new", haystack: "new tab")
        let boundary = FuzzyMatcher.score(needle: "tab", haystack: "new tab")
        let scattered = FuzzyMatcher.score(needle: "nb", haystack: "new tab")

        XCTAssertNotNil(prefix)
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(prefix!, boundary!)
        XCTAssertGreaterThan(boundary!, scattered!)
        XCTAssertNil(FuzzyMatcher.score(needle: "xyz", haystack: "new tab"))
    }
}
