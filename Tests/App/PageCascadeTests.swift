import XCTest
@testable import MacSpaceApp

final class PageCascadeTests: XCTestCase {
    func testArrivalRunsDownAndDepartureRunsUpAcrossTheWholePage() {
        let count = 30
        let down = (0..<count).map { PageCascade.delay(index: $0, count: count, visible: true) }
        let up = (0..<count).map { PageCascade.delay(index: $0, count: count, visible: false) }
        XCTAssertEqual(down, down.sorted())
        XCTAssertEqual(up, up.sorted(by: >))
        XCTAssertEqual(down.first, 0)
        XCTAssertEqual(up.last, 0)
        XCTAssertEqual(Set(down).count, count, "every item has its own place; late items do not all animate at once")
        XCTAssertLessThanOrEqual(down.last!, 0.6)
    }
}

@MainActor
final class PageDetailsVisibilityTests: XCTestCase {
    func testFastRefreshWaitsForTheDepartureBeforeRevealing() async throws {
        let state = PageDetailsVisibility(departure: .milliseconds(80))
        state.update(busy: true)
        state.update(busy: false)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(state.visible)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.visible)
    }

    func testAnotherRefreshCancelsAPendingReveal() async throws {
        let state = PageDetailsVisibility(departure: .milliseconds(50))
        state.update(busy: true)
        state.update(busy: false)
        state.update(busy: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(state.visible)
        state.cancel()
    }
}
