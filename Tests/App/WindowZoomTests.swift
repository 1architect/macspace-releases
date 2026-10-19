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

    /// Room above the glass as the shadow needs it, never under the menu bar: less near it, none against it.
    func testShadowWindowNeverReachesUnderTheMenuBar() {
        let top: CGFloat = 803
        let free = CGRect(x: 100, y: 200, width: 700, height: 490)
        XCTAssertEqual(ShadowWindow.roomAbove(free, screenTop: top), ShadowWindow.above)
        XCTAssertEqual(ShadowWindow.frame(around: free, room: ShadowWindow.above).maxY, free.maxY + ShadowWindow.above)
        let near = CGRect(x: 100, y: top - 490 - 10, width: 700, height: 490)
        XCTAssertEqual(ShadowWindow.roomAbove(near, screenTop: top), 10)
        let against = CGRect(x: 0, y: 0, width: 1280, height: top)
        XCTAssertEqual(ShadowWindow.roomAbove(against, screenTop: top), 0)
        XCTAssertLessThanOrEqual(ShadowWindow.frame(around: against, room: 0).maxY, top)
        let frame = ShadowWindow.frame(around: free, room: 0)
        XCTAssertEqual(frame.minY, free.minY - ShadowWindow.margin)
        XCTAssertEqual(frame.minX, free.minX - ShadowWindow.margin)
        XCTAssertEqual(frame.maxX, free.maxX + ShadowWindow.margin)
    }
}
