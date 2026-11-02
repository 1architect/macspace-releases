import XCTest
@testable import MacSpaceApp

final class RowFlagPlacementTests: XCTestCase {
    /// The action stays attached to the right, before the size when present.
    func testTheFlagStaysAtTheRightBeforeTheFigure() {
        XCTAssertEqual(RowFlagPlacement.for(hasTrailingFigure: true), .beforeFigure)
        XCTAssertEqual(RowFlagPlacement.for(hasTrailingFigure: false), .trailing)
    }
}
