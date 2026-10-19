import XCTest
import AppKit
@testable import MacSpaceApp

@MainActor
final class WindowZoomTests: XCTestCase {
    private static var kept: [NSWindow] = []

    func testCustomZoomFillsTheGlassAndRestoresThePreviousFrame() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let requested = CGRect(x: screen.visibleFrame.midX - 350, y: screen.visibleFrame.midY - 245, width: 700, height: 490)
        let window = NSWindow(contentRect: requested, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let original = window.frame // AppKit aligns the requested frame to this screen's backing pixels.
        XCTAssertTrue(WindowControls.toggleZoom(window))
        XCTAssertTrue(WindowControls.isZoomed(window))
        XCTAssertEqual(window.frame, screen.visibleFrame)
        XCTAssertFalse(WindowControls.toggleZoom(window))
        XCTAssertEqual(window.frame, original)
    }

    func testGlassWindowCanBecomeKey() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 490), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // Kept, as the app keeps its window: AppKit's observers of a window whose class was changed cannot be removed when it goes.
        Self.kept.append(window)
        XCTAssertFalse(window.canBecomeKey)
        KeyableWindow.adopt(window)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
    }

    /// Room beside and below the glass, none above: the shadow window never reaches under the menu bar when the glass is against it.
    func testShadowWindowNeverReachesAboveTheGlass() {
        let glass = CGRect(x: 100, y: 200, width: 700, height: 490)
        let frame = ShadowWindow.frame(around: glass)
        XCTAssertEqual(frame.maxY, glass.maxY)
        XCTAssertEqual(frame.minY, glass.minY - ShadowWindow.margin)
        XCTAssertEqual(frame.minX, glass.minX - ShadowWindow.margin)
        XCTAssertEqual(frame.maxX, glass.maxX + ShadowWindow.margin)
    }
}
