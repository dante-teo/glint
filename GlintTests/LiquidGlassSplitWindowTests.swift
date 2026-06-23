import XCTest
@testable import Glint

@MainActor
final class LiquidGlassSplitWindowTests: XCTestCase {
    private let defaultsKey = "glint.framedSplits"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func testFramedSplitsDefaultsToFalse() {
        let store = WorkspaceStore()

        XCTAssertFalse(store.framedSplits)
    }

    func testFramedSplitsPersistsToUserDefaults() {
        let store = WorkspaceStore()

        store.framedSplits = true

        XCTAssertTrue(UserDefaults.standard.bool(forKey: defaultsKey))
    }

    func testSplitNodeLeafCount() {
        let a = PaneID(value: 1)
        let b = PaneID(value: 2)
        let c = PaneID(value: 3)

        XCTAssertEqual(SplitNode.leaf(a).leafCount, 1)
        XCTAssertEqual(
            SplitNode.split(direction: .horizontal, ratio: 0.5, a: .leaf(a), b: .leaf(b)).leafCount,
            2
        )
        XCTAssertEqual(
            SplitNode.split(
                direction: .vertical,
                ratio: 0.4,
                a: .split(direction: .horizontal, ratio: 0.5, a: .leaf(a), b: .leaf(b)),
                b: .leaf(c)
            ).leafCount,
            3
        )
    }

    func testSplitNodeLeafTopAlignment() {
        let topLeft = PaneID(value: 1)
        let topRight = PaneID(value: 2)
        let bottom = PaneID(value: 3)
        let root = SplitNode.split(
            direction: .vertical,
            ratio: 0.5,
            a: .split(direction: .horizontal, ratio: 0.5, a: .leaf(topLeft), b: .leaf(topRight)),
            b: .leaf(bottom)
        )

        XCTAssertEqual(root.leafReachesTop(topLeft), true)
        XCTAssertEqual(root.leafReachesTop(topRight), true)
        XCTAssertEqual(root.leafReachesTop(bottom), false)
        XCTAssertNil(root.leafReachesTop(PaneID(value: 99)))
    }

    func testExtendedViewportInsetAppliesToEveryFramedSplitLeaf() {
        let top = PaneID(value: 1)
        let bottom = PaneID(value: 2)
        let root = SplitNode.split(
            direction: .vertical,
            ratio: 0.5,
            a: .leaf(top),
            b: .leaf(bottom)
        )

        XCTAssertEqual(WorkspaceStore.usesExtendedViewportInset(
            framedSplits: true,
            glassEffect: true,
            root: root,
            paneID: top
        ), true)
        XCTAssertEqual(WorkspaceStore.usesExtendedViewportInset(
            framedSplits: true,
            glassEffect: true,
            root: root,
            paneID: bottom
        ), true)
        XCTAssertEqual(WorkspaceStore.usesExtendedViewportInset(
            framedSplits: false,
            glassEffect: true,
            root: root,
            paneID: top
        ), true)
        XCTAssertEqual(WorkspaceStore.usesExtendedViewportInset(
            framedSplits: false,
            glassEffect: true,
            root: root,
            paneID: bottom
        ), false)
        XCTAssertNil(WorkspaceStore.usesExtendedViewportInset(
            framedSplits: true,
            glassEffect: true,
            root: root,
            paneID: PaneID(value: 99)
        ))
    }

    func testLiquidGlassSplitWindowEligibilityRequiresSplitAndGlass() {
        let single = SplitNode.leaf(PaneID(value: 1))
        let split = SplitNode.split(
            direction: .horizontal,
            ratio: 0.5,
            a: .leaf(PaneID(value: 1)),
            b: .leaf(PaneID(value: 2))
        )

        XCTAssertFalse(WorkspaceStore.usesLiquidGlassSplitWindows(
            framedSplits: true,
            glassEffect: true,
            root: single
        ))
        XCTAssertFalse(WorkspaceStore.usesLiquidGlassSplitWindows(
            framedSplits: true,
            glassEffect: false,
            root: split
        ))
        XCTAssertFalse(WorkspaceStore.usesLiquidGlassSplitWindows(
            framedSplits: false,
            glassEffect: true,
            root: split
        ))
        XCTAssertTrue(WorkspaceStore.usesLiquidGlassSplitWindows(
            framedSplits: true,
            glassEffect: true,
            root: split
        ))
    }

    func testFramedSplitModeForcesClearTerminalSurfaces() {
        let defaults = UserDefaults.standard
        let opacityKey = "glint.terminalOpacity"
        let previousOpacity = defaults.object(forKey: opacityKey)
        let previousActive = defaults.object(forKey: GhosttyManager.activeFramedSplitModeKey)
        defer {
            if let previousOpacity {
                defaults.set(previousOpacity, forKey: opacityKey)
            } else {
                defaults.removeObject(forKey: opacityKey)
            }
            if let previousActive {
                defaults.set(previousActive, forKey: GhosttyManager.activeFramedSplitModeKey)
            } else {
                defaults.removeObject(forKey: GhosttyManager.activeFramedSplitModeKey)
            }
        }

        defaults.set(0.72, forKey: opacityKey)
        defaults.set(false, forKey: GhosttyManager.activeFramedSplitModeKey)
        XCTAssertEqual(GhosttyManager.effectiveTerminalOpacity(defaults: defaults), 0.72)

        defaults.set(true, forKey: GhosttyManager.activeFramedSplitModeKey)
        XCTAssertEqual(GhosttyManager.effectiveTerminalOpacity(defaults: defaults), 0)
    }
}
