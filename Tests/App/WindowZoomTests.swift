import XCTest
import AppKit
@testable import MacSpaceApp

@MainActor
final class WindowZoomTests: XCTestCase {
    func testSystemPlacementPutsTheClearResizeBandOutsideThePlaceMacOSChose() throws {
        for visible in [CGRect(x: 0, y: 0, width: 1920, height: 1050),
                        CGRect(x: -1920, y: 180, width: 1920, height: 1020)] {
            let before = CGRect(x: visible.midX - 358, y: visible.midY - 253, width: 716, height: 506)
            // Fill, a half, a quarter: the glass lands exactly where macOS put the window.
            for placed in [visible,
                           CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height),
                           CGRect(x: visible.midX, y: visible.midY, width: visible.width / 2, height: visible.height / 2)] {
                let frame = try XCTUnwrap(WindowControls.frameAfterSystemPlacement(placed, untiled: before))
                XCTAssertEqual(frame.insetBy(dx: Theme.resizeMargin, dy: Theme.resizeMargin), placed)
            }
            // Put back at its size from before (Return to Previous Size, or dragged out of a tile): the window already has its band.
            XCTAssertNil(WindowControls.frameAfterSystemPlacement(before.offsetBy(dx: 40, dy: -90), untiled: before))
        }
    }

    func testCustomZoomFillsTheGlassAndRestoresThePreviousFrame() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let requested = CGRect(x: screen.visibleFrame.midX - 350, y: screen.visibleFrame.midY - 245, width: 700, height: 490)
        let window = NSWindow(contentRect: requested, styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let original = window.frame // AppKit aligns the requested frame to this screen's backing pixels.
        XCTAssertTrue(WindowControls.toggleZoom(window))
        XCTAssertTrue(WindowControls.isZoomed(window))
        XCTAssertEqual(window.frame.insetBy(dx: Theme.resizeMargin, dy: Theme.resizeMargin), screen.visibleFrame)
        XCTAssertFalse(WindowControls.toggleZoom(window))
        XCTAssertEqual(window.frame, original)
    }
}
