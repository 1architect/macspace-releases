import XCTest
@testable import MacSpaceApp

final class RowFlagPlacementTests: XCTestCase {
    /// A figure on the right keeps the right edge and the flag stands after the title; with none, the flag takes the right edge.
    func testTheFlagGoesAfterTheTitleOnlyWhenTheRowHasAFigureOnTheRight() {
        XCTAssertEqual(RowFlagPlacement.for(hasTrailingFigure: true), .afterTitle)
        XCTAssertEqual(RowFlagPlacement.for(hasTrailingFigure: false), .trailing)
    }
}
