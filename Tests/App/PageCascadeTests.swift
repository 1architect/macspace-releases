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

    func testRemovingACleanupRowHoldsTheGapUntilItsReverseCascadeFinishes() {
        let old = PageCascade.Structure(ids: ["free:header", "caches", "log", "content:header", "other"], offset: 9, count: 14)
        let next = PageCascade.Structure(ids: old.ids.filter { $0 != "log" }, offset: 9, count: 13)
        let completion = PageCascade.delay(index: old.offset + 2, count: old.count, visible: false) + PageCascade.duration
        XCTAssertEqual(PageCascade.layoutDelay(from: old, to: next), completion, accuracy: 0.00001,
                       "later sections must not close the row's space before its delayed departure")
    }

    func testSeveralRemovalsWaitForTheLastDepartureUsingTheOriginalWholePageOrder() {
        let old = PageCascade.Structure(ids: (0..<30).map(String.init), offset: 12, count: 42)
        let next = PageCascade.Structure(ids: old.ids.filter { !["2", "11", "20"].contains($0) }, offset: 10, count: 37)
        let completions = [2, 11, 20].map {
            PageCascade.delay(index: old.offset + $0, count: old.count, visible: false) + PageCascade.duration
        }
        XCTAssertEqual(PageCascade.layoutDelay(from: old, to: next), completions.max()!, accuracy: 0.00001)
    }

    func testOnlyDeparturesDelayStructuralLayoutNotInitialLoadNumbersOrInsertions() {
        let first = PageCascade.Structure(ids: ["header", "one"])
        XCTAssertEqual(PageCascade.layoutDelay(from: nil, to: first), 0)
        XCTAssertEqual(PageCascade.layoutDelay(from: first, to: first), 0)
        XCTAssertEqual(PageCascade.layoutDelay(from: first, to: .init(ids: ["header", "one", "two"])), 0)
        XCTAssertEqual(PageCascade.layoutDelay(from: first, to: .init(ids: ["one", "header"])), 0)
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
