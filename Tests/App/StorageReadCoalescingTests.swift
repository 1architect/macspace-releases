import XCTest
@testable import MacSpaceApp

private final class CapacityReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var reads = 0
    var count: Int { lock.withLock { reads } }
    func read() -> (UInt64?, UInt64?) {
        let first = lock.withLock { reads += 1; return reads == 1 }
        if first { _ = gate.wait(timeout: .now() + 5) }
        return (40, 100)
    }
    func release() { gate.signal() }
}

@MainActor
final class StorageReadCoalescingTests: XCTestCase {
    func testConcurrentCapacityRequestsShareOneReadAndLaterRequestsCanRefresh() async throws {
        let control = CapacityReadControl(), overview = StorageOverview(readCapacity: { control.read() })
        defer { control.release() }
        let tasks = (0..<20).map { _ in Task { await overview.refresh() } }
        for _ in 0..<100 where control.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(control.count, 1)
        control.release()
        for task in tasks { await task.value }
        XCTAssertEqual(control.count, 1)
        XCTAssertEqual(overview.usedBytes, 40)
        XCTAssertEqual(overview.totalBytes, 100)
        await overview.refresh()
        XCTAssertEqual(control.count, 2)
    }
}
