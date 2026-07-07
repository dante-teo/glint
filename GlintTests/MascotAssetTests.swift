import XCTest
import AppKit
import ImageIO
@testable import Glint

final class MascotAssetTests: XCTestCase {

    // MARK: Devin

    func testDevinIdle() {
        XCTAssertEqual(MascotAsset.devin(for: .idle, style: .portrait), "DevinIdle")
    }

    func testDevinNil() {
        XCTAssertEqual(MascotAsset.devin(for: nil, style: .portrait), "DevinIdle")
    }

    func testDevinThinking() {
        XCTAssertEqual(MascotAsset.devin(for: .thinking, style: .portrait), "DevinThinking")
    }

    func testDevinToolCall() {
        XCTAssertEqual(MascotAsset.devin(for: .tool, style: .portrait), "DevinToolCall")
    }

    func testDevinCompressing() {
        XCTAssertEqual(MascotAsset.devin(for: .compacting, style: .portrait), "DevinCompressing")
    }

    func testDevinNeedsPermission() {
        XCTAssertEqual(MascotAsset.devin(for: .needsPermission, style: .portrait), "DevinNeedsPermission")
    }

    func testDevinDone() {
        XCTAssertEqual(MascotAsset.devin(for: .justCompleted, style: .portrait), "DevinDone")
    }

    func testDevinFailed() {
        XCTAssertEqual(MascotAsset.devin(for: .failed, style: .portrait), "DevinFailed")
    }

    func testDevinPixelMonsterIdle() {
        XCTAssertEqual(MascotAsset.devin(for: .idle, style: .pixelMonster), "DevinPixelIdle")
    }

    func testDevinPixelMonsterNil() {
        XCTAssertEqual(MascotAsset.devin(for: nil, style: .pixelMonster), "DevinPixelIdle")
    }

    func testDevinPixelMonsterThinking() {
        XCTAssertEqual(MascotAsset.devin(for: .thinking, style: .pixelMonster), "DevinPixelThinking")
    }

    func testDevinPixelMonsterToolCall() {
        XCTAssertEqual(MascotAsset.devin(for: .tool, style: .pixelMonster), "DevinPixelToolCall")
    }

    func testDevinPixelMonsterCompressing() {
        XCTAssertEqual(MascotAsset.devin(for: .compacting, style: .pixelMonster), "DevinPixelCompressing")
    }

    func testDevinPixelMonsterNeedsPermission() {
        XCTAssertEqual(MascotAsset.devin(for: .needsPermission, style: .pixelMonster), "DevinPixelNeedsPermission")
    }

    func testDevinPixelMonsterDone() {
        XCTAssertEqual(MascotAsset.devin(for: .justCompleted, style: .pixelMonster), "DevinPixelDone")
    }

    func testDevinPixelMonsterFailed() {
        XCTAssertEqual(MascotAsset.devin(for: .failed, style: .pixelMonster), "DevinPixelFailed")
    }

    func testDevinIconStyleUnknownRawValueFallsBackToPortrait() {
        XCTAssertEqual(DevinIconStyle.resolved(rawValue: nil), .portrait)
        XCTAssertEqual(DevinIconStyle.resolved(rawValue: "bogus"), .portrait)
        XCTAssertEqual(DevinIconStyle.resolved(rawValue: "pixelMonster"), .pixelMonster)
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

    func testDevinPixelMonsterStatusAssetsAreAnimatedPNGs() throws {
        let assetNames = [
            "DevinPixelIdle",
            "DevinPixelThinking",
            "DevinPixelToolCall",
            "DevinPixelCompressing",
            "DevinPixelNeedsPermission",
            "DevinPixelDone",
            "DevinPixelFailed",
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

    func testDevinPixelMarkKeepsStaticRasterSizes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetRoot = repoRoot
            .appendingPathComponent("Glint/Resources/Assets.xcassets/DevinPixelMark.imageset")

        let oneXData = try Data(contentsOf: assetRoot.appendingPathComponent("devin-pixel24.png"))
        let twoXData = try Data(contentsOf: assetRoot.appendingPathComponent("devin-pixel48.png"))
        let oneX = try XCTUnwrap(NSBitmapImageRep(data: oneXData))
        let twoX = try XCTUnwrap(NSBitmapImageRep(data: twoXData))

        XCTAssertEqual(oneX.pixelsWide, 24)
        XCTAssertEqual(oneX.pixelsHigh, 24)
        XCTAssertEqual(twoX.pixelsWide, 48)
        XCTAssertEqual(twoX.pixelsHigh, 48)
    }

    // MARK: Oh My Pi

    func testOmpIdle() {
        XCTAssertEqual(MascotAsset.omp(for: .idle), "OhMyPiIdle")
    }

    func testOmpNil() {
        XCTAssertEqual(MascotAsset.omp(for: nil), "OhMyPiIdle")
    }

    func testOmpThinking() {
        XCTAssertEqual(MascotAsset.omp(for: .thinking), "OhMyPiThinking")
    }

    func testOmpToolCall() {
        XCTAssertEqual(MascotAsset.omp(for: .tool), "OhMyPiToolCall")
    }

    func testOmpCompressing() {
        XCTAssertEqual(MascotAsset.omp(for: .compacting), "OhMyPiCompressing")
    }

    func testOmpNeedsPermission() {
        XCTAssertEqual(MascotAsset.omp(for: .needsPermission), "OhMyPiNeedsPermission")
    }

    func testOmpDone() {
        XCTAssertEqual(MascotAsset.omp(for: .justCompleted), "OhMyPiDone")
    }

    func testOmpFailed() {
        XCTAssertEqual(MascotAsset.omp(for: .failed), "OhMyPiFailed")
    }

    func testOmpStatusAssetsAreAnimatedPNGs() throws {
        let assetNames = [
            "OhMyPiIdle",
            "OhMyPiThinking",
            "OhMyPiToolCall",
            "OhMyPiCompressing",
            "OhMyPiNeedsPermission",
            "OhMyPiDone",
            "OhMyPiFailed",
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

    func testOmpMarkKeepsStaticRasterSizes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetRoot = repoRoot
            .appendingPathComponent("Glint/Resources/Assets.xcassets/OhMyPiMark.imageset")

        let oneXData = try Data(contentsOf: assetRoot.appendingPathComponent("ohmypi24.png"))
        let twoXData = try Data(contentsOf: assetRoot.appendingPathComponent("ohmypi48.png"))
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
