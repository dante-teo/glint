import AppKit
import XCTest
@testable import Glint

final class AppIconAssetTests: XCTestCase {
    func testAppIconAssetCatalogProvidesCompleteMacIconSet() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourcesRoot = repoRoot.appendingPathComponent("Glint/Resources")
        let appIconSet = resourcesRoot.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        let privateIconSources = repoRoot.appendingPathComponent("AppIconSource")
        let projectYAML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: resourcesRoot.appendingPathComponent("AppIcon.icon").path),
            "Liquid Glass .icon source should not live under bundled resources."
        )
        XCTAssertTrue(
            projectYAML.contains("ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR: all"),
            "The standalone AppIcon.icns must keep all icon sizes for Launch Services."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: privateIconSources.path),
            "Private source photos and intermediate icon artwork must not be tracked in the repository."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appIconSet.path),
            "The bundle icon must come from a conventional AppIcon.appiconset."
        )

        let contentsData = try Data(contentsOf: appIconSet.appendingPathComponent("Contents.json"))
        let contents = try XCTUnwrap(
            JSONSerialization.jsonObject(with: contentsData) as? [String: Any]
        )
        let images = try XCTUnwrap(contents["images"] as? [[String: String]])
        let imagesByFilename = Dictionary(uniqueKeysWithValues: images.compactMap { image -> (String, [String: String])? in
            guard let filename = image["filename"] else { return nil }
            return (filename, image)
        })

        let expectedIcons: [(filename: String, size: String, scale: String, pixels: Int)] = [
            ("icon_16x16.png", "16x16", "1x", 16),
            ("icon_16x16@2x.png", "16x16", "2x", 32),
            ("icon_32x32.png", "32x32", "1x", 32),
            ("icon_32x32@2x.png", "32x32", "2x", 64),
            ("icon_128x128.png", "128x128", "1x", 128),
            ("icon_128x128@2x.png", "128x128", "2x", 256),
            ("icon_256x256.png", "256x256", "1x", 256),
            ("icon_256x256@2x.png", "256x256", "2x", 512),
            ("icon_512x512.png", "512x512", "1x", 512),
            ("icon_512x512@2x.png", "512x512", "2x", 1024),
        ]

        for icon in expectedIcons {
            let image = try XCTUnwrap(imagesByFilename[icon.filename], "\(icon.filename) should be declared")
            XCTAssertEqual(image["idiom"], "mac")
            XCTAssertEqual(image["size"], icon.size)
            XCTAssertEqual(image["scale"], icon.scale)

            let imageData = try Data(contentsOf: appIconSet.appendingPathComponent(icon.filename))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: imageData), "\(icon.filename) should decode")
            XCTAssertEqual(bitmap.pixelsWide, icon.pixels)
            XCTAssertEqual(bitmap.pixelsHigh, icon.pixels)
        }
    }

    func testEverySelectableAppIconPresetHasRuntimeAndHeaderAssets() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetsRoot = repoRoot.appendingPathComponent("Glint/Resources/Assets.xcassets")

        for preset in AppIconPreset.allCases where preset != .default {
            let presetAsset = assetsRoot.appendingPathComponent("\(preset.previewAsset).imageset/icon.png")
            let headerAsset = assetsRoot.appendingPathComponent("\(preset.headerLogoAsset).imageset/icon.png")

            try assertPNG(at: presetAsset, width: 1024, height: 1024)
            try assertPNG(at: headerAsset, width: 256, height: 256)
        }
    }

    private func assertPNG(at url: URL, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try Data(contentsOf: url)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "\(url.lastPathComponent) should decode", file: file, line: line)
        XCTAssertEqual(bitmap.pixelsWide, width, file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, height, file: file, line: line)
    }
}
