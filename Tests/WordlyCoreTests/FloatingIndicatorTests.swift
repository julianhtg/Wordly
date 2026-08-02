import XCTest
import AppKit
@testable import WordlyCore

/// The two pieces of pill-visibility logic that don't need a WindowServer:
/// where the pill goes, and whether a shown pill is really on screen.
final class FloatingIndicatorTests: XCTestCase {
    private let pill = NSSize(width: 92, height: 32)

    // MARK: pillOrigin

    func testPillSitsCenteredJustAboveTheDock() {
        let vf = NSRect(x: 0, y: 60, width: 1920, height: 1183)  // 60 pt Dock
        let origin = pillOrigin(in: vf, size: pill)
        XCTAssertEqual(origin.x, vf.midX - pill.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, vf.minY + 24, accuracy: 0.001)
    }

    func testPillFollowsTheScreenItIsPlacedOn() {
        let vf = NSRect(x: -1512, y: 200, width: 1512, height: 900)  // left of built-in
        let origin = pillOrigin(in: vf, size: pill)
        XCTAssertEqual(origin.x, vf.midX - pill.width / 2, accuracy: 0.001)
        XCTAssertEqual(origin.y, 224, accuracy: 0.001)
    }

    func testPillIsClampedIntoASmallerScreen() {
        // A stale frame from a bigger display must never survive a reposition.
        let vf = NSRect(x: 0, y: 0, width: 80, height: 40)
        let origin = pillOrigin(in: vf, size: pill)
        XCTAssertGreaterThanOrEqual(origin.x, vf.minX)
        XCTAssertGreaterThanOrEqual(origin.y, vf.minY)
        XCTAssertLessThanOrEqual(origin.y + pill.height, vf.maxY)
    }

    // MARK: PillHealth

    private let onScreen = NSRect(x: 914, y: 24, width: 92, height: 32)
    private let builtIn = [NSRect(x: 0, y: 0, width: 1920, height: 1243)]

    private func check(isVisible: Bool = true, alpha: CGFloat = 1,
                       onActiveSpace: Bool = true, hasScreen: Bool = true,
                       frame: NSRect? = nil, screens: [NSRect]? = nil) -> Bool {
        PillHealth.isHealthy(isVisible: isVisible, alpha: alpha,
                             isOnActiveSpace: onActiveSpace, hasScreen: hasScreen,
                             frame: frame ?? onScreen, screenFrames: screens ?? builtIn)
    }

    func testVisiblePillIsHealthy() {
        XCTAssertTrue(check())
    }

    func testEveryWayThePillCanGoMissingIsUnhealthy() {
        XCTAssertFalse(check(isVisible: false), "ordered out")
        XCTAssertFalse(check(alpha: 0.5), "fade-in stranded")
        XCTAssertFalse(check(onActiveSpace: false), "left behind on another Space")
        XCTAssertFalse(check(hasScreen: false), "no screen assigned")
        XCTAssertFalse(check(frame: NSRect(x: 3000, y: 2000, width: 92, height: 32)),
                       "off-screen origin")
        XCTAssertFalse(check(screens: []), "no displays")
    }
}
