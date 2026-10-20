import XCTest
@testable import MacSpaceApp

@MainActor
final class ClosedWindowReleaseTests: XCTestCase {
    func testThePagesGoWhenTheLastWindowClosesAndComeBackWithAWindow() {
        var open = true
        let release = ClosedWindowRelease(keepsRunning: { true }, hasOpenWindow: { _ in open })
        release.windowsChanged(closing: nil)
        XCTAssertFalse(release.isReleased, "a window is open")
        open = false
        release.windowsChanged(closing: nil)
        XCTAssertTrue(release.isReleased, "no window open: dropped at once")
        open = true
        release.windowsChanged(closing: nil)
        XCTAssertFalse(release.isReleased, "a window on screen again: built again")
    }

    func testNothingGoesWhenMacSpaceQuitsWithItsLastWindow() {
        let release = ClosedWindowRelease(keepsRunning: { false }, hasOpenWindow: { _ in false })
        release.windowsChanged(closing: nil)
        XCTAssertFalse(release.isReleased)
    }
}
