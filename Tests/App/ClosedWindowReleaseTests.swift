import XCTest
@testable import MacSpaceApp

@MainActor
final class ClosedWindowReleaseTests: XCTestCase {
    func testThePagesGoAfterTheDelayWithNoWindowOpen() async throws {
        let release = ClosedWindowRelease(delay: .milliseconds(50), keepsRunning: { true }, hasOpenWindow: { _ in false })
        release.windowClosed(nil)
        XCTAssertFalse(release.isReleased)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(release.isReleased)
        release.restore()
        XCTAssertFalse(release.isReleased, "built again once a window is on screen")
    }

    func testAWindowBackInTimeKeepsThePages() async throws {
        let release = ClosedWindowRelease(delay: .milliseconds(100), keepsRunning: { true }, hasOpenWindow: { _ in false })
        release.windowClosed(nil)
        try await Task.sleep(for: .milliseconds(20))
        release.restore()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(release.isReleased)
        XCTAssertFalse(release.isPending)
    }

    func testNothingGoesWhileAnotherWindowIsOpenOrWhenMacSpaceQuits() async throws {
        let open = ClosedWindowRelease(delay: .milliseconds(20), keepsRunning: { true }, hasOpenWindow: { _ in true })
        open.windowClosed(nil)
        XCTAssertFalse(open.isPending)
        let quits = ClosedWindowRelease(delay: .milliseconds(20), keepsRunning: { false }, hasOpenWindow: { _ in false })
        quits.windowClosed(nil)
        XCTAssertFalse(quits.isPending)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(open.isReleased)
        XCTAssertFalse(quits.isReleased)
    }
}
