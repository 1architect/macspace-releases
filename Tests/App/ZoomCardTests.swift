import SwiftUI
import XCTest
import MacSpaceSdk
@testable import MacSpaceApp

final class ZoomMathTests: XCTestCase {
    func testRampIsFlatOutsideItsRangeAndMonotonicInside() {
        XCTAssertEqual(ZoomMath.ramp(0, 0.2, 0.7), 0)
        XCTAssertEqual(ZoomMath.ramp(1, 0.2, 0.7), 1)
        XCTAssertEqual(ZoomMath.ramp(0.45, 0.2, 0.7), 0.5, accuracy: 0.0001)
        XCTAssertLessThan(ZoomMath.ramp(0.3, 0.2, 0.7), ZoomMath.ramp(0.5, 0.2, 0.7))
    }

    func testRectInterpolatesFromTileToWindow() {
        let tile = CGRect(x: 100, y: 200, width: 400, height: 300)
        let window = CGRect(x: 0, y: 0, width: 1000, height: 700)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 0), tile)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 1), window)
        XCTAssertEqual(ZoomMath.rect(from: tile, to: window, progress: 0.5), CGRect(x: 50, y: 100, width: 700, height: 500))
    }
}

final class BentoTests: XCTestCase {
    func testTheSketchedDashboardPacksIntoTwoFullRowsOfThree() {
        // Storage, System Data (wide), Debloat, Siri, Settings.
        let placements = Bento.pack(spans: [1, 2, 1, 1, 1], columns: 3)
        XCTAssertEqual(placements, [
            .init(row: 0, column: 0, span: 1), .init(row: 0, column: 1, span: 2),
            .init(row: 1, column: 0, span: 1), .init(row: 1, column: 1, span: 1), .init(row: 1, column: 2, span: 1),
        ])
        XCTAssertEqual(Bento.rows(placements), 2)
    }

    func testAWideTileThatDoesNotFitMovesDownAndSmallTilesFillTheGap() {
        let placements = Bento.pack(spans: [1, 2, 1, 1, 1], columns: 2)
        XCTAssertEqual(placements, [
            .init(row: 0, column: 0, span: 1), .init(row: 1, column: 0, span: 2),
            .init(row: 0, column: 1, span: 1), .init(row: 2, column: 0, span: 1), .init(row: 2, column: 1, span: 1),
        ])
    }

    func testTheLastTileOfAShortRowStretchesToTheEdge() {
        let placements = Bento.pack(spans: [1, 2, 1, 1], columns: 3)
        XCTAssertEqual(placements[3], .init(row: 1, column: 1, span: 2))
    }

    func testFramesShareTheSpaceWithTheSpacingBetween() {
        let size = CGSize(width: 314, height: 214)
        XCTAssertEqual(Bento.frame(.init(row: 0, column: 0, span: 1), columns: 3, rows: 2, in: size, spacing: 7), CGRect(x: 0, y: 0, width: 100, height: 103.5))
        XCTAssertEqual(Bento.frame(.init(row: 1, column: 1, span: 2), columns: 3, rows: 2, in: size, spacing: 7), CGRect(x: 107, y: 110.5, width: 207, height: 103.5))
    }
}
