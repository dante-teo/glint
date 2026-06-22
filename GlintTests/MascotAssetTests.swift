import XCTest
import AppKit
import ImageIO
@testable import Glint

final class MascotAssetTests: XCTestCase {

    // MARK: Devin

    func testDevinIdle() {
        XCTAssertEqual(MascotAsset.devin(for: .idle), "DevinIdle")
    }

    func testDevinNil() {
        XCTAssertEqual(MascotAsset.devin(for: nil), "DevinIdle")
    }

    func testDevinThinking() {
        XCTAssertEqual(MascotAsset.devin(for: .thinking), "DevinThinking")
    }

    func testDevinToolCall() {
        XCTAssertEqual(MascotAsset.devin(for: .tool), "DevinToolCall")
    }

    func testDevinCompressing() {
        XCTAssertEqual(MascotAsset.devin(for: .compacting), "DevinCompressing")
    }

    func testDevinNeedsPermission() {
        XCTAssertEqual(MascotAsset.devin(for: .needsPermission), "DevinNeedsPermission")
    }

    func testDevinDone() {
        XCTAssertEqual(MascotAsset.devin(for: .justCompleted), "DevinDone")
    }

    func testDevinFailed() {
        XCTAssertEqual(MascotAsset.devin(for: .failed), "DevinFailed")
    }

    func testDevinStatusAssetsAreAnimatedPNGs() throws {
        let assetNames = [
            "DevinIdle",
            "DevinThinking",
            "DevinToolCall",
            "DevinCompressing",
            "DevinNeedsPermission",
            "DevinDone",
            "DevinFailed",
        ]

        for assetName in assetNames {
            let data = try XCTUnwrap(NSDataAsset(name: assetName)?.data, "\(assetName) should exist")
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), "\(assetName) should decode")

            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
            XCTAssertGreaterThan(CGImageSourceGetCount(source), 1, "\(assetName) should be animated")
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 128)
            XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.height, 128)
        }
    }

    func testDevinMarkKeepsStaticRasterSizes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetRoot = repoRoot
            .appendingPathComponent("Glint/Resources/Assets.xcassets/DevinMark.imageset")

        let oneXData = try Data(contentsOf: assetRoot.appendingPathComponent("devin24.png"))
        let twoXData = try Data(contentsOf: assetRoot.appendingPathComponent("devin48.png"))
        let oneX = try XCTUnwrap(NSBitmapImageRep(data: oneXData))
        let twoX = try XCTUnwrap(NSBitmapImageRep(data: twoXData))

        XCTAssertEqual(oneX.pixelsWide, 24)
        XCTAssertEqual(oneX.pixelsHigh, 24)
        XCTAssertEqual(twoX.pixelsWide, 48)
        XCTAssertEqual(twoX.pixelsHigh, 48)
    }

    // MARK: Existing agents (regression)

    func testClaudeIdleMascot() {
        XCTAssertEqual(MascotAsset.claude(for: .idle, isSpark: false), "ClaudeIdle")
    }

    func testClaudeIdleSpark() {
        XCTAssertEqual(MascotAsset.claude(for: .idle, isSpark: true), "ClaudeSparkIdle")
    }

    func testClaudeThinkingMascot() {
        XCTAssertEqual(MascotAsset.claude(for: .thinking, isSpark: false), "ClaudeThinking")
    }

    func testCodexIdle() {
        XCTAssertEqual(MascotAsset.codex(for: .idle), "CodexIdle")
    }

    func testCodexThinking() {
        XCTAssertEqual(MascotAsset.codex(for: .thinking), "CodexThinking")
    }

    func testOpenCodeIdle() {
        XCTAssertEqual(MascotAsset.opencode(for: .idle), "OpenCodeIdle")
    }

    func testOpenCodeThinking() {
        XCTAssertEqual(MascotAsset.opencode(for: .thinking), "OpenCodeThinking")
    }
}
