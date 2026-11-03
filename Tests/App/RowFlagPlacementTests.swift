import XCTest
@testable import MacSpaceApp

final class RowFlagPlacementTests: XCTestCase {
    /// Public release v1.1.5 places the action after the title cluster when a size is present.
    func testTheFlagMatchesPublicReleaseAfterTheTitleCluster() {
        XCTAssertEqual(RowFlagPlacement.for(hasTrailingFigure: true), .afterTitle)
        XCTAssertEqual(RowFlagPlacement.for(hasTrailingFigure: false), .trailing)
    }
}
