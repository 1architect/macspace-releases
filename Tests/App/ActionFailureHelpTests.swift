import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

@MainActor
final class ActionFailureHelpTests: XCTestCase {
    func testFailurePillExposesTheUnderlyingReasonAndCompletePath() {
        let detail = "/Users/example/Documents/Folder/dosdevices/z:: Unsafe file type"
        let result = ActionResult(outcome: .needsAttention, message: "Couldn’t delete the folder", details: [detail])
        let pill = ActionPill(phase: .done(result), maximumWidth: 200, dismiss: {}, run: { _ in })
        XCTAssertEqual(pill.helpText, "Couldn’t delete the folder\n" + detail)
        let ordinary = ActionPill(phase: .idle(Action(id: "free", title: "Free")), maximumWidth: nil, dismiss: {}, run: { _ in })
        XCTAssertEqual(ordinary.helpText, "Free")
    }
}
