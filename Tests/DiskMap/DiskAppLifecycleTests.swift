import Foundation
import XCTest
@testable import MacSpaceDiskMap

@MainActor
final class DiskAppLifecycleTests: DiskSecurityFixtureCase {
    func testNormalQuitWaitsForMainAndEmbeddedAppsAndPreservesOtherInstallations() async {
        let path = "/Applications/Example.app"
        var running = [DiskAppLifecycle.Running(pid: 1, bundlePath: path, executablePath: path + "/Contents/MacOS/App"),
                       .init(pid: 2, bundlePath: path + "/Contents/Helpers/Helper.app", executablePath: nil),
                       .init(pid: 3, bundlePath: "/Other/Example.app", executablePath: nil),
                       .init(pid: 4, bundlePath: path + " Copy", executablePath: nil)]
        var terminated: [pid_t] = [], waited = false
        let client = DiskAppLifecycle.Client(running: { running }, terminate: { terminated.append($0.pid); return true }, pause: {
            waited = true; running.removeAll { terminated.contains($0.pid) }
        })
        let result = await DiskAppLifecycle.quit([path], client: client)
        XCTAssertTrue(result); XCTAssertTrue(waited)
        XCTAssertEqual(terminated, [1, 2])
        XCTAssertEqual(running.map(\.pid), [3, 4])
    }

    func testCancelledSaveOrUnresponsiveAppPreventsUninstallWithoutForceQuit() async {
        let app = DiskAppLifecycle.Running(pid: 1, bundlePath: "/Applications/Example.app", executablePath: nil)
        var attempts = 0
        let cancelled = DiskAppLifecycle.Client(running: { [app] }, terminate: { _ in attempts += 1; return false })
        let refused = await DiskAppLifecycle.quit([app.bundlePath!], client: cancelled)
        XCTAssertFalse(refused); XCTAssertEqual(attempts, 1)
        var now = Date()
        let busy = DiskAppLifecycle.Client(running: { [app] }, terminate: { _ in true }, pause: { now.addTimeInterval(31) }, now: { now })
        let timedOut = await DiskAppLifecycle.quit([app.bundlePath!], client: busy)
        XCTAssertFalse(timedOut)
    }
}
