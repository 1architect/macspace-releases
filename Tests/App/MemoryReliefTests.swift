import XCTest
@testable import MacSpaceApp

private final class ReliefCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@MainActor
final class MemoryReliefTests: XCTestCase {
    func testGivesMemoryBackOnceAfterTheDelay() async throws {
        let count = ReliefCount()
        let relief = MemoryRelief(delay: .milliseconds(50), busyRetry: .milliseconds(20)) { count.add() }
        relief.schedule { false }
        relief.schedule { false }
        XCTAssertEqual(count.count, 0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(count.count, 1)
        XCTAssertFalse(relief.isPending)
    }

    func testAWindowBackFirstCallsItOff() async throws {
        let count = ReliefCount()
        let relief = MemoryRelief(delay: .milliseconds(100), busyRetry: .milliseconds(20)) { count.add() }
        relief.schedule { false }
        try await Task.sleep(for: .milliseconds(20))
        relief.cancel()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(count.count, 0)
    }

    func testWaitsForModulesStillWorking() async throws {
        let count = ReliefCount()
        var busy = true
        let relief = MemoryRelief(delay: .milliseconds(20), busyRetry: .milliseconds(20)) { count.add() }
        relief.schedule { busy }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count.count, 0)
        XCTAssertTrue(relief.isPending)
        busy = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(count.count, 1)
    }
}
