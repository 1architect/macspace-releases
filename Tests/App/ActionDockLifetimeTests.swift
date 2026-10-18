import XCTest
@testable import MacSpaceApp

@MainActor
final class ActionDockLifetimeTests: XCTestCase {
    func testFooterStaysReservedUntilTheActualDepartureCompletes() {
        let state = ActionDockLifetime()
        _ = state.update(shown: true)
        let removal = state.update(shown: false)
        XCTAssertTrue(state.reservesSpace, "removing an action cannot collapse the footer while it is still fading")
        state.finishDeparture(removal)
        XCTAssertFalse(state.reservesSpace)
    }

    func testNewLoadingPhaseSupersedesAnOlderDepartureCompletion() {
        let state = ActionDockLifetime()
        _ = state.update(shown: true)
        let old = state.update(shown: false)
        _ = state.update(shown: true)
        state.finishDeparture(old)
        XCTAssertTrue(state.reservesSpace, "a reload that begins during departure keeps the footer")
        let latest = state.update(shown: false)
        state.finishDeparture(latest)
        XCTAssertFalse(state.reservesSpace)
    }

    func testClosingThePageCancelsPendingDeparture() {
        let state = ActionDockLifetime()
        _ = state.update(shown: true)
        let old = state.update(shown: false)
        state.cancel()
        _ = state.update(shown: true)
        state.finishDeparture(old)
        XCTAssertTrue(state.reservesSpace)
    }
}
