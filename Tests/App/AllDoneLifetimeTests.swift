import XCTest
@testable import MacSpaceApp

@MainActor
final class AllDoneLifetimeTests: XCTestCase {
    func testBackDismissesCompletionWhileReloadIsStillRunning() async throws {
        let state = AllDoneLifetime()
        var finished = 0
        state.reloading = true
        state.present(hold: .milliseconds(1)) { finished += 1 }
        XCTAssertTrue(state.shown)
        try await Task.sleep(for: .milliseconds(10))
        state.dismiss() // Back, changing group or closing the tile.
        state.reloading = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(state.shown)
        XCTAssertEqual(finished, 0)
    }

    func testCancelledCompletionCannotDismissANewerCompletion() async throws {
        let state = AllDoneLifetime()
        var finished = 0
        state.present(hold: .milliseconds(10)) { finished += 1 }
        state.dismiss()
        state.present(hold: .seconds(10)) { finished += 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.shown)
        XCTAssertEqual(finished, 0)
        state.dismiss()
    }

    func testCountdownStartsOnlyAfterTheReloadAndThenReturns() async throws {
        let state = AllDoneLifetime()
        var finished = 0
        state.reloading = true
        state.present(hold: .milliseconds(1), countdown: .milliseconds(150)) { finished += 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(state.countingDown, "the countdown waits for the module's new figures")
        state.reloading = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(state.countingDown)
        XCTAssertEqual(finished, 0, "a finished reload no longer returns at once")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(state.shown)
    }
}
