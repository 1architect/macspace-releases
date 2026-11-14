import Darwin
import Foundation
import XCTest
@testable import MacSpacePlatform

final class LoadWorkPriorityTests: XCTestCase {
    func testForegroundAndBackgroundTaskPrioritiesRemainDistinct() {
        XCTAssertEqual(LoadWorkPriority.qos(for: .userInitiated), .userInitiated)
        XCTAssertEqual(LoadWorkPriority.qos(for: .medium), .default)
        XCTAssertEqual(LoadWorkPriority.qos(for: .utility), .utility)
        XCTAssertEqual(LoadWorkPriority.qos(for: .background), .background)
    }

    func testNestedDirectoryWorkersInheritTheirQueueRatherThanAlwaysUsingUtility() {
        for qos in [DispatchQoS.QoSClass.userInitiated, .utility, .background] {
            let complete = expectation(description: "Priority \(qos)")
            DispatchQueue.global(qos: qos).async {
                XCTAssertEqual(LoadWorkPriority.current, qos)
                complete.fulfill()
            }
            wait(for: [complete], timeout: 3)
        }
    }

    func testSharedReaderStartsAtTheRequestPriorityIncludingBackgroundRequests() async {
        for priority in [TaskPriority.userInitiated, .medium, .utility, .background] {
            let done = expectation(description: "Reader priority \(priority)")
            let reading = SharedReading<TaskPriority> { _ in
                XCTAssertEqual(LoadWorkPriority.current, LoadWorkPriority.qos(for: priority))
                return Task.currentPriority
            }
            let task = Task.detached(priority: priority) {
                let actual = await reading.value(maxAge: 60)
                XCTAssertEqual(actual, priority)
                done.fulfill()
            }
            // Waiting on the expectation instead of task.value avoids accidentally escalating the background task.
            await fulfillment(of: [done], timeout: 3)
            await task.value
        }
    }
}
