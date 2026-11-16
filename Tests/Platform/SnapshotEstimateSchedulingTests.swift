import Foundation
import XCTest
@testable import MacSpacePlatform

final class SnapshotEstimateSchedulingTests: XCTestCase {
    func testTargetedEstimateCanArriveAfterTheBroadRequestAndStillRunFirst() async {
        let scheduling = SnapshotEstimateScheduling(coalescingWindow: .milliseconds(100), maximumWait: .seconds(3))
        let targetedStarted = expectation(description: "Targeted read started")
        let broadStarted = DispatchSemaphore(value: 0)
        let releaseTargeted = DispatchSemaphore(value: 0)
        let broad = Task.detached {
            scheduling.broad {
                broadStarted.signal()
                return 9
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while scheduling.pendingBroadReads == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(scheduling.pendingBroadReads, 1)
        let targeted = Task.detached {
            scheduling.targeted {
                targetedStarted.fulfill()
                _ = releaseTargeted.wait(timeout: .now() + 3)
                return 7
            }
        }
        await fulfillment(of: [targetedStarted], timeout: 2)
        XCTAssertEqual(broadStarted.wait(timeout: .now() + .milliseconds(150)), .timedOut)
        releaseTargeted.signal()
        XCTAssertEqual(broadStarted.wait(timeout: .now() + 2), .success)
        let actualTargeted = await targeted.value
        let actualBroad = await broad.value
        XCTAssertEqual(actualTargeted, 7)
        XCTAssertEqual(actualBroad, 9)
        XCTAssertEqual(scheduling.pendingBroadReads, 0)
    }

    func testSlowTargetedQueryDoesNotBlockBroadReadOrRetainExpiredWaiter() async {
        let scheduling = SnapshotEstimateScheduling(coalescingWindow: .milliseconds(1), maximumWait: .milliseconds(20))
        let started = expectation(description: "Targeted read started")
        let release = DispatchSemaphore(value: 0)
        let targeted = Task.detached {
            scheduling.targeted {
                started.fulfill()
                _ = release.wait(timeout: .now() + 3)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(scheduling.broad { 11 }, 11)
        XCTAssertEqual(scheduling.pendingBroadReads, 0)
        release.signal()
        await targeted.value
        XCTAssertEqual(scheduling.broad { 12 }, 12, "Each read executes independently, including after a timeout")
    }
}
