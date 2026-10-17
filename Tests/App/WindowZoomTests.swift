import XCTest
import AppKit
@testable import MacSpaceApp

@MainActor
final class WindowZoomTests: XCTestCase {
    func testSystemFillPlacesTheClearResizeBandOutsideTheScreen() throws {
        for visible in [CGRect(x: 0, y: 0, width: 1920, height: 1050),
                        CGRect(x: -1920, y: 180, width: 1920, height: 1020)] {
            let frame = try XCTUnwrap(WindowControls.glassFrameAfterSystemFill(visible, visible: visible))
            XCTAssertEqual(frame.insetBy(dx: Theme.resizeMargin, dy: Theme.resizeMargin), visible)
            XCTAssertNil(WindowControls.glassFrameAfterSystemFill(frame, visible: visible), "correcting Fill must not loop")
            XCTAssertNil(WindowControls.glassFrameAfterSystemFill(CGRect(x: visible.minX, y: visible.minY,
                width: visible.width / 2, height: visible.height), visible: visible), "leave tiled and ordinary windows alone")
        }
    }

    func testCustomZoomFillsTheGlassAndRestoresThePreviousFrame() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let original = CGRect(x: screen.visibleFrame.midX - 350, y: screen.visibleFrame.midY - 245, width: 700, height: 490)
        let window = NSWindow(contentRect: original, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(WindowControls.toggleZoom(window))
        XCTAssertTrue(WindowControls.isZoomed(window))
        XCTAssertEqual(window.frame.insetBy(dx: Theme.resizeMargin, dy: Theme.resizeMargin), screen.visibleFrame)
        XCTAssertFalse(WindowControls.toggleZoom(window))
        XCTAssertEqual(window.frame, original)
    }
}
