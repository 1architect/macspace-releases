import XCTest
@testable import MacSpaceApp

@MainActor
final class CoveredGraphLifetimeTests: XCTestCase {
    func testCoverReleasesDrawingOnlyAfterCurrentTransitionAndBackRestoresIt() {
        let state = CoveredGraphLifetime(covered: false)
        let token = state.token(for: true)
        state.update(covered: true)
        XCTAssertTrue(state.draws)
        state.finishCover(token)
        XCTAssertFalse(state.draws)
        state.update(covered: false)
        XCTAssertTrue(state.draws)
    }
    func testInterruptedCoverCannotHideThePageBeingRevealed() {
        let state = CoveredGraphLifetime(covered: false)
        let token = state.token(for: true)
        state.update(covered: true); state.update(covered: false)
        state.finishCover(token)
        XCTAssertTrue(state.draws)
        XCTAssertFalse(CoveredGraphLifetime(covered: true).draws)
    }
}
