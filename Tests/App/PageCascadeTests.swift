import XCTest
import Combine
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
        let revealed = expectation(description: "Page details return after the departure")
        let observation = state.$visible.dropFirst().filter { $0 }.sink { _ in revealed.fulfill() }
        defer { observation.cancel() }
        let started = ContinuousClock.now
        state.update(busy: true)
        state.update(busy: false)
        XCTAssertFalse(state.visible)
        await fulfillment(of: [revealed], timeout: 5)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(80))
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
