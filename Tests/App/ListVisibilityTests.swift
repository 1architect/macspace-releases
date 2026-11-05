import XCTest
@testable import MacSpaceApp

@MainActor
final class ListVisibilityTests: XCTestCase {
    func testInitialMountUsesHiddenRowsThenSharedCascadeAndStartsAtTheFirstLine() async {
        let state = ListVisibility()
        state.update(shown: true, rowCount: 4)
        XCTAssertTrue(state.expanded)
        XCTAssertFalse(state.visible, "The shade must start closed, even for prepared navigation pages")
        for _ in 0..<100 where !state.visible { await Task.yield() }
        XCTAssertTrue(state.visible)
        let timing = PageCascade.listStructure(["a", "b", "c", "d"])
        XCTAssertEqual(timing.offset, 0)
        XCTAssertEqual(PageCascade.delay(index: timing.offset, count: timing.count, visible: true), 0)
        XCTAssertEqual(PageCascade.listSpan(rowCount: 4), 0.325, accuracy: 0.00001)
        state.cancel()
    }

    func testRapidReopenIsImmediateAndCancelsThePendingCollapse() async throws {
        let state = ListVisibility()
        state.update(shown: true, rowCount: 10)
        for _ in 0..<100 where !state.visible { await Task.yield() }
        state.update(shown: false, rowCount: 10)
        XCTAssertFalse(state.visible)
        XCTAssertTrue(state.expanded, "Keep the space while individual rows depart")
        state.update(shown: true, rowCount: 10)
        XCTAssertTrue(state.visible, "Reopening must not wait for departure or a timer")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(state.visible); XCTAssertTrue(state.expanded)
        state.cancel()
    }

    func testEachAppsListUsesTheSameLocalTimingRegardlessOfPagePosition() {
        let first = PageCascade.listStructure(["first:cache", "first:support", "first:preferences"])
        let last = PageCascade.listStructure(["last:cache", "last:support", "last:preferences"])
        for n in first.ids.indices {
            XCTAssertEqual(PageCascade.delay(index: first.offset + n, count: first.count, visible: true),
                           PageCascade.delay(index: last.offset + n, count: last.count, visible: true))
        }
        let reduced = ListVisibility()
        reduced.update(shown: true, rowCount: 10, reduceMotion: true)
        XCTAssertTrue(reduced.visible)
        reduced.update(shown: false, rowCount: 10, reduceMotion: true)
        XCTAssertFalse(reduced.expanded)
    }
}
